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
   ;; Interleaved SOURCE-SUPERBLOCK, REF, DELTA fixnums; no cons cells on
   ;; the mutator path.  SOURCE-SUPERBLOCK is -1 for a non-mature source.
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
          ;; Each deferred edge carries its source superblock, target, and
          ;; delta.  Keeping these as fixnums preserves the allocation-free
          ;; mutator barrier while allowing per-superblock RC folding.
          (make-array (* 3 n) :element-type 'fixnum :initial-element 0
                      :fill-pointer 0)))
  barrier)

;; ---- fused note-write / note-read ---------------------------------------

(declaim (inline %barrier-record-transfer))
(defun %barrier-record-transfer (vm barrier)
  ;; BARrier transfers are counted at the fused dispatch point, where a
  ;; compiler can emit the same increment without allocating a per-rule
  ;; closure.  A barrier may be used by a small stand-alone VM in tests before
  ;; it is attached to a plan, in which case there is simply no counter.
  (let* ((plan (or (barrier-plan barrier) (and vm (vm-plan vm))))
         (stats (and plan (plan-stats plan))))
    (when stats (stats-event stats :barrier-transfers 1))))

(declaim (inline barrier-note-write))
(defun barrier-note-write (vm barrier src slot new)
  "Mutator reference store: apply every :ref-write transfer in order.
  Returns the value that should be stored (a transfer may replace NEW, e.g.
  publication rewrites the slot to the public copy)."
  (let ((rules (barrier-rules barrier)))
    (when rules
      (loop for r in rules
            when (eq (barrier-rule-trigger r) :ref-write)
            do (progn
                 (%barrier-record-transfer vm barrier)
                 (setf new (funcall (barrier-rule-transfer r) vm barrier src slot new)))))
    new))

(declaim (inline barrier-note-read))
(defun barrier-note-read (vm barrier slot-addr reference)
  "Mutator reference load: apply every :ref-read transfer; return the reference
  (possibly healed)."
  (let ((rules (barrier-rules barrier)))
    (if rules
        (loop for r in rules
              when (eq (barrier-rule-trigger r) :ref-read)
              do (progn
                   (%barrier-record-transfer vm barrier)
                   (setf reference (funcall (barrier-rule-transfer r) vm slot-addr reference)))
              finally (return reference))
        reference)))

