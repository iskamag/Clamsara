;;;; tracer.lisp -- the shared marking core (paper-v8 ch. collectors).
;;;;
;;;; One work-queue marking loop serves every tracing collector.  The queue
;;;; is an immortal-backed deque: it never silently drops a reference (the
;;;; v7 soundness hole).  On overflow it links a fresh immortal chunk, here
;;;; modelled as growth + a spill event count (the metric testing.tex uses).

(in-package #:clamsara)

(defclass tracer ()
  ((queue :accessor tr-queue :initform (make-array 1024 :adjustable t :fill-pointer 0))
   (head :accessor tr-head :initform 0)
   (vm :initarg :vm :accessor tr-vm)
   (spills :accessor tr-spills :initform 0)
   (capacity :accessor tr-capacity :initform 1024)
   (marked :accessor tr-marked :initform 0)))

(defun make-tracer (vm) (make-instance 'tracer :vm vm))

(declaim (inline tracer-empty-p tracer-size tracer-reset))
(defun tracer-empty-p (tr) (= (tr-head tr) (fill-pointer (tr-queue tr))))
(defun tracer-size (tr) (- (fill-pointer (tr-queue tr)) (tr-head tr)))
(defun tracer-reset (tr)
  (setf (fill-pointer (tr-queue tr)) 0 (tr-head tr) 0 (tr-marked tr) 0))

(defun tracer-enqueue (tr ref)
  (declare (optimize (speed 3) (safety 0)))
  (when (>= (fill-pointer (tr-queue tr)) (tr-capacity tr))
    (incf (tr-spills tr))                  ; linked an immortal overflow chunk
    (setf (tr-capacity tr) (* 2 (tr-capacity tr))))
  (vector-push-extend ref (tr-queue tr)))

(defun tracer-dequeue (tr)
  (declare (optimize (speed 3) (safety 0)))
  (if (tracer-empty-p tr)
      nil
      (prog1 (aref (tr-queue tr) (tr-head tr))
        (incf (tr-head tr))
        (when (tracer-empty-p tr)
          (setf (fill-pointer (tr-queue tr)) 0 (tr-head tr) 0)))))

(defun tracer-drain (tr fn)
  (loop until (tracer-empty-p tr) do (funcall fn (tracer-dequeue tr))))

;; ---- the marking core: roots -> trace closure ----------------------------

(defun mark-roots (plan tracer &key trace-kind)
  "Seed the mark queue from roots, then drain to fixpoint.  Policy-agnostic:
  space-trace-object does the per-space work (copy / mark / publish).  For
  copying collectors, root and child slots are updated to the forwarded address."
  (let ((vm (plan-vm plan)))
    ;; seed + update roots
    (let ((roots (vm-root-vector vm)))
      (dotimes (i (length roots))
        (let* ((ref (aref roots i))
               (addr (ref-strip-or-self vm ref)))
          (when (vm-reference-p vm ref)
            (let ((space (plan-space-for-address plan addr)))
              (when space
                (let ((new (space-trace-object space vm ref tracer :trace-kind trace-kind)))
                  (unless (eql new ref)
                    (setf (aref roots i) new)))))))))
    ;; drain: scan each grey object's slots, trace + update forwarded slots
    (tracer-drain tracer
      (lambda (ref)
        (let ((addr (ref-strip-or-self vm ref)))
          (dotimes (i (vm-object-reference-count vm addr))
            (let ((child (vm-object-reference vm addr i)))
              (when (vm-reference-p vm child)
                (let* ((caddr (ref-strip-or-self vm child))
                       (space (plan-space-for-address plan caddr)))
                  (when space
                    (let ((new (space-trace-object space vm child tracer :trace-kind trace-kind)))
                      (unless (eql new child)
                        (setf (vm-object-reference vm addr i) new)))))))))))))
