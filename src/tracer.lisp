(in-package #:clamsara)

;;; --- Tracer ---
;;; Manages the work queue for transitive closure during GC.

(defclass tracer ()
  ((queue :initarg :queue :initform nil :reader tracer-queue
    :documentation "Ring buffer work queue (simple-vector).")
   (head :initform 0 :accessor tracer-head :type fixnum)
   (tail :initform 0 :accessor tracer-tail :type fixnum)
   (capacity :initarg :capacity :initform 0 :reader tracer-capacity :type fixnum)
   (vm :initarg :vm :reader tracer-vm)
   (trace-fn :initarg :trace-fn :accessor tracer-trace-fn :type function)
   (visit-count :initform 0 :accessor tracer-visit-count :type fixnum)
   (plan :initform nil :accessor tracer-plan)
   (major-gc-p :initform nil :accessor tracer-major-gc-p)
   (cycle-kind :initform :major :accessor tracer-cycle-kind
    :documentation "GC cycle kind: :minor, :major, or :full.")
   (trace-kind :initform :fast :accessor tracer-trace-kind
    :documentation "Trace kind: :fast or :defrag.")
   (trace-fn-enqueues-p :initform nil :accessor tracer-trace-fn-enqueues-p))
  (:documentation "Manages transitive closure during GC tracing."))

(defun make-tracer (vm trace-fn &key queue-size)
  (let ((size (or queue-size 4096)))
    (make-instance 'tracer
      :queue (make-array size :element-type 'fixnum :initial-element 0)
      :capacity size
      :vm vm
      :trace-fn trace-fn)))

(declaim (inline tracer-enqueue tracer-dequeue tracer-empty-p))

(defun tracer-enqueue (tracer ref)
  "Enqueue REF onto TRACER's work queue. Grows the queue if full."
  (declare (type fixnum ref))
  (let* ((tail (tracer-tail tracer))
         (head (tracer-head tracer))
         (cap (tracer-capacity tracer))
         (next-tail (mod (1+ tail) cap)))
    (when (= next-tail head)
      ;; Grow the queue: double capacity, copy elements
      (let* ((new-cap (* cap 2))
             (new-queue (make-array new-cap :element-type 'fixnum :initial-element 0))
             (old-queue (tracer-queue tracer)))
        (loop for i from 0
              for idx = head then (mod (1+ idx) cap)
              until (= idx tail)
              do (setf (aref new-queue i) (aref old-queue idx))
              finally (setf (slot-value tracer 'queue) new-queue
                            (slot-value tracer 'head) 0
                            (slot-value tracer 'tail) i
                            (slot-value tracer 'capacity) new-cap
                            tail i
                            next-tail (mod (1+ i) new-cap)))))
    (setf (aref (tracer-queue tracer) tail) ref)
    (setf (tracer-tail tracer) next-tail)))

(defun tracer-dequeue (tracer)
  (let ((head (tracer-head tracer)))
    (prog1 (aref (tracer-queue tracer) head)
      (setf (tracer-head tracer)
            (mod (1+ head) (tracer-capacity tracer))))))

(defun tracer-empty-p (tracer)
  (= (tracer-head tracer) (tracer-tail tracer)))

(defun tracer-process-queue (tracer)
  "Process all items in the work queue until empty."
  (loop until (tracer-empty-p tracer)
        for ref = (tracer-dequeue tracer)
        do (tracer-visit-object tracer ref)))

(defun tracer-visit-object (tracer addr)
  "Scan the references of the object at ADDR."
  (incf (tracer-visit-count tracer))
  (let ((vm (tracer-vm tracer))
        (fn (tracer-trace-fn tracer)))
    (vm-scan-object-references vm addr
      (lambda (ref slot-idx)
        (declare (ignore slot-idx))
        (let ((new-ref (funcall fn ref)))
          (when new-ref
            (unless (tracer-trace-fn-enqueues-p tracer)
              (tracer-enqueue tracer new-ref))))))))

(defun tracer-process-roots (tracer vm collector-state)
  "Start tracing by scanning roots, then process the work queue."
  (vm-scan-roots vm collector-state
    (lambda (root)
      (when (and root (not (zerop root)))
        (let ((result (funcall (tracer-trace-fn tracer) root)))
          (when result
            (unless (tracer-trace-fn-enqueues-p tracer)
              (tracer-enqueue tracer result)))))))
  (tracer-process-queue tracer))
