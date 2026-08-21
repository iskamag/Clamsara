;;;; plans/semispace.lisp -- contiguous / trace / STW-copy / global / STW.
;;;; Cheney; in-header forwarding; release swaps from/to spaces.

(in-package #:clamsara)

(defclass semispace-plan (plan)
  ((from :accessor sp-from :initform nil)
   (to   :accessor sp-to   :initform nil))
  (:metaclass plan-metaclass))

(defmethod plan-allocate ((p semispace-plan) size space-designator)
  (let ((explicit (plan-explicit-space p space-designator)))
    (if explicit
        ;; Explicit names (including :from, :to, and :los) bypass the
        ;; default-space nursery/LOS policy and allocate in that space.
        (or (plan-allocate-in p size explicit)
            (plan-handle-allocation-failure p size explicit))
        (let ((los (plan-los p)))
          ;; Automatic LOS escalation applies only to the default request.
          (when (and (or (eq space-designator :default)
                         (null space-designator))
                     los (> (* size +word-bytes+)
                            (constraints-max-non-los-bytes
                             (plan-constraints p))))
            (return-from plan-allocate
              (or (plan-allocate-in p size los)
                  (plan-handle-allocation-failure p size los))))
          (or (plan-allocate-in p size (sp-from p))
              (plan-handle-allocation-failure p size (sp-from p)))))))

(defmethod plan-handle-allocation-failure ((p semispace-plan) size space)
  (plan-retry-after p size space :full))

(defmethod gc-phase :prologue ((p semispace-plan) k)
  (declare (ignore k))
  (let ((vm (plan-vm p)))
    (vm-stop-mutators vm)
    (space-prepare (sp-from p) vm)
    (space-prepare (sp-to p) vm)
    (allocator-reset (space-allocator (sp-to p)))))

(defmethod gc-phase :release ((p semispace-plan) k)
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
      ;; Balanced carve: the Cheney flip needs equally sized halves, so the
      ;; LOS space takes its pages from both instead of shrinking only :to.
      (add-los-space p 1/16 :balanced t)
      (finalize-plan p) p)))
