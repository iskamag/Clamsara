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
  (declare (ignore space-designator))
  (let ((addr (alloc (space-allocator (cl-nursery p)) size)))
    (cond (addr (let ((os (vm-object-start (plan-vm p))))
                 (when os (s-set-bit os addr))) addr)
          (t (plan-handle-allocation-failure p size (cl-nursery p))))))

(defmethod plan-handle-allocation-failure ((p claimore-plan) size space)
  (plan-collect p :cycle-kind :minor)
  (let ((addr (alloc (space-allocator space) size)))
    (cond (addr (let ((os (vm-object-start (plan-vm p))))
                 (when os (s-set-bit os addr))) addr)
          (t (plan-collect p :cycle-kind :major)
             (let ((a2 (alloc (space-allocator space) size)))
               (if a2
                   (progn (let ((os (vm-object-start (plan-vm p))))
                            (when os (s-set-bit os a2))) a2)
                   (error 'heap-exhausted :requested-size size :space :nursery)))))))

(defmethod phase-prologue ((p claimore-plan) k)
  (vm-stop-mutators (plan-vm p))
  (if (eq k :minor)
      (space-prepare (cl-nursery p) (plan-vm p))
      (prepare-spaces p k)))

(defmethod phase-mark ((p claimore-plan) k)
  (if (eq k :minor) (claimore-minor-mark p) (mark-roots p (plan-tracer p))))

(defmethod phase-reclaim ((p claimore-plan) k)
  (let ((vm (plan-vm p)))
    (if (eq k :minor)
        (space-reclaim (cl-nursery p) vm :cycle-kind k)
        (progn
          ;; apply the coalesced RC log (increments/decrements) to the table
          (claimore-apply-rc-log p)
          ;; backup trace reclaims cycles: mark from roots, sweep unmarked
          (reclaim-spaces p k)))))

(defmethod phase-checkpoint ((p claimore-plan) k)
  (declare (ignore k))
  ;; persistence stub: a real plan would capture the dirty set and mark CoW.
  (when (plan-stats p) (stats-event (plan-stats p) :checkpoints 1)))

(defmethod phase-release ((p claimore-plan) k)
  (let ((vm (plan-vm p)))
    (let ((mark (vm-stratum vm :mark))) (when (and mark (eq k :major)) (s-clear mark)))
    (let ((card (vm-stratum vm :card))) (when card (s-clear card))))
  (when (plan-stats p) (stats-event (plan-stats p) :gc-cycles 1)))

(defun claimore-minor-root-reference (plan ref)
  (let* ((vm (plan-vm plan))
         (nursery (cl-nursery plan))
         (addr (ref-strip-or-self vm ref)))
    (if (and (vm-reference-p vm ref)
             (space-contains-p nursery addr))
        (space-trace-object nursery vm ref (plan-tracer plan))
        ref)))

(defun claimore-minor-grey-reference (plan ref)
  (let* ((vm (plan-vm plan))
         (tracer (plan-tracer plan))
         (nursery (cl-nursery plan))
         (addr (ref-strip-or-self vm ref)))
    (dotimes (k (vm-object-reference-count vm addr))
      (let ((child (vm-object-reference vm addr k)))
        (when (and (vm-reference-p vm child)
                   (space-contains-p
                    nursery (ref-strip-or-self vm child)))
          (space-trace-object nursery vm child tracer))))))

(defun claimore-minor-mark (plan)
  "Private nursery collection: trace the request's roots + published objects
  within the nursery; public (mature) children are external."
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
    (tracer-drain tr #'claimore-minor-grey-reference plan)))

(defun claimore-apply-rc-log (plan)
  "Drain the RC delta buffer, folding each object-level delta up to the
  per-superblock reference count of its containing superblock (paper-v8
  heap.tex §7.6).  The mature space's refcounts are per-superblock, so two
  references to objects in the same superblock contribute one count.
  A delta logged against a poisoned nursery original (trap-error-copy-a) is
  redirected to the public copy it stands in for."
  (let ((buf (barrier-rc-buffer (plan-barrier plan)))
        (mature (cl-mature plan))
        (vm (plan-vm plan)))
    (when (and (sb-refcounts mature) buf)
      (let ((counts (sb-refcounts mature)))
        (loop for i from 0 below (length buf) by 2
              for ref = (aref buf i)
              for delta = (aref buf (1+ i))
              when (plusp ref)
              do (let ((target ref))
                   ;; trap-error-copy-a poisons the private original; route the
                   ;; delta to the public copy's superblock instead.
                   (when (and (error-object-p vm ref)
                              (space-contains-p mature (error-redirect vm ref)))
                     (setf target (error-redirect vm ref)))
                   (when (space-contains-p mature target)
                     (let* ((sb (sb-index mature target))
                            (cur (aref counts sb)))
                       (setf (aref counts sb) (max 0 (+ cur delta)))))))))
    (setf (fill-pointer buf) 0)))

(defun make-claimore-plan (vm heap-size)
  (declare (ignore heap-size))
  (destructuring-bind (nu ma) (partition-pages (vm-page-count vm) '(1/3 2/3))
    (let* ((nursery (make-instance 'immix-space :vm vm
                                    :start-page (car nu) :page-count (cdr nu)
                                    :name :nursery :default-space t
                                    :moving :opportunistic))
            (mature (make-instance 'superblock-space :vm vm
                                    :start-page (car ma) :page-count (cdr ma)
                                    :name :mature :default-space nil
                                    :policy :refcount
                                    :sb-refcounts
                                    (make-array (max 1 (ceiling (* (cdr ma) +page-words+)
                                                               +g-superblock+))
                                                :element-type 'fixnum
                                                :initial-element 0)))
            (barrier (make-instance 'barrier
                       :rules (list (publication-barrier-rule)
                                    (rc-barrier-rule))))
            (p (make-instance 'claimore-plan :name :claimore :vm vm
                             :spaces (list nursery mature) :barrier barrier
                             :constraints (make-instance 'plan-constraints
                                          :scope :thread :write-barrier :publication
                                          :read-barrier :none :forwarding :off-heap
                                          :concurrency :stw))))
      (setf (cl-nursery p) nursery (cl-mature p) mature (barrier-plan barrier) p
            (plan-publication p) (make-instance 'trap-error-copy-a :public-region mature))
      (finalize-plan p) p)))
