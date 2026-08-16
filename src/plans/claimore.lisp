;;;; plans/claimore.lisp -- the stress-test collector.  Coordinates: superblock
;;;; hierarchy / mixed policy (RC + trace) / non-moving + block compaction /
;;;; publication + RC barriers / private nursery + global mature / concurrent.
;;;;
;;;; This is a FUNCTIONAL implementation exercising every axis: a thread-local
;;;; mark-region nursery with publication, a mature space reclaimed by reference
;;;; counting at superblock granularity (paper-v8 heap.tex §7.6: per-superblock
;;;; counts, superblock 0 = root, never freed) with a backup trace for cycles,
;;;; and a checkpoint phase (persistence stub).  The metablock-search and
;;;; block-compaction levels of the hierarchy are not yet wired into the
;;;; reclaim path; the closure-over-matrices machinery (strata.lisp) is
;;;; available for them.

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
    (make-stratum :card (g-card) :bit (vm-heap-size vm))))

(defmethod plan-allocate ((p claimore-plan) size space-designator)
  (let ((explicit (plan-explicit-space p space-designator)))
    (if explicit
        ;; Explicit names (for example :mature or :los) bypass the nursery
        ;; and automatic LOS policy.
        (or (plan-allocate-in p size explicit)
            (plan-handle-allocation-failure p size explicit))
        (progn
          (let ((los (plan-los p)))
            (when (and (or (eq space-designator :default)
                           (null space-designator))
                       los (> (* size +word-bytes+)
                              (constraints-max-non-los-bytes
                               (plan-constraints p))))
              (return-from plan-allocate
                (or (plan-allocate-in p size los)
                    (plan-handle-allocation-failure p size los)))))
          (or (plan-allocate-in p size (cl-nursery p))
              (plan-handle-allocation-failure p size (cl-nursery p)))))))

(defmethod plan-handle-allocation-failure ((p claimore-plan) size space)
  (plan-collect p :cycle-kind :minor)
  (or (plan-allocate-in p size space)
      (plan-retry-after p size space :major)))

(defmethod gc-phase :prologue ((p claimore-plan) k)
  (vm-stop-mutators (plan-vm p))
  (if (eq k :minor)
      (space-prepare (cl-nursery p) (plan-vm p))
      (prepare-spaces p k)))

(defmethod gc-phase :mark ((p claimore-plan) k)
  (if (eq k :minor) (claimore-minor-mark p) (mark-roots p (plan-tracer p))))

(defmethod gc-phase :reclaim ((p claimore-plan) k)
  (let ((vm (plan-vm p)))
    (if (eq k :minor)
        (space-reclaim (cl-nursery p) vm :cycle-kind k)
        (progn
          ;; apply the coalesced RC log (increments/decrements) to the table
          (claimore-apply-rc-log p)
          ;; backup trace reclaims cycles: mark from roots, sweep unmarked
          (reclaim-spaces p k)))))

(defmethod gc-phase :checkpoint ((p claimore-plan) k)
  (declare (ignore k))
  ;; persistence stub: a real plan would capture the dirty set and mark CoW.
  (when (plan-stats p) (stats-event (plan-stats p) :checkpoints 1)))

(defmethod gc-phase :release ((p claimore-plan) k)
  (let ((vm (plan-vm p)))
    (let ((mark (vm-stratum vm :mark))) (when (and mark (eq k :major)) (s-clear mark)))
    (let ((card (vm-stratum vm :card))) (when card (s-clear card))))
  (when (plan-stats p) (stats-event (plan-stats p) :gc-cycles 1)))

(defun claimore-minor-root-reference (plan ref)
  (trace-root-in plan ref (cl-nursery plan) :trace-kind :minor))

(defun claimore-minor-grey-reference (plan ref)
  (trace-object-children plan ref
                         :target-space (cl-nursery plan)
                         :trace-kind :minor))

