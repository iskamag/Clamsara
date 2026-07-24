;;;; barrier.lisp -- barriers as data (paper-v8 ch. barriers).
;;;;
;;;; A barrier is a list of (metadatum, trigger, transfer) triples.  The
;;;; compiler fuses them into one inlined sequence; in the simulator the
;;;; fused barrier-note-write/read applies each transfer in order.

(in-package #:clamsara)

(defstruct barrier-rule
  (name      nil :type symbol)
  (metadatum nil)        ; which stratum / location the rule touches
  (trigger   :ref-write :type (member :ref-write :ref-read :alloc))
  (transfer  (constantly nil) :type (or function null)))

(defclass barrier ()
  ((rules :initarg :rules :accessor barrier-rules :initform nil)
   (plan :initarg :plan :accessor barrier-plan :initform nil)
   (satb-buffer :accessor barrier-satb-buffer :initform (make-array 0 :adjustable t :fill-pointer 0))
   (rc-buffer :accessor barrier-rc-buffer :initform (make-array 0 :adjustable t :fill-pointer 0)))
  (:metaclass barrier-metaclass))

(defun make-barrier (&rest rules) (make-instance 'barrier :rules rules))
(defun no-barrier () (make-barrier))

(defmethod component-validate ((b barrier)) b)

;; ---- fused note-write / note-read ---------------------------------------

(declaim (inline barrier-note-write))
(defun barrier-note-write (vm barrier src slot new)
  "Mutator reference store: apply every :ref-write transfer in order."
  (let ((rules (barrier-rules barrier)))
    (when rules
      (loop for r in rules
            when (eq (barrier-rule-trigger r) :ref-write)
            do (funcall (barrier-rule-transfer r) vm barrier src slot new)))))

(declaim (inline barrier-note-read))
(defun barrier-note-read (vm barrier slot-addr reference)
  "Mutator reference load: apply every :ref-read transfer; return the reference
  (possibly healed)."
  (let ((rules (barrier-rules barrier)))
    (if rules
        (loop for r in rules
              when (eq (barrier-rule-trigger r) :ref-read)
              do (setf reference (funcall (barrier-rule-transfer r) vm slot-addr reference))
              finally (return reference))
        reference)))

(defun satb-enqueue (barrier ref)
  (vector-push-extend ref (barrier-satb-buffer barrier)))
(defun rc-log-decrement (barrier ref)
  (vector-push-extend (cons ref -1) (barrier-rc-buffer barrier)))
(defun rc-log-increment (barrier ref)
  (vector-push-extend (cons ref +1) (barrier-rc-buffer barrier)))

;; ---- rule constructors --------------------------------------------------

(defun card-barrier-rule (&optional (name :card))
  (make-barrier-rule
   :name name :trigger :ref-write
   :transfer (lambda (vm barrier src slot new)
               (declare (ignore barrier slot))
               (when (and (vm-reference-p vm new) (vm-object-old-p vm src)
                          (vm-object-young-p vm new))
                 (let ((card (vm-stratum vm :card)))
                   (when card (s-set-bit card src)))))))

(defun satb-barrier-rule (&optional (name :satb))
  (make-barrier-rule
   :name name :trigger :ref-write
   :transfer (lambda (vm barrier src slot new)
               (declare (ignore new))
               (let ((prev (vm-object-reference vm src slot)))
                 (when (and prev (plusp prev) (vm-valid-reference-p vm prev))
                   (satb-enqueue barrier prev))))))

(defun rc-barrier-rule (&optional (name :rc))
  (make-barrier-rule
   :name name :trigger :ref-write
   :transfer (lambda (vm barrier src slot new)
               (declare (ignore src))
               (let ((old (vm-object-reference vm src slot)))
                 (when (vm-reference-p vm old) (rc-log-decrement barrier old))
                 (when (vm-reference-p vm new) (rc-log-increment barrier new))))))

(defun publication-barrier-rule (&optional (name :publication))
  (make-barrier-rule
   :name name :trigger :ref-write
   :transfer (lambda (vm barrier src slot new)
               (declare (ignore slot))
               (let ((plan (barrier-plan barrier)))
                 (when (and (vm-reference-p vm new)
                            (vm-object-is-public-p vm src)
                            (not (vm-object-is-public-p vm new)))
                   (publish (plan-publication plan) vm new))))))

(defun lvb-barrier-rule (&optional (name :lvb))
  "Self-healing load-value barrier: test colour; if stale, heal via forwarding."
  (make-barrier-rule
   :name name :trigger :ref-read
   :transfer (lambda (vm slot-addr reference)
               (if (ref-good-colour-p vm reference)
                   reference
                   (let ((healed (heal-reference vm reference)))
                     (setf (ref-u64 vm slot-addr) healed)
                     healed)))))

;; ---- healing (off-heap forwarding table) --------------------------------

(defun heal-reference (vm reference)
  "Follow the off-heap forwarding table and recolour to good.  Idempotent."
  (let* ((addr (ref-strip vm reference))
         (dst (gethash addr (vm-fwd-table vm))))
    (if dst
        (if (typep vm 'coloured-pointer-mixin)
            (ref-set-colour vm dst (vm-good-colour vm))
            dst)
        reference)))

;; ---- barrier-metaclass coherence checks (barriers.tex) -----------------

(defun barrier-check (barrier plan)
  (let ((rules (barrier-rules barrier))
        (c (plan-constraints plan)))
    (when (find :lvb rules :key #'barrier-rule-name)
      (unless (or (eq (constraints-forwarding c) :off-heap)
                  (some (lambda (s) (eq (space-moving s) :concurrent-relocate))
                        (plan-spaces plan)))
        (error 'barrier-incompatible :plan plan
               :message "LVB read barrier needs off-heap forwarding + concurrent-relocate")))
    (when (find :publication rules :key #'barrier-rule-name)
      (unless (plan-publication plan)
        (error 'barrier-incompatible :plan plan
               :message "publication barrier needs a publication strategy")))
    (when (find :rc rules :key #'barrier-rule-name)
      (unless (some (lambda (s) (eq (space-policy s) :refcount)) (plan-spaces plan))
        (error 'barrier-incompatible :plan plan
               :message "RC barrier needs a :refcount space")))))
