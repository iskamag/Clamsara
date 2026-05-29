(in-package #:clamsara)

;;; --- GC Statistics ---

(defclass plan-stats ()
  ((gc-count :initform 0 :accessor plan-stats-gc-count :type fixnum)
   (gc-time :initform 0.0 :accessor plan-stats-gc-time :type float))
  (:documentation "GC statistics for a plan."))

(defvar *gc-count* 0 "Total number of GC cycles.")
(defvar *gc-pause-time* 0 "Total GC pause time in internal time units.")

(defun reset-gc-stats ()
  (setf *gc-count* 0 *gc-pause-time* 0))

(defun gc-stats ()
  (list :gc-count *gc-count* :gc-pause-time *gc-pause-time*))
