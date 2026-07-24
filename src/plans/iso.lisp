;;;; plans/iso.lisp -- request-private mark-region + opportunistic copy +
;;;; eager-closure publication barrier (Qiu & Blackburn, PLDI 2025).
;;;; Coordinates: mark-region / trace / opportunistic / publication / request /
;;;; STW-local.  No read barrier (a deliberate Java-cost choice).

(in-package #:clamsara)

(defclass iso-plan (plan)
  ((private :accessor iso-private :initform nil)
   (public  :accessor iso-public  :initform nil))
  (:metaclass plan-metaclass))

(defmethod plan-install-strata ((p iso-plan) vm)
  (vm-set-location vm :mark :side)
  (vm-set-location vm :forwarding :in-header)
  (vm-register-stratum vm :mark
    (make-stratum :mark (vm-min-alignment-words vm) :bit (vm-heap-size vm)))
  (vm-register-stratum vm :public
    (make-stratum :public (vm-min-alignment-words vm) :bit (vm-heap-size vm))))

(defmethod plan-allocate ((p iso-plan) size space-designator)
  (declare (ignore space-designator))
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

(defmethod plan-collect ((p iso-plan) &key cycle-kind)
  (let ((fn (gethash 'plan-collect (plan-function-table p))))
    (if fn (funcall fn p (or cycle-kind :minor))
        (plan-collect-phase p (or cycle-kind :minor)))))

(defmethod phase-prologue ((p iso-plan) k)
  (vm-stop-mutators (plan-vm p))
  (if (eq k :minor)
      (space-prepare (iso-private p) (plan-vm p))
      (map-spaces p (lambda (s ck) (space-prepare s (plan-vm p) :cycle-kind ck)) k)))

(defmethod phase-mark ((p iso-plan) k)
  (if (eq k :minor) (iso-minor-mark p) (mark-roots p (plan-tracer p))))

(defmethod phase-reclaim ((p iso-plan) k)
  (if (eq k :minor)
      (space-reclaim (iso-private p) (plan-vm p) :cycle-kind k)
      (map-spaces p (lambda (s ck) (space-reclaim s (plan-vm p) :cycle-kind ck)))))

(defmethod phase-release ((p iso-plan) k)
  (declare (ignore k))
  (let ((mark (vm-stratum (plan-vm p) :mark))) (when mark (s-clear mark)))
  (when (plan-stats p) (stats-event (plan-stats p) :gc-cycles 1)))

;; A private collection traces the request's roots (in the private space) plus
;; every object already published (public bit) -- those are reachable from
;; outside, so they must survive.  Under DLG no public object references a
;; private one, so tracing never escapes the private space.
(defun iso-minor-mark (plan)
  (let* ((vm (plan-vm plan))
         (tr (plan-tracer plan))
         (priv (iso-private plan)))
    ;; seed roots in the private space
    (let ((roots (vm-root-vector vm)))
      (dotimes (i (length roots))
        (let* ((ref (aref roots i)) (addr (ref-strip-or-self vm ref)))
          (when (and (vm-reference-p vm ref) (space-contains-p priv addr))
            (space-trace-object priv vm ref tr)))))
    ;; seed published objects (external roots) within the private space
    (let ((pub (vm-stratum vm :public)) (os (vm-object-start vm)))
      (when (and pub os)
        (s-for-set-cells pub (cons (space-base-address priv) (space-end-address priv))
          (lambda (addr)
            (when (vm-object-start-p vm addr)
              (space-trace-object priv vm addr tr))))))
    ;; drain private only; public-space children are external
    (tracer-drain tr
      (lambda (ref)
        (let ((addr (ref-strip-or-self vm ref)))
          (dotimes (k (vm-object-reference-count vm addr))
            (let ((child (vm-object-reference vm addr k)))
              (when (vm-reference-p vm child)
                (let ((caddr (ref-strip-or-self vm child)))
                  (when (space-contains-p priv caddr)
                    (space-trace-object priv vm child tr)))))))))))

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
      (finalize-plan p) p)))
