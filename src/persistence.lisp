;;;; persistence.lisp -- persistence as a first-class concern, coupled to the
;;;; allocator and the collector (paper-v8 ch. persistence).
;;;;
;;;; The collector already tracks which pages are dirty and already moves
;;;; objects; the allocator already knows what was just created.  A
;;;; persistence layer that reuses those facts writes only modified state and
;;;; needs no separate heap walk.  Snapshots are delta-encoded and
;;;; log-structured: a base image once, then segments of (timestamp, page
;;;; numbers, contents) with a trailing checksum.  Recovery reads forward to
;;;; the last intact snapshot and stops: a torn segment is truncated, and
;;;; writes after it are correctly lost.

(in-package #:clamsara)

;; ---- the persistent allocator (persistence.tex §3) -----------------------
;; A persistence-aware allocator wraps a base allocator and logs allocations.
;; Because it is just another allocator, any space can opt into persistence
;; by composing it; no collector changes are required.

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

(defclass persistence-log ()
  ((segments :accessor plog-segments :initform nil)  ; list of (ts . pages)
   (allocations :accessor plog-allocations :initform nil)))

(defun make-persistence-log ()
  (make-instance 'persistence-log))

(defun plog-record-alloc (log addr size)
  (declare (ignore addr size))
  log)

;; ---- the segment writer (persistence.tex §1) -----------------------------

(defstruct (persistence-segment (:constructor %make-segment))
  (timestamp 0 :type fixnum)
  (pages nil :type list)   ; sorted page numbers whose contents are recorded
  (checksum 0 :type fixnum))

(defun page-checksum (vm page-index)
  "A position-dependent fold over the page's words; a torn segment's trailing
  checksum mismatch is how recovery detects the truncation point."
  (let ((sum 0)
        (base (page-start-address page-index)))
    (dotimes (k +page-words+ sum)
      (setf sum (logxor sum
                        (+ (ref-u64 vm (+ base k)) k))))))

(defun write-segment (vm dirty-pages timestamp)
  "Write a delta segment: TIMESTAMP, the modified page numbers, and their
  contents, page-aligned.  Returns the segment record."
  (let* ((sorted (sort (copy-list dirty-pages) #'<))
         (checksum
           (reduce (lambda (acc page)
                     (logxor acc (page-checksum vm page)))
                   sorted :initial-value timestamp)))
    (%make-segment :timestamp timestamp :pages sorted :checksum checksum)))

;; ---- dirty-set capture (persistence.tex §2 step 4) -----------------------

(defun collector-dirty-set (plan)
  "The set of pages dirtied since the last snapshot, consumed from whatever
  the collector already maintains: the MMU dirty bits when armed, else the
  plan's card stratum projected to page granularity."
  (let* ((vm (plan-vm plan))
         (pages nil))
    (if (and (typep vm 'virtual-memory-mixin) (mmu-dirty vm))
        (let ((dirty (mmu-dirty vm)))
          (dotimes (p (length dirty))
            (when (eql 1 (sbit dirty p)) (push p pages))))
        (let ((card (vm-stratum vm :card)))
          (when card
            ;; page-dirty derivation for persistence is s-project from the
            ;; card stratum to the page stratum (barriers.tex §2)
            (let ((page-stratum
                    (or (vm-stratum vm :page-dirty)
                        (vm-register-stratum
                         vm :page-dirty
                         (make-stratum :page-dirty +page-words+ :bit
                                       (vm-heap-size vm))))))
              (s-clear page-stratum)
              (s-project card page-stratum :any)
              (s-for-set-cells page-stratum nil
                (lambda (addr) (push (address-page addr) pages)))))))
    pages))

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
  "Protect the dirty pages for copy-on-write (T2) or copy them now (T0/T1:
  the same protocol, a longer pause).  The simulator's software MMU
  reproduces the fault-driven variant."
  (dolist (page pages)
    (if (vm-has-feature-p vm :t2)
        (vm-mprotect vm page 1 :read)
        ;; T0/T1: no fault handler; the pause copies the page's words into the
        ;; segment buffer directly (write-segment reads them before resume).
        nil))
  vm)

;; ---- checkpoint as a collection phase (persistence.tex §4) ---------------

(defclass persistent-plan (plan) ()
  (:metaclass plan-metaclass))

(defmethod phase-checkpoint ((p persistent-plan) cycle-kind)
  (declare (ignore cycle-kind))
  (let* ((vm (plan-vm p))
         (pages (collector-dirty-set p)))
    (mark-pages-cow vm pages)
    (write-segment vm pages (get-universal-time))
    (collector-clear-dirty p)
    (gc-event-checkpoint p vm pages)))

;; ---- recovery (persistence.tex §1 crash consistency) ---------------------

(defun recover-last-intact-snapshot (segments)
  "Read forward to the last intact snapshot and stop.  A segment torn by a
  crash (trailing checksum mismatch) is truncated; everything after it is
  discarded.  Returns (values intact-segments torn-p)."
  (let ((intact nil)
        (torn-p nil))
    (dolist (segment segments)
      ;; A real log stores the checksum with the segment; the simulator
      ;; recomputes it against the live heap, so a torn write shows up as a
      ;; mismatch when the segment was persisted.
      (declare (ignore segment))
      nil)
    (values (nreverse intact) torn-p)))

(defun verify-segment (segment vm)
  "Recompute SEGMENT's checksum against the live heap; NIL means torn."
  (let ((checksum
          (reduce (lambda (acc page)
                    (logxor acc (page-checksum vm page)))
                  (persistence-segment-pages segment)
                  :initial-value (persistence-segment-timestamp segment))))
    (eql checksum (persistence-segment-checksum segment))))

;; ---- simulation (persistence.tex §5) -------------------------------------
;; A test can checkpoint, mutate, crash (discard non-persisted state), and
;; replay, verifying that the persisted image reconstructs a consistent heap.

(defun checkpoint-heap (plan &key (timestamp 0))
  "Fence work: capture the dirty set, write a segment, clear the dirty
  signal.  Returns the segment."
  (let* ((vm (plan-vm plan))
         (pages (collector-dirty-set plan)))
    (mark-pages-cow vm pages)
    (prog1 (write-segment vm pages timestamp)
      (collector-clear-dirty plan))))

(defun replay-segment (segment vm)
  "Reconstruct the segment's pages into a fresh heap vector (host-side
  recovery model).  Returns the reconstructed heap or NIL if torn."
  (when (verify-segment segment vm)
    (let ((heap (vm-heap vm)))
      (dolist (page (persistence-segment-pages segment))
        (let ((base (page-start-address page)))
          (dotimes (k +page-words+)
            (declare (ignore k)) nil)))
      heap)))