(defun satb-enqueue (barrier ref)
  (unless (vector-push ref (barrier-satb-buffer barrier))
    (error 'heap-exhausted :requested-size 1 :space :satb-buffer))
  ref)
(declaim (inline rc-log-delta))
(defun rc-log-delta (barrier source-superblock ref delta)
  "Append one SOURCE-SUPERBLOCK/REF/DELTA triple without mutator allocation.
SOURCE-SUPERBLOCK is -1 when the source is outside Claimore's mature space."
  (let ((buf (barrier-rc-buffer barrier)))
    (unless (and (vector-push source-superblock buf)
                 (vector-push ref buf)
                 (vector-push delta buf))
      (error 'heap-exhausted :requested-size 3 :space :rc-buffer)))
  ref)
(defun rc-log-decrement (barrier ref &optional (source-superblock -1))
  (rc-log-delta barrier source-superblock ref -1))
(defun rc-log-increment (barrier ref &optional (source-superblock -1))
  (rc-log-delta barrier source-superblock ref +1))

;; ---- rule constructors --------------------------------------------------

(defun %rc-superblock-for (barrier vm reference)
  "Return REFERENCE's mature superblock index, or -1 for foreign objects.
This lookup is deliberately scalar and cons-free: the RC barrier records only
fixnums in its preallocated field log."
  (let* ((plan (barrier-plan barrier))
         (address (ref-strip-or-self vm reference)))
    (if (and plan (integerp address) (plusp address))
        (dolist (space (plan-spaces plan) -1)
          (when (and (typep space 'superblock-space)
                     (space-contains-p space address))
            (return (sb-index space address))))
        -1)))

(defun %rc-external-edge-p (source-superblock target-superblock)
  "Whether a mature TARGET edge contributes to its external in-degree."
  (and (>= target-superblock 0)
       (/= source-superblock target-superblock)))

(defun card-barrier-rule (&optional (name :card))
  "Mark the source's card dirty when a reference from OUTSIDE the nursery
(mature or LOS) is made to point at a nursery object.  Sources outside the
nursery are what a minor's remembered-set scan must re-check; requiring
vm-object-old-p misses LOS objects, whose age stratum stays 0."
  (make-barrier-rule
   :name name :trigger :ref-write
   :transfer (lambda (vm barrier src slot new)
               (declare (ignore slot))
               (when (and (vm-reference-p vm new)
                          (vm-object-young-p vm new)
                          (let* ((plan (barrier-plan barrier))
                                 (nursery (and plan (plan-nursery plan)))
                                 (addr (ref-strip-or-self vm src)))
                            ;; with a plan: outside the nursery (mature or
                            ;; LOS); without one, fall back to old-vs-young
                            (if nursery
                                (not (space-contains-p nursery addr))
                                (vm-object-old-p vm src))))
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
               (let* ((old (vm-object-reference vm src slot))
                      ;; Superblock counts are external in-degrees.  A mature
                      ;; object pointing within its own SB must not contribute;
                      ;; the source index is captured in the fixed-size log so
                      ;; the deferred apply path cannot lose this distinction.
                      (source-superblock (%rc-superblock-for barrier vm src))
                      (old-superblock (%rc-superblock-for barrier vm old))
                      (new-superblock (%rc-superblock-for barrier vm new)))
                 (when (and (vm-reference-p vm old)
                            (%rc-external-edge-p source-superblock old-superblock))
                   (rc-log-decrement barrier old source-superblock))
                 (when (and (vm-reference-p vm new)
                            (%rc-external-edge-p source-superblock new-superblock))
                   (rc-log-increment barrier new source-superblock))
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
                         ;; Hierarchy metadata belongs only to mature-space
                         ;; edges.  A mature source may point into the nursery
                         ;; or LOS; those references must not be interpreted
                         ;; as mature block indices.
                         (when (and (space-contains-p space saddr)
                                    (space-contains-p space naddr))
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

(defun shade-mark-barrier-rule (&optional (name :incremental-update))
  "Incremental-update marking for C4/ZGC-style plans.

A mutator load can pull a not-yet-marked reference into use while the
trace is already running, which would let the reclaim miss it.  The rule
marks (shades) every loaded reference before the mutator consumes it, so
nothing reachable behind the frontier is missed.  There is no write log:
snapshot semantics belong to LXR (SATB), not to this lineage."
  (make-barrier-rule
   :name name :trigger :ref-read
   :transfer (lambda (vm slot-addr reference)
               (declare (ignore slot-addr))
               ;; Shading is a concurrent-marking duty: it acts only while a
               ;; trace window can consume the grey work it enqueues.
               (when (and (vm-reference-p vm reference)
                          (vm-plan vm)
                          (plan-marking-active-p (vm-plan vm)))
                 (let* ((addr (ref-strip-or-self vm reference))
                        (plan (vm-plan vm)))
                   (unless (vm-object-is-marked-p vm addr)
                     (setf (vm-object-is-marked-p vm addr) t)
                     (let ((tracer (plan-tracer plan)))
                       (when tracer (tracer-enqueue tracer addr))))))
                reference)))

(defun lvb-barrier-rule (&optional (name :lvb))
  "Self-healing load-value barrier: resolve forwarding and stale colours.

The colour check alone is not sufficient here.  Heap slots are deliberately
bare addresses, and a bare old address has the good colour (zero) even while
its off-heap forwarding entry is live.  Always try the forwarding lookup first;
HEAL-REFERENCE cheaply rejects non-references and out-of-heap immediates."
  (make-barrier-rule
   :name name :trigger :ref-read
   :transfer (lambda (vm slot-addr reference)
               (let ((healed (heal-reference vm reference)))
                 ;; Write back only when forwarding changed the reference.
                 ;; In particular, do not call the colour predicate here:
                 ;; T0 VMs have bare references and no colour protocol.
                 (unless (eql healed reference)
                   (setf (ref-u64 vm slot-addr) healed))
                 healed))))

;; ---- healing (off-heap forwarding table) --------------------------------

(defun heal-reference (vm reference)
  "Follow forwarding and recolour the result to good.  Idempotent.

The forwarding table is indexed by heap words, not arbitrary mutator values:
ordinary payload integers (including Maclina's tagged immediates) must not be
used as indices.  A forwarding entry is itself sufficient evidence that an
old object address is stale; this also lets the barrier heal a reference after
its old object-start bit has been cleared during relocation."
  (if (and (integerp reference) (vm-fwd-table vm))
      (let ((addr (ref-strip-or-self vm reference)))
        (if (and (integerp addr) (plusp addr)
                 (< addr (vm-heap-size vm)))
            (let ((dst (fwd-get vm addr)))
              (if (plusp dst)
                  (if (typep vm 'coloured-pointer-mixin)
                      (ref-set-colour vm dst (vm-good-colour vm))
                      dst)
                  reference))
            reference))
      reference))

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
