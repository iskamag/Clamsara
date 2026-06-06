(in-package #:clamsara)

;;; --- Work-Packet Scheduler ---
;;; Manages work distribution for concurrent and parallel GC.
;;; Single-threaded initially; provides the protocol for multi-threaded extensions.

(defclass gc-work-scheduler ()
  ((plan :initarg :plan :reader scheduler-plan)
   (buckets :initarg :buckets :accessor scheduler-buckets :initform nil
    :documentation "Simple-vector of work buckets, one per phase.")
   (work-queue :initform nil :accessor scheduler-work-queue
    :documentation "Ring buffer work queue (simple-vector).")
   (queue-head :initform 0 :accessor scheduler-queue-head :type fixnum)
   (queue-tail :initform 0 :accessor scheduler-queue-tail :type fixnum)
   (queue-capacity :initarg :queue-capacity :initform 1024
    :accessor scheduler-queue-capacity :type fixnum)
   (worker-count :initarg :worker-count :initform 1
    :accessor scheduler-worker-count :type fixnum))
  (:documentation "Work-packet scheduler for parallel GC work distribution."))

(defun make-gc-work-scheduler (&key plan (queue-capacity 1024) (worker-count 1))
  (make-instance 'gc-work-scheduler
    :plan plan
    :queue-capacity queue-capacity
    :worker-count worker-count
    :buckets (make-array 4 :initial-element nil)))

;;; --- Scheduler Protocol ---

(defgeneric scheduler-add-work (scheduler work)
  (:documentation "Add a work packet to the scheduler."))

(defgeneric scheduler-run-all (scheduler)
  (:documentation "Execute all scheduled work."))

(defgeneric scheduler-schedule-collection (scheduler plan)
  (:documentation "Schedule a full collection cycle."))

(defgeneric scheduler-steal-work (scheduler)
  (:documentation "Try to steal work from another worker. Returns a work packet or NIL."))

;;; --- Default (single-threaded) implementations ---

(defmethod scheduler-add-work ((scheduler gc-work-scheduler) work)
  (let ((queue (scheduler-work-queue scheduler)))
    (unless queue
      (setf queue (make-array (scheduler-queue-capacity scheduler)
                              :element-type t :initial-element nil)
            (scheduler-work-queue scheduler) queue))
    (let ((tail (scheduler-queue-tail scheduler))
          (cap (scheduler-queue-capacity scheduler)))
      (setf (aref queue tail) work
            (scheduler-queue-tail scheduler) (mod (1+ tail) cap))
      (when (= (scheduler-queue-tail scheduler) (scheduler-queue-head scheduler))
        (warn 'queue-overflow :message "Scheduler work queue overflow")))))

(defmethod scheduler-run-all ((scheduler gc-work-scheduler))
  (let ((queue (scheduler-work-queue scheduler)))
    (when queue
      (loop until (= (scheduler-queue-head scheduler)
                     (scheduler-queue-tail scheduler))
            for head = (scheduler-queue-head scheduler)
            for cap = (scheduler-queue-capacity scheduler)
            for work = (aref queue head)
            do (setf (scheduler-queue-head scheduler) (mod (1+ head) cap))
            when (functionp work)
              do (funcall work)))))

(defmethod scheduler-schedule-collection ((scheduler gc-work-scheduler) plan)
  "Schedule collection phases as work packets. In single-threaded mode,
executes sequentially via plan-collect (which handles generational scheduling)."
  (scheduler-add-work scheduler
    (lambda ()
      (plan-collect plan :cycle-kind :major)))
  (scheduler-run-all scheduler))

(defmethod scheduler-steal-work ((scheduler gc-work-scheduler))
  "Single-worker mode: just dequeue from our own queue."
  (let ((queue (scheduler-work-queue scheduler)))
    (when queue
      (unless (= (scheduler-queue-head scheduler)
                 (scheduler-queue-tail scheduler))
        (let ((head (scheduler-queue-head scheduler))
              (cap (scheduler-queue-capacity scheduler)))
          (prog1 (aref queue head)
            (setf (scheduler-queue-head scheduler) (mod (1+ head) cap))))))))

;;; --- Concurrent Marking Trait ---

(defclass concurrent-marking-trait ()
  ((marking-thread :initform nil :accessor cm-marking-thread
    :documentation "Thread performing concurrent marking (NIL in single-threaded mode).")
   (mark-phase :initform :idle :accessor cm-mark-phase :type (member :idle :root-scanning :marking :draining)
    :documentation "Current concurrent marking phase."))
  (:documentation "Trait for plans that support concurrent marking.
The marking thread runs concurrently with mutators using SATB barriers.
In single-threaded simulator mode, marking happens during STW pauses."))

(defgeneric cm-start-concurrent-mark (plan)
  (:documentation "Start concurrent marking. Returns immediately after initiating."))

(defgeneric cm-drain-mark-buffers (plan)
  (:documentation "Drain SATB queues and finish marking. Called at STW points."))

(defgeneric cm-is-marking-active-p (plan)
  (:documentation "Return T if concurrent marking is in progress.")
  (:method ((plan t)) nil))

(defmethod cm-start-concurrent-mark ((plan concurrent-marking-trait))
  (setf (cm-mark-phase plan) :marking)
  plan)

(defmethod cm-drain-mark-buffers ((plan concurrent-marking-trait))
  (when (eq (cm-mark-phase plan) :marking)
    (setf (cm-mark-phase plan) :draining)
    (let ((barrier (plan-barrier plan)))
      (when (typep barrier 'satb-barrier)
        (let ((tracer (plan-tracer plan)))
          (when tracer
            (satb-drain barrier
              (lambda (ref)
                (when tracer
                  (tracer-enqueue tracer ref))))))))
    (setf (cm-mark-phase plan) :idle)))

(defmethod cm-is-marking-active-p ((plan concurrent-marking-trait))
  (not (eq (cm-mark-phase plan) :idle)))

;;; --- Concurrent Collector Trait ---

(defclass concurrent-collector-trait ()
  ((concurrent-mode :initform :stop-the-world :accessor cc-concurrent-mode
    :type (member :stop-the-world :incremental :concurrent)
    :documentation "Collector concurrency mode."))
  (:documentation "Trait for plans that support concurrent or incremental collection.
Coordinates STW-to-concurrent transitions and mutator coordination."))

(defgeneric cc-enter-concurrent-mode (plan)
  (:documentation "Transition from STW to concurrent collection mode."))

(defgeneric cc-enter-stw-mode (plan)
  (:documentation "Transition from concurrent to STW collection mode."))

(defmethod cc-enter-concurrent-mode ((plan concurrent-collector-trait))
  (setf (cc-concurrent-mode plan) :concurrent))

(defmethod cc-enter-stw-mode ((plan concurrent-collector-trait))
  (setf (cc-concurrent-mode plan) :stop-the-world))
