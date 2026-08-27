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
  (let ((explicit (plan-explicit-space p space-designator)))
    (if explicit
        ;; Explicit names (for example :public or :los) are authoritative.
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
          (or (plan-allocate-in p size (iso-private p))
              (plan-handle-allocation-failure p size (iso-private p)))))))

(defmethod plan-handle-allocation-failure ((p iso-plan) size space)
  (plan-collect p :cycle-kind :minor)
  (or (plan-allocate-in p size space)
      (plan-retry-after p size space :major)))

(defmethod gc-phase :prologue ((p iso-plan) k)
  (vm-direct-stop-mutators (plan-vm p))
  (if (eq k :minor)
      (space-direct-prepare (iso-private p) (plan-vm p) k)
      (prepare-spaces p k)))

(defmethod gc-phase :mark ((p iso-plan) k)
  (if (eq k :minor) (iso-minor-mark p) (mark-roots p (plan-tracer p))))

(defmethod gc-phase :reclaim ((p iso-plan) k)
  (if (eq k :minor)
      (space-direct-reclaim (iso-private p) (plan-vm p) k)
      (reclaim-spaces p k)))

(defmethod gc-phase :release ((p iso-plan) k)
  (declare (ignore k))
  (let ((mark (vm-direct-stratum (plan-vm p) :mark))) (when mark (s-clear mark)))
  (when (plan-stats p) (stats-event (plan-stats p) :gc-cycles 1)))

;; A private collection traces the request's roots (in the private space) plus
;; every object already published (public bit) -- those are reachable from
;; outside, so they must survive.  Under DLG no public object references a
;; private one, so tracing never escapes the private space.
(defun iso-minor-root-reference (plan ref)
  (trace-root-in plan ref (iso-private plan) :trace-kind :minor))

(defun iso-minor-grey-reference (plan ref)
  (trace-object-children plan ref
                         :target-space (iso-private plan)
                         :trace-kind :minor))

(defun iso-minor-mark (plan)
  (let* ((vm (plan-vm plan))
         (tr (plan-tracer plan))
         (priv (iso-private plan)))
    (tracer-reset tr)
    ;; seed roots in the private space
    (vm-direct-scan-roots vm plan #'iso-minor-root-reference)
    ;; seed published objects (external roots) within the private space
    (let ((pub (vm-direct-stratum vm :public)) (os (vm-object-start vm)))
      (when (and pub os)
        (loop for address from (space-base-address priv)
              below (space-end-address priv)
              when (and (s-test-bit pub address)
                        (s-test-bit os address))
                do (space-direct-trace-object priv vm address tr :minor))))
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
         (let* ((vm (plan-vm plan))
                (referent (vm-direct-object-reference vm object slot))
                (private (iso-private plan)))
           (when (and (vm-reference-p vm referent)
                      (space-direct-contains-p
                       private (ref-strip-or-self vm referent)))
             (space-direct-trace-object
              private vm referent (plan-tracer plan) nil))))))))

(defun make-iso-plan (vm heap-size)
  (declare (ignore heap-size))
  (destructuring-bind (pr pu) (partition-pages (vm-page-count vm) '(1/2 1/2))
    (let* ((private (make-instance 'private-immix-space :vm vm
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
