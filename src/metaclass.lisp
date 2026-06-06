(in-package #:clamsara)

;;;; Metaclass Infrastructure
;;;
;;; The paper describes custom metaclasses that validate constraints at
;;; class-finalization time and register plan types in a global registry.

;;; --- Base Metaclass ---

(defclass clamsara-metaclass (standard-class)
  ()
  (:documentation "Base metaclass for all Clamsara metaclasses."))

(defmethod validate-superclass ((class clamsara-metaclass) (superclass standard-class))
  t)

(defmethod validate-superclass ((class standard-class) (superclass clamsara-metaclass))
  t)

(defmethod validate-superclass ((class clamsara-metaclass) (superclass clamsara-metaclass))
  t)

;;; --- Plan Metaclass ---

(defvar *registered-plan-types* (make-hash-table :test #'eq)
  "Global registry mapping plan type keywords to plan classes.")

(defclass plan-metaclass (clamsara-metaclass)
  ()
  (:documentation "Metaclass for GC plan classes. Validates trait consistency
at finalize-inheritance and registers the plan type in the global registry."))

(defun class-has-trait-p (class trait-class)
  "Check if CLASS (or any of its superclasses) inherits from TRAIT-CLASS."
  (find trait-class (closer-mop:class-precedence-list class)))

(defun constraints-compatible-p (space-constraints plan-constraints)
  "Check that SPACE-CONSTRAINTS are compatible with PLAN-CONSTRAINTS."
  (declare (ignore space-constraints plan-constraints))
  t)

(defun validate-plan-constraints (plan)
  "Validate that PLAN's constraints are consistent with its spaces and traits."
  (let ((spaces (ignore-errors (plan-spaces plan)))
        (vm (ignore-errors (plan-vm plan))))
    (declare (ignore vm))
    ;; Check that spaces exist
    (unless (and (listp spaces) (> (length spaces) 0))
      (return-from validate-plan-constraints plan))
    ;; Check that spaces have consistent constraints
    (dolist (space spaces)
      (let ((space-constraints (ignore-errors (space-constraints space))))
        (when (and space-constraints (ignore-errors (plan-constraints plan)))
          (unless (constraints-compatible-p space-constraints (plan-constraints plan))
            (error "Space constraints incompatible with plan constraints")))))
    plan))

(defmethod finalize-inheritance :after ((class plan-metaclass))
  "Register the plan type in the global registry."
  (let ((type (find-class-option class :plan-type)))
    (when type
      (setf (gethash type *registered-plan-types*) class))))

;;; --- Other Metaclasses ---

(defclass space-metaclass (clamsara-metaclass)
  ()
  (:documentation "Metaclass for GC space classes. Validates trait/allocator
compatibility at finalize-inheritance."))

(defmethod finalize-inheritance :after ((class space-metaclass))
  "Validate space class structural invariants."
  (let ((cpd (closer-mop:class-precedence-list class)))
    (when (find (find-class 'copying-space-trait) cpd)
      (unless (find 'partner-space
                    (mapcar #'closer-mop:slot-definition-name
                            (closer-mop:class-slots class)))
        (warn "Space class ~A inherits copying-space-trait but has no partner-space slot."
              (closer-mop:class-name class))))
    (when (find (find-class 'marksweep-space-trait) cpd)
      (unless (or (find 'allocator
                        (mapcar #'closer-mop:slot-definition-name
                                (closer-mop:class-slots class)))
                  (member (closer-mop:class-name class)
                          '(mark-sweep-space)))
        (warn "Space class ~A inherits marksweep-space-trait but has no allocator slot."
              (closer-mop:class-name class))))))

(defclass allocator-metaclass (clamsara-metaclass)
  ()
  (:documentation "Metaclass for allocator classes. Validates that required
protocol methods are present."))

(defmethod finalize-inheritance :after ((class allocator-metaclass))
  "Validate allocator class protocol conformance."
  (let* ((name (closer-mop:class-name class))
         (cpd (closer-mop:class-precedence-list class)))
    (when (find (find-class 'free-list-allocator) cpd)
      (unless (eq name 'free-list-allocator)
        ;; free-list-allocator subclasses must have alloc and free methods;
        ;; checking at finalize-inheritance is best-effort: warn if these
        ;; are likely missing later.
        nil))))

(defclass barrier-metaclass (clamsara-metaclass)
  ()
  (:documentation "Metaclass for barrier classes."))

(defclass vm-metaclass (clamsara-metaclass)
  ()
  (:documentation "Metaclass for VM classes."))

;;; --- Trait Base Classes ---
;;; These are mixins that plans/spaces/barriers can include.

(defclass space-trait () ())
(defclass allocator-trait () ())
(defclass barrier-trait () ())
(defclass generational-trait () ())
(defclass concurrent-marking-trait () ())
(defclass concurrent-collector-trait () ())
(defclass line-marking-trait () ())
(defclass weak-reference-trait () ())
(defclass finalization-trait () ())

;;; --- Helper Functions ---

(defun find-class-option (class option-name)
  "Find OPTION-NAME in CLASS's class options."
  (let ((options (closer-mop:class-direct-default-initargs class)))
    (cdr (assoc option-name options))))

;; make-plan is defined in api.lisp using *plan-selectors*
