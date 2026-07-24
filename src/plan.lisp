;;;; plan.lisp -- the plan: a point in axis space (paper-v8 ch. plans).
;;;;
;;;; A plan binds spaces, allocators, a barrier, a publication strategy, and
;;;; a concurrency model.  plan-constraints ARE the row of the axis table.
;;;; Collection proceeds through ordered phases via the gc-phase method
;;;; combination.

(in-package #:clamsara)

;; ---- plan constraints (axis coordinates) ---------------------------------

(defclass plan-constraints ()
  ((generational       :initarg :generational       :initform nil :accessor constraints-generational)
   (scope              :initarg :scope              :initform :global :accessor constraints-scope)
   (write-barrier      :initarg :write-barrier      :initform :none :accessor constraints-write-barrier)
   (read-barrier       :initarg :read-barrier       :initform :none :accessor constraints-read-barrier)
   (forwarding         :initarg :forwarding         :initform :in-header :accessor constraints-forwarding)
   (concurrency        :initarg :concurrency        :initform :stw :accessor constraints-concurrency)
   (max-non-los-bytes  :initarg :max-non-los-bytes  :initform 8192 :accessor constraints-max-non-los-bytes))
  (:documentation "The axis coordinates of a plan (plans.tex)."))

;; ---- ordered phases (paper-v8 ch. plans) ---------------------------------
;;;; Implemented as explicit per-phase generic functions rather than a custom
;;;; method-combination: the same ordered semantics (prologue mark reclaim
;;;; compact checkpoint release epilogue), robust and easy to override.  A
;;;; plan overrides the individual phase generic it needs.

(defgeneric phase-prologue (plan cycle-kind))
(defgeneric phase-mark (plan cycle-kind))
(defgeneric phase-reclaim (plan cycle-kind))
(defgeneric phase-compact (plan cycle-kind))
(defgeneric phase-checkpoint (plan cycle-kind))
(defgeneric phase-release (plan cycle-kind))
(defgeneric phase-epilogue (plan cycle-kind))

(defgeneric plan-collect-phase (plan cycle-kind)
  (:documentation "Run the ordered collection phases.  Wrapped by :around for
  timing; each phase dispatches to its generic so plans override per-phase."))

;; ---- plan class ---------------------------------------------------------

(defclass plan ()
  ((name :initarg :name :reader plan-name)
   (vm   :initarg :vm   :reader plan-vm)
   (spaces :initarg :spaces :accessor plan-spaces)
   (barrier :initarg :barrier :accessor plan-barrier :initform nil)
   (publication :initarg :publication :initform nil :accessor plan-publication)
   (constraints :initarg :constraints :reader plan-constraints)
   (page-resource :accessor plan-page-resource :initform nil)
   (stats :accessor plan-stats :initform nil)
   (function-table :initform (make-hash-table :test 'eq) :reader plan-function-table)
   (sft :accessor plan-sft :initform nil)
   (tracer :accessor plan-tracer :initform nil)
   ;; Mutable state for allocation-free root/drain callbacks. A concurrent
   ;; backend replaces this per-plan slot with per-worker collector state.
   (active-trace-kind :accessor plan-active-trace-kind :initform nil)
   (booted-p :accessor plan-booted-p :initform nil)
   (sticky-p :initarg :sticky :initform nil :reader plan-sticky-p))
  (:metaclass plan-metaclass)
  (:default-initargs :constraints (make-instance 'plan-constraints)))

(defmethod shared-initialize :after ((p plan) slot-names &key)
  (declare (ignore slot-names))
  (setf (vm-plan (plan-vm p)) p))

;; ---- default phase methods ----------------------------------------------

(defun map-spaces (plan fn &optional (cycle-kind :full))
  (dolist (s (plan-spaces plan)) (funcall fn s cycle-kind)))

(defun prepare-spaces (plan cycle-kind)
  (let ((vm (plan-vm plan)))
    (dolist (space (plan-spaces plan))
      (space-prepare space vm :cycle-kind cycle-kind))))

(defun reclaim-spaces (plan cycle-kind)
  (let ((vm (plan-vm plan)))
    (dolist (space (plan-spaces plan))
      (space-reclaim space vm :cycle-kind cycle-kind))))

(defun release-spaces (plan cycle-kind)
  (let ((vm (plan-vm plan)))
    (dolist (space (plan-spaces plan))
      (space-release space vm :cycle-kind cycle-kind))))

(defmethod phase-prologue ((p plan) k)
  (vm-stop-mutators (plan-vm p))
  (prepare-spaces p k))

(defmethod phase-mark ((p plan) k)
  (declare (ignore k))
  (mark-roots p (plan-tracer p)))

(defmethod phase-reclaim ((p plan) k)
  (reclaim-spaces p k))

(defmethod phase-compact ((p plan) k) (declare (ignore p k)) nil)
(defmethod phase-checkpoint ((p plan) k) (declare (ignore p k)) nil)

(defmethod phase-release ((p plan) k)
  (release-spaces p k)
  (when (plan-stats p) (stats-event (plan-stats p) :gc-cycles 1)))

(defmethod phase-epilogue ((p plan) k)
  (declare (ignore k))
  (vm-resume-mutators (plan-vm p)))

(defmethod plan-collect-phase ((p plan) cycle-kind)
  (phase-prologue p cycle-kind)
  (phase-mark p cycle-kind)
  (phase-reclaim p cycle-kind)
  (phase-compact p cycle-kind)
  (phase-checkpoint p cycle-kind)
  (phase-release p cycle-kind)
  (phase-epilogue p cycle-kind))

(defmethod plan-collect-phase :around ((p plan) cycle-kind)
  (let ((t0 (get-internal-run-time)))
    (call-next-method)
    (when (plan-stats p)
      (stats-event (plan-stats p) :gc-time (- (get-internal-run-time) t0)))))

;; ---- plan-collect (compiled function table, else phase machine) ---------

(defun plan-default-cycle-kind (plan)
  (case (slot-value plan 'name)
    ((:gencopy :genms :genimmix :stickyimmix :stickyms :iso :claimore)
     :minor)
    (otherwise :full)))

(defun plan-collect (plan &key cycle-kind)
  "Enter the boot-compiled collector without CLOS dispatch at the entry point."
  (when (eq (slot-value plan 'name) :nogc)
    (error 'heap-exhausted :requested-size 0 :space :nogc))
  (let* ((kind (or cycle-kind (plan-default-cycle-kind plan)))
         (function
           (gethash 'plan-collect (slot-value plan 'function-table))))
    (if function
        (funcall function plan kind)
        (plan-collect-phase plan kind))))

;; ---- space accessors ----------------------------------------------------

(defun default-space (plan)
  (or (find-if #'space-default-p (plan-spaces plan))
      (find-if (lambda (s) (not (or (typep s 'immortal-space) (typep s 'los-space))))
              (plan-spaces plan))))

(defun plan-get-space (plan designator)
  (find designator (plan-spaces plan) :key #'space-name))

(defgeneric plan-nursery (plan)
  (:documentation "Return the currently allocating nursery, if PLAN has one."))

(defmethod plan-nursery ((plan plan))
  (or (find :nursery (plan-spaces plan) :key #'space-name)
      (find-if (lambda (s) (member (scope (space-constraints s)) '(:thread :request)))
               (plan-spaces plan))))

(defun plan-cons-space (plan)
  (find :cons (plan-spaces plan) :key #'space-name))

(defun plan-los (plan)
  (find-if (lambda (s) (typep s 'los-space)) (plan-spaces plan)))

;; ---- SFT (Space Function Table, O(1) address->space) --------------------

(defun plan-build-sft (plan)
  (let ((sft (make-array (vm-page-count (plan-vm plan)) :initial-element nil)))
    (dolist (space (plan-spaces plan))
      (loop for p from (space-start-page space)
            below (+ (space-start-page space) (space-page-count space))
            when (< p (length sft)) do (setf (aref sft p) space)))
    (setf (plan-sft plan) sft)))

(defun plan-space-for-address (plan addr)
  (let ((sft (plan-sft plan)))
    (cond
      ((null sft) nil)
      ((or (minusp addr) (>= (address-page addr) (length sft))) nil)
      (t (aref sft (address-page addr))))))

;; ---- allocation + escalation (plans.tex §5) -----------------------------

(defgeneric plan-allocate (plan size space-designator)
  (:method ((p plan) size space-designator)
    (let* ((vm (plan-vm p))
           (los (plan-los p))
           (space (if (and los (> (* size +word-bytes+) (constraints-max-non-los-bytes (plan-constraints p))))
                      los
                      (or (and (keywordp space-designator) (plan-get-space p space-designator))
                          (default-space p))))
           (addr (when space (alloc (space-allocator space) size))))
      (cond
        (addr (let ((os (vm-object-start vm))) (when os (s-set-bit os addr))) addr)
        (t (plan-handle-allocation-failure p size space))))))

(defgeneric plan-handle-allocation-failure (plan size space)
  (:method ((p plan) size space)
    ;; non-generational: try alloc; full collect; try alloc; signal.
    (plan-collect p :cycle-kind :full)
    (let ((addr (alloc (space-allocator space) size)))
      (if addr
          (progn (let ((os (vm-object-start (plan-vm p)))) (when os (s-set-bit os addr))) addr)
          (error 'heap-exhausted :requested-size size :space (space-name space))))))

(defun allocate-object (plan slot-count &key (type-tag +tag-object+) (space :default))
  "Allocate a headered object of SLOT-COUNT slots; return its address."
  (let ((addr (plan-allocate plan (1+ slot-count) space)))
    (vm-write-header (plan-vm plan) addr type-tag slot-count)
    addr))

;; ---- finalization / boot hooks ------------------------------------------

(defun finalize-plan (plan)
  "Wire spaces, SFT, strata, barrier, then validate.  Idempotent."
  (unless (plan-booted-p plan)
    (let ((vm (plan-vm plan)))
      (plan-install-strata plan vm)
      (dolist (s (plan-spaces plan))
        (setf (space-vm s) vm)
        (%ensure-allocator s vm))
      (plan-build-sft plan)
      (setf (plan-tracer plan) (make-tracer vm)
            (plan-stats plan) (or (plan-stats plan) (make-stats)))
      (when (plan-barrier plan)
        (initialize-barrier-buffers (plan-barrier plan) vm)
        (barrier-check (plan-barrier plan) plan))
      (when (plan-publication plan)
        (initialize-publication-work (plan-publication plan) vm))
      (component-validate plan)
      (setf (plan-booted-p plan) t)))
  plan)

(defgeneric plan-install-strata (plan vm)
  (:documentation "Register the side strata the plan's policy needs on the VM.")
  (:method ((p plan) vm)
    ;; defaults every tracing plan needs; concurrent/generational plans add more.
    (vm-set-location vm :mark :side)
    (vm-set-location vm :forwarding :in-header)
    (vm-register-stratum vm :mark
      (make-stratum :mark (vm-min-alignment-words vm) :bit (vm-heap-size vm)))))

;; ---- validation (plans.tex §1) ------------------------------------------

(defmethod component-validate ((p plan))
  (let ((c (plan-constraints p)) (vm (plan-vm p)))
    (when (eq (constraints-concurrency c) :concurrent-relocate)
      (unless (eq (constraints-forwarding c) :off-heap)
        (error 'plan-incompatible :plan p
               :message "concurrent-relocate requires off-heap forwarding")))
    (when (eq (constraints-forwarding c) :off-heap)
      (unless (vm-has-feature-p vm :t0)         ; off-heap table works on any tier
        (error 'plan-incompatible :plan p :message "off-heap forwarding needs VM access")))
    (when (member (constraints-scope c) '(:thread :request))
      (unless (plan-publication p)
        (error 'plan-incompatible :plan p
               :message "non-global scope requires a publication strategy")))
    p))
