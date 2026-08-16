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

(defmethod vm-has-feature-p ((vm simulator-vm) (feature (eql :t1)))
  (declare (ignore vm feature))
  t)

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

(defun %make-simulator-vm (class heap-words plan &key
                              (work-packets (max 1 heap-words))
                              (root-region-capacity 16))
  (when (>= heap-words (ash 1 +colour-pos+))
    (error 'clamsara-error
           :message "simulator heap does not fit below the colour bits"))
  (unless (and (integerp root-region-capacity) (<= 0 root-region-capacity))
    (error 'clamsara-error :message "root-region-capacity must be a non-negative integer"))
  (let* ((heap (make-array heap-words :element-type '(unsigned-byte 64)
                          :initial-element 0))
         (roots (make-array heap-words :element-type 'fixnum
                            :initial-element 0 :fill-pointer 0))
         (fwd (make-array heap-words :element-type 'fixnum :initial-element 0))
         (rc (make-array heap-words :element-type 'fixnum :initial-element 0))
         ;; Descriptors themselves are immortal VM storage.  Registration only
         ;; fills these records and copies its map during boot.
         (root-regions (make-array root-region-capacity))
         (vm (make-instance class
                            :heap heap :heap-size heap-words :roots roots
                            :fwd-table fwd :rc-table rc
                            :root-regions root-regions
                            :root-region-capacity root-region-capacity
                            :plan plan)))
    (dotimes (i root-region-capacity)
      (setf (aref root-regions i) (%make-root-region)))
    ;; object-start stratum at the VM's minimum alignment (1 word here).
    (setf (vm-object-start vm)
          (make-stratum :object-start (vm-min-alignment-words vm) :bit heap-words))
    ;; Work packets and the one-worker scheduler are immortal VM storage: they
    ;; must exist before any plan or collector can enqueue work.
    (initialize-vm-scheduler vm :capacity work-packets)
    ;; Every advertised software-MMU capability is ready before booted
    ;; collector code can run; MMU-ENSURE will not allocate on first use.
    (mmu-init vm)
    vm))

(defun make-simulator-vm (heap-words &key plan
                             (work-packets (max 1 heap-words))
                             work-packet-count scheduler-capacity
                             (root-region-capacity 16))
  "Allocate a fresh heap and a simulator VM over it.
WORK-PACKETS (also accepted as WORK-PACKET-COUNT or SCHEDULER-CAPACITY)
is the fixed capacity of the VM's packet pool and scheduler queue.
ROOT-REGION-CAPACITY is the fixed number of explicit root-region descriptors
reserved at boot."
  (%make-simulator-vm 'simulator-vm heap-words plan
                      :work-packets (or scheduler-capacity
                                         work-packet-count
                                         work-packets)
                      :root-region-capacity root-region-capacity))