(defun claimore-minor-mark (plan)
  "Private nursery collection: trace the request's roots + published objects
  within the nursery; public (mature) children are external.  The
  published-roots set is drained twice (locality.tex §1)."
  (let* ((vm (plan-vm plan)) (tr (plan-tracer plan)) (nursery (cl-nursery plan)))
    (tracer-reset tr)
    (vm-scan-roots vm plan #'claimore-minor-root-reference)
    (let ((pub (vm-stratum vm :public)) (os (vm-object-start vm)))
      (when (and pub os)
        (loop for address from (space-base-address nursery)
              below (space-end-address nursery)
              when (and (s-test-bit pub address)
                        (s-test-bit os address))
                do (space-trace-object nursery vm address tr))))
    (claimore-drain-published-roots plan)
    (tracer-drain tr #'claimore-minor-grey-reference plan)
    (claimore-drain-published-roots plan)))

(defun claimore-drain-published-roots (plan)
  (let* ((strategy (plan-publication plan))
         (pr (and strategy (strategy-published-roots strategy))))
    (when (and pr (strategy-read-guarded-p strategy))
      (drain-published-roots
       pr
       (lambda (object slot)
         (let ((vm (plan-vm plan)))
           (let ((referent (vm-object-reference vm object slot)))
             (when (vm-reference-p vm referent)
               (let ((nursery (cl-nursery plan)))
                 (when (space-contains-p
                        nursery (ref-strip-or-self vm referent))
                   (space-trace-object
                    nursery vm referent (plan-tracer plan))))))))))))

(defun claimore-apply-rc-log (plan)
  "Drain the RC delta buffer, folding external edges into per-SB counts.
  Each entry carries its source superblock, target, and delta.  Edges within a
  single superblock are not external in-degree and are ignored even if an old
  producer left such an entry in the buffer."
  (let ((buf (barrier-rc-buffer (plan-barrier plan)))
        (mature (cl-mature plan)))
    (when (and (sb-refcounts mature) buf)
      (let ((counts (sb-refcounts mature)))
        (loop for i from 0 below (length buf) by 3
              for source-sb = (aref buf i)
              for ref = (aref buf (+ i 1))
              for delta = (aref buf (+ i 2))
              when (and (plusp ref) (space-contains-p mature ref))
              do (let ((target-sb (sb-index mature ref)))
                   (when (/= source-sb target-sb)
                     (let ((cur (aref counts target-sb)))
                       (setf (aref counts target-sb)
                             (max 0 (+ cur delta)))))))))
    (setf (fill-pointer buf) 0)))

(defun make-claimore-plan (vm heap-size)
  (declare (ignore heap-size))
  ;; Mature space region geometry: simulator-scale hierarchy (paper-v8
  ;; heap.tex §6).  Blocks stay 512 words (1 page); metablocks and superblocks
  ;; are shrunk so a small heap still contains several of each.  Superblock 0
  ;; holds the persistent root set and is never freed.
  (destructuring-bind (nu ma) (partition-pages (vm-page-count vm) '(1/3 2/3))
    (let* ((nursery (make-instance 'private-immix-space :vm vm
                                    :start-page (car nu) :page-count (cdr nu)
                                    :name :nursery :default-space t
                                    :moving :opportunistic
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
                                   (rc-barrier-rule)
                                   lvb-rule
                                   read-rule)))
           (p (make-instance 'claimore-plan :name :claimore :vm vm
                            :spaces (list nursery mature) :barrier barrier
                            :constraints (make-instance 'plan-constraints
                                          :scope :thread :write-barrier '(:publication :rc)
                                          :read-barrier '(:lvb :trap)
                                          :forwarding :off-heap
                                          :concurrency :concurrent-relocate
                                          :requires-tier :t2))))
      (setf (cl-nursery p) nursery (cl-mature p) mature (barrier-plan barrier) p
            (plan-publication p) publication)
      (add-los-space p 1/16)
      (finalize-plan p) p)))
