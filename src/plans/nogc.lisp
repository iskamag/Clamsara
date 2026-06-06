(in-package #:clamsara)

;;; --- NoGC Plan ---
;;; Allocates from a monotone space, never collects.

(defclass nogc-plan (plan) ()
  (:documentation "NoGC plan: allocates, never collects."))

(defmethod plan-collect ((plan nogc-plan) &key cycle-kind)
  (declare (ignore cycle-kind))
  (error 'heap-exhausted :plan plan :message "NoGC plan cannot collect"))

(defmethod plan-get-space ((plan nogc-plan) (designator (eql :default)))
  (or (plan-default-space plan)
      (error "No default space for NoGC plan")))

(defmethod plan-allocate ((plan nogc-plan) size (designator (eql :default)))
  (let* ((space (plan-get-space plan :default))
         (alloc (space-allocator space)))
    (or (alloc alloc size)
        (error 'heap-exhausted :plan plan :message "NoGC heap exhausted"))))

(defun make-nogc-plan (vm heap-size &rest initargs)
  (declare (ignore initargs))
  (let* ((plan (make-instance 'nogc-plan
                  :name "NoGC" :vm vm
                   :constraints (make-instance 'plan-constraints
                                  :moves-objects nil :generational nil
                                  :nursery-kind nil :num-generations 1
                                  :needs-log-bit nil :barrier :none
                                  :needs-forwarding nil))))
    (initialize-plan-heap plan heap-size)
    (let* ((pr (plan-page-resource plan))
           (n-pages (ceiling heap-size +page-size-words+))
           (start-page (page-resource-get pr n-pages :kind :boxed))
           (alloc (make-bump-allocator nil pr :alignment 1))
            (space (make-instance 'nogc-space
                     :name :nogc :kind :nogc
                     :start-page start-page :page-count n-pages
                     :allocator alloc :page-resource pr
                     :constraints (make-instance 'space-constraints
                                    :moves-objects nil :accepts-copies nil
                                    :mixed-age nil :immortal nil))))
      (bump-allocator-reset alloc
                            :cursor (* start-page +page-size-words+)
                            :limit (* (+ start-page n-pages) +page-size-words+))
      (setf (plan-default-space plan) space)
      (plan-add-space plan space)
      (setf (plan-barrier plan) (make-no-barrier))
      plan)))

(register-plan-selector :nogc #'make-nogc-plan)
