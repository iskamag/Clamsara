;;;; plans/marksweep.lisp -- free-list / trace / non-moving / global / STW.

(in-package #:clamsara)

(defun make-marksweep-plan (vm heap-size)
  (declare (ignore heap-size))
  (let ((spaces (make-plan-spaces vm
                   '((mark-sweep-space 1 :default :default-space t)))))
    (let ((p (make-instance 'plan :name :marksweep :vm vm
                            :spaces spaces
                            :constraints (make-instance 'plan-constraints))))
      (finalize-plan p))))
