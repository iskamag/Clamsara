(in-package #:clamsara)

;;; --- Plan Constraints ---

(defclass plan-constraints ()
  ((moves-objects :initarg :moves-objects :reader plan-moves-objects-p :initform nil)
   (generational :initarg :generational :reader plan-generational-p :initform nil)
   (nursery-kind :initarg :nursery-kind :reader plan-nursery-kind
    :type (member :copying :sticky nil) :initform nil)
   (num-generations :initarg :num-generations :reader plan-num-generations
    :type fixnum :initform 1)
   (needs-log-bit :initarg :needs-log-bit :reader plan-needs-log-bit-p :initform nil)
   (barrier :initarg :barrier :reader plan-barrier-type :type (member :none :object :satb)
    :initform :none)
   (needs-forwarding :initarg :needs-forwarding :reader plan-needs-forwarding-p :initform nil)
   (max-non-los-alloc-bytes :initarg :max-non-los-alloc-bytes
    :reader plan-max-non-los-alloc-bytes :type fixnum :initform 8192))
  (:documentation "Plan-level constraints describing the collection strategy."))

;;; --- Plan Protocol Generics ---

(defgeneric plan-collect (plan &key cycle-kind)
  (:documentation "Execute a GC cycle. CYCLE-KIND is :minor, :major, or :full.
   The default method delegates to a full-heap collection."))

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

(defgeneric plan-card-size-words (plan)
  (:documentation "Return the card size in words for this plan."))

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
    (default-space :initform nil :accessor plan-default-space)
    (sft :initform nil :accessor plan-sft
     :documentation "Space Function Table: simple-vector mapping page-index -> space for O(1) lookup."))
  (:documentation "A GC plan composed of spaces, barriers, and allocators."))

;;; --- Plan Helpers ---

(defun initialize-plan-heap (plan word-count)
  "Initialize or resize heap backing stores for PLAN.
Adds one extra page to account for page 0 being reserved as the null sentinel."
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

;;; --- Sticky Space Metrics ---
;;; Shared metrics for sticky generational plans (StickyImmix, StickyMS).

(defclass sticky-space-metrics ()
  ((live-young-bytes :initform 0 :accessor space-live-young-bytes :type fixnum
    :documentation "Bytes of live young objects found during the current nursery GC.")
   (dead-mature-bytes :initform 0 :accessor space-dead-mature-bytes :type fixnum
    :documentation "Bytes of dead mature objects found during the current nursery GC."))
  (:documentation "Metrics tracked during sticky generational nursery collection.
Used by mature-dead-ratio-exceeded-p for escalation decisions."))

(defmethod plan-handle-allocation-failure ((plan plan) size space-designator)
  (flet ((try-alloc ()
           (let* ((space (plan-get-space plan space-designator))
                  (alloc (space-allocator space)))
             (alloc alloc size))))
    (plan-request-gc plan)
    (plan-collect plan :cycle-kind :major)
    (or (try-alloc)
        (error 'heap-exhausted :plan plan))))

(defgeneric should-minor-gc-p (plan)
  (:documentation "Return T if the next collection should be nursery-only.
   Returns NIL if a full-heap (major) collection is warranted.")
  (:method ((plan plan)) nil))

(defgeneric plan-max-minor-gcs-before-major (plan)
  (:method ((plan plan)) 32))

(defgeneric nursery-exhausted-p (plan)
  (:documentation "True when the nursery is near capacity.")
  (:method ((plan plan)) nil))

(defgeneric mature-dead-ratio-exceeded-p (plan)
  (:documentation "True when accumulated mature garbage warrants a major GC.")
  (:method ((plan plan)) nil))

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

(defun plan-build-sft (plan)
  "Build the Space Function Table for O(1) space lookup by address."
  (let ((n-pages (pr-total-pages (plan-page-resource plan))))
    (unless n-pages
      (setf n-pages (ceiling (vm-heap-size (plan-vm plan)) +page-size-words+)))
    (let ((sft (make-array n-pages :initial-element nil)))
      (dolist (space (plan-spaces plan))
        (loop for p from (space-start-page space)
              below (+ (space-start-page space) (space-page-count space))
              do (setf (aref sft p) space)))
      (setf (plan-sft plan) sft))))

(defun plan-space-for-address (plan addr)
  "Return the space containing ADDR using SFT if available, linear search otherwise."
  (let ((sft (plan-sft plan)))
    (if sft
        (let ((page (floor (address-index addr) +page-size-words+)))
          (when (< page (length sft))
            (aref sft page)))
        (find-if (lambda (s) (space-contains-p s addr))
                 (plan-spaces plan)))))

;;; --- Plan Metaclass (stub - validates at finalization) ---
;;; In a full implementation this would be a proper CLOS metaclass.
;;; For the simulator, we use simple validation functions.

;; validate-plan-constraints is defined in metaclass.lisp
