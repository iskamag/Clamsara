(in-package #:clamsara)

;;; --- GC Statistics ---

(defvar *gc-count* 0 "Total number of GC cycles.")
(defvar *gc-pause-time* 0 "Total GC pause time in internal time units.")

(defun reset-gc-stats ()
  (setf *gc-count* 0 *gc-pause-time* 0))

(defun gc-stats ()
  (list :gc-count *gc-count* :gc-pause-time *gc-pause-time*))
