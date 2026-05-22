(in-package #:clamsara)

;;; --- Plan Constraints ---

(defclass plan-constraints ()
  ((moves-objects :initarg :moves-objects :reader plan-moves-objects-p :initform nil)
   (generational :initarg :generational :reader plan-generational-p :initform nil)
   (needs-log-bit :initarg :needs-log-bit :reader plan-needs-log-bit-p :initform nil)
   (barrier :initarg :barrier :reader plan-barrier-type :type (member :none :object :satb)
    :initform :none)
   (needs-forwarding :initarg :needs-forwarding :reader plan-needs-forwarding-p :initform nil)
   (max-gc-threads :initarg :max-gc-threads :reader plan-max-gc-threads :initform 1))
  (:documentation "Plan-level constraints describing the collection strategy."))

;;; --- Plan Protocol Generics ---

(defgeneric plan-collect (plan)
  (:documentation "Execute a full GC cycle."))

(defgeneric plan-allocate (plan size space-designator)
  (:documentation "Allocate SIZE words from the space designated by SPACE-DESIGNATOR."))

(defgeneric plan-prepare (plan &key cycle-kind)
  (:documentation "Prepare the plan's spaces for collection."))

(defgeneric plan-release (plan &key cycle-kind)
  (:documentation "Release the plan's spaces after collection."))

(defgeneric plan-get-space (plan designator)
  (:documentation "Return the space for DESIGNATOR (e.g., :default, :nursery)."))

(defgeneric plan-handle-allocation-failure (plan size space-designator)
  (:documentation "Handle allocation failure by triggering GC and retrying."))

;;; --- Plan Class ---

(defclass plan ()
  ((name :initarg :name :reader plan-name :type string)
   (vm :initarg :vm :reader plan-vm)
   (spaces :initarg :spaces :accessor plan-spaces :initform nil :type list)
   (constraints :initarg :constraints :reader plan-constraints)
   (options :initarg :options :accessor plan-options :initform nil)
   (stats :initarg :stats :accessor plan-stats :initform nil)
   (page-resource :initarg :page-resource :accessor plan-page-resource)
   (card-table :initarg :card-table :accessor plan-card-table :initform nil)
   (barrier :initarg :barrier :accessor plan-barrier :initform nil)
   (scheduler :initarg :scheduler :accessor plan-scheduler :initform nil)
   (copy-config :initarg :copy-config :accessor plan-copy-config :initform nil)
   (function-table :initform (make-hash-table :test #'eq :size 64)
    :reader plan-function-table)
   (gc-requested :initform nil :accessor plan-gc-requested :type boolean)
   (tracer :initform nil :accessor plan-tracer)
   (default-space :initform nil :accessor plan-default-space))
  (:documentation "A GC plan composed of spaces, barriers, and allocators."))

;;; --- Plan Helpers ---

(defun initialize-plan-heap (plan word-count)
  "Initialize or resize heap backing stores for PLAN."
  (let ((actual (+ word-count +page-size-words+)))
    (ensure-heap actual)
    (ensure-page-table actual)
    (ensure-metadata actual)
    (let ((pr (initialize-page-resource actual))
          (ct (ensure-card-table actual)))
      (setf (plan-page-resource plan) pr
            (plan-card-table plan) ct)
      plan)))

(defun plan-add-space (plan space)
  (push space (plan-spaces plan)))

(defun plan-find-space (plan name)
  (find name (plan-spaces plan) :key #'space-name))

(defun plan-request-gc (plan)
  (setf (plan-gc-requested plan) t))

;;; --- Default Plan Methods ---

(defmethod plan-handle-allocation-failure ((plan plan) size space-designator)
  (plan-request-gc plan)
  (plan-collect plan)
  (let* ((space (plan-get-space plan space-designator))
         (alloc (space-allocator space)))
    (alloc alloc size)))

(defmethod plan-prepare ((plan plan) &key cycle-kind)
  (dolist (space (plan-spaces plan))
    (when (typep space 'collectable-space)
      (space-prepare space (plan-vm plan) :cycle-kind cycle-kind))))

(defmethod plan-release ((plan plan) &key cycle-kind)
  (let ((vm (plan-vm plan)))
    (dolist (space (plan-spaces plan))
      (when (typep space 'collectable-space)
        (space-release space vm :cycle-kind cycle-kind)))
    (vm-clear-all-forwarding vm)
    (vm-clear-all-log-bits vm)))

;;; --- Space-for-address helper ---

(defun plan-space-for-address (plan addr)
  (find-if (lambda (s) (space-contains-p s addr))
           (plan-spaces plan)))

;;; --- Plan Metaclass (stub - validates at finalization) ---
;;; In a full implementation this would be a proper CLOS metaclass.
;;; For the simulator, we use simple validation functions.

(defun validate-plan-constraints (plan)
  "Validate that the plan's constraints are consistent with its spaces."
  (let ((constraints (plan-constraints plan)))
    (when (plan-generational-p constraints)
      (unless (>= (plan-max-gc-threads constraints) 1)
        (error "Generational plan must have max-gc-threads >= 1")))
    plan))
