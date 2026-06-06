(in-package #:clamsara)

;;; --- GC Statistics ---

(defclass plan-stats ()
  ((gc-count :initform 0 :accessor plan-stats-gc-count :type fixnum)
   (gc-time :initform 0.0 :accessor plan-stats-gc-time :type float))
  (:documentation "GC statistics for a plan."))

(defun reset-gc-stats (plan)
  (setf (plan-stats-gc-count plan) 0
        (plan-stats-gc-time plan) 0.0))

(defun gc-stats (plan)
  (list :gc-count (plan-stats-gc-count plan)
        :gc-time (plan-stats-gc-time plan)))
