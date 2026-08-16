;;;; tracer.lisp -- the shared marking core (paper-v8 ch. collectors).
;;;;
;;;; One work-queue marking loop serves every tracing collector.  The queue
;;;; is an immortal-backed deque: it never silently drops a reference (the
;;;; v7 soundness hole). The simulator preallocates the maximum useful queue
;;;; (one entry per heap word) at boot. A target backend may instead link
;;;; immortal chunks, as required by paper-v8.

(in-package #:clamsara)

(defclass tracer ()
  ((queue :initarg :queue :accessor tr-queue)
   (head :accessor tr-head :initform 0)
   (tail :accessor tr-tail :initform 0)
   (vm :initarg :vm :accessor tr-vm)
   (spills :accessor tr-spills :initform 0)
   (capacity :initarg :capacity :accessor tr-capacity)
   (marked :accessor tr-marked :initform 0)))

(defun make-tracer (vm)
  (let ((capacity (vm-heap-size vm)))
    (make-instance 'tracer :vm vm :capacity capacity
                   :queue (make-array capacity :element-type 'fixnum
                                      :initial-element 0))))

(declaim (inline tracer-empty-p tracer-size tracer-reset))
(defun tracer-empty-p (tr) (= (tr-head tr) (tr-tail tr)))
(defun tracer-size (tr) (- (tr-tail tr) (tr-head tr)))
(defun tracer-reset (tr)
  (setf (tr-head tr) 0 (tr-tail tr) 0 (tr-marked tr) 0))

(defun tracer-enqueue (tr ref)
  (declare (optimize (speed 3) (safety 0)))
  (when (>= (tr-tail tr) (tr-capacity tr))
    ;; One queue entry per heap word is a strict upper bound on the number of
    ;; distinct marked objects. Reaching it means a tracer invariant failed.
    ;; Keep the event visible even though this simulator reports exhaustion
    ;; rather than linking a target-side immortal spill chunk.
    (incf (tr-spills tr))
    (let ((stats (%stats-for-vm (tr-vm tr))))
      (when stats (stats-event stats :queue-spills 1)))
    (error 'heap-exhausted :requested-size 1 :space :tracer-queue))
  (setf (aref (tr-queue tr) (tr-tail tr)) ref)
  (incf (tr-tail tr))
  ref)

(defun tracer-dequeue (tr)
  (declare (optimize (speed 3) (safety 0)))
  (if (tracer-empty-p tr)
      nil
      (prog1 (aref (tr-queue tr) (tr-head tr))
        (incf (tr-head tr))
        (when (tracer-empty-p tr)
          (setf (tr-tail tr) 0 (tr-head tr) 0)))))

(defun tracer-drain (tr fn collector-state)
  "Invoke FN as (FN COLLECTOR-STATE REF) until the preallocated queue is empty."
  ;; A drain is one transitive-closure pass.  Keep this outside the loop: it
  ;; is one fixpoint operation, not one event per object, and does not cons.
  (let ((stats (or (and (typep collector-state 'plan)
                        (plan-stats collector-state))
                   (%stats-for-vm (tr-vm tr)))))
    (when stats (stats-event stats :closure-passes 1)))
  (loop until (tracer-empty-p tr)
        do (funcall fn collector-state (tracer-dequeue tr))))

;; ---- the marking core: roots -> trace closure ----------------------------

(defun mark-root-reference (plan ref)
  (let* ((vm (plan-vm plan))
         (tracer (plan-tracer plan))
         (addr (ref-strip-or-self vm ref)))
    (if (vm-reference-p vm ref)
        (let ((space (plan-space-for-address plan addr)))
          (if space
              (space-trace-object
               space vm ref tracer
               :trace-kind (plan-active-trace-kind plan))
              ref))
        ref)))

(defun trace-root-in (plan ref target-space &key trace-kind)
  "Trace the root REF if it lives in TARGET-SPACE; return the (possibly
forwarded) reference.  Shared by every minor/private collector's root seeder."
  (let ((vm (plan-vm plan)))
    (if (and (vm-reference-p vm ref)
             (space-contains-p target-space (ref-strip-or-self vm ref)))
        (space-trace-object target-space vm ref (plan-tracer plan)
                            :trace-kind trace-kind)
        ref)))

(defun trace-object-children (plan ref
                              &key target-space trace-kind
                                (exclude-weak-referent t))
  "Trace every reference slot of the object at REF, routing each child
through its owning space's space-trace-object (restricted to TARGET-SPACE
when given), writing back forwarded references.  Returns REF.
Top-level with explicit state: no host closure per object.  Weak pointers'
referent slot 0 is excluded by default (weak.tex §1); healing paths pass
:exclude-weak-referent nil so a moved referent is resolved in the slot too."
  (let* ((vm (plan-vm plan))
         (tracer (plan-tracer plan))
         (addr (ref-strip-or-self vm ref))
         (slots (vm-reference-slots vm addr))
         (weak-p (and exclude-weak-referent (weak-pointer-p vm addr))))
    (labels ((process (i)
               (when (or (not weak-p) (not (zerop i)))
                 (let ((child (vm-object-reference vm addr i)))
                   (when (vm-reference-p vm child)
                     (let* ((caddr (ref-strip-or-self vm child))
                            (space (plan-space-for-address plan caddr)))
                       (when (and space
                                  (or (null target-space)
                                      (eq space target-space)))
                         (let ((new
                                 (space-trace-object
                                  space vm child tracer
                                  :trace-kind trace-kind)))
                           (unless (eql new child)
                             (setf (vm-object-reference vm addr i)
                                   new))))))))))
      (if slots
          (loop for i across slots do (process i))
          (dotimes (i (vm-object-reference-count vm addr)) (process i))))
    ref))

(defun mark-grey-reference (plan ref)
  (trace-object-children
   plan ref :trace-kind (plan-active-trace-kind plan)))

(defun mark-roots (plan tracer &key trace-kind)
  "Seed the mark queue from roots, then drain to fixpoint.  Policy-agnostic:
  space-trace-object does the per-space work (copy / mark / publish).  For
  copying collectors, root and child slots are updated to the forwarded address."
  (setf (plan-active-trace-kind plan) trace-kind)
  (tracer-reset tracer)
  ;; The visitor functions are top-level and state is explicit: neither step
  ;; constructs a host closure on the collection path.
  (vm-scan-roots (plan-vm plan) plan #'mark-root-reference)
  (tracer-drain tracer #'mark-grey-reference plan))

(defun sticky-rescan-dirty (plan)
  "Rescan marked objects changed since the last sticky minor.
Their mark bit cannot double as this cycle's grey bit, so the write barrier
records them in the per-object log stratum."
  (let* ((vm (plan-vm plan))
         (tracer (plan-tracer plan))
         (log (vm-stratum vm :log))
         (object-start (vm-object-start vm)))
    (when (and log object-start)
      (dolist (space (plan-spaces plan))
        (loop for address from (space-base-address space)
              below (space-end-address space)
              when (and (s-test-bit object-start address)
                        (s-test-bit log address))
                do (tracer-enqueue tracer address)))
      (s-clear log)
      (tracer-drain tracer #'mark-grey-reference plan)))
  plan)
