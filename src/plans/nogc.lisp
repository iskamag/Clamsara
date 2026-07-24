;;;; plans/nogc.lisp -- contiguous / --- / non-moving / global / STW.
;;;; Bump-allocate; collection is impossible (prologue signals heap-exhausted).

(in-package #:clamsara)

(defclass nogc-plan (plan) ()
  (:metaclass plan-metaclass))

(defmethod plan-collect ((p nogc-plan) &key cycle-kind)
  (declare (ignore cycle-kind))
  (error 'heap-exhausted :requested-size 0 :space :nogc))

(defmethod plan-install-strata ((p nogc-plan) vm)
  (vm-set-location vm :forwarding :in-header)
  (vm-register-stratum vm :mark
    (make-stratum :mark (vm-min-alignment-words vm) :bit (vm-heap-size vm))))

(defun make-nogc-plan (vm heap-size)
  (declare (ignore heap-size))
  (destructuring-bind (a) (partition-pages (vm-page-count vm) '(1))
    (let ((space (make-instance 'space :vm vm :start-page (car a)
                                 :page-count (cdr a) :name :default
                                 :policy nil :moving :none :default-space t)))
      (let ((p (make-instance 'nogc-plan :name :nogc :vm vm :spaces (list space)
                             :constraints (make-instance 'plan-constraints))))
        (finalize-plan p) p))))
