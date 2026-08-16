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

;;; The simulator inherits several capability mixins.  Since those mixins are
;;; sibling direct superclasses, their inherited primary methods can lose to
;;; the vm-binding defaults under CLOS method ordering.  Keep the simulator's
;;; advertised capability contract explicit rather than relying on that
;;; ordering.
(defmethod vm-tier ((vm simulator-vm))
  (declare (ignore vm))
  :t2)

(defmethod vm-has-feature-p ((vm simulator-vm) (feature (eql :t2)))
  (declare (ignore vm feature))
  t)

(defmethod vm-has-feature-p ((vm simulator-vm) (feature (eql :ring0)))
  (declare (ignore vm feature))
  t)

(defmethod vm-has-feature-p ((vm simulator-vm) (feature (eql :virtual-memory)))
  (declare (ignore vm feature))
  t)

(defmethod vm-has-feature-p ((vm simulator-vm) (feature (eql :coloured-pointers)))
  (declare (ignore vm feature))
  t)

(defun %make-simulator-vm (class heap-words plan)
  (when (>= heap-words (ash 1 +colour-pos+))
    (error 'clamsara-error
           :message "simulator heap does not fit below the colour bits"))
  (let* ((heap (make-array heap-words :element-type '(unsigned-byte 64)
                          :initial-element 0))
         (roots (make-array heap-words :element-type 'fixnum
                            :initial-element 0 :fill-pointer 0))
         (fwd (make-array heap-words :element-type 'fixnum :initial-element 0))
         (rc (make-array heap-words :element-type 'fixnum :initial-element 0))
         (vm (make-instance class
                            :heap heap :heap-size heap-words :roots roots
                            :fwd-table fwd :rc-table rc :plan plan)))
    ;; object-start stratum at the VM's minimum alignment (1 word here).
    (setf (vm-object-start vm)
          (make-stratum :object-start (vm-min-alignment-words vm) :bit heap-words))
    ;; Every advertised software-MMU capability is ready before booted
    ;; collector code can run; MMU-ENSURE will not allocate on first use.
    (mmu-init vm)
    vm))

(defun make-simulator-vm (heap-words &key plan)
  "Allocate a fresh heap of HEAP-WORDS words and a simulator VM over it."
  (%make-simulator-vm 'simulator-vm heap-words plan))
