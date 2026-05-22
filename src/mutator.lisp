(in-package #:clamsara)

;;; --- Mutator Context ---
;;; Per-thread allocation state.

(defclass mutator-context ()
  ((id :initarg :id :reader mutator-id :type fixnum)
   (tlab-cursor :accessor mutator-tlab-cursor :type fixnum :initform 0)
   (tlab-limit :accessor mutator-tlab-limit :type fixnum :initform 0)
   (tlab-space :accessor mutator-tlab-space :initform nil)
   (barrier :accessor mutator-barrier :initform nil)
   (plan :initarg :plan :reader mutator-plan :initform nil)
   (allocators :accessor mutator-allocators :initform (make-hash-table :test 'eq)))
  (:documentation "Per-thread mutator state."))

(defun make-mutator (&key id plan barrier)
  (make-instance 'mutator-context :id (or id 0) :plan plan :barrier barrier))

(defun mutator-alloc (mutator size space-designator)
  "Allocate SIZE words through the mutator's plan."
  (let ((plan (mutator-plan mutator)))
    (unless plan (error "No plan bound to mutator"))
    (plan-allocate plan size space-designator)))
