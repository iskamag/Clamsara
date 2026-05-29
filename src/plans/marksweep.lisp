(in-package #:clamsara)

;;; --- MarkSweep Plan ---
;;; Non-moving mark-and-sweep collector.

(defclass marksweep-plan (plan) ()
  (:documentation "Mark-and-sweep collector."))

(defmethod plan-collect ((plan marksweep-plan) &key cycle-kind)
  (declare (ignore cycle-kind))
  (let* ((vm (plan-vm plan))
         (tracer nil))
    (vm-stop-mutators vm)
    ;; Mark phase: trace from roots
    (flet ((trace-fn (ref)
             (let ((space (plan-space-for-address plan ref)))
               (when (and space (typep space 'collectable-space))
                 (space-trace-object space vm ref tracer)))))
      (setf tracer (make-tracer vm #'trace-fn :queue-size 4096))
      (setf (tracer-trace-fn-enqueues-p tracer) t)
      (let ((tracer tracer))
        (vm-scan-roots vm plan
          (lambda (root)
            (when (and root (not (zerop root)))
              (let ((space (plan-space-for-address plan root)))
                (if (and space (typep space 'collectable-space))
                    (space-trace-object space vm root tracer)
                    (progn
                      (setf (vm-object-is-marked-p vm root) t)
                      (unless (tracer-trace-fn-enqueues-p tracer)
                        (tracer-enqueue tracer root))))))))
        (tracer-process-queue tracer)))
    ;; Sweep phase
    (dolist (space (plan-spaces plan))
      (when (typep space 'marksweep-space-trait)
        (space-sweep space vm)))
    ;; Cleanup
    (vm-clear-all-mark-bits vm)
    (vm-post-gc-cleanup vm)
    (vm-resume-mutators vm)))

(defmethod plan-get-space ((plan marksweep-plan) (designator (eql :default)))
  (or (plan-default-space plan)
      (error "No default space for MarkSweep plan")))

(defmethod plan-allocate ((plan marksweep-plan) size (designator (eql :default)))
  (let* ((space (plan-get-space plan :default))
         (alloc (space-allocator space)))
    (or (alloc alloc size)
        (plan-handle-allocation-failure plan size designator))))

(defun make-marksweep-plan (vm heap-size &rest initargs)
  (declare (ignore initargs))
  (let* ((plan (make-instance 'marksweep-plan
                  :name "MarkSweep" :vm vm
                  :constraints (make-instance 'plan-constraints
                                 :moves-objects nil :generational nil
                                 :needs-log-bit nil :barrier :none
                                 :needs-forwarding nil))))
    (initialize-plan-heap plan heap-size)
    (let* ((pr (plan-page-resource plan))
           (n-pages (ceiling heap-size +page-size-words+))
           (start-page (page-resource-get pr n-pages :kind :boxed))
           (alloc (make-free-list-allocator nil pr))
           (space (make-instance 'mark-sweep-space
                    :name :ms-heap :kind :ms
                    :start-page start-page :page-count n-pages
                    :allocator alloc :page-resource pr)))
      (dotimes (i n-pages)
        (free-list-allocator-add-page alloc (+ start-page i)))
      (setf (plan-default-space plan) space)
      (plan-add-space plan space)
      (setf (plan-barrier plan) (make-no-barrier))
      plan)))

(register-plan-selector :marksweep #'make-marksweep-plan)
