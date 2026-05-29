(in-package #:clamsara)

;;; --- StickyImmix Plan ---
;;; Sticky generational: nursery and mature in one Immix space, log-bit discriminated.

(defclass stickyimmix-plan (generational-plan-trait plan)
  ((should-minor-gc :initform t :accessor plan-should-minor-gc))
  (:documentation "StickyImmix: mixed-age Immix space."))

(defmethod plan-collect ((plan stickyimmix-plan))
  (if (plan-should-minor-gc plan)
      (sticky-nursery-collect plan)
      (sticky-major-collect plan)))

(defun sticky-nursery-collect (plan)
  "Nursery GC for sticky Immix: scan young objects, promote survivors."
  (let* ((vm (plan-vm plan))
         (space (plan-get-space plan :default))
         (barrier (plan-barrier plan))
         (tracer nil))
    (vm-stop-mutators vm)
    (flet ((trace-fn (ref)
             (cond
               ;; Object in nursery (logged): promote survivor
               ((vm-object-is-logged-p vm ref)
                (setf (vm-object-is-logged-p vm ref) nil)
                (unless (vm-object-is-marked-p vm ref)
                  (setf (vm-object-is-marked-p vm ref) t)
                  (immix-mark-object-lines vm space ref
                                           (immix-space-line-mark-state space))
                  (tracer-enqueue tracer ref))
                ref)
               ;; Already mature: just mark if not marked
               ((not (vm-object-is-marked-p vm ref))
                (setf (vm-object-is-marked-p vm ref) t)
                (tracer-enqueue tracer ref)
                ref)
               (t nil))))
      (setf tracer (make-tracer vm #'trace-fn :queue-size 4096))
      (setf (tracer-trace-fn-enqueues-p tracer) t)
      ;; Scan roots - only young objects need promotion
      (vm-scan-roots vm plan
        (lambda (root)
          (when (and root (not (zerop root)))
            (let ((result (funcall #'trace-fn root)))
              (when result (tracer-enqueue tracer result))))))
      ;; Card scanning for old-to-young pointers
      (when barrier
        (barrier-card-scan barrier plan
          (lambda (ref slot-idx)
            (declare (ignore slot-idx))
            (let ((result (funcall #'trace-fn ref)))
              (when result (tracer-enqueue tracer result))))))
      (tracer-process-queue tracer))
    ;; Sweep: reclaim dead young objects
    (space-sweep space vm)
    (when barrier (barrier-clear-all barrier))
    (vm-clear-all-mark-bits vm)
    (incf (plan-minor-gc-count plan))
    (vm-post-gc-cleanup vm)
    (vm-resume-mutators vm)))

(defun sticky-major-collect (plan)
  "Major GC for sticky Immix: full mark-sweep."
  (let* ((vm (plan-vm plan))
         (space (plan-get-space plan :default))
         (tracer nil))
    (vm-stop-mutators vm)
    (space-prepare space vm :cycle-kind :major)
    (flet ((trace-fn (ref)
             (space-trace-object space vm ref tracer :cycle-kind :major)))
      (setf tracer (make-tracer vm #'trace-fn :queue-size 4096))
      (setf (tracer-trace-fn-enqueues-p tracer) t)
      (vm-scan-roots vm plan
        (lambda (root)
          (when (and root (not (zerop root)))
            (space-trace-object space vm root tracer :cycle-kind :major)
            (tracer-enqueue tracer root))))
      (tracer-process-queue tracer))
    (space-sweep space vm)
    (vm-clear-all-log-bits vm)
    (vm-clear-all-mark-bits vm)
    (incf (plan-major-gc-count plan))
    (vm-post-gc-cleanup vm)
    (vm-resume-mutators vm)))

(defmethod plan-get-space ((plan stickyimmix-plan) (designator (eql :default)))
  (or (plan-default-space plan)
      (error "No default space for StickyImmix plan")))

(defmethod plan-allocate ((plan stickyimmix-plan) size (designator (eql :default)))
  (let* ((space (plan-get-space plan :default))
         (alloc (space-allocator space)))
    (let ((addr (or (alloc alloc size)
                    (plan-handle-allocation-failure plan size designator))))
      ;; New allocations are young (logged)
      (when addr
        (setf (vm-object-is-logged-p (plan-vm plan) addr) t))
      addr)))

(defun make-stickyimmix-plan (vm heap-size &rest initargs)
  (declare (ignore initargs))
  (let* ((plan (make-instance 'stickyimmix-plan
                  :name "StickyImmix" :vm vm
                  :constraints (make-instance 'plan-constraints
                                 :moves-objects nil :generational t
                                 :needs-log-bit t :barrier :object
                                 :needs-forwarding nil))))
    (initialize-plan-heap plan heap-size)
    (let* ((pr (plan-page-resource plan))
           (space (make-immix-space plan pr :name :immix-heap :size 0))
           (alloc (make-immix-allocator space pr)))
      (setf (space-allocator space) alloc
            (plan-default-space plan) space)
      (plan-add-space plan space)
      (let* ((space (plan-get-space plan :default))
             (space-start (* (space-start-page space) +page-size-words+))
             (space-end (+ space-start (* (space-page-count space) +page-size-words+)))
             (barrier (make-object-barrier (plan-card-table plan) space-start space-end)))
        (setf (plan-barrier plan) barrier
              (vm-barrier vm) barrier))
      plan)))

(register-plan-selector :stickyimmix #'make-stickyimmix-plan)
