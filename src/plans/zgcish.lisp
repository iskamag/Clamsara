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

(defmethod plan-collect ((p zgc-plan) &key cycle-kind)
  (declare (ignore cycle-kind))
  (let ((fn (gethash 'plan-collect (plan-function-table p))))
    (if fn (funcall fn p :full)
        (plan-collect-phase p :full))))

(defmethod phase-prologue ((p zgc-plan) k)
  (declare (ignore k))
  (vm-stop-mutators (plan-vm p))
  (let ((vm (plan-vm p)))
    (space-prepare (z-from p) vm)
    (allocator-reset (space-allocator (z-to p)))
    (clrhash (vm-fwd-table vm))))

;; mark: precise trace + drain the SATB snapshot buffer (remark)
(defmethod phase-mark ((p zgc-plan) k)
  (declare (ignore k))
  (mark-roots p (plan-tracer p))
  (let ((vm (plan-vm p)) (tr (plan-tracer p)))
    (map nil (lambda (ref)
               (let ((addr (ref-strip-or-self vm ref)))
                 (when (and (vm-reference-p vm ref)
                            (space-contains-p (z-from p) addr))
                   (space-trace-object (z-from p) vm ref tr))))
         (barrier-satb-buffer (plan-barrier p)))
    (setf (fill-pointer (barrier-satb-buffer (plan-barrier p))) 0)))

;; relocate: copy every live (marked) object into the 'to' region, recording
;; old->new in the off-heap forwarding table.
(defmethod phase-compact ((p zgc-plan) k)
  (declare (ignore k))
  (let* ((vm (plan-vm p))
         (mark (vm-stratum vm :mark))
         (os (vm-object-start vm))
         (fwd (vm-fwd-table vm))
         (to (space-allocator (z-to p))))
    (when (and mark os)
      (s-for-set-cells mark
        (cons (space-base-address (z-from p)) (space-end-address (z-from p)))
        (lambda (addr)
          (when (s-test-bit mark addr)
            (let* ((n (vm-object-total-words vm addr))
                   (dst (alloc to n)))
              (when dst
                (vm-object-copy vm addr dst)
                (setf (gethash addr fwd) dst))))))
      ;; remap: heal every root + every 'to' object's slots to forwarded refs
      (let ((roots (vm-root-vector vm)))
        (dotimes (i (length roots))
          (let ((r (aref roots i)))
            (when (vm-reference-p vm r)
              (setf (aref roots i) (gethash r fwd r))))))
      (dolist (b (ix-blocks to))
        (s-for-set-cells os
          (cons (immix-block-base b) (+ (immix-block-base b) (ix-block-words to)))
          (lambda (addr)
            (dotimes (j (vm-object-reference-count vm addr))
              (let ((c (vm-object-reference vm addr j)))
                (when (vm-reference-p vm c)
                  (let ((healed (gethash c fwd c)))
                    (unless (eql healed c)
                      (setf (vm-object-reference vm addr j) healed))))))))))))

(defmethod phase-release ((p zgc-plan) k)
  (declare (ignore k))
  (let ((vm (plan-vm p)))
    (s-clear (vm-stratum vm :mark))
    ;; the relocated objects now live in 'to'; swap and reset
    (rotatef (z-from p) (z-to p))
    (setf (space-default-p (z-from p)) t (space-default-p (z-to p)) nil)
    (allocator-reset (space-allocator (z-to p)))
    (clrhash (vm-fwd-table vm))
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
      (finalize-plan p) p)))
