;;;; compile.lisp -- compile-to-functions and boot (paper-v8 ch. compilation).
;;;;
;;;; The compiler turns the MOP-composed collector into plain functions at
;;;; boot so the hot path has no generic dispatch.  Each component implements
;;;; compile-to-functions returning an alist of (name . lambda-form); the
;;;; append combination aggregates the inheritance chain.  Axis resolution
;;;; (metadata location, barrier fusion, moving model) is emitted once here.
;;;; In the simulator the resolved code is the per-plan phase methods plus the
;;;; cached closure below; the seam exists for future per-fragment splicing.

(in-package #:clamsara)

(defgeneric compile-to-functions (component)
  (:method-combination append)
  (:method append ((c t)) (list))
  (:documentation "Return an alist of (name . lambda-form) for the component."))

(defgeneric boot-gc (plan)
  (:method ((p plan))
    (finalize-plan p)
    (let ((table (plan-function-table p)))
      (loop for (name . form) in (compile-to-functions p)
            do (setf (gethash name table) (compile nil form))))
    p))

(defmethod compile-to-functions append ((p plan))
  "Emit the compiled plan-collect: one closure, no per-cycle gethash."
  (list
   (cons 'plan-collect
         `(lambda (plan cycle-kind)
            (let ((ck (or cycle-kind (cycle-decision plan))))
              (plan-collect-phase plan ck))))))

(defun cycle-decision (plan)
  "Default cycle kind.  Generational plans override via :around on plan-collect."
  :full)

;; ---- construction -------------------------------------------------------

(defun make-plan (&rest args &key name vm spaces barrier publication constraints
                  &allow-other-keys)
  "Construct a generic plan instance and finalize it."
  (declare (ignore args))
  (let ((p (make-instance 'plan :name name :vm vm :spaces spaces
                           :barrier barrier :publication publication
                           :constraints (or constraints (make-instance 'plan-constraints)))))
    (finalize-plan p)
    p))

(defmacro defplan (name &body args)
  "Define a parameter holding a configured plan."
  `(defparameter ,name (make-plan ,@args)))

;; ---- axis resolution helpers (used by future per-fragment emitters) ------

(defun resolve-metadata-location (plan datum)
  "Where DATUM physically lives for this plan (Axis 2)."
  (vm-location (plan-vm plan) datum))

(defun resolve-barrier-sequence (plan)
  "The fused list of barrier rules (Axis 5), in application order."
  (when (plan-barrier plan) (barrier-rules (plan-barrier plan))))

;; ---- space layout helpers (used by the plan constructors) ---------------

(defun partition-pages (total-pages fractions)
  "FRACTIONS is a list of ratios summing to <= 1.  Return (start . count) pairs,
page 0 reserved for the null sentinel; the last fraction absorbs slack."
  (let* ((usable (max 0 (1- total-pages)))
         (n (length fractions))
         (counts (loop for f in (if (zerop n) fractions (butlast fractions))
                       collect (floor (* usable f))))
         (sum (reduce #'+ counts :initial-value 0))
         (counts (if (zerop n) counts
                    (append counts (list (max 0 (- usable sum)))))))
    (let ((start 1) result)
      (dolist (c counts) (push (cons start c) result) (incf start c))
      (nreverse result))))

(declaim (inline make-space))
(defun make-space (class vm start-page page-count &rest initargs)
  (apply #'make-instance class :vm vm :start-page start-page :page-count page-count
         :default-space t initargs))
