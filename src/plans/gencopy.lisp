;;;; plans/gencopy.lisp -- generational: copying nursery + copying mature,
;;;; card barrier, minor/major cycles.  The generational machinery is shared by
;;;; genms/genimmix (different mature space).

(in-package #:clamsara)

;; ---- generational base --------------------------------------------------

(defclass generational-plan (plan)
  ((nursery :accessor gen-nursery :initform nil)
   (mature :accessor gen-mature :initform nil)
   (mature-to :accessor gen-mature-to :initform nil)  ; set for copying mature
   (minor-count :accessor gen-minor-count :initform 0))
  (:metaclass plan-metaclass))

(defmethod plan-install-strata ((p generational-plan) vm)
  (vm-set-location vm :mark :side)
  (vm-set-location vm :forwarding :in-header)
  (vm-register-stratum vm :mark
    (make-stratum :mark (vm-min-alignment-words vm) :bit (vm-heap-size vm)))
  (vm-register-stratum vm :card
    (make-stratum :card (g-card) :bit (vm-heap-size vm)))
  (vm-register-stratum vm :age
    (make-stratum :age (vm-min-alignment-words vm) :u4 (vm-heap-size vm))))

(defmethod plan-allocate ((p generational-plan) size space-designator)
  (declare (ignore space-designator))
  (let ((addr (alloc (space-allocator (gen-nursery p)) size)))
    (cond (addr (let ((os (vm-object-start (plan-vm p))))
                 (when os (s-set-bit os addr))) addr)
          (t (plan-handle-allocation-failure p size (gen-nursery p))))))

(defmethod plan-handle-allocation-failure ((p generational-plan) size space)
  ;; try minor; retry; try major; retry; signal.
  (plan-collect p :cycle-kind :minor)
  (let ((addr (alloc (space-allocator space) size)))
    (cond
      (addr (let ((os (vm-object-start (plan-vm p))))
              (when os (s-set-bit os addr))) addr)
      (t (plan-collect p :cycle-kind :major)
         (let ((addr2 (alloc (space-allocator space) size)))
           (if addr2
               (progn (let ((os (vm-object-start (plan-vm p))))
                       (when os (s-set-bit os addr2))) addr2)
               (error 'heap-exhausted :requested-size size :space :nursery)))))))

(defmethod plan-collect ((p generational-plan) &key cycle-kind)
  (let ((fn (gethash 'plan-collect (plan-function-table p))))
    (if fn
        (funcall fn p (or cycle-kind :minor))
        (plan-collect-phase p (or cycle-kind :minor)))))

;; ---- phases -------------------------------------------------------------

(defmethod phase-prologue ((p generational-plan) k)
  (vm-stop-mutators (plan-vm p))
  (if (eq k :minor)
      (space-prepare (gen-nursery p) (plan-vm p))
      (progn
        (map-spaces p (lambda (s ck) (space-prepare s (plan-vm p) :cycle-kind ck)) k)
        (when (gen-mature-to p)
          (allocator-reset (space-allocator (gen-mature-to p)))))))

(defmethod phase-mark ((p generational-plan) k)
  (if (eq k :minor)
      (minor-mark p)
      (mark-roots p (plan-tracer p))))

(defmethod phase-reclaim ((p generational-plan) k)
  (if (eq k :minor)
      (space-reclaim (gen-nursery p) (plan-vm p) :cycle-kind k)
      (map-spaces p (lambda (s ck)
                      (space-reclaim s (plan-vm p) :cycle-kind ck)))))

(defmethod phase-release ((p generational-plan) k)
  (let ((vm (plan-vm p)))
    (when (and (gen-mature-to p) (eq k :major))
      (rotatef (gen-mature p) (gen-mature-to p))
      (setf (space-default-p (gen-mature p)) t
            (space-default-p (gen-mature-to p)) nil)
      (allocator-reset (space-allocator (gen-mature-to p))))
    (let ((card (vm-stratum vm :card))) (when card (s-clear card)))
    (let ((mark (vm-stratum vm :mark))) (when (and mark (eq k :minor)) (s-clear mark)))
    (when (plan-stats p) (stats-event (plan-stats p) :gc-cycles 1))
    (incf (gen-minor-count p))))

;; ---- minor marking: nursery only, seeded from roots + remembered set ----

(defun minor-mark (plan)
  (let* ((vm (plan-vm plan))
         (tr (plan-tracer plan))
         (nursery (gen-nursery plan)))
    ;; seed roots that point into the nursery
    (let ((roots (vm-root-vector vm)))
      (dotimes (i (length roots))
        (let* ((ref (aref roots i)) (addr (ref-strip-or-self vm ref)))
          (when (and (vm-reference-p vm ref) (space-contains-p nursery addr))
            (let ((new (space-trace-object nursery vm ref tr)))
              (unless (eql new ref) (setf (aref roots i) new)))))))
    ;; seed remembered set: dirty mature cards -> nursery refs
    (scan-remset plan vm nursery tr)
    ;; drain: trace nursery children only (mature refs are external roots)
    (tracer-drain tr
      (lambda (ref)
        (let ((addr (ref-strip-or-self vm ref)))
          (dotimes (k (vm-object-reference-count vm addr))
            (let ((child (vm-object-reference vm addr k)))
              (when (vm-reference-p vm child)
                (let ((caddr (ref-strip-or-self vm child)))
                  (when (space-contains-p nursery caddr)
                    (let ((new (space-trace-object nursery vm child tr)))
                      (unless (eql new child)
                        (setf (vm-object-reference vm addr k) new)))))))))))))

(defun scan-remset (plan vm nursery tr)
  "For each dirty mature card, seed the tracer with its nursery references."
  (let ((card (vm-stratum vm :card))
        (os (vm-object-start vm))
        (mature (gen-mature plan)))
    (when (and card os mature)
      (s-for-set-cells card
        (cons (space-base-address mature) (space-end-address mature))
        (lambda (caddr)
          (s-for-set-cells os
            (cons caddr (+ caddr (g-card)))
            (lambda (oaddr)
              (dotimes (k (vm-object-reference-count vm oaddr))
                (let ((child (vm-object-reference vm oaddr k)))
                  (when (and (vm-reference-p vm child)
                             (space-contains-p nursery (ref-strip-or-self vm child)))
                    (space-trace-object nursery vm child tr)))))))))))

;; ---- construction -------------------------------------------------------

(defun %make-generational (name vm mature-class copy-mature-p)
  (multiple-value-bind (nursery-spec mature-spec mto-spec)
      (if copy-mature-p
          (values-list (partition-pages (vm-page-count vm) '(1/4 3/8 3/8)))
          (values-list (append (partition-pages (vm-page-count vm) '(1/4 3/4))
                                (list nil))))
    (let* ((nursery (make-instance 'mark-sweep-space :vm vm
                                    :start-page (car nursery-spec) :page-count (cdr nursery-spec)
                                    :name :nursery :default-space t))
           (mature (make-instance mature-class :vm vm
                                   :start-page (car mature-spec) :page-count (cdr mature-spec)
                                   :name :mature :default-space nil))
           (barrier (make-instance 'barrier :rules (list (card-barrier-rule))))
           (p (make-instance 'generational-plan
                            :name name :vm vm
                            :spaces (list nursery mature)
                            :barrier barrier
                            :constraints (make-instance 'plan-constraints
                                         :generational t :write-barrier :card))))
      (setf (gen-nursery p) nursery (gen-mature p) mature)
      (setf (barrier-plan barrier) p)
      (when (and copy-mature-p mto-spec)
        (let ((mto-space (make-instance 'copy-space :vm vm
                                        :start-page (car mto-spec) :page-count (cdr mto-spec)
                                        :name :mature-to :default-space nil)))
          (setf (gen-mature-to p) mto-space
                (space-partner mature) mto-space
                (space-partner mto-space) mature)
          (setf (plan-spaces p) (list nursery mature mto-space))))
      (finalize-plan p) p)))

(defun make-gencopy-plan (vm heap-size)
  (declare (ignore heap-size))
  (%make-generational :gencopy vm 'copy-space t))
