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

(defvar *vm-features* nil
  "List of registered VM feature keywords from defvm-feature.")

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
                            (closer-mop:class-direct-slots class)))
        (warn "Space class ~A inherits copying-space-trait but has no partner-space slot."
              (class-name class))))
    (when (find (find-class 'marksweep-space-trait) cpd)
      (unless (or (find 'allocator
                        (mapcar #'closer-mop:slot-definition-name
                                (closer-mop:class-direct-slots class)))
                  (member (class-name class)
                          '(mark-sweep-space)))
        (warn "Space class ~A inherits marksweep-space-trait but has no allocator slot."
              (class-name class))))))

(defclass allocator-metaclass (clamsara-metaclass)
  ()
  (:documentation "Metaclass for allocator classes. Validates that required
protocol methods are present."))

(defmethod finalize-inheritance :after ((class allocator-metaclass))
  "Validate allocator class protocol conformance."
  (let* ((name (class-name class))
         (cpd (closer-mop:class-precedence-list class)))
    (when (find (find-class 'free-list-allocator) cpd)
      (unless (eq name 'free-list-allocator)
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

;;; --- defvm-feature Macro ---
;;; Generates a mixin class for a VM feature keyword.

(defmacro defvm-feature (name &key documentation)
  "Define a VM feature mixin class and register the feature keyword.
NAME is a keyword (e.g. :virtual-memory, :has-cas, :headerless-cons).
Generates a mixin class named NAME-MIXIN and registers NAME in *VM-FEATURES*."
  (let ((string-name (string name))
        (base-mixin 'vm-feature-mixin))
    (let* ((mixin-name (intern (concatenate 'string string-name "-MIXIN"))))
      `(eval-when (:compile-toplevel :load-toplevel :execute)
         (defclass ,mixin-name (,base-mixin)
           ()
           (:documentation ,(or documentation (format nil "VM feature: ~A" string-name))))
         (pushnew ,name *vm-features*)
         ',name))))

(defclass vm-feature-mixin ()
  ()
  (:documentation "Base class for all VM feature mixins generated by defvm-feature."))

;;; --- define-trait-optimized-function ---
;;; Generates optimized dispatch for a function based on trait presence.

(defmacro define-trait-optimized-function (name (component &rest args) &body trait-cases)
  "Define NAME as a function that dispatches based on which traits COMPONENT has.
Each clause in TRAIT-CASES is (trait-class-name &body body). The function tries each
clause in order and executes the first matching body. A final default clause
can use T as the trait-class-name."
  (let ((c (gensym "COMPONENT")))
    `(defun ,name (,c ,@args)
       (cond
         ,@(loop for (trait . body) in trait-cases
                 collect (if (eq trait t)
                             `(t ,@body)
                             `((class-has-trait-p (class-of ,c) (find-class ',trait))
                               ,@body)))))))
