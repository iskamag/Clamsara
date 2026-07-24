;;;; plans/semispace.lisp -- contiguous / trace / STW-copy / global / STW.
;;;; Cheney; in-header forwarding; release swaps from/to spaces.

(in-package #:clamsara)

(defclass semispace-plan (plan)
  ((from :accessor sp-from :initform nil)
   (to   :accessor sp-to   :initform nil))
  (:metaclass plan-metaclass))

(defmethod plan-allocate ((p semispace-plan) size space-designator)
  (declare (ignore space-designator))
  (let ((addr (alloc (space-allocator (sp-from p)) size)))
    (cond (addr (let ((os (vm-object-start (plan-vm p))))
                 (when os (s-set-bit os addr))) addr)
          (t (plan-handle-allocation-failure p size (sp-from p))))))

(defmethod plan-handle-allocation-failure ((p semispace-plan) size space)
  (plan-collect p :cycle-kind :full)
  (let ((addr (alloc (space-allocator space) size)))
    (if addr
        (progn (let ((os (vm-object-start (plan-vm p))))
                 (when os (s-set-bit os addr))) addr)
        (error 'heap-exhausted :requested-size size :space (space-name space)))))

(defmethod phase-prologue ((p semispace-plan) k)
  (declare (ignore k))
  (let ((vm (plan-vm p)))
    (vm-stop-mutators vm)
    (space-prepare (sp-from p) vm)
    (space-prepare (sp-to p) vm)
    (allocator-reset (space-allocator (sp-to p)))))

(defmethod phase-release ((p semispace-plan) k)
  (declare (ignore k))
  (let ((vm (plan-vm p)))
    (s-clear (vm-stratum vm :mark))
    (rotatef (sp-from p) (sp-to p))
    (setf (space-default-p (sp-from p)) t
          (space-default-p (sp-to p)) nil)
    (allocator-reset (space-allocator (sp-to p)))
    (when (plan-stats p)
      (stats-event (plan-stats p) :gc-cycles 1))))

(defun make-semispace-plan (vm heap-size)
  (declare (ignore heap-size))
  (destructuring-bind (a b) (partition-pages (vm-page-count vm) '(1/2 1/2))
    (let* ((from (make-instance 'copy-space :vm vm :start-page (car a)
                                :page-count (cdr a) :name :from :default-space t))
           (to   (make-instance 'copy-space :vm vm :start-page (car b)
                                :page-count (cdr b) :name :to :default-space nil))
           (p (make-instance 'semispace-plan :name :semispace :vm vm
                            :spaces (list from to)
                            :constraints (make-instance 'plan-constraints))))
      (setf (space-partner from) to (space-partner to) from
            (sp-from p) from (sp-to p) to)
      (finalize-plan p) p)))
