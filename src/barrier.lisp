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
   (satb-buffer :accessor barrier-satb-buffer
                :initform (make-array 0 :fill-pointer 0))
   ;; Interleaved REF, DELTA fixnums; no cons cells on the mutator path.
   (rc-buffer :accessor barrier-rc-buffer
              :initform (make-array 0 :fill-pointer 0)))
  (:metaclass barrier-metaclass))

(defun make-barrier (&rest rules) (make-instance 'barrier :rules rules))
(defun no-barrier () (make-barrier))

(defmethod component-validate ((b barrier)) b)

(defun initialize-barrier-buffers (barrier vm)
  "Allocate bounded simulator buffers at boot, standing in for immortal pages."
  (let ((n (vm-heap-size vm)))
    (setf (barrier-satb-buffer barrier)
          (make-array n :element-type 'fixnum :initial-element 0
                      :fill-pointer 0)
          (barrier-rc-buffer barrier)
          (make-array (* 2 n) :element-type 'fixnum :initial-element 0
                      :fill-pointer 0)))
  barrier)

;; ---- fused note-write / note-read ---------------------------------------

(declaim (inline barrier-note-write))
(defun barrier-note-write (vm barrier src slot new)
  "Mutator reference store: apply every :ref-write transfer in order.
  Returns the value that should be stored (a transfer may replace NEW, e.g.
  publication rewrites the slot to the public copy)."
  (let ((rules (barrier-rules barrier)))
    (when rules
      (loop for r in rules
            when (eq (barrier-rule-trigger r) :ref-write)
            do (setf new (funcall (barrier-rule-transfer r) vm barrier src slot new))))
    new))

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
  (unless (vector-push ref (barrier-satb-buffer barrier))
    (error 'heap-exhausted :requested-size 1 :space :satb-buffer))
  ref)
(defun rc-log-decrement (barrier ref)
  (let ((buf (barrier-rc-buffer barrier)))
    (unless (and (vector-push ref buf) (vector-push -1 buf))
      (error 'heap-exhausted :requested-size 2 :space :rc-buffer)))
  ref)
(defun rc-log-increment (barrier ref)
  (let ((buf (barrier-rc-buffer barrier)))
    (unless (and (vector-push ref buf) (vector-push +1 buf))
      (error 'heap-exhausted :requested-size 2 :space :rc-buffer)))
  ref)

;; ---- rule constructors --------------------------------------------------

(defun card-barrier-rule (&optional (name :card))
  (make-barrier-rule
   :name name :trigger :ref-write
   :transfer (lambda (vm barrier src slot new)
               (declare (ignore barrier slot))
               (when (and (vm-reference-p vm new) (vm-object-old-p vm src)
                          (vm-object-young-p vm new))
                 (let ((card (vm-stratum vm :card)))
                   (when card (s-set-bit card src))))
               new)))

(defun sticky-dirty-barrier-rule (&optional (name :sticky-dirty))
  "Log a mutated marked object so a sticky minor rescans its outgoing edges."
  (make-barrier-rule
   :name name :trigger :ref-write
   :transfer (lambda (vm barrier src slot new)
               (declare (ignore barrier slot new))
               (when (and (vm-reference-p vm src)
                          (vm-object-is-marked-p vm src))
                 (let ((log (vm-stratum vm :log)))
                   (when log (s-set-bit log src))))
               new)))

(defun satb-barrier-rule (&optional (name :satb))
  (make-barrier-rule
   :name name :trigger :ref-write
   :transfer (lambda (vm barrier src slot new)
               (declare (ignore new))
               (let ((prev (vm-object-reference vm src slot)))
                 (when (and prev (plusp prev) (vm-valid-reference-p vm prev))
                   (satb-enqueue barrier prev)))
               new)))

(defun rc-barrier-rule (&optional (name :rc))
  (make-barrier-rule
   :name name :trigger :ref-write
   :transfer (lambda (vm barrier src slot new)
               (let ((old (vm-object-reference vm src slot)))
                 (when (vm-reference-p vm old) (rc-log-decrement barrier old))
                 (when (vm-reference-p vm new) (rc-log-increment barrier new))
                 ;; hierarchy bookkeeping (heap.tex §6): a store whose source
                 ;; or target lives in a superblock space updates the
                 ;; per-SB/per-MB points-to matrices and the block escape bits
                 (let* ((plan (barrier-plan barrier))
                        (spaces (and plan (plan-spaces plan))))
                   (dolist (space spaces)
                     (when (and (typep space 'superblock-space)
                                (vm-reference-p vm new))
                       (let ((saddr (ref-strip-or-self vm src))
                             (naddr (ref-strip-or-self vm new)))
                         (when (space-contains-p space saddr)
                           (superblock-note-write space vm saddr naddr)))))))
               new)))

(defun publication-barrier-rule (&optional (name :publication))
  (make-barrier-rule
   :name name :trigger :ref-write
   :transfer (lambda (vm barrier src slot new)
               (declare (ignore slot))
               (let ((plan (barrier-plan barrier)))
                 (if (and (vm-reference-p vm new)
                          (vm-object-is-public-p vm src)
                          (not (vm-object-is-public-p vm new)))
                     (let ((published (publish (plan-publication plan) vm new)))
                       ;; The mutator stores the returned value, so the slot
                       ;; ends up pointing at the public copy; the original is
                       ;; poisoned and pre-existing references to it are healed
                       ;; by the read barrier.  The RC rule runs after this
                       ;; rule and logs the single +1 for the copy (the value
                       ;; that now lives in the RC-counted mature space).
                       ;; Publication failure (NIL: the public region could
                       ;; not hold the closure) must NEVER fall back to
                       ;; storing the private referent -- that would silently
                       ;; break DLG (locality.tex §1).
                       (if (and published (not (eql published new)))
                           published
                           (if published
                               new
                               (error 'heap-exhausted
                                      :requested-size 1 :space :public))))
                     new)))))

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
         (dst (fwd-get vm addr)))
    (if (plusp dst)
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
      (unless (some (lambda (s) (member (space-policy s) '(:refcount :hierarchical)))
                    (plan-spaces plan))
        (error 'barrier-incompatible :plan plan
               :message "RC barrier needs a :refcount or :hierarchical space")))))
