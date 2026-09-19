;;;; plans/nogc.lisp -- contiguous / --- / non-moving / global / STW.
;;;; Bump-allocate; collection is impossible (prologue signals heap-exhausted).

(in-package #:clamsara)

(defclass nogc-plan (plan) ()
  (:metaclass plan-metaclass))

(defmethod boot-cycle-kinds ((p nogc-plan))
  (declare (ignore p))
  nil)

(defun make-nogc-plan (vm heap-size)
  (declare (ignore heap-size))
  (let ((spaces (make-plan-spaces vm
                   '((space 1 :default :default-space t
                      :policy nil :moving :none)))))
    (let ((p (make-instance 'nogc-plan :name :nogc :vm vm
                            :spaces spaces
                            :constraints (make-instance 'plan-constraints))))
      (finalize-plan p))))
