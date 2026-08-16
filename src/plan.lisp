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
   (requires-tier      :initarg :requires-tier      :initform :t0 :accessor constraints-requires-tier)
   (max-non-los-bytes  :initarg :max-non-los-bytes  :initform 8192 :accessor constraints-max-non-los-bytes))
  (:documentation "The axis coordinates of a plan (plans.tex)."))

;; ---- ordered phases (paper-v8 ch. plans) ---------------------------------
;;;;
;;;; Collection proceeds through the gc-phase method combination: one generic
;;;; function, one qualified method per phase, phases run in declaration order
;;;; (prologue mark weak reclaim compact checkpoint release epilogue).
;;;; :around methods wrap the assembled primary, so plan-wide wrappers (e.g.
;;;; timing) survive compilation.  The boot assembler (compile.lisp) resolves
;;;; the most-specific method per phase through the MOP and emits one compiled
;;;; plan-collect body; the combination and the compiler share this ordering
;;;; constant, so the two can never diverge.
;;;;
;;;; gc-phase methods take (plan cycle-kind) as arguments; the combination is
;;;; an ordered long-form method combination (the phases are qualifiers).

(defparameter +gc-phase-order+
  '(:prologue :mark :weak :reclaim :compact :checkpoint :release :epilogue)
  "The ordered gc-phase qualifiers, in execution order (plans.tex §3).  The
combination and the boot assembler both read this list, so the phase machine
has one source of truth.")

(define-method-combination gc-phase ()
  ;; One qualifier per phase; the combination assembles the most-specific
  ;; method of each phase in +gc-phase-order+, wrapped by :around methods.
  ;; The group list below must mirror +gc-phase-order+ (both are literal in
  ;; this file so they cannot drift silently; compile-time asserts follow).
  ((around (:around))
   (prologue (:prologue))
   (mark (:mark))
   (weak (:weak))
   (reclaim (:reclaim))
   (compact (:compact))
   (checkpoint (:checkpoint))
   (release (:release))
   (epilogue (:epilogue)))
  (let ((primary
          `(progn
             ,@(mapcan (lambda (phase-group)
                         (mapcar (lambda (m) `(call-method ,m ()))
                                 phase-group))
                       (list prologue mark weak reclaim compact
                             checkpoint release epilogue)))))
    (if around
        `(call-method ,(first around)
                      (,@(rest around)
                       (make-method ,primary)))
        primary)))

(defgeneric gc-phase (plan cycle-kind)
  (:documentation "The ordered collection phase machine.  Methods carry one
  phase qualifier from +gc-phase-order+; the combination assembles them in
  declaration order, each phase running its most-specific method.")
  (:method-combination gc-phase))

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
   (sticky-p :initarg :sticky :initform nil :reader plan-sticky-p)
   ;; finalization trait (weak.tex §2): known/pending finalizer vectors, plus
   ;; a collector-private freeze list (phase-weak snapshot -> epilogue move)
   (known :accessor plan-known-finalizers :initform nil)
   (pending :accessor plan-pending-finalizers :initform nil)
   (pending-finalizer-freeze :accessor plan-pending-finalizer-freeze
                             :initform nil))
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

(defmethod gc-phase :prologue ((p plan) k)
  (vm-stop-mutators (plan-vm p))
  (prepare-spaces p k))

(defmethod gc-phase :mark ((p plan) k)
  (declare (ignore k))
  (mark-roots p (plan-tracer p)))

(defmethod gc-phase :weak ((p plan) k)
  ;; weak.tex: weak-pointer processing after the transitive closure and
  ;; BEFORE reclamation (liveness data must still be readable).  Finalizer
  ;; deadness is snapshotted here for the same reason: reclaim/release clear
  ;; the mark stratum before the epilogue.
  (weak-phase p)
  (when (plan-known-finalizers p)
    (setf (plan-pending-finalizer-freeze p)
          (snapshot-finalizer-deadness p (plan-vm p) k))))

(defmethod gc-phase :reclaim ((p plan) k)
  (reclaim-spaces p k))

(defmethod gc-phase :compact ((p plan) k) (declare (ignore p k)) nil)
(defmethod gc-phase :checkpoint ((p plan) k) (declare (ignore p k)) nil)

(defmethod gc-phase :release ((p plan) k)
  (release-spaces p k)
  (when (plan-stats p) (stats-event (plan-stats p) :gc-cycles 1)))

(defmethod gc-phase :epilogue ((p plan) k)
  (vm-resume-mutators (plan-vm p))
  ;; weak.tex §2: dead objects with registered finalizers move known->pending
  ;; in the EPILOGUE, from the snapshot taken in the weak phase; finalizers
  ;; themselves run on a mutator after the pause, never inside it.
  (when (plan-pending-finalizer-freeze p)
    (process-finalizers p (plan-pending-finalizer-freeze p))
    (setf (plan-pending-finalizer-freeze p) nil)))

(defun call-gc-phase-method (plan cycle-kind phase)
  "Resolve the most-specific GC-PHASE method qualified PHASE for PLAN and
invoke its method function (MOP calling convention: (method-function args
next-methods)).  Boot compilation (compile.lisp) uses the same resolution, so
interpreted and compiled collectors cannot diverge."
  (let* ((gf (fdefinition 'gc-phase))
         (methods (compute-applicable-methods gf (list plan cycle-kind)))
         (method (find-if (lambda (m)
                            (equal (sb-mop:method-qualifiers m) (list phase)))
                          methods)))
    (unless method
      (error "No ~a method for ~s" phase (type-of plan)))
    (funcall (sb-mop:method-function method) (list plan cycle-kind) nil)))

(defmethod plan-collect-phase ((p plan) cycle-kind)
  (if (eq cycle-kind :checkpoint)
      ;; persistence.tex §4: a checkpoint is a snapshot, not a collection.
      ;; Only the checkpoint phase (plus the stop/resume safepoint) runs.
      (progn
        (vm-stop-mutators (plan-vm p))
        (call-gc-phase-method p cycle-kind :checkpoint)
        (vm-resume-mutators (plan-vm p)))
      (gc-phase p cycle-kind)))

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

(defun add-los-space (plan pages-fraction)
  "Append a large-object space (heap.tex §2: whole-page, treadmill) to PLAN's
  layout by carving PAGES-FRACTION of the last space's pages.  The last space
  keeps its start page; only its extent shrinks, so other spaces' addresses
  are undisturbed.  LOS allocations are exempt from the plan's nursery
  overrides via PLAN-ALLOCATE's size check."
  (let ((vm (plan-vm plan))
        (spaces (plan-spaces plan)))
    (when spaces
      (let* ((last (car (last spaces)))
             (carve (max 4 (floor (* (space-page-count last) pages-fraction))))
             (los-count (min carve (max 1 (- (space-page-count last) 2)))))
        (when (plusp los-count)
          (decf (slot-value last 'page-count) los-count)
          ;; The last space's allocator was built against the old extent;
          ;; rebuild it so its limit matches the shrunk region.
          (slot-makunbound last 'allocator)
          (%ensure-allocator last vm)
          (let* ((los-start (+ (space-start-page last)
                               (space-page-count last)))
                 (space (make-instance 'los-space :vm vm
                                       :start-page los-start
                                       :page-count los-count
                                       :name :los :default-space nil)))
            (setf (plan-spaces plan) (append spaces (list space)))
            space))))))

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
      ;; space validation runs here, after slots are populated: allocator
      ;; checks and the concurrent-relocate forwarding rule need the VM.
      (dolist (s (plan-spaces plan))
        (component-validate s))
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
               :message "concurrent-relocate requires off-heap forwarding"))
      ;; an LVB read rule is required for concurrent relocation
      (let ((rules (and (plan-barrier p) (barrier-rules (plan-barrier p)))))
        (unless (find :lvb rules :key #'barrier-rule-name)
          (error 'plan-incompatible :plan p
                 :message "concurrent-relocate requires an LVB read barrier"))))
    (when (eq (constraints-forwarding c) :off-heap)
      (unless (vm-has-feature-p vm :t0)         ; off-heap table works on any tier
        (error 'plan-incompatible :plan p :message "off-heap forwarding needs VM access")))
    (when (member (constraints-scope c) '(:thread :request))
      (unless (plan-publication p)
        (error 'plan-incompatible :plan p
               :message "non-global scope requires a publication strategy"))
      ;; a space with scope /= :global requires the plan's publication
      ;; strategy (heap.tex §7); a read-guarded strategy requires a read rule
      ;; or a trap entry (locality.tex §5)
      (when (and (plan-publication p)
                 (strategy-read-guarded-p (plan-publication p))
                 (not (eq (constraints-read-barrier c) :none))
                 (null (publication-read-rule (plan-publication p))))
        (unless (member :trap
                        (if (listp (constraints-read-barrier c))
                            (constraints-read-barrier c)
                            (list (constraints-read-barrier c))))
          (error 'plan-incompatible :plan p
                 :message "read-guarded publication needs a read rule or trap"))))
    ;; requires-tier must not exceed the VM's tier (plans.tex §1)
    (let* ((tiers '(:t0 :t1 :t2))
           (vm-pos (position (vm-tier vm) tiers))
           (req-pos (position (constraints-requires-tier c) tiers)))
      (unless (and vm-pos req-pos (<= req-pos vm-pos))
        (error 'plan-incompatible :plan p
               :message (format nil "plan requires ~a, VM provides ~a"
                                (constraints-requires-tier c) (vm-tier vm)))))
    ;; copying spaces must declare a partner (heap.tex §7)
    (dolist (s (plan-spaces p))
      (when (and (eq (space-moving s) :stw-copy) (not (space-partner s)))
        (error 'plan-incompatible :plan p
               :message (format nil "copying space ~a has no partner"
                                (space-name s)))))
    ;; the barrier rule list must be consistent with the declared write
    ;; barrier names (plans.tex §1)
    (let ((rules (and (plan-barrier p) (barrier-rules (plan-barrier p)))))
      (dolist (name (if (listp (constraints-write-barrier c))
                        (constraints-write-barrier c)
                        (and (not (eq (constraints-write-barrier c) :none))
                             (list (constraints-write-barrier c)))))
        (unless (or (eq name :none)
                    (find name rules :key #'barrier-rule-name))
          (error 'plan-incompatible :plan p
                 :message (format nil "declared write barrier ~a not in rule list"
                                  name)))))
    p))
