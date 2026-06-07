(in-package #:clamsara)

;;;; Barrier protocol

(defvar *barrier-selectors* '(:none :object :satb)
  "Valid barrier type specifiers.")

(defgeneric barrier-note-write (barrier source-addr slot-idx new-value &key old-value)
  (:documentation "Notify the BARRIER that a write has occurred.
OLD-VALUE is the previous reference value, captured before the write."))

(defgeneric barrier-note-read (barrier addr)
  (:documentation "Notify the BARRIER that a read of ADDR has occurred.
Returns the value to use (for read barriers that may remap or log)."))

(defgeneric barrier-card-scan (barrier vm scan-fn)
  (:documentation "Scan remembered cards / old-to-young references."))

(defgeneric barrier-clear-all (barrier)
  (:documentation "Reset all barrier state for a new GC cycle."))

;;; --- Barrier base class ---

(defclass barrier ()
  ()
  (:metaclass barrier-metaclass)
  (:documentation "Base class for GC barriers."))

;;; --- No barrier ---

(defclass no-barrier (barrier) ())

(defun make-no-barrier () (make-instance 'no-barrier))

(defmethod barrier-note-write ((b no-barrier) source-addr slot-idx new-value &key old-value)
  (declare (ignore source-addr slot-idx new-value old-value))
  nil)

(defmethod barrier-note-read ((b no-barrier) addr)
  addr)

(defmethod barrier-card-scan ((b no-barrier) vm scan-fn)
  (declare (ignore vm scan-fn))
  nil)

(defmethod barrier-clear-all ((b no-barrier))
  nil)

;;; --- Object barrier (generational card table) ---

(defclass object-barrier (barrier)
  ((card-table :initarg :card-table :accessor barrier-card-table)
   (nursery-start :initarg :nursery-start :accessor barrier-nursery-start)
   (nursery-end :initarg :nursery-end :accessor barrier-nursery-end)
   (vm :initarg :vm :initform nil :accessor barrier-vm
    :documentation "VM binding for log-bit-based age discrimination (sticky plans).")
   (dirty-cards :initform (make-array 64 :element-type 'fixnum
                                      :initial-element 0
                                      :adjustable t :fill-pointer 0)
    :accessor barrier-dirty-cards
    :documentation "Adjustable vector of dirty card indices for O(n_dirty) scan."))
  (:metaclass barrier-metaclass))

(defun make-object-barrier (card-table nursery-start nursery-end &key vm)
  (make-instance 'object-barrier
                 :card-table card-table
                 :nursery-start nursery-start
                 :nursery-end nursery-end
                 :vm vm))

(defun barrier-card-table-cards (barrier)
  (card-table-cards (barrier-card-table barrier)))

(defun card-dirty-p (barrier card-idx)
  (> (aref (barrier-card-table-cards barrier) card-idx) 0))

(defmethod barrier-note-write ((b object-barrier) source-addr slot-idx new-value &key old-value)
  (declare (ignore slot-idx old-value))
  ;; Mark the card if SOURCE is OLD and NEW-VALUE is YOUNG.
  ;; For sticky plans (log-bit discrimination), check log bits.
  ;; For separate-space plans, check address ranges.
  (let* ((vm (and (slot-boundp b 'vm) (slot-value b 'vm)))
         (log-source-old (and vm (not (vm-object-is-logged-p vm source-addr))))
         (log-target-young (and vm (vm-object-is-logged-p vm new-value)))
         (range-source-old (< source-addr (barrier-nursery-start b)))
         (range-target-young (and (>= new-value (barrier-nursery-start b))
                                   (< new-value (barrier-nursery-end b)))))
    (when (or (and log-source-old log-target-young)
              (and range-source-old range-target-young
                   (not log-source-old) (not log-target-young)))
      (let* ((idx (card-index source-addr))
             (cards (barrier-card-table-cards b)))
        (when (zerop (aref cards idx))
          (vector-push-extend idx (barrier-dirty-cards b)))
        (setf (aref cards idx) 1)))))

(defmethod barrier-note-read ((b object-barrier) addr)
  addr)

(defmethod barrier-card-scan ((b object-barrier) vm scan-fn)
  (let ((nursery-start (barrier-nursery-start b))
        (nursery-end (barrier-nursery-end b))
        (dirty (barrier-dirty-cards b)))
    (loop for i across dirty
          for card-addr = (* i +card-size-words+)
          for card-end = (+ card-addr +card-size-words+)
          for cursor = card-addr then cursor
          do (loop while (< cursor card-end)
                   for addr = (make-address cursor)
                   do (if (vm-object-start-p vm addr)
                          (let ((obj-size (vm-object-total-words vm addr)))
                            (when (vm-object-has-children-p vm addr)
                              (dotimes (slot (vm-object-reference-count vm addr))
                                (let ((val (vm-object-reference vm addr slot)))
                                  (when (and (>= val nursery-start)
                                             (< val nursery-end))
                                    (funcall scan-fn val addr)))))
                            (incf cursor obj-size))
                          (incf cursor))))))

(defmethod barrier-clear-all ((b object-barrier))
  (fill (barrier-card-table-cards b) 0)
  (setf (fill-pointer (barrier-dirty-cards b)) 0))

;;; --- SATB barrier (Snapshot-At-The-Beginning) ---

(defclass satb-barrier (barrier)
  ((queue :initarg :queue :accessor satb-queue
    :documentation "Ring buffer simple-vector for captured references.")
   (queue-head :initform 0 :accessor satb-queue-head :type fixnum)
   (queue-tail :initform 0 :accessor satb-queue-tail :type fixnum)
   (queue-capacity :initarg :queue-capacity :initform 4096
    :accessor satb-queue-capacity :type fixnum)
   (vm :initarg :vm :accessor barrier-vm
    :documentation "VM binding for log-bit management."))
  (:metaclass barrier-metaclass)
  (:documentation "Snapshot-At-The-Beginning barrier for concurrent marking.
Captures overwritten reference values before mutation, preserving the
object graph as it existed at the start of GC."))

(defun make-satb-barrier (vm &key (queue-size 4096))
  (make-instance 'satb-barrier
                 :vm vm
                 :queue (make-array queue-size
                                    :element-type 'fixnum
                                    :initial-element 0)
                 :queue-capacity queue-size))

(defgeneric satb-enqueue (barrier ref)
  (:documentation "Capture REF into the SATB queue before it is overwritten."))

(defgeneric satb-drain (barrier trace-fn)
  (:documentation "Drain all SATB-captured references, passing each to TRACE-FN."))

(defmethod satb-enqueue ((b satb-barrier) ref)
  (when (and ref (not (zerop ref)))
    (let ((tail (satb-queue-tail b)))
      (setf (aref (satb-queue b) tail) ref
            (satb-queue-tail b) (mod (1+ tail) (satb-queue-capacity b)))
      (when (= (satb-queue-tail b) (satb-queue-head b))
        (warn 'queue-overflow :message "SATB queue overflow")))))

(defmethod satb-drain ((b satb-barrier) trace-fn)
  (loop until (= (satb-queue-head b) (satb-queue-tail b))
        for ref = (aref (satb-queue b) (satb-queue-head b))
        do (setf (satb-queue-head b) (mod (1+ (satb-queue-head b))
                                          (satb-queue-capacity b)))
        when (and ref (not (zerop ref)))
          do (funcall trace-fn ref)))

(defmethod barrier-note-write ((b satb-barrier) source-addr slot-idx new-value &key old-value)
  (declare (ignore new-value))
  ;; Capture the old value before it gets overwritten
  (let ((vm (barrier-vm b))
        (prev (or old-value
                  (when (and vm (>= slot-idx 0))
                    (vm-object-reference vm source-addr slot-idx)))))
    (when vm
      (when (and prev (not (zerop prev))
                 (vm-valid-reference-p vm prev))
        (satb-enqueue b prev))
      ;; Set log bit so concurrent marker doesn't miss this object
      (setf (vm-object-is-logged-p vm source-addr) t))))

(defmethod barrier-note-read ((b satb-barrier) addr)
  addr)

(defmethod barrier-card-scan ((b satb-barrier) vm scan-fn)
  (declare (ignore vm scan-fn))
  nil)

(defmethod barrier-clear-all ((b satb-barrier))
  (fill (satb-queue b) 0)
  (setf (satb-queue-head b) 0
        (satb-queue-tail b) 0))
