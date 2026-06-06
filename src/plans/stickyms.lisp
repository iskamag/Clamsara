(in-package #:clamsara)

;;; --- StickyMS Plan ---
;;; Sticky generational: nursery and mature in one mark-sweep space, log-bit discriminated.

(defclass stickyms-plan (generational-plan-trait sticky-space-metrics plan)
  ((live-young-bytes :initform 0 :accessor plan-live-young-bytes :type fixnum)
   (dead-mature-bytes :initform 0 :accessor plan-dead-mature-bytes :type fixnum))
  (:documentation "StickyMS: mixed-age mark-sweep space."))

(defun %stickyms-collect (plan cycle-kind)
  "Core sticky-ms collection dispatch."
  (if (eq cycle-kind :major)
      (sticky-ms-major-collect plan)
      (if (should-minor-gc-p plan)
          (sticky-ms-nursery-collect plan)
          (progn
            (setf (plan-last-major-gc-minor-count plan)
                  (plan-minor-gc-count plan))
            (sticky-ms-major-collect plan)))))

(defmethod plan-collect ((plan stickyms-plan) &key (cycle-kind :minor))
  (%stickyms-collect plan cycle-kind))

(defmethod mature-dead-ratio-exceeded-p ((plan stickyms-plan))
  (let* ((young-live (plan-live-young-bytes plan))
         (mature-dead (plan-dead-mature-bytes plan)))
    (and (> young-live 0)
         (> mature-dead (* 2 young-live)))))

(defun sticky-ms-nursery-collect (plan)
  "Nursery GC for sticky MS: promote young survivors, sweep dead young."
  (let* ((vm (plan-vm plan))
         (space (plan-get-space plan :default))
         (barrier (plan-barrier plan))
         (tracer nil))
    (vm-stop-mutators vm)
    ;; Reset metrics for this cycle
    (setf (plan-live-young-bytes plan) 0
          (plan-dead-mature-bytes plan) 0)
    (flet ((trace-fn (ref)
             (cond
               ((vm-object-is-logged-p vm ref)
                ;; Young object: promote
                (setf (vm-object-is-logged-p vm ref) nil)
                (setf (vm-object-age vm ref) (1+ (vm-object-age vm ref)))
                (unless (vm-object-is-marked-p vm ref)
                  (setf (vm-object-is-marked-p vm ref) t)
                  (incf (plan-live-young-bytes plan)
                        (vm-object-total-words vm ref))
                  (tracer-enqueue tracer ref))
                ref)
               ((not (vm-object-is-marked-p vm ref))
                ;; Mature, not yet marked
                (setf (vm-object-is-marked-p vm ref) t)
                (tracer-enqueue tracer ref)
                ref)
               (t nil))))
      (setf tracer (make-tracer vm #'trace-fn :queue-size 4096))
      (setf (tracer-trace-fn-enqueues-p tracer) t)
      (vm-scan-roots vm plan
        (lambda (root)
          (when (and root (not (zerop root)))
            (let ((result (funcall #'trace-fn root)))
              (when result
                (unless (tracer-trace-fn-enqueues-p tracer)
                  (tracer-enqueue tracer result)))))))
      (when barrier
        (barrier-card-scan barrier vm
          (lambda (ref slot-idx)
            (declare (ignore slot-idx))
            (let ((result (funcall #'trace-fn ref)))
              (when result
                (unless (tracer-trace-fn-enqueues-p tracer)
                  (tracer-enqueue tracer result)))))))
      (tracer-process-queue tracer))
    ;; Sweep: reclaim dead young objects only
    (space-sweep-young space vm)
    (when barrier (barrier-clear-all barrier))
    (vm-clear-all-mark-bits vm)
    (incf (plan-minor-gc-count plan))
    (vm-post-gc-cleanup vm)
    (vm-resume-mutators vm)))

(defun sticky-ms-major-collect (plan)
  "Major GC for sticky MS: full mark-sweep."
  (let* ((vm (plan-vm plan))
         (space (plan-get-space plan :default))
         (tracer nil))
    (vm-stop-mutators vm)
    (flet ((trace-fn (ref)
             (space-trace-object space vm ref tracer :cycle-kind :major)))
      (setf tracer (make-tracer vm #'trace-fn :queue-size 4096))
      (setf (tracer-trace-fn-enqueues-p tracer) t)
      (vm-scan-roots vm plan
        (lambda (root)
          (when (and root (not (zerop root)))
            (space-trace-object space vm root tracer :cycle-kind :major)
            (unless (tracer-trace-fn-enqueues-p tracer)
              (tracer-enqueue tracer root)))))
      (tracer-process-queue tracer))
    (space-sweep space vm)
    (vm-clear-all-log-bits vm)
    (vm-clear-all-mark-bits vm)
    (incf (plan-major-gc-count plan))
    (vm-post-gc-cleanup vm)
    (vm-resume-mutators vm)))

(defmethod plan-get-space ((plan stickyms-plan) (designator (eql :default)))
  (or (plan-default-space plan)
      (error "No default space for StickyMS plan")))

(defmethod plan-allocate ((plan stickyms-plan) size (designator (eql :default)))
  (let* ((space (plan-get-space plan :default))
         (alloc (space-allocator space)))
    (let ((addr (or (alloc alloc size)
                    (plan-handle-allocation-failure plan size designator))))
      (when addr
        (setf (vm-object-is-logged-p (plan-vm plan) addr) t))
      addr)))

(defmethod plan-handle-allocation-failure ((plan stickyms-plan) size space-designator)
  (flet ((try-alloc ()
           (let* ((space (plan-get-space plan space-designator))
                  (alloc (space-allocator space)))
             (alloc alloc size))))
    (or (try-alloc)
        (progn
          (sticky-ms-nursery-collect plan)
          (or (try-alloc)
              (progn
                (sticky-ms-major-collect plan)
                (or (try-alloc)
                    (error 'heap-exhausted :plan plan))))))))

(defun make-stickyms-plan (vm heap-size &rest initargs)
  (declare (ignore initargs))
  (let* ((plan (make-instance 'stickyms-plan
                  :name "StickyMS" :vm vm
                   :constraints (make-instance 'plan-constraints
                                  :moves-objects nil :generational t
                                  :nursery-kind :sticky :num-generations 2
                                  :needs-log-bit t :barrier :object
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
      (let* ((space (plan-get-space plan :default))
             (space-start (* (space-start-page space) +page-size-words+))
             (space-end (+ space-start (* (space-page-count space) +page-size-words+)))
              (barrier (make-object-barrier (plan-card-table plan) space-start space-end :vm vm)))
        (setf (plan-barrier plan) barrier
              (vm-barrier vm) barrier))
      plan)))

(register-plan-selector :stickyms #'make-stickyms-plan)

(defmethod compile-to-functions append ((plan stickyms-plan))
  (list (cons 'plan-collect
              (lambda (&key (cycle-kind :minor))
                (%stickyms-collect plan cycle-kind)))))
