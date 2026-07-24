;;;; metaclass.lisp -- the component metaclasses (paper-v8 ch. heap/plans).
;;;;
;;;; Marker metaclasses that let a component validate its axis coordinates.
;;;; Validation runs at instance creation (shared-initialize :after) and again
;;;; at plan finalization/boot, so an incoherent configuration is rejected
;;;; before any code is generated.

(in-package #:clamsara)

(defclass space-metaclass (standard-class) ())
(defclass plan-metaclass (standard-class) ())
(defclass barrier-metaclass (standard-class) ())

;; SBCL needs to accept standard-class as a superclass of these.
(defmethod sb-mop:validate-superclass ((class space-metaclass) (super standard-class)) t)
(defmethod sb-mop:validate-superclass ((class plan-metaclass) (super standard-class)) t)
(defmethod sb-mop:validate-superclass ((class barrier-metaclass) (super standard-class)) t)

(defgeneric component-validate (instance)
  (:documentation "Validate a component's axis coordinates; signal on failure.")
  (:method ((instance t)) (declare (ignore instance)) nil))
