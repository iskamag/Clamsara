;;;; plans/marksweep.lisp -- free-list / trace / non-moving / global / STW.

(in-package #:clamsara)

(defun make-marksweep-plan (vm heap-size)
  (declare (ignore heap-size))
  (destructuring-bind (a) (partition-pages (vm-page-count vm) '(1))
    (let ((space (make-instance 'mark-sweep-space :vm vm :start-page (car a)
                                 :page-count (cdr a) :name :default :default-space t)))
      (let ((p (make-instance 'plan :name :marksweep :vm vm :spaces (list space)
                             :constraints (make-instance 'plan-constraints))))
        (add-los-space p 1/16)
        (finalize-plan p) p))))
