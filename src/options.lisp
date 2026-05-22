(in-package #:clamsara)

;;; --- Plan Selector ---
;;; Maps plan type keywords to constructor functions.

(defvar *plan-selectors* (make-hash-table :test 'eq)
  "Registry of plan type keywords to constructors.")

(defun plan-selector (type vm heap-size &rest initargs)
  "Create a plan of TYPE using the registered selector."
  (let ((constructor (gethash type *plan-selectors*)))
    (unless constructor
      (error "Unknown plan type: ~A" type))
    (apply constructor vm heap-size initargs)))

(defun register-plan-selector (type constructor)
  (setf (gethash type *plan-selectors*) constructor))
