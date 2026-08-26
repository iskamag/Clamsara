;;;; metaclass.lisp -- the component metaclasses (paper-v9 ch. philosophy).
;;;;
;;;; Marker metaclasses that let a component validate its axis coordinates.
;;;; Validation runs at instance creation (shared-initialize :after) and again
;;;; at plan finalization/boot, so an incoherent configuration is rejected
;;;; before any code is generated.

(in-package #:clamsara)

(defclass clamsara-metaclass (standard-class) ())
(defclass space-metaclass (clamsara-metaclass) ())
(defclass plan-metaclass (clamsara-metaclass) ())
(defclass allocator-metaclass (clamsara-metaclass) ())
(defclass barrier-metaclass (clamsara-metaclass) ())
(defclass vm-metaclass (clamsara-metaclass) ())

;; SBCL needs to accept standard-class and sibling Clamsara metaclasses as
;; superclasses of these component classes.
(defmethod sb-mop:validate-superclass
    ((class clamsara-metaclass) (super standard-class)) t)
(defmethod sb-mop:validate-superclass
    ((class clamsara-metaclass) (super clamsara-metaclass)) t)
(defmethod sb-mop:validate-superclass
    ((class space-metaclass) (super standard-class)) t)
(defmethod sb-mop:validate-superclass
    ((class plan-metaclass) (super standard-class)) t)
(defmethod sb-mop:validate-superclass
    ((class allocator-metaclass) (super standard-class)) t)
(defmethod sb-mop:validate-superclass
    ((class barrier-metaclass) (super standard-class)) t)
(defmethod sb-mop:validate-superclass
    ((class vm-metaclass) (super standard-class)) t)

(defgeneric component-validate (instance)
  (:documentation "Validate a component's axis coordinates; signal on failure.")
  (:method ((instance t)) (declare (ignore instance)) nil))
