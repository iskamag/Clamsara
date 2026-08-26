;;;; stats.lisp -- event counters (paper-v8 ch. testing).
;;;;
;;;; The simulator measures in EVENTS that transfer to hardware, not wall
;;;; clock: faults serviced, barriers executed, words copied, queue spills,
;;;; closure passes.  This lets the simulator rank collectors meaningfully.

(in-package #:clamsara)

;; Keep the event vocabulary in one place.  Counters are deliberately plain
;; fixnums in a hash table: the table is warmed at plan boot, so recording an
;; event on a collector path never has to resize it or cons a key/value pair.
(defparameter +stats-event-names+
  '(:barrier-transfers :words-copied :objects-copied :queue-spills
    :closure-passes :pages-written :dirty-pages :pages-mapped :mmu-faults
    ;; Existing clients use this general cycle counter; retain it alongside
    ;; the paper metrics.
    :gc-cycles :gc-time :checkpoints)
  "Event names preallocated in every plan's statistics table.")

(defclass stats ()
  ((events :accessor stats-events :initform (make-hash-table :test 'eq))))

(defun make-stats () (make-instance 'stats))

(defun %stats-for-plan (plan)
  (and plan (plan-stats plan)))

(defun %stats-for-vm (vm)
  (and vm (vm-plan vm) (plan-stats (vm-plan vm))))

(defun stats-prepare (stats)
  "Preallocate the standard event slots in STATS.

This is called during plan finalization, before a collector can run.  It is
separate from MAKE-STATS to preserve the historical empty SNAPSHOT result for
stand-alone statistics objects." 
  (dolist (name +stats-event-names+ stats)
    (setf (gethash name (stats-events stats)) 0)))

(defun stats-event (stats name delta)
  "Add DELTA to the event counter NAME (a keyword)."
  (incf (gethash name (stats-events stats) 0) delta))

(defun stats-get (stats name)
  (gethash name (stats-events stats) 0))

(defun stats-reset (stats)
  ;; Retain the warmed keys: resetting a live plan must not make its next
  ;; collector event resize the hash table on the hot path.
  (maphash (lambda (name value)
             (declare (ignore value))
             (setf (gethash name (stats-events stats)) 0))
           (stats-events stats))
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
  (:method ((plan plan) (vm vm-binding) dirty-pages)
    ;; Checkpoint capture is a first-class event even when it writes no pages;
    ;; keep this counter on the event seam so every persistence backend reports
    ;; it consistently.
    (declare (ignore vm dirty-pages))
    (when (plan-stats plan)
      (stats-event (plan-stats plan) :checkpoints 1))
    nil)
  (:method (plan vm dirty-pages)
    (declare (ignore plan vm dirty-pages))
    nil))
