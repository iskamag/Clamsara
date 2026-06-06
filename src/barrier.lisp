(in-package #:clamsara)

;;;; Barrier protocol

(defvar *barrier-selectors* '(:none :object :satb)
  "Valid barrier type specifiers.")

(defgeneric barrier-note-write (barrier source-addr slot-idx new-value)
  (:documentation "Notify the BARRIER that a write has occurred."))

(defgeneric barrier-note-read (barrier addr)
  (:documentation "Notify the BARRIER that a read of ADDR has occurred.
Returns the value to use (for read barriers that may remap or log)."))

(defgeneric barrier-card-scan (barrier vm scan-fn)
  (:documentation "Scan remembered cards / old-to-young references."))

(defgeneric barrier-clear-all (barrier)
  (:documentation "Reset all barrier state for a new GC cycle."))

;;; --- No barrier ---

(defclass no-barrier () ())

(defun make-no-barrier () (make-instance 'no-barrier))

(defmethod barrier-note-write ((b no-barrier) source-addr slot-idx new-value)
  (declare (ignore source-addr slot-idx new-value))
  nil)

(defmethod barrier-note-read ((b no-barrier) addr)
  addr)

(defmethod barrier-card-scan ((b no-barrier) vm scan-fn)
  (declare (ignore vm scan-fn))
  nil)

(defmethod barrier-clear-all ((b no-barrier))
  nil)

;;; --- Object barrier (generational card table) ---

(defclass object-barrier ()
  ((card-table :initarg :card-table :accessor barrier-card-table)
   (nursery-start :initarg :nursery-start :accessor barrier-nursery-start)
   (nursery-end :initarg :nursery-end :accessor barrier-nursery-end))
  (:metaclass barrier-metaclass))

(defun make-object-barrier (card-table nursery-start nursery-end)
  (make-instance 'object-barrier
                 :card-table card-table
                 :nursery-start nursery-start
                 :nursery-end nursery-end))

(defun barrier-card-table-cards (barrier)
  (card-table-cards (barrier-card-table barrier)))

(defun card-dirty-p (barrier card-idx)
  (> (aref (barrier-card-table-cards barrier) card-idx) 0))

(defmethod barrier-note-write ((b object-barrier) source-addr slot-idx new-value)
  (declare (ignore slot-idx))
  ;; Only mark the card if SOURCE is OLD and NEW-VALUE is YOUNG.
  (when (and (< source-addr (barrier-nursery-start b))
             (>= new-value (barrier-nursery-start b))
             (< new-value (barrier-nursery-end b)))
    (let ((idx (card-index source-addr)))
      (setf (aref (barrier-card-table-cards b) idx) 1))))

(defmethod barrier-note-read ((b object-barrier) addr)
  addr)

(defmethod barrier-card-scan ((b object-barrier) vm scan-fn)
  (let ((cards (barrier-card-table-cards b))
        (nursery-start (barrier-nursery-start b))
        (nursery-end (barrier-nursery-end b)))
    (dotimes (i (length cards))
      (when (> (aref cards i) 0)
        ;; Card is dirty — scan objects in this card for old->young references
        (let ((card-addr (* i +card-size-words+)))
          (dotimes (offset +card-size-words+)
            (let ((addr (+ card-addr offset)))
              (when (and (vm-object-start-p vm addr)
                         (vm-object-has-children-p vm addr))
                (dotimes (slot (vm-object-reference-count vm addr))
                  (let ((val (vm-object-reference vm addr slot)))
                    (when (and (>= val nursery-start)
                               (< val nursery-end))
                      (funcall scan-fn addr val))))))))))))

(defmethod barrier-clear-all ((b object-barrier))
  (fill (barrier-card-table-cards b) 0))
