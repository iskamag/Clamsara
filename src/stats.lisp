;;;; stats.lisp -- event counters (paper-v8 ch. testing).
;;;;
;;;; The simulator measures in EVENTS that transfer to hardware, not wall
;;;; clock: faults serviced, barriers executed, words copied, queue spills,
;;;; closure passes.  This lets the simulator rank collectors meaningfully.

(in-package #:clamsara)

(defclass stats ()
  ((events :accessor stats-events :initform (make-hash-table :test 'eq))))

(defun make-stats () (make-instance 'stats))

(defun stats-event (stats name delta)
  "Add DELTA to the event counter NAME (a keyword)."
  (incf (gethash name (stats-events stats) 0) delta))

(defun stats-get (stats name)
  (gethash name (stats-events stats) 0))

(defun stats-reset (stats)
  (clrhash (stats-events stats))
  stats)

(defun stats-snapshot (stats)
  "A fresh alist of (name . count)."
  (let (result)
    (maphash (lambda (k v) (push (cons k v) result)) (stats-events stats))
    (nreverse result)))

(defun stats-merge (into from)
  (maphash (lambda (k v) (incf (gethash k (stats-events into) 0) v))
           (stats-events from))
  into)

;; ---- GC event protocol (persistence.tex); checkpoint is the live hook ----

(defgeneric gc-event-checkpoint (plan vm dirty-pages)
  (:method (plan vm dirty-pages) (declare (ignore plan vm dirty-pages)) nil))
