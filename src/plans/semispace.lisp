(in-package #:clamsara)

;;; --- SemiSpace Plan ---
;;; A Cheney-style copying collector with two equal-sized CopySpaces.

(defclass semispace-plan (plan) ()
  (:documentation "SemiSpace copying collector."))

(defun plan-from-space (plan)
  "Return the current from-space (where live objects are)."
  (find-if (lambda (s) (and (typep s 'copying-space-trait)
                            (copying-from-space-p s)))
           (plan-spaces plan)))

(defun plan-to-space (plan)
  "Return the current to-space (where objects are evacuated to)."
  (find-if (lambda (s) (and (typep s 'copying-space-trait)
                            (not (copying-from-space-p s))))
           (plan-spaces plan)))

(defmethod plan-collect ((plan semispace-plan) &key cycle-kind)
  (declare (ignore cycle-kind))
  (let* ((vm (plan-vm plan))
         (from (plan-from-space plan))
         (to (plan-to-space plan))
         (tracer nil))
    (vm-stop-mutators vm)
    ;; Prepare to-space
    (space-prepare to vm)
    ;; Trace
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
              (let ((result (funcall #'trace-fn root)))
                (when result
                  (unless (tracer-trace-fn-enqueues-p tracer)
                    (tracer-enqueue tracer result)))))))
        (tracer-process-queue tracer)))
    ;; Release: swap from/to
    (space-release from vm)
    (vm-update-roots-forwarded vm)
    (vm-clear-all-forwarding vm)
    (setf (plan-default-space plan) (plan-from-space plan))
    (vm-resume-mutators vm)))

(defmethod plan-get-space ((plan semispace-plan) (designator (eql :default)))
  (or (plan-default-space plan)
      (plan-from-space plan)))

(defmethod plan-allocate ((plan semispace-plan) size (designator (eql :default)))
  (let* ((space (plan-get-space plan :default))
         (alloc (space-allocator space)))
    (or (alloc alloc size)
        (plan-handle-allocation-failure plan size designator))))

(defun make-semispace-plan (vm heap-size &rest initargs)
  (declare (ignore initargs))
  (let* ((plan (make-instance 'semispace-plan
                  :name "SemiSpace" :vm vm
                  :constraints (make-instance 'plan-constraints
                                 :moves-objects t :generational nil
                                 :needs-log-bit nil :barrier :none
                                 :needs-forwarding t))))
    (initialize-plan-heap plan heap-size)
    (let* ((pr (plan-page-resource plan))
           (half-size (floor heap-size 2))
           (pages-per-space (max 1 (floor (ceiling half-size +page-size-words+) 1)))
           (cs0 (make-copy-space plan pr :name :copyspace0 :size pages-per-space))
           (cs1 (make-copy-space plan pr :name :copyspace1 :size pages-per-space)))
      (setf (copying-partner-space cs0) cs1
            (copying-partner-space cs1) cs0
            (copying-from-space-p cs0) t
            (copying-from-space-p cs1) nil)
      (setf (plan-default-space plan) cs0)
      (plan-add-space plan cs0)
      (plan-add-space plan cs1)
      (setf (plan-barrier plan) (make-no-barrier))
      plan)))

(register-plan-selector :semispace #'make-semispace-plan)
