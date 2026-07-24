;;;; vm/simulator.lisp -- the simulator VM: emulates every capability tier
;;;; in software (paper-v8 ch. bootstrap).  A plan that boots here boots on
;;;; Mezzano if Mezzano's tier is sufficient.

(in-package #:clamsara)

(defclass simulator-vm
    (vm-binding virtual-memory-mixin ring0-mixin has-cas128-mixin
     coloured-pointer-mixin software-mmu)
  ()
  (:documentation "The reference VM.  Advertises T0/T1/T2 + coloured pointers,
  all implemented in software via the software MMU."))

(defun make-simulator-vm (heap-words &key plan)
  "Allocate a fresh heap of HEAP-WORDS words and a simulator VM over it."
  (let* ((heap (make-array heap-words :element-type '(unsigned-byte 64)
                          :initial-element 0))
         (vm (make-instance 'simulator-vm :heap heap :heap-size heap-words
                            :plan plan)))
    ;; object-start stratum at the VM's minimum alignment (1 word here).
    (setf (vm-object-start vm)
          (make-stratum :object-start (vm-min-alignment-words vm) :bit heap-words))
    vm))
