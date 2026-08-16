;;;; plans/iso.lisp -- request-private mark-region + opportunistic copy +
;;;; eager-closure publication barrier (Qiu & Blackburn, PLDI 2025).
;;;; Coordinates: mark-region / trace / opportunistic / publication / request /
;;;; STW-local.  No read barrier (a deliberate Java-cost choice).

(in-package #:clamsara)

(defclass iso-plan (plan)
  ((private :accessor iso-private :initform nil)
   (public  :accessor iso-public  :initform nil))
  (:metaclass plan-metaclass))

(defmethod boot-cycle-kinds ((p iso-plan))
  (declare (ignore p))
  '(:minor :major))

(defmethod plan-install-strata ((p iso-plan) vm)
  (vm-set-location vm :mark :side)
  (vm-set-location vm :forwarding :in-header)
  (vm-register-stratum vm :mark
    (make-stratum :mark (vm-min-alignment-words vm) :bit (vm-heap-size vm)))
  (vm-register-stratum vm :public
    (make-stratum :public (vm-min-alignment-words vm) :bit (vm-heap-size vm))))

(defmethod plan-allocate ((p iso-plan) size space-designator)
  (declare (ignore space-designator))
  (let* ((los (plan-los p)))
    (when (and los (> (* size +word-bytes+)
                      (constraints-max-non-los-bytes (plan-constraints p))))
      (return-from plan-allocate
        (let ((addr (alloc (space-allocator los) size)))
          (cond (addr (let ((os (vm-object-start (plan-vm p))))
                        (when os (s-set-bit os addr))) addr)
                (t (plan-handle-allocation-failure p size los)))))))
  (let ((addr (alloc (space-allocator (iso-private p)) size)))
    (cond (addr (let ((os (vm-object-start (plan-vm p))))
                 (when os (s-set-bit os addr))) addr)
          (t (plan-handle-allocation-failure p size (iso-private p))))))

(defmethod plan-handle-allocation-failure ((p iso-plan) size space)
  (plan-collect p :cycle-kind :minor)
  (let ((addr (alloc (space-allocator space) size)))
    (cond (addr (let ((os (vm-object-start (plan-vm p))))
                 (when os (s-set-bit os addr))) addr)
          (t (plan-collect p :cycle-kind :major)
             (let ((a2 (alloc (space-allocator space) size)))
               (if a2
                   (progn (let ((os (vm-object-start (plan-vm p))))
                            (when os (s-set-bit os a2))) a2)
                   (error 'heap-exhausted :requested-size size :space :private)))))))

(defmethod gc-phase :prologue ((p iso-plan) k)
  (vm-stop-mutators (plan-vm p))
  (if (eq k :minor)
      (space-prepare (iso-private p) (plan-vm p))
      (prepare-spaces p k)))

(defmethod gc-phase :mark ((p iso-plan) k)
  (if (eq k :minor) (iso-minor-mark p) (mark-roots p (plan-tracer p))))

(defmethod gc-phase :reclaim ((p iso-plan) k)
  (if (eq k :minor)
      (space-reclaim (iso-private p) (plan-vm p) :cycle-kind k)
      (reclaim-spaces p k)))

(defmethod gc-phase :release ((p iso-plan) k)
  (declare (ignore k))
  (let ((mark (vm-stratum (plan-vm p) :mark))) (when mark (s-clear mark)))
  (when (plan-stats p) (stats-event (plan-stats p) :gc-cycles 1)))

;; A private collection traces the request's roots (in the private space) plus
;; every object already published (public bit) -- those are reachable from
;; outside, so they must survive.  Under DLG no public object references a
;; private one, so tracing never escapes the private space.
(defun iso-minor-root-reference (plan ref)
  (let* ((vm (plan-vm plan))
         (private (iso-private plan))
         (addr (ref-strip-or-self vm ref)))
    (if (and (vm-reference-p vm ref)
             (space-contains-p private addr))
        (space-trace-object private vm ref (plan-tracer plan))
        ref)))

(defun iso-minor-grey-reference (plan ref)
  (let* ((vm (plan-vm plan))
         (tracer (plan-tracer plan))
         (private (iso-private plan))
         (addr (ref-strip-or-self vm ref)))
    (iso-trace-private-children vm addr private tracer)
    ref))

(defun iso-trace-private-children (vm address private tracer)
  "Trace every reference slot of the object at ADDRESS whose target lives in
  PRIVATE.  Top-level with explicit state: no host closure per object."
  (let ((slots (vm-reference-slots vm address)))
    (flet ((process-slot (i)
             (let ((child (vm-object-reference vm address i)))
               (when (and (vm-reference-p vm child)
                          (space-contains-p
                           private (ref-strip-or-self vm child)))
                 (space-trace-object private vm child tracer)))))
      (if slots
          (loop for i across slots do (process-slot i))
          (dotimes (i (vm-object-reference-count vm address))
            (process-slot i)))))
  address)

(defun iso-minor-mark (plan)
  (let* ((vm (plan-vm plan))
         (tr (plan-tracer plan))
         (priv (iso-private plan)))
    (tracer-reset tr)
    ;; seed roots in the private space
    (vm-scan-roots vm plan #'iso-minor-root-reference)
    ;; seed published objects (external roots) within the private space
    (let ((pub (vm-stratum vm :public)) (os (vm-object-start vm)))
      (when (and pub os)
        (loop for address from (space-base-address priv)
              below (space-end-address priv)
              when (and (s-test-bit pub address)
                        (s-test-bit os address))
                do (space-trace-object priv vm address tr))))
    ;; first drain of the published-roots set: guarded inbound edges seed the
    ;; trace (locality.tex §1)
    (iso-drain-published-roots plan)
    ;; drain private only; public-space children are external
    (tracer-drain tr #'iso-minor-grey-reference plan)
    ;; second drain just before reclaim: referents of edges appended
    ;; mid-collection are traced so the reclaim cannot free them
    (iso-drain-published-roots plan)))

(defun iso-drain-published-roots (plan)
  "Trace the referent of every guarded edge in the published-roots set
  (first drain seeds; second drain re-pins mid-collection edges)."
  (let* ((strategy (plan-publication plan))
         (pr (and strategy (strategy-published-roots strategy))))
    (when (and pr (strategy-read-guarded-p strategy))
      (drain-published-roots
       pr
       (lambda (object slot)
         (let ((vm (plan-vm plan)))
           (let ((referent (vm-object-reference vm object slot)))
             (when (vm-reference-p vm referent)
               (let ((private (iso-private plan)))
                 (when (space-contains-p
                        private (ref-strip-or-self vm referent))
                   (space-trace-object
                    private vm referent (plan-tracer plan))))))))))))

(defun make-iso-plan (vm heap-size)
  (declare (ignore heap-size))
  (destructuring-bind (pr pu) (partition-pages (vm-page-count vm) '(1/2 1/2))
    (let* ((private (make-instance 'immix-space :vm vm
                                    :start-page (car pr) :page-count (cdr pr)
                                    :name :private :default-space t))
           (public (make-instance 'immix-space :vm vm
                                   :start-page (car pu) :page-count (cdr pu)
                                   :name :public :default-space nil))
           (barrier (make-instance 'barrier :rules (list (publication-barrier-rule))))
           (p (make-instance 'iso-plan :name :iso :vm vm
                            :spaces (list private public) :barrier barrier
                            :constraints (make-instance 'plan-constraints
                                         :scope :request :write-barrier :publication))))
      (setf (iso-private p) private (iso-public p) public
            (barrier-plan barrier) p
            (plan-publication p) (make-instance 'eager-closure :public-region public))
      (add-los-space p 1/16)
      (finalize-plan p) p)))
