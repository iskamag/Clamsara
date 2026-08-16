;;;; plans/zgcish.lisp -- a C4/ZGC-style collector: mark-region / trace /
;;;; concurrent-relocate / SATB write + LVB read / global / concurrent.
;;;; Concurrent phases are STW-simulated (the spec's software-MMU seam); the
;;;; axes exercised are SATB, the self-healing load barrier, off-heap
;;;; forwarding, and the concurrent-relocate moving model.

(in-package #:clamsara)

(defclass zgc-plan (plan)
  ((from :accessor z-from :initform nil)
   (to   :accessor z-to   :initform nil))
  (:metaclass plan-metaclass))

(defmethod plan-install-strata ((p zgc-plan) vm)
  (vm-set-location vm :mark :side)
  (vm-set-location vm :forwarding :off-heap)     ; concurrent relocation -> off-heap
  (vm-register-stratum vm :mark
    (make-stratum :mark (vm-min-alignment-words vm) :bit (vm-heap-size vm))))

(defmethod plan-allocate ((p zgc-plan) size space-designator)
  (declare (ignore space-designator))
  (let* ((los (plan-los p)))
    (when (and los (> (* size +word-bytes+)
                      (constraints-max-non-los-bytes (plan-constraints p))))
      (return-from plan-allocate
        (let ((addr (alloc (space-allocator los) size)))
          (cond (addr (let ((os (vm-object-start (plan-vm p))))
                        (when os (s-set-bit os addr))) addr)
                (t (plan-handle-allocation-failure p size los)))))))
  (let ((addr (alloc (space-allocator (z-from p)) size)))
    (cond (addr (let ((os (vm-object-start (plan-vm p))))
                 (when os (s-set-bit os addr))) addr)
          (t (plan-handle-allocation-failure p size (z-from p))))))

(defmethod plan-handle-allocation-failure ((p zgc-plan) size space)
  (plan-collect p :cycle-kind :full)
  (let ((addr (alloc (space-allocator space) size)))
    (if addr
        (progn (let ((os (vm-object-start (plan-vm p))))
                 (when os (s-set-bit os addr))) addr)
        (error 'heap-exhausted :requested-size size :space :from))))

(defmethod gc-phase :prologue ((p zgc-plan) k)
  (declare (ignore k))
  (vm-stop-mutators (plan-vm p))
  (let ((vm (plan-vm p)))
    (space-prepare (z-from p) vm)
    (allocator-reset (space-allocator (z-to p)))
    (fwd-clear vm)))

;; mark: precise trace + drain the SATB snapshot buffer (remark)
(defmethod gc-phase :mark ((p zgc-plan) k)
  (declare (ignore k))
  (mark-roots p (plan-tracer p))
  (let ((vm (plan-vm p))
        (tr (plan-tracer p))
        (buffer (barrier-satb-buffer (plan-barrier p))))
    (loop for ref across buffer
          for address = (ref-strip-or-self vm ref)
          when (and (vm-reference-p vm ref)
                    (eq (plan-space-for-address p address)
                        (z-from p)))
            do (mark-root-reference p ref))
    ;; SATB entries may introduce previously unseen grey objects.
    (tracer-drain tr #'mark-grey-reference p)
    (setf (fill-pointer buffer) 0)))

;; Relocation consumes the mark set. Generic Immix reclaim would clear it
;; before PHASE-COMPACT and silently relocate nothing.
(defmethod gc-phase :reclaim ((p zgc-plan) k)
  (declare (ignore p k))
  nil)

;; relocate: copy every live (marked) object into the 'to' region, recording
;; old->new in the off-heap forwarding table.
(defmethod gc-phase :compact ((p zgc-plan) k)
  (declare (ignore k))
  (let* ((vm (plan-vm p))
         (mark (vm-stratum vm :mark))
         (os (vm-object-start vm))
         (fwd (vm-fwd-table vm))
         (to (space-allocator (z-to p))))
    (when (and mark os)
      (loop for address from (space-base-address (z-from p))
            below (space-end-address (z-from p))
            when (s-test-bit mark address)
              do (let* ((words (vm-object-total-words vm address))
                        (destination (alloc to words)))
                   (when destination
                     (vm-object-copy vm address destination)
                     (setf (aref fwd address) destination))))
      ;; remap: heal every root + every live object's slots in EVERY space
      ;; (a LOS object may hold an edge into a relocated 'from' object)
      (heal-every-space p fwd))))

(defmethod gc-phase :release ((p zgc-plan) k)
  (declare (ignore k))
  (let ((vm (plan-vm p)))
    (s-clear (vm-stratum vm :mark))
    ;; the relocated objects now live in 'to'; swap and reset
    (rotatef (z-from p) (z-to p))
    (setf (space-default-p (z-from p)) t (space-default-p (z-to p)) nil)
    (allocator-reset (space-allocator (z-to p)))
    (fwd-clear vm)
    (when (plan-stats p) (stats-event (plan-stats p) :gc-cycles 1))))

(defun make-zgcish-plan (vm heap-size)
  (declare (ignore heap-size))
  (destructuring-bind (a b) (partition-pages (vm-page-count vm) '(1/2 1/2))
    (let* ((from (make-instance 'immix-space :vm vm :start-page (car a)
                                :page-count (cdr a) :name :from :default-space t
                                :moving :concurrent-relocate))
           (to (make-instance 'immix-space :vm vm :start-page (car b)
                              :page-count (cdr b) :name :to :default-space nil
                              :moving :concurrent-relocate))
           (barrier (make-instance 'barrier
                      :rules (list (satb-barrier-rule) (lvb-barrier-rule))))
           (p (make-instance 'zgc-plan :name :zgcish :vm vm
                            :spaces (list from to) :barrier barrier
                            :constraints (make-instance 'plan-constraints
                                         :write-barrier :satb :read-barrier :lvb
                                         :forwarding :off-heap
                                         :concurrency :concurrent-relocate))))
      (setf (z-from p) from (z-to p) to (barrier-plan barrier) p)
      (add-los-space p 1/16)
      (finalize-plan p) p)))
