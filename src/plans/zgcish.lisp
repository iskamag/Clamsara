;;;; plans/zgcish.lisp -- a C4/ZGC-style collector: mark-region / trace /
;;;; concurrent-relocate / incremental-update mark through the LVB /
;;;; global / concurrent.  Concurrent phases are STW-simulated (the spec's
;;;; software-MMU seam); the axes exercised are the shaded-load marking
;;;; rule, the self-healing load barrier, off-heap forwarding, and the
;;;; concurrent-relocate moving model.  No SATB write log exists here:
;;;; snapshot semantics belong to LXR (collectors.tex, barriers.tex).

(in-package #:clamsara)

(defclass zgc-plan (plan)
  ((from :accessor z-from :initform nil)
   (to   :accessor z-to   :initform nil))
  (:metaclass plan-metaclass))

;; Concurrent marking narrows the mark datum: mutator loads shade while
;; the collector marks, so the writers race and idempotent 0->1 sets still
;; need an atomic operation (strata.tex section 5).
(defmethod component-metadata-specifications ((p zgc-plan))
  (let ((vm (plan-vm p)))
    (substitute (mark-specification vm :writers :concurrent
                                    :atomicity '(:bit-atomic :cas))
                :mark (call-next-method)
                :key #'metadata-name)))

(defmethod plan-allocate ((p zgc-plan) size space-designator)
  (let ((explicit (plan-explicit-space p space-designator)))
    (if explicit
        ;; Explicit names (including :from, :to, and :los) are authoritative.
        (or (plan-allocate-in p size explicit)
            (plan-direct-handle-allocation-failure p size explicit))
        (progn
          (let ((los (plan-los p)))
            (when (and (or (eq space-designator :default)
                           (null space-designator))
                       los (> (* size +word-bytes+)
                              (constraints-max-non-los-bytes
                               (plan-constraints p))))
              (return-from plan-allocate
                (or (plan-allocate-in p size los)
                    (plan-direct-handle-allocation-failure p size los)))))
          (or (plan-allocate-in p size (z-from p))
              (plan-direct-handle-allocation-failure p size (z-from p)))))))

(defmethod plan-handle-allocation-failure ((p zgc-plan) size space)
  (plan-retry-after p size space :full))

(defmethod plan-current-space ((p zgc-plan) space)
  ;; The from/to pair swaps on every full collection; resolve either stale
  ;; object to the current allocating half.
  (if (or (eq space (z-from p)) (eq space (z-to p)))
      (z-from p)
      space))

(defmethod gc-phase :prologue ((p zgc-plan) k)
  (declare (ignore k))
  (vm-direct-stop-mutators (plan-vm p))
  (setf (plan-marking-active-p p) t)
  (let ((vm (plan-vm p)))
    (space-direct-prepare (z-from p) vm nil)
    (space-direct-reset (z-to p))
    (fwd-clear vm)))

;; mark: precise trace.  Incremental update keeps the graph consistent
;; through the load barrier: every reference a mutator loads is shaded by
;; the SHADE-MARK-BARRIER-RULE before use, so no snapshot write log exists.
;; Concurrent phases are STW-simulated, so mutator traffic cannot interleave
;; here, but the barrier contract is what the axis requires.
(defmethod gc-phase :mark ((p zgc-plan) k)
  (declare (ignore k))
  (mark-roots p (plan-tracer p)))

;; Relocation consumes the mark set: an immix-style reclaim of the from
;; space would clear marks before :compact and relocate nothing.  The LOS
;; is not relocated, so it still reclaims dead pages here (heap.tex §2).
(defmethod gc-phase :reclaim ((p zgc-plan) k)
  ;; Mark closed at reclaim entry: shaded grey work has been drained by the
  ;; trace drain, so later loads are plain reads.
  (setf (plan-marking-active-p p) nil)
  (let ((los (plan-los p)))
    (when los
      (space-direct-reclaim los (plan-vm p) k))))

;; relocate: copy every live (marked) object into the 'to' region, recording
;; old->new in the off-heap forwarding table.
(defmethod gc-phase :compact ((p zgc-plan) k)
  (declare (ignore k))
  (let* ((vm (plan-vm p))
         (mark (vm-direct-stratum vm :mark))
         (os (vm-object-start vm))
         (fwd (vm-fwd-table vm))
         (to (z-to p)))
    (when (and mark os)
      (loop for address from (space-base-address (z-from p))
            below (space-end-address (z-from p))
            when (s-test-bit mark address)
              do (let* ((words (vm-direct-object-total-words vm address))
                        (destination (space-direct-alloc to words)))
                   ;; A live object that cannot move leaves a stranded
                   ;; reference: the next prologue clears the from-space's
                   ;; metadata, so silently skipping the copy corrupts the
                   ;; heap.  Report exhaustion like the Cheney copier.
                   (unless destination
                     (error 'heap-exhausted :requested-size words
                                            :space (space-name (z-to p))))
                   (vm-direct-object-copy vm address destination)
                   (setf (aref fwd address) destination)))
      ;; remap: heal every root + every live object's slots in EVERY space
      ;; (a LOS object may hold an edge into a relocated 'from' object)
      (heal-every-space p fwd)
      ;; The forwarding table remains live until the correction grace period
      ;; closes; it is cleared only in the release phase.
      (vm-direct-memory-fence vm))))

(defmethod gc-phase :release ((p zgc-plan) k)
  (declare (ignore k))
  (let ((vm (plan-vm p)))
    (s-clear (vm-direct-stratum vm :mark))
    ;; the relocated objects now live in 'to'; swap and reset
    (rotatef (z-from p) (z-to p))
    (setf (space-default-p (z-from p)) t (space-default-p (z-to p)) nil)
    (space-direct-reset (z-to p))
    (fwd-clear vm)
    (when (plan-stats p) (stats-event (plan-stats p) :gc-cycles 1))))

(defun make-zgcish-plan (vm heap-size)
  (declare (ignore heap-size))
  ;; Relocation copies into :to; the halves split evenly so a full :from
  ;; always fits its destination.
  (destructuring-bind (from to los)
      (make-plan-spaces vm
        '((immix-space 1/2 :from :default-space t :moving :concurrent-relocate)
          (immix-space 1/2 :to :moving :concurrent-relocate)))
    (let* (;; The relocation LVB runs first: a stale reference is healed
           ;; before any other read rule tests it (barriers.tex).
           (barrier (make-instance 'barrier
                      :rules (list (lvb-barrier-rule)
                                   (shade-mark-barrier-rule))))
           (p (make-instance 'zgc-plan :name :zgcish :vm vm
                            :spaces (list from to los) :barrier barrier
                            :constraints (make-instance 'plan-constraints
                                         :write-barrier :incremental-update
                                         :read-barrier '(:lvb :incremental-update)
                                         :forwarding :off-heap
                                         :concurrency :concurrent-relocate))))
      (setf (z-from p) from (z-to p) to (barrier-plan barrier) p)
      (finalize-plan p))))
