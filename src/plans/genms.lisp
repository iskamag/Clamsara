(in-package #:clamsara)

;;; --- GenMS Plan ---
;;; Generational with copying nursery and mark-sweep mature space.

(defclass genms-plan (generational-plan-trait plan)
  ((ms-mature-space :initform nil :accessor plan-genms-mature-space))
  (:documentation "GenMS: copying nursery, mark-sweep mature."))

(defmethod plan-collect-phase :prologue ((plan genms-plan) (cycle-kind (eql :minor)))
  (gen-minor-collect plan))

(defmethod plan-collect-phase :prologue ((plan genms-plan) (cycle-kind (eql :major)))
  (gen-major-collect plan))

(defmethod gen-minor-collect ((plan genms-plan))
  (let* ((vm (plan-vm plan))
         (n-from (plan-nursery-from plan))
         (n-to (plan-nursery-to plan))
         (ms-space (plan-genms-mature-space plan))
         (barrier (plan-barrier plan))
         (tracer nil)
         (promoted (make-array 1024 :element-type 'fixnum :initial-element 0 :fill-pointer 0)))
    (vm-stop-mutators vm)
    (space-prepare n-to vm :cycle-kind :minor)
    (labels ((promote-or-copy (ref)
               (when (and (vm-address-in-space-p vm ref n-from)
                          (not (vm-object-is-forwarded-p vm ref)))
                 (let ((age (vm-object-age vm ref)))
                   (if (>= age (plan-survivor-threshold plan))
                        (let* ((alloc (space-allocator ms-space))
                               (n-words (vm-object-total-words vm ref))
                               (dst (alloc alloc n-words)))
                          (when (null dst)
                            (error 'heap-exhausted :plan plan))
                          (vm-object-copy vm ref dst)
                          (setf (vm-object-generation vm dst) 1
                                (vm-object-age vm dst) 0)
                          (setf (vm-object-is-marked-p vm dst) t)
                          (vector-push-extend dst promoted)
                          dst)
                       (let* ((n-words (vm-object-total-words vm ref))
                              (nursery-alloc (space-allocator n-to))
                              (dst (alloc nursery-alloc n-words)))
                         (when (null dst)
                           (error 'heap-exhausted :plan plan))
                          (vm-object-copy vm ref dst)
                          (setf (vm-object-age vm dst) (min 15 (1+ age)))
                         dst)))))
             (trace-ref (ref)
               (let ((already-fwd (vm-object-is-forwarded-p vm ref)))
                 (when already-fwd
                   (return-from trace-ref
                     (vm-object-forwarding-pointer vm ref))))
               (let ((new-addr (promote-or-copy ref)))
                 (when new-addr
                   (setf (vm-object-forwarding-pointer vm ref) new-addr)
                   (when tracer (tracer-enqueue tracer new-addr))
                   new-addr))))
      (setf tracer (make-tracer vm #'trace-ref :queue-size 4096))
      (setf (tracer-trace-fn-enqueues-p tracer) t)
      (vm-scan-roots vm plan
        (lambda (root)
          (when (and root (not (zerop root)))
            (let ((result (trace-ref root)))
              (when result
                (unless (tracer-trace-fn-enqueues-p tracer)
                  (tracer-enqueue tracer result)))))))
      (when barrier
        (barrier-card-scan barrier vm
          (lambda (ref slot-idx)
            (declare (ignore slot-idx))
            (let ((result (trace-ref ref)))
              (when result
                (unless (tracer-trace-fn-enqueues-p tracer)
                  (tracer-enqueue tracer result)))))))
      (tracer-process-queue tracer))
    (loop for i from 0 below (fill-pointer promoted)
          do (setf (vm-object-is-marked-p vm (aref promoted i)) t))
    (rotatef (copying-from-space-p n-from) (copying-from-space-p n-to))
    (setf (plan-nursery-from plan) n-to
          (plan-nursery-to plan) n-from
          (plan-nursery plan) n-to)
    (vm-update-roots-forwarded vm)
    (when barrier (barrier-clear-all barrier))
    (vm-clear-all-forwarding vm)
    (incf (plan-minor-gc-count plan))
    (vm-post-gc-cleanup vm)
    (vm-resume-mutators vm)))

(defmethod gen-major-collect ((plan genms-plan))
  (let* ((vm (plan-vm plan))
         (n-from (plan-nursery-from plan))
         (n-to (plan-nursery-to plan))
         (ms-space (plan-genms-mature-space plan))
         (tracer nil))
    (vm-stop-mutators vm)
    (space-prepare n-to vm :cycle-kind :major)
    (flet ((trace-fn (ref)
             (let ((space (plan-space-for-address plan ref)))
               (when (and space (typep space 'collectable-space))
                 (space-trace-object space vm ref tracer :cycle-kind :major)))))
      (setf tracer (make-tracer vm #'trace-fn :queue-size 4096))
      (setf (tracer-trace-fn-enqueues-p tracer) t)
      (vm-scan-roots vm plan
        (lambda (root)
          (when (and root (not (zerop root)))
            (let ((result (funcall #'trace-fn root)))
              (when result
                (unless (tracer-trace-fn-enqueues-p tracer)
                  (tracer-enqueue tracer result)))))))
      (tracer-process-queue tracer))
    ;; Sweep MS space
    (when ms-space
      (space-sweep ms-space vm))
    ;; Swap nursery
    (when (and n-from n-to)
      (rotatef (copying-from-space-p n-from) (copying-from-space-p n-to))
      (setf (plan-nursery-from plan) n-to
            (plan-nursery-to plan) n-from
            (plan-nursery plan) n-to))
    (vm-update-roots-forwarded vm)
    (let ((barrier (plan-barrier plan)))
      (when barrier (barrier-clear-all barrier)))
    (vm-clear-all-forwarding vm)
    (vm-clear-all-mark-bits vm)
    (incf (plan-major-gc-count plan))
    (vm-post-gc-cleanup vm)
    (vm-resume-mutators vm)))

(defmethod plan-get-space ((plan genms-plan) (designator (eql :default)))
  (plan-nursery plan))

(defmethod plan-allocate ((plan genms-plan) size (designator (eql :default)))
  (let* ((space (plan-nursery plan))
         (alloc (space-allocator space)))
    (or (alloc alloc size)
        (plan-handle-allocation-failure plan size designator))))

(defmethod plan-handle-allocation-failure ((plan genms-plan) size space-designator)
  (flet ((try-alloc ()
           (let* ((space (plan-nursery plan))
                  (alloc (space-allocator space)))
             (alloc alloc size))))
    (plan-request-gc plan)
    (gen-minor-collect plan)
    (or (try-alloc)
        (progn
          (gen-major-collect plan)
          (or (try-alloc)
              (error 'heap-exhausted :plan plan))))))

(defun make-genms-plan (vm heap-size &rest initargs)
  (declare (ignore initargs))
  (let* ((plan (make-instance 'genms-plan
                  :name "GenMS" :vm vm
                   :constraints (make-instance 'plan-constraints
                                  :moves-objects t :generational t
                                  :nursery-kind :copying :num-generations 2
                                  :needs-log-bit t :barrier-type :object
                                  :needs-forwarding t))))
    (initialize-plan-heap plan heap-size)
    (let* ((pr (plan-page-resource plan))
           (ms-size (floor heap-size 4))
           (ms-pages (max 1 (ceiling ms-size +page-size-words+)))
           (ms-start (page-resource-get pr ms-pages :kind :boxed))
           (ms-alloc (make-free-list-allocator nil pr))
           (ms-space (make-instance 'mark-sweep-space
                        :name :ms-mature :kind :ms
                        :start-page ms-start :page-count ms-pages
                        :allocator ms-alloc :page-resource pr)))
      (dotimes (i ms-pages)
        (free-list-allocator-add-page ms-alloc (+ ms-start i)))
      (gen-plan-init-nursery plan heap-size)
      (setf (plan-genms-mature-space plan) ms-space)
      (plan-add-space plan ms-space)
      (setf (plan-default-space plan) (plan-nursery-from plan))
      (let* ((nursery (plan-nursery plan))
             (nursery-start (* (space-start-page nursery) +page-size-words+))
             (nursery-end (+ nursery-start (* (space-page-count nursery) +page-size-words+)))
             (barrier (make-object-barrier (plan-card-table plan) nursery-start nursery-end)))
        (setf (plan-barrier plan) barrier
              (vm-barrier vm) barrier))
      plan)))

(register-plan-selector :genms #'make-genms-plan)
