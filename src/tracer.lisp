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
  (declare (type fixnum ref))
  (let* ((tail (tracer-tail tracer))
         (next-tail (mod (1+ tail) (tracer-capacity tracer))))
    (when (= next-tail (tracer-head tracer))
      (warn 'queue-overflow
            :message (format nil "Queue overflow at ~D entries; dropping ~D"
                             (tracer-capacity tracer) ref))
      (return-from tracer-enqueue nil))
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
