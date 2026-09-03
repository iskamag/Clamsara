;;;; plans/claimore.lisp -- the stress-test collector.  Coordinates: superblock
;;;; hierarchy / mixed policy (RC + trace) / non-moving + block compaction /
;;;; publication + RC barriers / private nursery + global mature / concurrent.
;;;;
;;;; This is a FUNCTIONAL implementation exercising every axis: a thread-local
;;;; mark-region nursery with publication, a mature space reclaimed by reference
;;;; counting at superblock granularity (paper-v8 heap.tex §7.6: per-superblock
;;;; counts, superblock 0 = root, never freed) with a backup trace for cycles,
;;;; and a checkpoint phase.  The simulator uses scaled hierarchy geometry,
;;;; but keeps the paper's ownership, Fine/Mature, relation, RC, map, move,
;;;; and OVC protocols explicit.

(in-package #:clamsara)

(defclass claimore-plan (plan)
  ((nursery :accessor cl-nursery :initform nil)
   (mature :accessor cl-mature :initform nil))
  (:metaclass plan-metaclass))

(defmethod boot-cycle-kinds ((p claimore-plan))
  (declare (ignore p))
  '(:minor :major))

(defmethod plan-install-strata ((p claimore-plan) vm)
  (vm-set-location vm :mark :side)
  (vm-set-location vm :forwarding :off-heap)      ; block compaction uses off-heap fwd
  (vm-set-location vm :rc :off-heap)
  (vm-register-stratum vm :mark
    (make-stratum :mark (vm-min-alignment-words vm) :bit (vm-heap-size vm)))
  (vm-register-stratum vm :public
    (make-stratum :public (vm-min-alignment-words vm) :bit (vm-heap-size vm)))
  (vm-register-stratum vm :card
    (make-stratum :card (g-card) :bit (vm-heap-size vm)))
  ;; Temporary OVC destination identity; allocated at boot and never grown
  ;; while the nursery is being compacted.
  (vm-register-stratum vm :claimore-ovc-destination
    (make-stratum :claimore-ovc-destination
                  (vm-min-alignment-words vm) :bit (vm-heap-size vm))))

(defmethod plan-allocate ((p claimore-plan) size space-designator)
  (let ((explicit (plan-explicit-space p space-designator)))
    (if explicit
        ;; Explicit names (for example :mature or :los) bypass the nursery
        ;; and automatic LOS policy.
        (or (plan-allocate-in p size explicit)
            (plan-direct-handle-allocation-failure p size explicit))
        (progn
          (let ((los (plan-los p)))
            (when (and (or (eq space-designator :default)
                           (null space-designator))
                       los (> (* size +word-bytes+)
                              (constraints-max-non-los-bytes
                               (plan-constraints p))))
              (return-from plan-allocate
                (or (plan-allocate-in p size los)
                    (plan-direct-handle-allocation-failure p size los)))))
          (or (plan-allocate-in p size (cl-nursery p))
              (plan-direct-handle-allocation-failure p size (cl-nursery p)))))))

(defmethod plan-handle-allocation-failure ((p claimore-plan) size space)
  (plan-collect p :cycle-kind :minor)
  (or (plan-allocate-in p size space)
      (plan-retry-after p size space :major)))

(defmethod gc-phase :prologue ((p claimore-plan) k)
  (let ((vm (plan-vm p)))
    (vm-direct-stop-mutators vm)
    ;; The owner seal is the publication fence, not merely the simulator's
    ;; stop flag.  A target backend may have foreign publishers that do not
    ;; stop with this mutator set.
    (when (plan-publication p)
      (unless (publication-seal (plan-publication p) vm)
        (error 'gc-phase-error :phase :prologue
               :message "publication epoch has an active publisher")))
    ;; The delta log is sealed here: mutators are stopped and the publication
    ;; epoch is sealed.  Fold the pending external-edge deltas into the
    ;; per-superblock counts at every collection boundary, minors included.
    ;; Minors never release mature storage, so the fold only keeps the counts
    ;; fresh and bounds log growth between boundaries; majors still perform
    ;; the exact reconciliation before any zero-count release.
    (claimore-apply-rc-log p))
  (if (eq k :minor)
      (space-direct-prepare (cl-nursery p) (plan-vm p) k)
      (prepare-spaces p k)))

(defmethod gc-phase :mark ((p claimore-plan) k)
  (if (eq k :minor) (claimore-minor-mark p) (mark-roots p (plan-tracer p))))

(defmethod gc-phase :reclaim ((p claimore-plan) k)
  (let ((vm (plan-vm p)))
    (if (eq k :minor)
        (space-direct-reclaim (cl-nursery p) vm k)
        (progn
          ;; Reconcile the sealed edge set before any zero-count release;
          ;; precise tracing remains the authority for object liveness.
          (claimore-reconcile-rc p)
          ;; backup trace reclaims cycles: mark from roots, sweep unmarked
          (reclaim-spaces p k)))))

(defmethod gc-phase :checkpoint ((p claimore-plan) k)
  (declare (ignore k))
  ;; Claimore participates in the same persistence fence as other plans:
  ;; capture dirty pages, arm COW/materialize T0 snapshots, append the segment,
  ;; and clear the dirty signal before publishing the checkpoint event.
  (let ((vm (plan-vm p)))
    (when (plan-publication p)
      (unless (publication-seal (plan-publication p) vm)
        (error 'gc-phase-error :phase :checkpoint
               :message "publication epoch has an active publisher")))
    (let ((segment (checkpoint-heap p :timestamp (get-universal-time))))
      (superblock-seal-fine (cl-mature p))
      (gc-event-checkpoint p (plan-vm p)
                           (persistence-segment-pages segment)))
    (when (plan-publication p)
      (publication-open (plan-publication p) vm))))

(defmethod gc-phase :release ((p claimore-plan) k)
  (let ((vm (plan-vm p)))
    (let ((mark (vm-direct-stratum vm :mark)))
      (when (and mark (member k '(:major :full))) (s-clear mark)))
    (let ((card (vm-direct-stratum vm :card))) (when card (s-clear card)))
    (superblock-seal-fine (cl-mature p))
    (when (plan-publication p)
      ;; Published-root entries are append-only for the sealed epoch.  Compact
      ;; them before reopening it, otherwise a long-lived read-guarded plan
      ;; eventually exhausts its immortal owner buffer on stale entries.
      (let ((pr (strategy-published-roots (plan-publication p))))
        (when pr
          (compact-published-roots pr vm (cl-nursery p))))
      (publication-open (plan-publication p) vm))
    (when (plan-stats p) (stats-event (plan-stats p) :gc-cycles 1))))

(defun claimore-minor-root-reference (plan ref)
  (trace-root-in plan ref (cl-nursery plan) :trace-kind :minor))

(defun claimore-minor-grey-reference (plan ref)
  (trace-object-children plan ref
                         :target-space (cl-nursery plan)
                         :trace-kind :minor))

(defun claimore-minor-scan-remembered-object (plan address)
  "Trace nursery children of one dirty mature/LOS source.

Claimore's nursery is owner-local, so a minor cannot rediscover incoming
edges by scanning only nursery roots.  The fused metadata barrier dirties the
source card; this pass consumes those cards at the stop boundary and routes
only young referents into the nursery tracer."
  (let* ((vm (plan-vm plan))
         (nursery (cl-nursery plan))
         (slots (vm-reference-slots vm address))
         (weak-p (weak-pointer-p vm address)))
    (labels ((visit (slot)
               (when (or (not weak-p) (not (zerop slot)))
                 (let ((ref (vm-direct-object-reference vm address slot)))
                   (when (and (vm-reference-p vm ref)
                              (space-direct-contains-p
                               nursery (ref-strip-or-self vm ref)))
                     (trace-root-in plan ref nursery :trace-kind :minor))))))
      (if slots
          (loop for slot across slots do (visit slot))
          (dotimes (slot (vm-direct-object-reference-count vm address))
            (visit slot)))))
  address)

(defun claimore-minor-scan-remembered (plan)
  "Consume dirty cards from every non-nursery space.

The card is a conservative source filter; precise slot/layout scanning below
keeps raw payload words and weak referents out of the nursery trace."
  (let* ((vm (plan-vm plan))
         (nursery (cl-nursery plan))
         (card (vm-direct-stratum vm :card))
         (os (vm-object-start vm)))
    (when (and card os)
      (dolist (space (plan-spaces plan))
        (unless (eq space nursery)
          (loop for address from (space-base-address space)
                below (space-end-address space)
                when (and (s-test-bit os address)
                          (s-test-bit card address))
                  do (claimore-minor-scan-remembered-object plan address)))))
    plan))

(defun claimore-minor-mark (plan)
  "Private nursery collection: trace the request's roots + published objects
  within the nursery; public (mature) children are external.  The
  published-roots set is drained twice (locality.tex §1)."
  (let* ((vm (plan-vm plan)) (tr (plan-tracer plan)) (nursery (cl-nursery plan)))
    (tracer-reset tr)
    (vm-direct-scan-roots vm plan #'claimore-minor-root-reference)
    (let ((pub (vm-direct-stratum vm :public)) (os (vm-object-start vm)))
      (when (and pub os)
        (loop for address from (space-base-address nursery)
              below (space-end-address nursery)
              when (and (s-test-bit pub address)
                        (s-test-bit os address))
                do (space-direct-trace-object nursery vm address tr :minor))))
    (claimore-drain-published-roots plan)
    (claimore-minor-scan-remembered plan)
    (tracer-drain tr #'claimore-minor-grey-reference plan)
    (claimore-drain-published-roots plan)))

(defun claimore-drain-published-roots (plan)
  (let* ((strategy (plan-publication plan))
         (pr (and strategy (strategy-published-roots strategy))))
    (when (and pr (strategy-read-guarded-p strategy))
      (drain-published-roots
       pr
       (lambda (object slot)
         (let* ((vm (plan-vm plan))
                (referent (vm-direct-object-reference vm object slot))
                (nursery (cl-nursery plan)))
           (when (and (vm-reference-p vm referent)
                      (space-direct-contains-p
                       nursery (ref-strip-or-self vm referent)))
             (space-direct-trace-object
              nursery vm referent (plan-tracer plan) nil))))))))

(defun claimore-apply-rc-log (plan)
  "Drain the sealed RC delta log, folding external edges into per-SB counts.
  Each entry carries its source superblock, target, and delta.  Edges within a
  single superblock are not external in-degree and are ignored even if an old
  producer left such an entry in the buffer.

  Call at a collection boundary with mutators stopped, so the log is
  quiescent.  The fold iterates only the used fill pointer -- complete
  triples -- never the whole heap-sized capacity.  The sealed log is cleared
  only after a successful fold, and a torn tail signals an invariant
  violation instead of silently dropping a record."
  (let* ((buf (barrier-rc-buffer (plan-barrier plan)))
         (mature (cl-mature plan))
         (vm (plan-vm plan)))
    (when (and (sb-refcounts mature) buf)
      (let ((counts (sb-refcounts mature))
            (used (fill-pointer buf)))
        (unless (zerop (mod used 3))
          (error 'clamsara-error
                 :message (format nil
                                  "RC log holds a partial triple: ~a elements"
                                  used)))
        (loop for i from 0 below used by 3
              for source-sb = (aref buf i)
              for reference = (aref buf (+ i 1))
              for delta = (aref buf (+ i 2))
              for address = (ref-strip-or-self vm reference)
              when (and (plusp address)
                        (space-direct-contains-p mature address))
              do (let ((target-sb (sb-index mature address)))
                   (when (/= source-sb target-sb)
                     (let ((cur (aref counts target-sb)))
                       (setf (aref counts target-sb)
                             (max 0 (+ cur delta)))))))))
    ;; The fold succeeded (or there was nothing to fold): only now release
    ;; the sealed records.
    (when buf (setf (fill-pointer buf) 0)))
  plan)

(defun claimore-reconcile-rc-edge (mature vm source-sb reference counts)
  (when (and (vm-reference-p vm reference)
             (space-direct-contains-p mature (ref-strip-or-self vm reference)))
    (let ((target-sb (sb-index mature (ref-strip-or-self vm reference))))
      (when (or (< source-sb 0) (/= source-sb target-sb))
        (incf (aref counts target-sb)))))
  counts)

(defun claimore-reconcile-rc (plan)
  "Recompute exact incoming cross-superblock pointer-slot counts.
The mutator log is a fast-path signal, but release is permitted only after
this precise reconciliation at the collection stop boundary."
  (let* ((vm (plan-vm plan))
         (mature (cl-mature plan))
         (counts (sb-refcounts mature))
         (os (vm-object-start vm)))
    (fill counts 0)
    (dolist (space (plan-spaces plan))
      (loop for address from (space-base-address space)
            below (space-end-address space)
            when (s-test-bit os address)
              do (let* ((slots (vm-reference-slots vm address))
                        (count (vm-direct-object-reference-count vm address))
                        (weak-p (weak-pointer-p vm address))
                        (source-sb (if (space-direct-contains-p mature address)
                                       (sb-index mature address)
                                       -1)))
                   (if slots
                       (loop for slot across slots
                             when (or (not weak-p) (not (zerop slot)))
                               do (claimore-reconcile-rc-edge
                                   mature vm source-sb
                                   (vm-direct-object-reference vm address slot)
                                   counts))
                       (dotimes (slot count)
                         (when (or (not weak-p) (not (zerop slot)))
                           (claimore-reconcile-rc-edge
                            mature vm source-sb
                            (vm-direct-object-reference vm address slot)
                            counts)))))))
    (setf (fill-pointer (barrier-rc-buffer (plan-barrier plan))) 0))
  plan)

(defun claimore-metadata-barrier-rule (&optional (name :claimore-metadata))
  "Fuse owner-local nursery relation tracking and page dirtiness into stores.
The publication rule runs first, so NEW is the final value that becomes
visible; the precise OVC later rebuilds rows and occupancy from the heap."
  (make-barrier-rule
   :name name :trigger :ref-write
   :transfer (lambda (vm barrier src slot new)
               (let* ((plan (barrier-plan barrier))
                      (nursery (and plan (plan-nursery plan)))
                      (old (vm-direct-object-reference vm src slot)))
                 (when nursery
                   (claimore-nursery-note-write nursery vm src old new))
                 (let ((card (vm-direct-stratum vm :card)))
                   (when card (s-set-bit card src))))
               new)))

(defun make-claimore-plan (vm heap-size)
  (declare (ignore heap-size))
  ;; Mature space region geometry: simulator-scale hierarchy (paper-v8
  ;; heap.tex §6).  Blocks stay 512 words (1 page); metablocks and superblocks
  ;; are shrunk so a small heap still contains several of each.  Superblock 0
  ;; holds the persistent root set and is never freed.
  (destructuring-bind (nu ma) (partition-pages (vm-page-count vm) '(1/3 2/3))
    (let* ((nursery (make-instance 'claimore-nursery-space :vm vm
                                    :start-page (car nu) :page-count (cdr nu)
                                    :name :nursery :default-space t
                                    :moving :sliding-ovc
                                    :constraints (make-instance 'space-constraints
                                                                 :scope :thread)))
           (mature (make-instance 'superblock-space :vm vm
                                   :start-page (car ma) :page-count (cdr ma)
                                   :name :mature :default-space nil
                                   :blocks-per-metablock 8
                                   :metablocks-per-superblock 4
                                   :policy :hierarchical))
           (publication (make-instance 'trap-error-copy-a :public-region mature))
           ;; The relocation LVB runs before the publication trap/read rule,
           ;; matching the paper's declared read-barrier order.
           (lvb-rule (lvb-barrier-rule))
           (read-rule (make-barrier-rule
                       :name :trap :trigger :ref-read
                       :transfer (publication-read-rule publication)))
           (barrier (make-instance 'barrier
                      :rules (list (publication-barrier-rule)
                                   (claimore-metadata-barrier-rule)
                                   (rc-barrier-rule)
                                   lvb-rule
                                   read-rule)))
           (p (make-instance 'claimore-plan :name :claimore :vm vm
                            :spaces (list nursery mature) :barrier barrier
                            :constraints (make-instance 'plan-constraints
                                          :scope :thread
                                          :write-barrier '(:publication
                                                           :claimore-metadata
                                                           :rc)
                                          :read-barrier '(:lvb :trap)
                                          :forwarding :off-heap
                                          :concurrency :concurrent-relocate
                                          :requires-tier :t2))))
      (setf (cl-nursery p) nursery (cl-mature p) mature (barrier-plan barrier) p
            (plan-publication p) publication)
      (add-los-space p 1/16)
      (finalize-plan p) p)))
