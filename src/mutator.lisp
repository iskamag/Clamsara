(in-package #:clamsara)

;;; --- Mutator Context ---
;;; Per-thread allocation state with TLAB (Thread-Local Allocation Buffer) support.

(defclass mutator-context ()
  ((id :initarg :id :reader mutator-id :type fixnum)
   (tlab-cursor :accessor mutator-tlab-cursor :type fixnum :initform 0)
   (tlab-limit :accessor mutator-tlab-limit :type fixnum :initform 0)
   (tlab-space :accessor mutator-tlab-space :initform nil)
   (barrier :initarg :barrier :accessor mutator-barrier :initform nil)
   (plan :initarg :plan :reader mutator-plan :initform nil)
   (allocators :accessor mutator-allocators :initform (make-hash-table :test 'eq)))
  (:documentation "Per-thread mutator state with TLAB fast-path allocation."))

(defun make-mutator (&key id plan barrier)
  (make-instance 'mutator-context :id (or id 0) :plan plan :barrier barrier))

;;; --- TLAB Fast Path ---

(defun tlab-alloc (mutator size)
  "Inline fast-path allocation from the mutator's TLAB.
Bumps the TLAB cursor if there is room; returns NIL if TLAB is exhausted."
  (let* ((cursor (mutator-tlab-cursor mutator))
         (new-cursor (+ cursor size)))
    (if (<= new-cursor (mutator-tlab-limit mutator))
        (progn
          (setf (mutator-tlab-cursor mutator) new-cursor)
          (make-address cursor))
        nil)))

(defun tlab-refill (mutator size)
  "Acquire a fresh TLAB from the underlying space allocator.
Returns T if a TLAB of at least SIZE words was acquired."
  (let* ((plan (mutator-plan mutator))
         (space (plan-get-space plan :default))
         (alloc (space-allocator space))
         (tlab-size (max (* size 8) (* +page-size-words+ 2))))
    (let ((block (alloc alloc tlab-size)))
      (when block
        (let ((start (address-index block)))
          (setf (mutator-tlab-cursor mutator) start
                (mutator-tlab-limit mutator) (+ start tlab-size)
                (mutator-tlab-space mutator) space)
          t)))))

(defun mutator-alloc (mutator size space-designator)
  "Allocate SIZE words through the mutator. Uses TLAB fast path for the
default space; falls back to plan-allocate for other spaces."
  (let ((plan (mutator-plan mutator)))
    (unless plan (error "No plan bound to mutator"))
    (if (or (eq space-designator :default)
            (eq (plan-get-space plan space-designator)
                (mutator-tlab-space mutator)))
        ;; TLAB fast path
        (or (tlab-alloc mutator size)
            (and (tlab-refill mutator size)
                 (tlab-alloc mutator size))
            ;; TLAB refill failed — full plan allocation with GC escalation
            (plan-allocate plan size space-designator))
        ;; Non-default space: use plan-allocate directly
        (plan-allocate plan size space-designator))))

(defun mutator-tlab-occupancy (mutator)
  "Return the fraction of the TLAB that has been consumed."
  (let ((cursor (mutator-tlab-cursor mutator))
        (limit (mutator-tlab-limit mutator)))
    (if (zerop limit)
        0.0
        (/ (float cursor) (float limit)))))
