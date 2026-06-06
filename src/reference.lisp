(in-package #:clamsara)

;;; --- Weak References ---

(defclass weak-reference-trait ()
  ((weak-pointer-list :accessor plan-weak-pointers
    :initform (make-array 256 :adjustable t
                          :initial-element 0 :fill-pointer 0)))
  (:documentation "Mixin that adds weak reference processing."))

(defun make-weak-pointer (referent)
  "Create a weak pointer to REFERENT in the active plan's heap."
  (let ((plan *active-plan*))
    (unless plan (error 'no-active-plan))
    (let ((vm (plan-vm plan)))
      (let ((addr (plan-allocate plan 3 :default)))
        (when addr
          (setf (vm-object-header vm addr)
                (make-object-header 2 :type-tag +type-tag-object+))
          (setf (vm-object-reference vm addr 0) referent)
          (setf (vm-object-reference vm addr 1) 0)
          (when (typep plan 'weak-reference-trait)
            (vector-push-extend addr (plan-weak-pointers plan)))
          addr)))))

(defun update-weak-pointer-referents (plan)
  "Update forwarded referents in weak pointers."
  (let ((vm (plan-vm plan)))
    (loop with wp-vec = (plan-weak-pointers plan)
          for i from 0 below (fill-pointer wp-vec)
          do (let* ((wp (aref wp-vec i))
                    (ref (vm-object-reference vm wp 0)))
               (when (and (not (zerop ref))
                          (vm-object-is-forwarded-p vm ref))
                 (setf (vm-object-reference vm wp 0)
                       (vm-object-forwarding-pointer vm ref)))))))

(defun process-weak-references (plan)
  "Clear weak pointers whose referents are dead."
  (let ((vm (plan-vm plan))
        (live-count 0))
    (loop with wp-vec = (plan-weak-pointers plan)
          for i from 0 below (fill-pointer wp-vec)
          do (let* ((wp (aref wp-vec i))
                    (ref (vm-object-reference vm wp 0)))
               (cond
                 ((or (zerop ref)
                      (vm-object-is-marked-p vm ref))
                  (setf (aref wp-vec live-count) wp)
                  (incf live-count))
                 (t
                  (setf (vm-object-reference vm wp 0) 0)))))
    (setf (fill-pointer (plan-weak-pointers plan)) live-count)))

(defmethod plan-collect :around ((plan weak-reference-trait) &key cycle-kind)
  "Update weak pointer referents before collection and clear dead ones after."
  (update-weak-pointer-referents plan)
  (call-next-method)
  (process-weak-references plan))
