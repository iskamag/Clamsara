;;;; vm/object-model.lisp -- the object model and metadata-location dispatch
;;;; (paper-v8 ch. memory).  Collector code is written against the LOGICAL
;;;; accessors (vm-object-is-marked-p, ...); each resolves to the declared
;;;; location (side / in-header / in-pointer / off-heap) at run time.  Moving
;;;; forwarding from in-header to an off-heap table changes only the location
;;;; declaration, never the marking code.

(in-package #:clamsara)

;; ---- header packing (simulator: one 64-bit word) -------------------------
;; size(24) | type-tag(8) | gc-flags(16) | spare(16). The simulator reserves
;; fixnum bit 61 as the STW forwarding tag (see types.lisp).

(declaim (inline pack-header header-size header-tag header-gc-flags header-spare))
(defun pack-header (size tag &optional (gc-flags 0) (spare 0))
  (logior (ldb (byte 24 0) size) (ash (ldb (byte 8 0) tag) 24)
          (ash (ldb (byte 16 0) gc-flags) 32) (ash (ldb (byte 16 0) spare) 48)))
(defun header-size (h) (ldb (byte 24 0) h))
(defun header-tag (h) (ldb (byte 8 24) h))
(defun header-gc-flags (h) (ldb (byte 16 32) h))
(defun header-spare (h) (ldb (byte 16 48) h))

(defparameter *promotion-age* 1)

;; ---- cons detection (headerless cells in a cons-space) ------------------

(defgeneric vm-address-cons-p (vm address)
  (:documentation "Is ADDRESS a headerless cons cell?  The VM binding method
returns true only for addresses in the plan's configured cons-space."))

;; ---- object model protocol ----------------------------------------------

(defgeneric vm-object-header (vm address)
  (:method ((vm vm-binding) address) (ref-u64 vm address)))
(defgeneric (setf vm-object-header) (new vm address)
  (:method (new (vm vm-binding) address) (setf (ref-u64 vm address) new)))

(defgeneric vm-object-total-words (vm address)
  (:method ((vm vm-binding) address)
    (if (vm-address-cons-p vm address)
        2
        (1+ (header-size (vm-object-header vm address))))))

(defgeneric vm-object-reference-count (vm address)
  (:method ((vm vm-binding) address)
    (if (vm-address-cons-p vm address) 2 (header-size (vm-object-header vm address)))))

(defgeneric vm-object-type-tag (vm address)
  (:method ((vm vm-binding) address)
    (if (vm-address-cons-p vm address) +tag-cons+ (header-tag (vm-object-header vm address)))))

(defgeneric vm-object-reference (vm address slot)
  (:method ((vm vm-binding) address slot)
    (if (vm-address-cons-p vm address)
        (ref-u64 vm (+ address slot))
        (ref-u64 vm (+ address 1 slot)))))
(defgeneric (setf vm-object-reference) (new vm address slot)
  (:method (new (vm vm-binding) address slot)
    (if (vm-address-cons-p vm address)
        (setf (ref-u64 vm (+ address slot)) new)
        (setf (ref-u64 vm (+ address 1 slot)) new))))

(defun vm-set-reference (vm address slot value)
  "Collector-internal store: bypasses the write barrier."
  (setf (vm-object-reference vm address slot) value))

(defgeneric vm-object-has-children-p (vm address)
  (:method ((vm vm-binding) address)
    (plusp (vm-object-reference-count vm address))))

(defgeneric vm-object-start-p (vm address)
  (:method ((vm vm-binding) address)
    (let ((os (vm-object-start vm)))
      (if os (s-test-bit os address) t))))

(defgeneric vm-object-copy (vm src dst)
  (:documentation "Copy payload words and preserve relocatable side metadata.")
  (:method ((vm vm-binding) src dst)
    (let ((n (vm-object-total-words vm src)))
      ;; Object-copy is the common relocation/publication seam.  Count both
      ;; units here so every collector path (including publication and
      ;; compaction) reports the same event, without allocating per object.
      (let ((stats (%stats-for-vm vm)))
        (when stats
          (stats-event stats :objects-copied 1)
          (stats-event stats :words-copied n)))
      (loop for k below n do (setf (ref-u64 vm (+ dst k)) (ref-u64 vm (+ src k)))))
    (let ((os (vm-object-start vm)))
      (when os (s-set-bit os dst)))
    ;; Preserve side metadata so identity survives relocation: mark, age,
    ;; public, log, and the weak-pointer bit (weak.tex: a weak pointer that
    ;; loses its bit on copy silently becomes a strong pointer, keeping a dead
    ;; referent alive forever).  A copy of a live (marked) object is itself
    ;; live, so the mark bit is carried too; callers that want a fresh mark
    ;; (copy-space tracing an unmarked source) are unaffected because the
    ;; source is unmarked there.
    (let ((age (vm-stratum vm :age)) (pub (vm-stratum vm :public))
          (mark (vm-stratum vm :mark)) (log (vm-stratum vm :log))
          (weak (vm-stratum vm :weak)))
      (when age (s-set age dst (s-get age src)))
      (when pub (when (s-test-bit pub src) (s-set-bit pub dst)))
      (when mark (when (s-test-bit mark src) (s-set-bit mark dst)))
      (when log (when (s-test-bit log src) (s-set-bit log dst)))
      (when weak (when (s-test-bit weak src) (s-set-bit weak dst))))))

(defgeneric vm-scan-object-references (vm address fn)
  (:documentation "Invoke FN on each reference slot of the object at ADDRESS.")
  (:method ((vm vm-binding) address fn)
    (vm-map-reference-slots vm address fn)))

(defun vm-map-reference-slots (vm address fn)
  "Invoke FN on each reference-bearing slot of the object at ADDRESS, per the
  declared per-type layout (memory.tex §3); NIL layout means conservative
  scanning (every payload slot).  Weak pointers (weak.tex §1) have their
  referent slot 0 excluded from normal tracing; the weak phase processes it.
  Returns ADDRESS."
  (let ((slots (vm-reference-slots vm address))
        (weak-p (weak-pointer-p vm address)))
    (flet ((visit (i)
             (when (or (not weak-p) (not (zerop i)))
               (let ((r (vm-object-reference vm address i)))
                 (unless (null-ref-p r) (funcall fn r))))))
      (if slots
          (loop for i across slots do (visit i))
          (dotimes (i (vm-object-reference-count vm address)) (visit i)))))
  address)

(defun vm-heal-reference-slots (vm address fwd-table)
  "Writeback-heal every reference slot of the object at ADDRESS through
  FWD-TABLE (a dense from->to table).  Top-level with explicit state, so the
  collection path never constructs a host closure per object.  Returns
  ADDRESS."
  (let ((slots (vm-reference-slots vm address)))
    (flet ((heal-slot (i)
      (let ((child (vm-object-reference vm address i)))
               ;; A moving collector may clear the old object's identity
               ;; before this pass (Claimore OVC does so to make stale reads
               ;; fail).  The forwarding table is then the authoritative
               ;; proof that this particular in-heap word was a moved object;
               ;; requiring VM-REFERENCE-P here would skip the edge we must
               ;; heal.  Raw words are still untouched unless they name an
               ;; active forwarding entry.
               (when (and (vm-valid-reference-p vm child)
                          (< (ref-strip-or-self vm child)
                             (length fwd-table)))
                 (let* ((bare (ref-strip-or-self vm child))
                        (destination (aref fwd-table bare)))
                   (when (plusp destination)
                     (setf (vm-object-reference vm address i)
                           destination)))))))
      (if slots
          (loop for i across slots do (heal-slot i))
          (dotimes (i (vm-object-reference-count vm address)) (heal-slot i))))
    address))

(defun vm-valid-reference-p (vm reference)
  (and (integerp reference) (plusp reference)
       (< (ref-strip-or-self vm reference) (vm-heap-size vm))))

(defun vm-reference-p (vm value)
  "Conservative pointer identification: VALUE is a live reference iff it is a
  positive in-heap object start.  A real VM uses type tags; the simulator,
  lacking them, treats any non-object-start word as raw data (skipped)."
  (let ((addr (ref-strip-or-self vm value)))
    (and (integerp addr) (plusp addr)
         (< addr (vm-heap-size vm))
         (vm-object-start-p vm addr))))
(declaim (inline ref-strip-or-self))
(defun ref-strip-or-self (vm r)
  (if (and (integerp r) (typep vm 'coloured-pointer-mixin))
      (ref-strip vm r)
      r))

;; ---- logical metadata accessors (Axis 2: location dispatch) --------------
;; Each datum resolves to its location; the marking code is unchanged by it.

(defgeneric vm-object-is-marked-p (vm reference))
(defgeneric (setf vm-object-is-marked-p) (new vm reference))
(defgeneric vm-object-is-logged-p (vm address))
(defgeneric (setf vm-object-is-logged-p) (new vm address))
(defgeneric vm-object-is-public-p (vm address))
(defgeneric (setf vm-object-is-public-p) (new vm address))
(defgeneric vm-object-age (vm address))
(defgeneric (setf vm-object-age) (age vm address))
(defgeneric vm-object-rc (vm address))
(defgeneric (setf vm-object-rc) (n vm address))
(defgeneric vm-object-is-forwarded-p (vm address))
(defgeneric vm-object-forwarding-pointer (vm address))
(defgeneric (setf vm-object-forwarding-pointer) (dst vm address))

;; mark ---
(defmethod vm-object-is-marked-p ((vm vm-binding) reference)
  (ecase (vm-location vm :mark)
    (:side      (let ((s (vm-stratum vm :mark))) (and s (s-test-bit s (ref-strip-or-self vm reference)))))
    (:in-pointer (eql (ref-colour vm reference) (vm-mark-colour vm)))
    (:in-header  (logbitp 0 (header-gc-flags (vm-object-header vm reference))))))
(defmethod (setf vm-object-is-marked-p) (new (vm vm-binding) reference)
  (ecase (vm-location vm :mark)
    (:side      (let ((s (vm-stratum vm :mark)))
                 (if new (s-set-bit s (ref-strip-or-self vm reference))
                         (s-clear-bit s (ref-strip-or-self vm reference)))))
    (:in-pointer (ref-set-colour vm reference
                                 (if new (vm-mark-colour vm)
                                     (vm-good-colour vm))))
    (:in-header  (let ((h (vm-object-header vm reference)))
                  (setf (vm-object-header vm reference)
                        (dpb (if new 1 0) (byte 1 0) (header-gc-flags h)))))))

;; log / public / age (side strata) ---
(defmethod vm-object-is-logged-p ((vm vm-binding) address)
  (let ((s (vm-stratum vm :log))) (and s (s-test-bit s address))))
(defmethod (setf vm-object-is-logged-p) (new (vm vm-binding) address)
  (let ((s (vm-stratum vm :log))) (if new (s-set-bit s address) (s-clear-bit s address))))
(defmethod vm-object-is-public-p ((vm vm-binding) address)
  (let ((s (vm-stratum vm :public))) (and s (s-test-bit s address))))
(defmethod (setf vm-object-is-public-p) (new (vm vm-binding) address)
  (let ((s (vm-stratum vm :public))) (if new (s-set-bit s address) (s-clear-bit s address))))
(defmethod vm-object-age ((vm vm-binding) address)
  (let ((s (vm-stratum vm :age))) (if s (s-get s address) 0)))
(defmethod (setf vm-object-age) (age (vm vm-binding) address)
  (let ((s (vm-stratum vm :age))) (when s (s-set s address age)) age))

;; reference count (off-heap table) ---
(defmethod vm-object-rc ((vm vm-binding) address)
  (rc-get vm address))
(defmethod (setf vm-object-rc) (n (vm vm-binding) address)
  (rc-set vm address n))

;; forwarding (in-header STW, or off-heap concurrent) ---
(defmethod vm-object-is-forwarded-p ((vm vm-binding) address)
  (ecase (vm-location vm :forwarding)
    (:in-header (header-forwarded-p (vm-object-header vm address)))
    (:off-heap  (fwd-present-p vm address))))
(defmethod vm-object-forwarding-pointer ((vm vm-binding) address)
  (ecase (vm-location vm :forwarding)
    (:in-header (forwarding-address (vm-object-header vm address)))
    (:off-heap  (fwd-get vm address))))
(defmethod (setf vm-object-forwarding-pointer) (dst (vm vm-binding) address)
  (ecase (vm-location vm :forwarding)
    (:in-header (setf (vm-object-header vm address) (make-forwarding-header dst)))
    (:off-heap  (fwd-set vm address dst))))

;; ---- generational discrimination ---------------------------------------

(defgeneric vm-object-young-p (vm reference))
(defgeneric vm-object-old-p (vm reference))

(defmethod vm-object-young-p ((vm vm-binding) reference)
  (let ((addr (ref-strip-or-self vm reference))
        (plan (vm-plan vm)))
    (cond
      ((and plan (plan-nursery plan) (space-contains-p (plan-nursery plan) addr)) t)
      ((vm-stratum vm :log) (not (s-test-bit (vm-stratum vm :log) addr)))
      ((vm-stratum vm :age) (zerop (s-get (vm-stratum vm :age) addr)))
      (t nil))))
(defmethod vm-object-old-p ((vm vm-binding) reference)
  (let ((addr (ref-strip-or-self vm reference)))
    (and (vm-object-start-p vm addr)
         (not (vm-object-young-p vm reference)))))

;; ---- allocation helper (header write + object-start mark) ----------------

(defun vm-write-header (vm address type-tag slot-count &optional (layout-id 0))
  "Write a header at ADDRESS, zero the SLOT-COUNT payload slots, and mark the
  object-start bit.  LAYOUT-ID is stored in the header spare field and defaults
  to zero.  Returns ADDRESS.  Zeroing the payload is required so a first
  barrier-visible store to a fresh slot observes a non-reference: reused heap
  regions hold stale words from their previous occupant."
  (unless (%valid-layout-id-p layout-id)
    (error 'clamsara-error
           :message (format nil "invalid layout id ~s (expected 0..~d)"
                            layout-id (1- +layout-id-limit+))))
  ;; Pass the layout id through PACK-HEADER's spare argument.  This preserves
  ;; the complete spare field (rather than silently dropping it as the old
  ;; four-argument call did) while retaining the existing header bit layout.
  (setf (ref-u64 vm address) (pack-header slot-count type-tag 0 layout-id))
  (dotimes (k slot-count) (setf (ref-u64 vm (+ address 1 k)) 0))
  (let ((os (vm-object-start vm)))
    (when os (s-set-bit os address)))
  address)

(defun vm-forget-object (vm address)
  "Clear object identity and per-object metadata before an address is reused."
  (let ((os (vm-object-start vm)))
    (when os (s-clear-bit os address)))
  (dolist (name '(:mark :log :public :age :weak))
    (let ((s (vm-stratum vm name)))
      (when s (s-set s address (stratum-default s)))))
  (when (and (vm-fwd-table vm) (< address (length (vm-fwd-table vm))))
    (setf (aref (vm-fwd-table vm) address) 0))
  (when (and (vm-rc-table vm) (< address (length (vm-rc-table vm))))
    (setf (aref (vm-rc-table vm) address) 0))
  address)

(defun vm-clear-metadata-range (vm start end)
  "Forget every object and per-object datum in [START, END)."
  (let ((os (vm-object-start vm)))
    (when os (s-clear-range os start end)))
  (dolist (name '(:mark :log :public :age :weak))
    (let ((s (vm-stratum vm name)))
      (when s (s-clear-range s start end))))
  (when (vm-fwd-table vm)
    (fill (vm-fwd-table vm) 0 :start start :end end))
  (when (vm-rc-table vm)
    (fill (vm-rc-table vm) 0 :start start :end end))
  vm)
