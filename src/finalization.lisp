(in-package #:clamsara)

;;; --- Finalization ---

(defclass finalization-trait ()
  ((known-finalizers :accessor plan-known-finalizers
    :initform (make-array 64 :adjustable t :initial-element 0 :fill-pointer 0))
   (pending-finalizers :accessor plan-pending-finalizers
    :initform (make-array 64 :adjustable t :initial-element 0 :fill-pointer 0)))
  (:documentation "Mixin that adds finalization support."))

(defun register-finalizer (plan obj-address finalizer-fn)
  "Register a finalizer for OBJ-ADDRESS."
  (when (typep plan 'finalization-trait)
    (vector-push-extend (cons obj-address finalizer-fn)
                        (plan-known-finalizers plan))
    obj-address))

(defun process-pending-finalizers (plan)
  "Run all pending finalizers."
  (when (typep plan 'finalization-trait)
    (let ((pending (plan-pending-finalizers plan)))
      (loop for i from 0 below (fill-pointer pending)
            for entry = (aref pending i)
            do (when (consp entry)
                 (funcall (cdr entry) (car entry))))
      (setf (fill-pointer pending) 0))))

(defmethod plan-collect-phase :epilogue ((plan finalization-trait) (phase t))
  "Move dead objects from known-finalizers to pending-finalizers after mark/sweep."
  (declare (ignore phase))
  (let ((vm (plan-vm plan))
        (keep-count 0))
    (loop with known = (plan-known-finalizers plan)
          for i from 0 below (fill-pointer known)
          for entry = (aref known i)
          do (when (consp entry)
               (let ((obj-addr (car entry)))
                 (if (and (not (zerop obj-addr))
                          (vm-object-is-marked-p vm obj-addr))
                     (progn
                       (setf (aref known keep-count) entry)
                       (incf keep-count))
                     (progn
                       (vector-push-extend entry
                                           (plan-pending-finalizers plan)))))))
    (setf (fill-pointer (plan-known-finalizers plan)) keep-count))
  (call-next-method))
