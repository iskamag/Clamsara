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

(defun %barrier-stats (barrier)
  "The plan statistics table recording BARRIER's events, or NIL when the
barrier is not attached to a booted plan (stand-alone test VMs have no
counter; they report no event rather than allocating one)."
  (let ((plan (barrier-plan barrier)))
    (and plan (plan-stats plan))))

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
  ;; The fused dispatch point counts one :barrier-event per mutator store
  ;; that reaches a barrier with rules, distinct from :barrier-transfers,
  ;; which the per-rule loop below counts once per applied rule.  Both are
  ;; prewarmed fixnum increments; neither allocates.
  (let ((rules (barrier-rules barrier)))
    (when rules
      (let ((stats (%barrier-stats barrier)))
        (when stats (stats-event stats :barrier-events 1)))
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
  ;; Same event/transfer split as the write path: one event per fused load
  ;; barrier invocation, one transfer per applied read rule.
  (let ((rules (barrier-rules barrier)))
    (if rules
        (let ((stats (%barrier-stats barrier)))
          (when stats (stats-event stats :barrier-events 1))
          (loop for r in rules
                when (eq (barrier-rule-trigger r) :ref-read)
                do (progn
                     (%barrier-record-transfer vm barrier)
                     (setf reference (funcall (barrier-rule-transfer r) vm slot-addr reference)))
                finally (return reference)))
        reference)))

(declaim (inline %reserve-vector-capacity))
(defun %reserve-vector-capacity (vector n space)
  "Reserve tail capacity for N more elements in a fixed-capacity fill-pointer
VECTOR (the simulator stand-in for immortal collector storage).  Overflow is a
declared HEAP-EXHAUSTED failure naming SPACE, signalled BEFORE any element is
appended, so an event that fails its reservation leaves the vector unchanged.
Returns VECTOR; after a successful reservation of N elements, appends of up to
N elements cannot fail."
  ;; LENGTH observes a vector's fill pointer, not its backing capacity.
  ;; ARRAY-TOTAL-SIZE is the fixed reservation bound.
  (unless (<= (+ (fill-pointer vector) n) (array-total-size vector))
    (error 'heap-exhausted :requested-size n :space space))
  vector)

(defun satb-enqueue (barrier ref)
  (let ((buf (%reserve-vector-capacity (barrier-satb-buffer barrier)
                                       1 :satb-buffer)))
    (vector-push ref buf)
    ;; One record = one enqueued pre-value reference = one simulated heap
    ;; word of log bytes.  Counted only after the reservation succeeded, so
    ;; a failed event appends nothing and reports nothing.
    (let ((stats (%barrier-stats barrier)))
      (when stats
        (stats-event stats :satb-log-records 1)
        (stats-event stats :satb-log-bytes +word-bytes+))))
  ref)

(declaim (inline rc-log-reserve))
(defun rc-log-reserve (barrier triple-count)
  "Reserve capacity for TRIPLE-COUNT whole SOURCE-SUPERBLOCK/REF/DELTA triples
in the RC log before the store event appends any of its deltas.  A store that
emits a decrement and an increment reserves once for both, so a full log fails
before the exposure store and cannot tear the event or leave a partial record."
  (declare (type fixnum triple-count))
  (%reserve-vector-capacity (barrier-rc-buffer barrier)
                            (* 3 triple-count) :rc-buffer))

(declaim (inline %rc-log-append))
(defun %rc-log-append (buf source-superblock ref delta)
  "Append one triple with NO capacity check.  Private: the caller must have
reserved the triples through RC-LOG-RESERVE first -- RC-LOG-DELTA for the
single-delta public API, or a store rule that reserved its whole event once.
No append path may reserve after the event's reservation: a second reservation
between the event's reserve and its appends is exactly the tear this split
removes."
  (declare (type (vector fixnum) buf))
  (vector-push source-superblock buf)
  (vector-push ref buf)
  (vector-push delta buf))

(declaim (inline rc-log-delta))
(defun rc-log-delta (barrier source-superblock ref delta)
  "Append one SOURCE-SUPERBLOCK/REF/DELTA triple without mutator allocation.
SOURCE-SUPERBLOCK is -1 when the source is outside Claimore's mature space.
The triple is all-or-nothing: capacity is reserved before the first push, so
the log never holds a partial triple and a failed append leaves it unchanged."
  (let ((buf (rc-log-reserve barrier 1)))
    (%rc-log-append buf source-superblock ref delta)
    (let ((stats (%barrier-stats barrier)))
      (when stats
        (stats-event stats :rc-log-records 1)
        (stats-event stats :rc-log-bytes (* 3 +word-bytes+)))))
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
               (declare (ignore barrier slot))
               (when (and (vm-reference-p vm src)
                          (vm-object-is-marked-p vm src))
                 (let ((log (vm-stratum vm :log)))
                   (when log (s-set-bit log src))))
               new)))

(defun satb-barrier-rule (&optional (name :satb))
  (make-barrier-rule
   :name name :trigger :ref-write
   :transfer (lambda (vm barrier src slot new)
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
                      (new-superblock (%rc-superblock-for barrier vm new))
                      ;; One store event may emit a decrement AND an
                      ;; increment.  Decide both edges before appending
                      ;; anything.
                      (dec-edge-p (and (vm-reference-p vm old)
                                       (%rc-external-edge-p
                                        source-superblock old-superblock)))
                      (inc-edge-p (and (vm-reference-p vm new)
                                       (%rc-external-edge-p
                                        source-superblock new-superblock))))
                 ;; Exact per-superblock cancellation: when the old and new
                 ;; external targets are the SAME superblock, the -1/+1 pair
                 ;; nets zero external in-degree for that superblock, so the
                 ;; event records nothing at all.
                 (unless (and dec-edge-p inc-edge-p
                              (eql old-superblock new-superblock))
                   (let* ((records (+ (if dec-edge-p 1 0)
                                      (if inc-edge-p 1 0)))
                          ;; Reserve once for the whole event; append through
                          ;; the private no-reserve path.  No record append
                          ;; may reserve again between the event's
                          ;; reservation and its last record: a second
                          ;; reservation at exact capacity is the tear this
                          ;; split removes.  Failure happens here, before the
                          ;; exposure store, with the log unchanged.
                          (buf (and (plusp records)
                                    (rc-log-reserve barrier records))))
                     (when buf
                       (when dec-edge-p
                         (%rc-log-append buf source-superblock old -1))
                       (when inc-edge-p
                         (%rc-log-append buf source-superblock new +1))
                       ;; Whole records only: one record is one deferred
                       ;; edge, three fixnum log words.  Cancellation events
                       ;; never reserve, never append, never count.
                       (let ((stats (%barrier-stats barrier)))
                         (when stats
                           (stats-event stats :rc-log-records records)
                           (stats-event stats :rc-log-bytes
                                        (* 3 +word-bytes+ records)))))))
                 ;; hierarchy bookkeeping (heap.tex §6): a store whose source
                 ;; or target lives in a superblock space updates the
                 ;; per-SB/per-MB points-to matrices and the block escape bits
                 (let* ((plan (barrier-plan barrier))
                        (spaces (and plan (plan-spaces plan))))
                   (dolist (space spaces)
                     (when (typep space 'superblock-space)
                       (let ((saddr (ref-strip-or-self vm src)))
                         ;; Fine is source state and must be cleared even
                         ;; when the new value is a nursery/LOS reference.
                         (when (space-contains-p space saddr)
                           (if (vm-reference-p vm new)
                               (superblock-note-write
                                space vm saddr (ref-strip-or-self vm new))
                               (sb-clear-fine-for-address space saddr))))))))
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
                     (let ((published (publication-publish
                                       (plan-publication plan) vm new)))
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
