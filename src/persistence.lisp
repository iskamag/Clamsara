;;;; persistence.lisp -- persistence as a first-class concern, coupled to the
;;;; allocator and the collector (paper-v8 ch. persistence).

(in-package #:clamsara)

;; ---- the persistent allocator (persistence.tex §3) -----------------------

(defclass persistent-allocator ()
  ((base :initarg :base :reader pa-base)
   (log :initarg :log :accessor allocator-log)
   (vm :initarg :vm :accessor pa-vm)
   (space :initarg :space :accessor pa-space)))

(defmethod alloc ((a persistent-allocator) size &key &allow-other-keys)
  (let ((addr (alloc (pa-base a) size)))
    (when addr
      (plog-record-alloc (allocator-log a) addr size))
    addr))

(defmethod free ((a persistent-allocator) addr size)
  (free (pa-base a) addr size))

(defmethod coalesce ((a persistent-allocator))
  (coalesce (pa-base a)))

(defmethod allocator-reset ((a persistent-allocator))
  (allocator-reset (pa-base a)))

;; ---- the log (persistence.tex §1, §3) ------------------------------------
;;
;; A log has one complete base image and then an ordered list of page deltas.
;; Keeping this state separate from the segment object is important: the first
;; checkpoint must make an image from *all* pages, otherwise replaying a heap
;; with an untouched page would silently turn that page into zeroes.

(defclass persistence-log ()
  ((base-image :accessor plog-base-image :initform nil)
   (base-timestamp :accessor plog-base-timestamp :initform nil)
   (base-checksum :accessor plog-base-checksum :initform nil)
   (segments :accessor plog-segments :initform nil)  ; chronological order
   (allocations :accessor plog-allocations :initform nil)
   (alloc-count :accessor plog-alloc-count :initform 0)))

(defun make-persistence-log ()
  (make-instance 'persistence-log))

;; Friendly names for clients that do not use the historical PLOG prefix.
(defun persistence-log-base-image (log) (plog-base-image log))
(defun persistence-log-base-timestamp (log) (plog-base-timestamp log))
(defun persistence-log-base-checksum (log) (plog-base-checksum log))
(defun persistence-log-segments (log) (plog-segments log))

(defun plog-record-alloc (log addr size)
  "Record an allocation: the base allocator's address/size pair is appended
  to the allocation history so a recovered image can rebuild free state."
  (setf (plog-allocations log)
        (cons (cons addr size) (plog-allocations log)))
  (incf (plog-alloc-count log))
  log)

(defun %heap-image (vm)
  (let ((image (make-array (vm-heap-size vm)
                           :element-type '(unsigned-byte 64)
                           :initial-element 0)))
    (replace image (vm-heap vm))
    image))

(defun %base-image-checksum (image timestamp)
  (let ((sum timestamp))
    (dotimes (i (length image) sum)
      (setf sum (logxor sum (+ (aref image i) i))))))

(defun plog-record-base (log vm timestamp)
  "Capture the complete heap image once, before the first delta segment."
  (unless (plog-base-image log)
    (let ((image (%heap-image vm)))
      (setf (plog-base-image log) image
            (plog-base-timestamp log) timestamp
            (plog-base-checksum log) (%base-image-checksum image timestamp))))
  log)

(defun plog-record-segment (log segment)
  "Append SEGMENT after the base image, preserving checkpoint order."
  (setf (plog-segments log)
        (nconc (plog-segments log) (list segment)))
  log)

;; ---- the segment writer (persistence.tex §1) -----------------------------

(defstruct (persistence-segment (:constructor %make-segment))
  (timestamp 0 :type fixnum)
  (pages nil :type list)   ; sorted page numbers whose contents are recorded
  (images nil :type (or hash-table null)) ; page-index -> frozen word vector
  (checksum 0 :type fixnum))

(defun page-checksum-of-image (words timestamp page-index)
  "A position-dependent fold over a frozen page image."
  (let ((sum timestamp))
    (dotimes (k +page-words+ sum)
      (setf sum (logxor sum (+ (aref words k) k page-index))))))

(defun %segment-checksum (pages images timestamp)
  "Fold the stored page images in checkpoint order.

  The caller owns IMAGES and PAGES; this helper only updates local scalar
  state, so it introduces no list, closure, or temporary image allocation."
  (let ((checksum timestamp))
    (dolist (page pages checksum)
      (setf checksum
            (logxor checksum
                    (page-checksum-of-image (gethash page images)
                                            checksum page))))))

(defun %copy-page-words (vm page words &optional buffer)
  "Copy PAGE into the caller-owned WORDS vector.

  Supplying WORDS keeps the page-copy loop allocation-free, which matters for
  T0/T1 snapshot buffers and for the COW fault's plain handler path.  BUFFER,
  when present, is the pre-materialised T0/T1 snapshot; otherwise the live VM
  is read (the T2 fault path)."
  (let ((base (page-start-address page)))
    (dotimes (k +page-words+ words)
      (let ((address (+ base k)))
        (when (< address (vm-heap-size vm))
          (setf (aref words k)
                (if buffer
                    (s-get buffer address)
                    (ref-u64 vm address))))))))

(defun %copy-page-image (vm page)
  "Return a newly allocated frozen image for PAGE.

  The allocation belongs to the image owner (the COW table); the actual copy
  is shared with the allocation-free destination helper above."
  (let ((words (make-array +page-words+
                           :element-type '(unsigned-byte 64)
                           :initial-element 0)))
    (%copy-page-words vm page words)
    words))

;; ---- simulator COW/MMU support ------------------------------------------
;;
;; The software MMU normally only supplies page protection and dirty bits.  A
;; checkpoint adds a protected-page set and a frozen-image table.  On the first
;; write fault the handler copies the old page, then makes the live mapping
;; writable.  The segment writer also freezes pages that were never written;
;; this models a concurrent writer which reaches a quiet page before a fault.

(defun %ensure-cow-tables (vm)
  (unless (vm-cow-pages vm)
    (setf (vm-cow-pages vm)
          (make-array (vm-page-count vm) :element-type 'bit :initial-element 0)))
  (unless (vm-cow-images vm)
    (setf (vm-cow-images vm) (make-hash-table :test 'eql)))
  ;; virtual-memory-mixin carries the same state slots for VM backends that
  ;; expose COW metadata through their MMU protocol.  Keep the simulator's
  ;; frozen-image table mirrored there rather than leaving those protocol
  ;; slots inert.
  (when (typep vm 'virtual-memory-mixin)
    (unless (mmu-cow-pages vm)
      (setf (mmu-cow-pages vm) (vm-cow-pages vm)))
    (unless (mmu-cow-copied vm)
      (setf (mmu-cow-copied vm) (vm-cow-images vm))))
  vm)

(defun %cow-page-p (vm page)
  (and (vm-cow-pages vm)
       (<= 0 page) (< page (length (vm-cow-pages vm)))
       (eql 1 (sbit (vm-cow-pages vm) page))))

(defun persistence-cow-page-fault (vm address access-kind)
  "Service a simulator COW write fault.  The function is intentionally a
  plain handler target (rather than a closure allocating per fault)."
  (let ((page (address-page address)))
    (when (and (eq access-kind :write) (%cow-page-p vm page))
      (let ((images (vm-cow-images vm)))
        (unless (gethash page images)
          (setf (gethash page images) (%copy-page-image vm page)))
        ;; Keep the MMU-facing table as an alias of the VM table.  This is
        ;; deliberately inside the binding above: a write fault must publish
        ;; the actual frozen vector, not an unbound/NIL value.
        (when (and (typep vm 'virtual-memory-mixin) (mmu-cow-copied vm))
          (setf (gethash page (mmu-cow-copied vm))
                (gethash page images))))
      ;; The frozen image is now independent of the live physical page.
      (vm-mprotect vm page 1 :read-write)))
  vm)

(defun %finish-cow (vm)
  (when (vm-cow-pages vm)
    (dotimes (page (length (vm-cow-pages vm)))
      (when (eql 1 (sbit (vm-cow-pages vm) page))
        ;; The segment is frozen and durable in the simulator, so no page
        ;; needs to remain write-protected after this point.
        (when (typep vm 'virtual-memory-mixin)
          (vm-mprotect vm page 1 :read-write))))
    (fill (vm-cow-pages vm) 0)
    (when (vm-cow-images vm) (clrhash (vm-cow-images vm)))
    (when (typep vm 'virtual-memory-mixin)
      (when (mmu-cow-pages vm) (fill (mmu-cow-pages vm) 0))
      (when (mmu-cow-copied vm) (clrhash (mmu-cow-copied vm)))
      (when (typep vm 'ring0-mixin)
        (setf (mmu-handler vm) (mmu-cow-previous-handler vm)))
      (setf (mmu-cow-previous-handler vm) nil)))
  vm)

(defun write-segment (vm dirty-pages timestamp)
  "Write a delta segment.  If MARK-PAGES-COW armed the simulator, consume its
  frozen images; otherwise freeze the current page (the T0/T1 pause path)."
  (let* ((sorted (sort (remove-duplicates (copy-list dirty-pages)) #'<))
         (images (make-hash-table :test 'eql))
         (buffer (vm-stratum vm :snapshot-buffer)))
    (dolist (page sorted)
      (let ((words (or (and (vm-cow-images vm)
                            (gethash page (vm-cow-images vm)))
                       (let ((copy (make-array +page-words+
                                               :element-type '(unsigned-byte 64)
                                               :initial-element 0)))
                         (%copy-page-words vm page copy buffer)
                         copy))))
        (setf (gethash page images) words)))
    ;; A page in SORTED corresponds to one persistence write in this segment.
    ;; Count after deduplication so a page reported by both MMU and cards is
    ;; not charged twice.
    (let ((stats (%stats-for-vm vm)))
      (when stats (stats-event stats :pages-written (length sorted))))
    (let ((segment (%make-segment :timestamp timestamp :pages sorted
                                  :images images
                                  :checksum (%segment-checksum
                                             sorted images timestamp))))
      (%finish-cow vm)
      segment)))

;; ---- dirty-set capture (persistence.tex §2 step 4) -----------------------

(defun collector-dirty-set (plan)
  "Collect dirty pages from the armed MMU and, when present, the collector's
  card stratum.  The union is intentional: a collector may continue to report
  card writes while the simulator MMU is armed, and neither signal should be
  lost at a checkpoint fence."
  (let* ((vm (plan-vm plan))
         (pages nil))
    (when (and (typep vm 'virtual-memory-mixin) (mmu-armed vm))
      (let ((dirty (mmu-dirty vm)))
        (when dirty
          (dotimes (p (length dirty))
            (when (eql 1 (sbit dirty p))
              (push p pages))))))
    (let ((card (vm-stratum vm :card)))
      (when card
        ;; Keep the LET binding form limited to PAGE-STRATUM.  In particular,
        ;; S-PROJECT is body work, not another binding spec.
        (let ((page-stratum
                (or (vm-stratum vm :page-dirty)
                    (vm-register-stratum
                     vm :page-dirty
                     (make-stratum :page-dirty +page-words+ :bit
                                   (vm-heap-size vm))))))
          (s-clear page-stratum)
          (s-project card page-stratum :any)
          (s-for-set-cells page-stratum nil
            (lambda (addr)
              (push (address-page addr) pages))))))
    (let ((result (sort (remove-duplicates pages) #'<)))
      (let ((stats (%stats-for-plan plan)))
        (when stats (stats-event stats :dirty-pages (length result))))
      result)))

(defun collector-clear-dirty (plan)
  "Reset the dirty signal the collector handed persistence."
  (let ((vm (plan-vm plan)))
    (when (and (typep vm 'virtual-memory-mixin) (mmu-dirty vm))
      (fill (mmu-dirty vm) 0))
    (let ((card (vm-stratum vm :card)))
      (when card (s-clear card)))
    (let ((page-stratum (vm-stratum vm :page-dirty)))
      (when page-stratum (s-clear page-stratum))))
  plan)

;; ---- copy-on-write marking (persistence.tex §2 step 5) -------------------

(defun mark-pages-cow (vm pages)
  "Protect dirty pages for COW.  T2 uses the simulator fault handler and T0/T1
  materialise frozen words during the pause.  Arming the MMU even for an empty
  dirty set is deliberate: writes after the first checkpoint must set MMU dirty
  bits for the next delta."
  (if (and (typep vm 'virtual-memory-mixin)
           (vm-has-feature-p vm :t2))
      (progn
        (%ensure-cow-tables vm)
        (when (typep vm 'ring0-mixin)
          (setf (mmu-cow-previous-handler vm) (mmu-handler vm)))
        (vm-install-fault-handler
         vm (lambda (address access-kind)
             (persistence-cow-page-fault vm address access-kind)))
        ;; MMU-ARM is the simulator's explicit T1/T2 routing hook.  Keep the
        ;; fallback SETF for VM backends predating that helper.
        (if (fboundp 'mmu-arm)
            (mmu-arm vm :clear-dirty nil)
            (setf (mmu-armed vm) t))
        (dolist (page pages)
          (when (and (<= 0 page) (< page (vm-page-count vm)))
            (setf (sbit (vm-cow-pages vm) page) 1)
            (when (and (typep vm 'virtual-memory-mixin)
                       (mmu-cow-pages vm))
              (setf (sbit (mmu-cow-pages vm) page) 1))
            (vm-mprotect vm page 1 :read))))
      (when pages
        ;; T0/T1: no write fault path, so materialise the frozen copy now.
        (let ((buffer (or (vm-stratum vm :snapshot-buffer)
                          (vm-register-stratum
                           vm :snapshot-buffer
                           (make-stratum :snapshot-buffer
                                         (vm-min-alignment-words vm) :ref
                                         (vm-heap-size vm))))))
          (dolist (page pages)
            (let ((base (page-start-address page)))
              (dotimes (k +page-words+)
                (let ((address (+ base k)))
                  (when (< address (vm-heap-size vm))
                    (s-set buffer address (ref-u64 vm address))))))))))
  vm)

;; ---- checkpoint as a collection phase (persistence.tex §4) ---------------

(defclass persistent-plan (plan)
  ((log :initarg :log :accessor plan-persistence-log :initform nil))
  (:metaclass plan-metaclass))

(defmethod gc-phase :checkpoint ((p persistent-plan) cycle-kind)
  (declare (ignore cycle-kind))
  (let ((segment (checkpoint-heap p :timestamp (get-universal-time))))
    (gc-event-checkpoint p (plan-vm p)
                         (persistence-segment-pages segment))))

;; ---- recovery (persistence.tex §1 crash consistency) ---------------------

(defun verify-segment (segment vm)
  "Recompute SEGMENT's checksum against its STORED page images (not the live
  heap); NIL means torn."
  (declare (ignore vm))
  (handler-case
      (let ((pages (persistence-segment-pages segment))
            (images (persistence-segment-images segment)))
        ;; Keep malformed-image rejection here so the shared fold can remain a
        ;; tight, allocation-free checksum loop for trusted segment images.
        (dolist (page pages)
          (let ((words (gethash page images)))
            (unless (and (arrayp words) (>= (length words) +page-words+))
              (return-from verify-segment nil))))
        (eql (%segment-checksum
              pages images (persistence-segment-timestamp segment))
             (persistence-segment-checksum segment)))
    (error () nil)))

(defun %segment-list (segments)
  (if (typep segments 'persistence-log)
      (plog-segments segments)
      segments))

(defun recover-last-intact-snapshot (segments &optional vm)
  "Read forward to the last intact segment.  A torn segment and all following
  segments are discarded.  Returns (values intact-segments torn-p)."
  (declare (ignore vm))
  (let ((intact nil)
        (torn-p nil))
    (dolist (segment (%segment-list segments))
      (if (verify-segment segment nil)
          (push segment intact)
          (progn (setf torn-p t) (return))))
    (values (nreverse intact) torn-p)))

(defun %heap-from-base (vm base)
  (let ((heap (make-array (vm-heap-size vm)
                          :element-type '(unsigned-byte 64)
                          :initial-element 0)))
    (when (arrayp base)
      (replace heap base :end1 (min (length heap) (length base))))
    heap))

(defun %apply-segment (heap segment)
  (dolist (page (persistence-segment-pages segment) heap)
    (let ((base (page-start-address page))
          (words (gethash page (persistence-segment-images segment))))
      (when (and words (< base (length heap)))
        (dotimes (k (min +page-words+ (- (length heap) base)))
          (setf (aref heap (+ base k)) (aref words k)))))))

(defun replay-segments (segments vm &optional base)
  "Replay an ordered list of delta segments over BASE (or a zero heap).
  Recovery stops at the first torn segment; the second value reports tearing."
  (multiple-value-bind (intact torn-p)
      (recover-last-intact-snapshot segments vm)
    (let ((heap (%heap-from-base vm base)))
      (dolist (segment intact) (%apply-segment heap segment))
      (values heap torn-p))))

(defun verify-base-image (log)
  (let ((image (plog-base-image log)))
    (and image
         (eql (plog-base-checksum log)
              (%base-image-checksum image (plog-base-timestamp log))))))

(defun replay-persistence-log (log vm)
  "Replay LOG's complete base and all intact deltas into a fresh heap."
  (when (or (null (plog-base-image log)) (verify-base-image log))
    (replay-segments (plog-segments log) vm (plog-base-image log))))

(defun replay-log (log vm)
  (replay-persistence-log log vm))

(defun replay-segment (segment vm &optional base)
  "Replay one SEGMENT, or a list of segments, into a fresh heap.  BASE is an
  optional complete heap image and is useful for explicit base-plus-delta
  recovery; the historical two-argument form remains unchanged."
  (if (listp segment)
      ;; A list obtained from the VM's persistence log carries the complete
      ;; base implicitly; retain the explicit BASE override for callers
      ;; replaying an externally supplied log.
      (replay-segments
       segment vm
       (or base
           (and (vm-persistence-log vm)
                (plog-base-image (vm-persistence-log vm)))))
      (when (verify-segment segment vm)
        (let ((heap (%heap-from-base vm base)))
          (%apply-segment heap segment)
          heap))))

;; ---- checkpoint simulation ------------------------------------------------

(defun checkpoint-heap (plan &key (timestamp 0) log)
  "Fence work: capture dirty pages, append one delta segment, and clear the
  dirty signal.  The first call records a complete base image in LOG."
  (let* ((vm (plan-vm plan))
         (persistent-log
           (or log
               (and (typep plan 'persistent-plan)
                    (plan-persistence-log plan))
               (vm-persistence-log vm)
               (make-persistence-log))))
    (setf (vm-persistence-log vm) persistent-log)
    (when (typep plan 'persistent-plan)
      (setf (plan-persistence-log plan) persistent-log))
    (plog-record-base persistent-log vm timestamp)
    (let ((pages (collector-dirty-set plan)))
      (mark-pages-cow vm pages)
      (let ((segment (write-segment vm pages timestamp)))
        (plog-record-segment persistent-log segment)
        (collector-clear-dirty plan)
        segment))))
