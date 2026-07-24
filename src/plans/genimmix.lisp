;;;; plans/genimmix.lisp -- generational: nursery + immix mature.

(in-package #:clamsara)
(defun make-genimmix-plan (vm heap-size)
  (declare (ignore heap-size))
  (%make-generational :genimmix vm 'immix-space nil))
