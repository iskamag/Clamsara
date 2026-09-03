;;;; stats.lisp -- event counters (paper-v8 ch. testing).
;;;;
;;;; The simulator measures in EVENTS that transfer to hardware, not wall
;;;; clock: faults serviced, barriers executed, words copied, queue spills,
;;;; closure passes.  This lets the simulator rank collectors meaningfully.

(in-package #:clamsara)

;; Keep the event vocabulary in one place.  Counters are plain fixnums in a
;; boot-sized dense vector.  Stable keyword-to-index CASE dispatch keeps event
;; writes off the host allocator and avoids even cold hash-table work.
;;
;; Every key below is preallocated by STATS-PREPARE before a collector can
;; run, so a site may emit it unconditionally.  Add new keys HERE before the
;; emitting site exists; never let a collection path introduce a key.
;;
;; Exact semantics of the credible-statistics keys (v11 slice S3):
;;
;; :ref-locations-scanned -- cumulative count of reference slot locations
;;   examined by grey processing.  One increment per slot index visited in
;;   TRACE-OBJECT-CHILDREN (the shared grey step of every tracing plan and
;;   every minor's remembered-set scan), whether or not the slot yields a
;;   traceable in-scope child, and including a weak pointer's referent slot
;;   zero.  Not deduplicated: one VISIT of one location.
;; :root-locations-scanned -- cumulative count of root locations a root scan
;;   enumerates: each entry of the VM's explicit root vector plus each
;;   root-region index a VM-SCAN-ROOTS visit rewrites (mapped indices, or the
;;   whole [start,end) range of a conservative region).  Backend adapters that
;;   append further locations on top of the VM-BINDING scan (Maclina's
;;   interpreted stack and value cells) extend the scan outside this method
;;   and are not included.
;; :barrier-events -- one increment per fused mutator barrier invocation
;;   (BARRIER-NOTE-WRITE or BARRIER-NOTE-READ) on a barrier that has at least
;;   one rule.  Deliberately distinct from :barrier-transfers, which counts
;;   individual rule applications, so a fused multi-rule barrier reports one
;;   event and several transfers; a ruleless barrier reports neither.
;; :satb-log-records -- cumulative SATB pre-values appended to the SATB log
;;   (one record = one enqueued reference).  Records a failed reservation
;;   would have appended are not counted; the reservation fails first.
;; :satb-log-bytes -- cumulative bytes occupied by :satb-log-records: one
;;   record is one simulated heap word, so bytes = records * +WORD-BYTES+.
;; :rc-log-records -- cumulative complete SOURCE-SUPERBLOCK/REF/DELTA triples
;;   appended to the deferred RC log.  Cancellations are never appended and
;;   never counted; a store event may append 0, 1, or 2 records.
;; :rc-log-bytes -- cumulative bytes occupied by :rc-log-records: one record
;;   is three fixnum log words, so bytes = records * 3 * +WORD-BYTES+.
;; :queue-spills -- existing: tracer queue reservations that hit the
;;   one-entry-per-heap-word capacity bound before signalling exhaustion.
;; :relation-rows-rebuilt -- cumulative count of logical matrix rows cleared
;;   and then re-derived by a complete metadata rebuild pass (superblock
;;   hierarchy relations and the Claimore nursery matrix).  Empty rows count:
;;   clearing them is the pass's authoritative reconstruction of no edges.
;; :safepoint-requests -- cumulative stop-request state transitions in
;;   VM-STOP-MUTATORS.  A repeated request inside one open interval is the
;;   documented idempotent case and is NOT a new request.
;; :safepoint-arrivals -- cumulative VM-SAFEPOINT calls that observe an
;;   outstanding stop request (the work done at the safepoint: marking a
;;   stream arrived, whether from the collector's synchronous acknowledgment
;;   or a mutator poll).
;; :collection-aborts -- cumulative collections that unwound through an
;;   error instead of completing (PLAN-COLLECT's :abort hook phase).
;; :allocation-retries -- cumulative allocation-failure events handled by
;;   PLAN-HANDLE-ALLOCATION-FAILURE.  Each such event runs at least one
;;   collection and re-attempts the failed allocation (the retry); an event's
;;   internal escalation to further collections stays one retry event.
;; :retained-bytes-sample -- GAUGE, not a counter: the most recent
;;   post-collection sample of occupied bytes across the plan's spaces
;;   (sum of SPACE-OCCUPANCY times +WORD-BYTES+, taken after a completed
;;   collection or checkpoint).  The latest value replaces the previous one;
;;   STATS-RESET zeroes it and STATS-MERGE must not be used to add it.
(defparameter +stats-event-names+
  '(:barrier-transfers :words-copied :objects-copied :queue-spills
    :closure-passes :pages-written :dirty-pages :pages-mapped :mmu-faults
    :ref-locations-scanned :root-locations-scanned :barrier-events
    :satb-log-records :satb-log-bytes :rc-log-records :rc-log-bytes
    :relation-rows-rebuilt :safepoint-requests :safepoint-arrivals
    :collection-aborts :allocation-retries :retained-bytes-sample
    ;; Existing clients use this general cycle counter; retain it alongside
    ;; the paper metrics.
    :gc-cycles :gc-time :checkpoints)
  "Event names preallocated in every plan's statistics table.")

(defclass stats ()
  ;; Dense boot-owned counter storage removes hash-table probing and its cold
  ;; runtime/linkage work from every collector event.  The diagnostic API
  ;; still names counters with stable keywords; only this private layout is
  ;; numeric.  PREPARED-P preserves the historical empty snapshot of a newly
  ;; made stand-alone statistics object.
  ((events :accessor stats-events
           :initform (make-array (length +stats-event-names+)
                                 :element-type 'fixnum :initial-element 0))
   (prepared-p :accessor stats-prepared-p :initform nil)))

(defun make-stats () (make-instance 'stats))

(defun %stats-for-plan (plan)
  (and plan (plan-stats plan)))

(defun %stats-for-vm (vm)
  (and vm (vm-plan vm) (plan-stats (vm-plan vm))))

(declaim (inline %stats-index))
(defun %stats-index (name)
  "Dense index of a declared event, or -1 for an unsupported event name."
  (case name
    (:barrier-transfers 0) (:words-copied 1) (:objects-copied 2)
    (:queue-spills 3) (:closure-passes 4) (:pages-written 5)
    (:dirty-pages 6) (:pages-mapped 7) (:mmu-faults 8)
    (:ref-locations-scanned 9) (:root-locations-scanned 10)
    (:barrier-events 11) (:satb-log-records 12) (:satb-log-bytes 13)
    (:rc-log-records 14) (:rc-log-bytes 15)
    (:relation-rows-rebuilt 16) (:safepoint-requests 17)
    (:safepoint-arrivals 18) (:collection-aborts 19)
    (:allocation-retries 20) (:retained-bytes-sample 21)
    (:gc-cycles 22) (:gc-time 23) (:checkpoints 24)
    (otherwise -1)))

(defun stats-prepare (stats)
  "Initialize every declared dense counter before a collector can run."
  (fill (slot-value stats 'events) 0)
  (setf (slot-value stats 'prepared-p) t)
  stats)

(declaim (inline %stats-vector-add %stats-vector-set
                 stats-event stats-sample))
(defun %stats-vector-add (events index delta)
  (declare (type (simple-array fixnum (*)) events)
           (type fixnum index delta)
           (optimize (speed 3) (safety 0)))
  (incf (aref events index) delta))
(defun %stats-vector-set (events index value)
  (declare (type (simple-array fixnum (*)) events)
           (type fixnum index value)
           (optimize (speed 3) (safety 0)))
  (setf (aref events index) value))

(defun stats-event (stats name delta)
  "Add DELTA to declared event NAME.  The CLOS record is opened once here;
the authored counter body is %STATS-VECTOR-ADD."
  (declare (type stats stats) (type fixnum delta)
           (optimize (speed 3) (safety 0)))
  (let ((index (%stats-index name)))
    (declare (type fixnum index))
    (when (minusp index)
      (error "Unknown statistics event ~S" name))
    (%stats-vector-add (slot-value stats 'events) index delta)))

(defun stats-get (stats name)
  (let ((index (%stats-index name)))
    (if (minusp index)
        0
        (aref (slot-value stats 'events) index))))

(defun stats-sample (stats name value)
  "Replace gauge NAME with VALUE.  Unlike STATS-EVENT, this never sums samples."
  (declare (type stats stats) (type fixnum value)
           (optimize (speed 3) (safety 0)))
  (let ((index (%stats-index name)))
    (declare (type fixnum index))
    (when (minusp index)
      (error "Unknown statistics gauge ~S" name))
    (%stats-vector-set (slot-value stats 'events) index value)))

(defun stats-reset (stats)
  (fill (slot-value stats 'events) 0)
  (setf (slot-value stats 'prepared-p) t)
  stats)

(defun stats-snapshot (stats)
  "A fresh alist of (name . value), or NIL before preparation."
  (when (slot-value stats 'prepared-p)
    (loop for name in +stats-event-names+
          for index fixnum from 0
          collect (cons name (aref (slot-value stats 'events) index)))))

(defun stats-merge (into from)
  "Merge cumulative events and retain FROM's latest retained-bytes gauge."
  (let ((target (slot-value into 'events))
        (source (slot-value from 'events))
        (gauge (%stats-index :retained-bytes-sample)))
    (dotimes (index (length target))
      (if (= index gauge)
          (setf (aref target index) (aref source index))
          (incf (aref target index) (aref source index))))
    (setf (slot-value into 'prepared-p)
          (or (slot-value into 'prepared-p)
              (slot-value from 'prepared-p))))
  into)

;; ---- GC event protocol (persistence.tex); checkpoint is the live hook ----

(defgeneric gc-event-checkpoint (plan vm dirty-pages)
  (:method ((plan plan) (vm vm-binding) dirty-pages)
    ;; Checkpoint capture is a first-class event even when it writes no pages;
    ;; keep this counter on the event seam so every persistence backend reports
    ;; it consistently.
    (declare (ignore vm dirty-pages))
    (when (plan-stats plan)
      (stats-event (plan-stats plan) :checkpoints 1))
    nil)
  (:method (plan vm dirty-pages)
    (declare (ignore plan vm dirty-pages))
    nil))
