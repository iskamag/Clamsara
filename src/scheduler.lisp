(in-package #:clamsara)

;;; --- Work-Packet Scheduler ---
;;; Single-threaded in initial implementation; scaffolding for parallel GC.

(defclass gc-work-scheduler ()
  ((plan :initarg :plan :reader scheduler-plan)
   (buckets :accessor scheduler-buckets :initform nil
    :documentation "Simple-vector of work buckets, one per phase."))
  (:documentation "Work-packet scheduler."))

(defun make-gc-work-scheduler (&key plan)
  (make-instance 'gc-work-scheduler :plan plan))

(defgeneric scheduler-add-work (scheduler work)
  (:documentation "Add a work packet to the scheduler."))

(defgeneric scheduler-run-all (scheduler)
  (:documentation "Execute all scheduled work."))

(defgeneric scheduler-schedule-collection (scheduler plan)
  (:documentation "Schedule a full collection cycle."))

(defmethod scheduler-add-work ((scheduler gc-work-scheduler) work)
  (declare (ignore scheduler work))
  nil)

(defmethod scheduler-run-all ((scheduler gc-work-scheduler))
  (declare (ignore scheduler))
  nil)

(defmethod scheduler-schedule-collection ((scheduler gc-work-scheduler) plan)
  (declare (ignore scheduler plan))
  nil)
