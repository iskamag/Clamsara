;;;; plans/genms.lisp -- generational: nursery + mark-sweep mature.

(in-package #:clamsara)
(defun make-genms-plan (vm heap-size)
  (declare (ignore heap-size))
  (%make-generational :genms vm 'mark-sweep-space nil))
