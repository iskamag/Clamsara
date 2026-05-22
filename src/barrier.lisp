(in-package #:clamsara)

;;; --- Barrier System ---
;;; Barriers for remembered sets and inter-generational pointer tracking.

(defclass barrier () ()
  (:documentation "Base barrier class."))

(defclass no-barrier (barrier) ()
  (:documentation "No barrier."))

(defclass object-barrier (barrier)
  ((card-table :initarg :card-table :reader barrier-card-table)
   (vm :initarg :vm :reader barrier-vm)
   (plan :initarg :plan :initform nil :reader barrier-plan))
  (:documentation "Card-table write barrier for generational plans."))

(defclass satb-barrier (barrier)
  ((queue :accessor satb-queue :initform nil)
   (vm :initarg :vm :reader barrier-vm))
  (:documentation "SATB pre-write barrier for concurrent marking."))

;;; --- Barrier Protocol ---

(defgeneric barrier-note-write (barrier source-addr slot new-value)
  (:documentation "Called after a mutator writes NEW-VALUE into SLOT of SOURCE-ADDR."))

(defgeneric barrier-note-read (barrier addr)
  (:documentation "Called when a mutator reads a reference. Returns the value."))

(defgeneric barrier-card-scan (barrier plan visitor-fn)
  (:documentation "Scan dirty cards, calling VISITOR-FN for each reference."))

(defgeneric barrier-clear-all (barrier)
  (:documentation "Clear all barrier state."))

;;; --- Constructor helpers ---

(defun make-no-barrier ()
  (make-instance 'no-barrier))

(defun make-object-barrier (vm card-table &optional plan)
  (make-instance 'object-barrier :vm vm :card-table card-table :plan plan))

(defun make-satb-barrier (vm)
  (make-instance 'satb-barrier :vm vm))

;;; --- No Barrier Methods ---

(defmethod barrier-note-write ((b no-barrier) source-addr slot new-value)
  (declare (ignore source-addr slot new-value))
  nil)

(defmethod barrier-note-read ((b no-barrier) addr)
  (declare (ignore b))
  addr)

(defmethod barrier-card-scan ((b no-barrier) plan visitor-fn)
  (declare (ignore b plan visitor-fn))
  nil)

(defmethod barrier-clear-all ((b no-barrier))
  nil)

;;; --- Object Barrier Methods ---

(defmethod barrier-note-write ((b object-barrier) source-addr slot new-value)
  (declare (ignore slot))
  (let ((vm (barrier-vm b))
        (plan (barrier-plan b)))
    (when (and vm
               (integerp new-value) (not (zerop new-value))
               (integerp source-addr))
      (let* ((old-p (if (vm-address-old-p vm source-addr) t nil))
             (young-p (vm-address-young-p vm new-value)))
        (when (and old-p young-p)
          (let ((ct (barrier-card-table b)))
            (when ct (mark-card-dirty ct source-addr)))
          (setf (vm-object-is-logged-p vm source-addr) t))))))

(defmethod barrier-note-read ((b object-barrier) addr)
  (declare (ignore b))
  addr)

(defmethod barrier-card-scan ((b object-barrier) plan visitor-fn)
  (let* ((vm (barrier-vm b))
         (ct (barrier-card-table b))
         (cards (card-table-cards ct)))
    (loop for i from 0 below (length cards)
          when (> (aref cards i) 0)
            do (let ((base (* i +card-size-words+)))
                 (loop for j from 0 below +card-size-words+
                       for addr = (+ base j)
                       when (and (vm-object-start-p vm (make-address addr))
                                 (vm-object-is-logged-p vm (make-address addr)))
                         do (vm-scan-object-references vm (make-address addr) visitor-fn))))))

(defmethod barrier-clear-all ((b object-barrier))
  (let ((vm (barrier-vm b))
        (ct (barrier-card-table b)))
    (when ct (clear-all-cards ct))
    (when vm (vm-clear-all-log-bits vm))))

;;; --- SATB Barrier Methods (scaffolding) ---

(defmethod barrier-note-write ((b satb-barrier) source-addr slot new-value)
  (declare (ignore new-value))
  (let* ((vm (barrier-vm b))
         (old-ref (vm-object-reference vm source-addr slot)))
    (when (and old-ref (not (zerop old-ref))
               (not (vm-object-is-logged-p vm old-ref)))
      (let ((q (satb-queue b)))
        (push old-ref q)
        (setf (satb-queue b) q)
        (setf (vm-object-is-logged-p vm old-ref) t)))))

(defmethod barrier-note-read ((b satb-barrier) addr)
  (declare (ignore b))
  addr)

(defmethod barrier-card-scan ((b satb-barrier) plan visitor-fn)
  (declare (ignore b plan visitor-fn))
  nil)

(defmethod barrier-clear-all ((b satb-barrier))
  (let ((vm (barrier-vm b)))
    (setf (satb-queue b) nil)
    (when vm (vm-clear-all-log-bits vm))))
