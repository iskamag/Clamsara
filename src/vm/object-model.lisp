;;;; vm/object-model.lisp -- the object model and metadata-location dispatch
;;;; (paper-v8 ch. memory).  Collector code is written against the LOGICAL
;;;; accessors (vm-object-is-marked-p, ...); each resolves to the declared
;;;; location (side / in-header / in-pointer / off-heap) at run time.  Moving
;;;; forwarding from in-header to an off-heap table changes only the location
;;;; declaration, never the marking code.

(in-package #:clamsara)

;; ---- header packing (simulator: one 64-bit word) -------------------------
;; size(24) | type-tag(8) | gc-flags(16) | spare(16).  bit 63 = STW fwd tag.

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
  (:documentation "Is ADDRESS a headerless cons cell?  Default no.")
  (:method ((vm vm-binding) address) (declare (ignore address)) nil))

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
      (loop for k below n do (setf (ref-u64 vm (+ dst k)) (ref-u64 vm (+ src k)))))
    (let ((os (vm-object-start vm)))
      (when os (s-set-bit os dst)))
    ;; preserve age + public bit (mark starts fresh)
    (let ((age (vm-stratum vm :age)) (pub (vm-stratum vm :public)))
      (when age (s-set age dst (s-get age src)))
      (when pub (when (s-test-bit pub src) (s-set-bit pub dst))))))

(defgeneric vm-scan-object-references (vm address fn)
  (:documentation "Invoke FN on each reference slot of the object at ADDRESS.")
  (:method ((vm vm-binding) address fn)
    (let ((n (vm-object-reference-count vm address)))
      (dotimes (i n)
        (let ((r (vm-object-reference vm address i)))
          (unless (null-ref-p r) (funcall fn r)))))))

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
  (if (typep vm 'coloured-pointer-mixin) (ref-strip vm r) r))

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
    (:in-pointer (setf (ref-colour vm reference) (if new (vm-mark-colour vm) (vm-good-colour vm))))
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
  (gethash address (vm-rc-table vm) 0))
(defmethod (setf vm-object-rc) (n (vm vm-binding) address)
  (setf (gethash address (vm-rc-table vm)) n))

;; forwarding (in-header STW, or off-heap concurrent) ---
(defmethod vm-object-is-forwarded-p ((vm vm-binding) address)
  (ecase (vm-location vm :forwarding)
    (:in-header (header-forwarded-p (vm-object-header vm address)))
    (:off-heap  (nth-value 1 (gethash address (vm-fwd-table vm))))))
(defmethod vm-object-forwarding-pointer ((vm vm-binding) address)
  (ecase (vm-location vm :forwarding)
    (:in-header (forwarding-address (vm-object-header vm address)))
    (:off-heap  (gethash address (vm-fwd-table vm)))))
(defmethod (setf vm-object-forwarding-pointer) (dst (vm vm-binding) address)
  (ecase (vm-location vm :forwarding)
    (:in-header (setf (vm-object-header vm address) (make-forwarding-header dst)))
    (:off-heap  (setf (gethash address (vm-fwd-table vm)) dst))))

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

(defun vm-write-header (vm address type-tag slot-count)
  "Write a header at ADDRESS and mark the object-start bit.  Returns ADDRESS."
  (setf (ref-u64 vm address) (pack-header slot-count type-tag))
  (let ((os (vm-object-start vm)))
    (when os (s-set-bit os address)))
  address)
