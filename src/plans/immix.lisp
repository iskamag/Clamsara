(in-package #:clamsara)

;;; --- Immix Plan ---
;;; Mark-region collector with block and line granularity.

(defclass immix-plan (plan) ()
  (:documentation "Immix mark-region collector."))

;;; --- Immix plan-collect-phase methods ---

(defmethod plan-collect-phase :prologue ((plan immix-plan) (cycle-kind t))
  (vm-stop-mutators (plan-vm plan))
  (space-prepare (plan-get-space plan :default) (plan-vm plan)))

(defmethod plan-collect-phase :mark ((plan immix-plan) (cycle-kind t))
  (let* ((vm (plan-vm plan))
         (space (plan-get-space plan :default))
         (cs (plan-copy-semantics plan))
         (tracer nil))
    (flet ((trace-fn (ref)
             (space-trace-object space vm ref tracer
                                 :copy-semantics cs)))
      (setf tracer (make-tracer vm #'trace-fn :queue-size 4096))
      (setf (tracer-trace-fn-enqueues-p tracer) t)
      (let ((tracer tracer))
        (vm-scan-roots vm plan
          (lambda (root)
            (when (and root (not (zerop root)))
              (space-trace-object space vm root tracer
                                  :copy-semantics cs)
              (unless (tracer-trace-fn-enqueues-p tracer)
                (tracer-enqueue tracer root)))))
        (tracer-process-queue tracer)))))

(defmethod plan-collect-phase :sweep ((plan immix-plan) (cycle-kind t))
  (space-sweep (plan-get-space plan :default) (plan-vm plan)))

(defmethod plan-collect-phase :release ((plan immix-plan) (cycle-kind t))
  (let ((vm (plan-vm plan)))
    (vm-clear-all-mark-bits vm)
    (vm-post-gc-cleanup vm)
    (vm-resume-mutators vm)))

(defmethod plan-get-space ((plan immix-plan) (designator (eql :default)))
  (or (plan-default-space plan)
      (error "No default space for Immix plan")))

(defmethod plan-allocate ((plan immix-plan) size (designator (eql :default)))
  (let* ((space (plan-get-space plan :default))
         (alloc (space-allocator space)))
    (or (alloc alloc size)
        (plan-handle-allocation-failure plan size designator))))

(defun make-immix-plan (vm heap-size &rest initargs)
  (declare (ignore initargs))
  (let* ((plan (make-instance 'immix-plan
                  :name "Immix" :vm vm
                   :constraints (make-instance 'plan-constraints
                                  :moves-objects nil :generational nil
                                  :nursery-kind nil :num-generations 1
                                  :needs-log-bit nil :barrier-type :none
                                  :needs-forwarding nil))))
    (initialize-plan-heap plan heap-size)
    (let* ((pr (plan-page-resource plan))
           (space (make-immix-space plan pr :name :immix-heap :size 0))
           (alloc (make-immix-allocator space pr)))
      (setf (space-allocator space) alloc
            (plan-default-space plan) space)
      (plan-add-space plan space)
      (setf (plan-barrier plan) (make-no-barrier))
      plan)))

(register-plan-selector :immix #'make-immix-plan)
