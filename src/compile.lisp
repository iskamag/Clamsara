(in-package #:clamsara)

;;;; Compilable Framework
;;;
;;; The paper describes a gc-phase method combination and boot-gc that
;;; compiles hot-path functions into a function table.  compile-to-functions
;;; returns an alist of (name . lambda-form) where each lambda-form is an
;;; unevaluated list (lambda (args) body...).  boot-gc calls compile on
;;; each form and stores the resulting function in the plan's function table.
;;;
;;; At boot time the full MOP is available to query the class hierarchy,
;;; compute effective methods, and embed method functions directly.  After
;;; boot, the hot path executes only compiled direct calls -- no CLOS
;;; generic dispatch, no method-combination resolution.

;;; --- gc-phase Method Combination ---
;;; Qualifiers: :around, :prologue, :mark, :sweep, :compact, :release, :epilogue
;;; Order: prologue -> mark -> sweep -> compact -> release -> epilogue
;;; The :around method wraps the phase sequence via call-next-method.
;;; Within each phase only the most-specific method is called.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (define-method-combination gc-phase ()
    ((around (:around))
     (prologue (:prologue))
     (mark (:mark))
     (sweep (:sweep))
     (compact (:compact))
     (release (:release))
     (epilogue (:epilogue))
     (default ()))
    (flet ((call-primary (method-group)
             (let ((m (first method-group)))
               (when m
                 `(call-method ,m)))))
      (let ((form (if default
                      `(progn ,@(mapcar #'(lambda (m) `(call-method ,m)) default))
                      nil)))
        (let ((m (call-primary epilogue)))
          (when m (setf form `(progn ,m ,form))))
        (let ((m (call-primary release)))
          (when m (setf form `(progn ,m ,form))))
        (let ((m (call-primary compact)))
          (when m (setf form `(progn ,m ,form))))
        (let ((m (call-primary sweep)))
          (when m (setf form `(progn ,m ,form))))
        (let ((m (call-primary mark)))
          (when m (setf form `(progn ,m ,form))))
        (let ((m (call-primary prologue)))
          (when m (setf form `(progn ,m ,form))))
        (if around
            `(call-method ,(first around)
                          (,@(rest around)
                           (make-method ,form)))
            form)))))

;;; --- Generic with gc-phase ---

(defgeneric plan-collect-phase (plan cycle-kind)
  (:method-combination gc-phase)
  (:documentation "Collect garbage for PLAN in CYCLE-KIND (:minor or :major).
Uses the gc-phase method combination to order collection phases."))

;;; --- Default phase methods ---
;;; These are fallbacks for plans that don't provide their own.

(defmethod plan-collect-phase :prologue ((plan plan) (cycle-kind t))
  "Prologue: clear barrier state."
  (declare (ignore cycle-kind))
  (when (plan-barrier plan)
    (barrier-clear-all (plan-barrier plan))))

(defmethod plan-collect-phase :mark ((plan plan) (cycle-kind t))
  "Mark: no-op default."
  (declare (ignore cycle-kind))
  nil)

(defmethod plan-collect-phase :sweep ((plan plan) (cycle-kind t))
  "Sweep: no-op default."
  (declare (ignore cycle-kind))
  nil)

(defmethod plan-collect-phase :compact ((plan plan) (cycle-kind t))
  "Compact: no-op default."
  (declare (ignore cycle-kind))
  nil)

(defmethod plan-collect-phase :release ((plan plan) (cycle-kind t))
  "Release: no-op default."
  (declare (ignore cycle-kind))
  nil)

(defmethod plan-collect-phase :epilogue ((plan plan) (cycle-kind t))
  "Epilogue: no-op default."
  (declare (ignore cycle-kind))
  nil)

(defmethod plan-collect-phase :epilogue ((plan finalization-trait) (cycle-kind t))
  "Finalization hook: move dead finalizer objects to pending queue."
  (declare (ignore cycle-kind))
  (let ((vm (plan-vm plan))
        (keep-count 0))
    (loop with known = (plan-known-finalizers plan)
          for i from 0 below (fill-pointer known)
          for entry = (aref known i)
          do (when (consp entry)
               (let ((obj-addr (car entry)))
                 (if (and (not (zerop obj-addr))
                          (vm-object-is-marked-p vm obj-addr))
                     (progn
                       (setf (aref known keep-count) entry)
                       (incf keep-count))
                     (progn
                       (vector-push-extend entry
                                           (plan-pending-finalizers plan)))))))
    (setf (fill-pointer (plan-known-finalizers plan)) keep-count)))

;;; --- :around method for timing ---

(defmethod plan-collect-phase :around ((plan plan) (cycle-kind t))
  ":around method for timing and statistics."
  (let ((start (get-internal-run-time)))
    (call-next-method)
    (let ((end (get-internal-run-time))
          (stats (plan-stats plan)))
      (incf (plan-stats-gc-count stats))
      (incf (plan-stats-gc-time stats)
            (/ (- end start) internal-time-units-per-second)))))

;;; --- Function Table ---

(defgeneric plan-function-table (plan)
  (:documentation "Return the compiled function table for PLAN."))

(defmethod plan-function-table ((plan plan))
  (slot-value plan 'function-table))

(defun lookup-compiled-function (plan name)
  "Look up the compiled function named NAME in PLAN's function table."
  (gethash name (plan-function-table plan)))

;;; --- Method-function helpers ---
;;; At boot time we use the MOP to find the method function that would
;;; be invoked by CLOS dispatch.  That function is embedded directly
;;; in the compiled lambda so the hot path skips all dispatch.

(defun method-fn-for (gf args)
  "Return the method function of the most-specific method of GF
applicable to ARGS, or NIL."
  (let ((m (first (compute-applicable-methods gf args))))
    (when m
      (method-function m))))

(defun phase-method-fns (gf plan cycle-kind)
  "Return an alist of (phase . method-function) for the most-specific
method of each gc-phase qualifier applicable to (PLAN CYCLE-KIND).
The :around entry holds the method-function of the most-specific
:around method, or NIL."
  (let* ((args (list plan cycle-kind))
         (methods (compute-applicable-methods gf args))
         (around nil)
         (phase-fns nil))
    (dolist (m methods)
      (let* ((quals (method-qualifiers m))
             (key (if quals (first quals) :default)))
        (cond
          ((eq key :around)
           (unless around
             (setf around (method-function m))))
          ((member key '(:prologue :mark :sweep :compact :release :epilogue))
           ;; Only keep the most-specific (first) method per phase.
           ;; compute-applicable-methods returns most-specific-first.
           (unless (assoc key phase-fns)
             (push (cons key (method-function m)) phase-fns))))))
    ;; Sort by phase order
    (let ((phase-order '(:prologue :mark :sweep :compact :release :epilogue)))
      (append (list (cons :around around))
              (loop for phase in phase-order
                    for pair = (assoc phase phase-fns)
                    when pair collect pair)))))

(defun space-method-fn (space gf-name &optional extra-args)
  "Return the method-function of the most-specific method of
\(FDEFINITION GF-NAME) applicable to (SPACE . EXTRA-ARGS)."
  (let* ((gf (fdefinition gf-name))
         (args (list* space extra-args)))
    (method-fn-for gf args)))

;;; --- Compilation helpers ---

(defun space-qname (space op-name)
  "Return a qualified keyword symbol like :NURSERY0-SPACE-TRACE-OBJECT."
  (intern (format nil "~A-~A" (space-name space) op-name) :keyword))

;;; --- compile-gc-phase-form ---
;;; Produces a lambda form that directly calls the method functions
;;; of plan-collect-phase, skipping all CLOS dispatch.

(defun compile-gc-phase-form (plan)
  "Return a lambda form that runs the gc-phase effective method for PLAN.
At boot time we find all applicable methods, extract their method-functions,
pre-build args lists and continuation closures, and embed them as constants.
The resulting compiled lambda does zero allocation at runtime."
  (flet ((build (cycle-kind)
           (let* ((pairs (phase-method-fns #'plan-collect-phase plan cycle-kind))
                  (around-fn (cdr (assoc :around pairs)))
                  ;; Pre-build the arguments list -- one allocation at boot time.
                  (args (list plan cycle-kind))
                  ;; Phase call forms that reference the pre-built args list.
                  (phase-forms
                    (loop for (phase . fn) in pairs
                          unless (eq phase :around)
                          collect `(funcall ,fn ',args ()))))
             (if around-fn
                 ;; Pre-build continuation closure and next-methods list.
                 (let* ((cont (compile nil
                                `(lambda (args next)
                                   (declare (ignore args next))
                                   ,@phase-forms)))
                        (next (list cont)))
                   `(funcall ,around-fn ',args ',next))
                 `(progn ,@phase-forms)))))
    (let ((major-body (build :major))
          (minor-body (build :minor)))
      `(lambda (plan cycle-kind)
         (declare (optimize speed) (ignorable plan cycle-kind))
         (ecase cycle-kind
           (:major ,major-body)
           (:minor ,minor-body))))))

;;; --- compile-trace-dispatch ---
;;; Produces a case form over space names with inlined space-trace-object
;;; method functions.  No per-object space lookup dispatch at runtime.

(defun compile-trace-dispatch (plan)
  "Return a lambda form that dispatches object tracing by space name.
Each branch contains a direct call to the space's trace method function."
  (let ((clauses nil))
    (dolist (space (plan-spaces plan))
      (when (typep space 'collectable-space)
        (let* ((fn (space-method-fn space 'space-trace-object
                                    (list nil nil nil)))
               (name (space-name space)))
          (when fn
            (push `(,name
                     ;; Method lambda-list: (space vm ref tracer
                     ;;   &key cycle-kind trace-kind copy-semantics)
                     (funcall ,fn
                              (list ,space vm ref tracer
                                    :cycle-kind cycle-kind
                                    :trace-kind trace-kind
                                    :copy-semantics copy-semantics)
                              ()))
                  clauses)))))
    `(lambda (vm ref tracer cycle-kind trace-kind copy-semantics)
       (declare (optimize speed) (ignorable cycle-kind trace-kind copy-semantics))
       (let ((space (plan-space-for-address *active-plan* ref)))
         (if space
             (case (space-name space)
               ,@(nreverse clauses)
               (t ref))
             ref)))))

;;; --- compile-to-functions ---
;;; Returns an alist of (name . lambda-form).  Each lambda-form is an
;;; unevaluated list ready for compile.  The append method combination
;;; collects contributions from all components in the specialisation chain.

(defgeneric compile-to-functions (component)
  (:method-combination append)
  (:documentation "Return an alist of (name . lambda-form) for all hot-path
functions contributed by COMPONENT.  Each lambda-form is a list
 (lambda (args) body...), not yet compiled."))

(defmethod compile-to-functions append ((space space))
  nil)

(defmethod compile-to-functions append ((b no-barrier))
  nil)

(defmethod compile-to-functions append ((a free-list-allocator))
  nil)

(defmethod compile-to-functions append ((a immix-allocator))
  nil)

(defmethod compile-to-functions append ((a large-object-allocator))
  nil)

(defmethod compile-to-functions append ((plan plan))
  "Plan contributes the compiled gc-phase form and trace dispatch,
plus all component contributions from spaces, barrier, and allocators."
  (append (compile-to-functions-components plan)
          (list (cons 'plan-collect-phase (compile-gc-phase-form plan))
                (cons 'plan-trace-fn (compile-trace-dispatch plan)))))

(defun compile-to-functions-components (plan)
  "Collect compile-to-functions contributions from the plan's spaces,
barrier, and allocators."
  (let ((forms nil))
    (dolist (space (plan-spaces plan))
      (setf forms (append (compile-to-functions space) forms)))
    (let ((barrier (plan-barrier plan)))
      (when barrier
        (setf forms (append (compile-to-functions barrier) forms))))
    (dolist (space (plan-spaces plan))
      (let ((alloc (space-allocator space)))
        (when alloc
          (setf forms (append (compile-to-functions alloc) forms)))))
    forms))

;;; --- Space contributions ---
;;; Each space trait contributes its trace, prepare, sweep, and release
;;; functions as compiled lambda forms keyed by space-qualified symbols.

(defmethod compile-to-functions append ((space copying-space-trait))
  (let* ((trace-fn (space-method-fn space 'space-trace-object
                                    (list nil nil nil)))
         (prepare-fn (space-method-fn space 'space-prepare (list nil)))
         (release-fn (space-method-fn space 'space-release (list nil)))
         (result nil))
    (when trace-fn
      (push (cons (space-qname space 'space-trace-object)
                  `(lambda (vm ref tracer &key cycle-kind trace-kind copy-semantics)
                     (declare (optimize speed))
                     (funcall ,trace-fn
                              (list ,space vm ref tracer
                                    :cycle-kind cycle-kind
                                    :trace-kind trace-kind
                                    :copy-semantics copy-semantics)
                              ())))
            result))
    (when prepare-fn
      (push (cons (space-qname space 'space-prepare)
                  `(lambda (vm &key cycle-kind)
                     (declare (optimize speed))
                     (funcall ,prepare-fn
                              (list ,space vm :cycle-kind cycle-kind)
                              ())))
            result))
    (when release-fn
      (push (cons (space-qname space 'space-release)
                  `(lambda (vm &key cycle-kind)
                     (declare (optimize speed))
                     (funcall ,release-fn
                              (list ,space vm :cycle-kind cycle-kind)
                              ())))
            result))
    (nreverse result)))

(defmethod compile-to-functions append ((space marksweep-space-trait))
  (let* ((trace-fn (space-method-fn space 'space-trace-object
                                    (list nil nil nil)))
         (sweep-fn (space-method-fn space 'space-sweep (list nil)))
         (result nil))
    (when trace-fn
      (push (cons (space-qname space 'space-trace-object)
                  `(lambda (vm ref tracer &key cycle-kind trace-kind copy-semantics)
                     (declare (optimize speed))
                     (funcall ,trace-fn
                              (list ,space vm ref tracer
                                    :cycle-kind cycle-kind
                                    :trace-kind trace-kind
                                    :copy-semantics copy-semantics)
                              ())))
            result))
    (when sweep-fn
      (push (cons (space-qname space 'space-sweep)
                  `(lambda (vm)
                     (declare (optimize speed))
                     (funcall ,sweep-fn (list ,space vm) ())))
            result))
    (nreverse result)))

;;; --- Barrier contributions ---

(defmethod compile-to-functions append ((barrier object-barrier))
  (let* ((write-fn (method-fn-for #'barrier-note-write
                                  (list barrier 0 0 0)))
         (scan-fn (method-fn-for #'barrier-card-scan
                                  (list barrier nil nil)))
         (clear-fn (method-fn-for #'barrier-clear-all
                                   (list barrier)))
         (result nil))
    (when write-fn
      (push (cons 'barrier-note-write
                  `(lambda (source-addr slot-idx new-value &key old-value)
                     (declare (optimize speed))
                     (funcall ,write-fn
                              (list ,barrier source-addr slot-idx new-value
                                    :old-value old-value)
                              ())))
            result))
    (when scan-fn
      (push (cons 'barrier-card-scan
                  `(lambda (vm scan-fn)
                     (declare (optimize speed))
                     (funcall ,scan-fn (list ,barrier vm scan-fn) ())))
            result))
    (when clear-fn
      (push (cons 'barrier-clear-all
                  `(lambda ()
                     (declare (optimize speed))
                     (funcall ,clear-fn (list ,barrier) ())))
            result))
    (nreverse result)))

;;; --- Allocator contributions ---

(defmethod compile-to-functions append ((a bump-allocator))
  (let ((alloc-fn (method-fn-for #'alloc (list a 0))))
    (when alloc-fn
      (list (cons 'bump-alloc
                  `(lambda (size)
                     (declare (optimize speed) (type fixnum size))
                     (funcall ,alloc-fn (list ,a size) ())))))))

;;; --- boot-gc ---
;;; Idempotent: if the function table is already populated, returns immediately.
;;; Compiles all lambda forms, populates the function table, and shadows
;;; the plan-collect generic to use the compiled entry point.

(defun boot-gc (plan)
  "Compile all hot-path functions for PLAN into the function table.
After boot, plan-collect reads from the table via an :around method,
avoiding a global fdefinition shadow that would break multi-plan use."
  (let ((table (plan-function-table plan)))
    (unless (plusp (hash-table-count table))
      (let ((forms (compile-to-functions plan)))
        ;; Process in reverse so most-specific entries (plan type) override
        ;; less-specific ones (base classes) for duplicate keys.
        (loop for (name . lambda-form) in (reverse forms)
              do (let ((fn (compile nil lambda-form)))
                   (setf (gethash name table) fn))))))
  plan)

;;; --- plan-collect :around lookup ---
;;; Checks the function table for a compiled plan-collect entry,
;;; falling back to plan-collect-phase for non-generational plans.

(defmethod plan-collect :around ((plan plan) &key (cycle-kind :major))
  ":around method that tries the compiled function table first.
When boot-gc has populated the table, this avoids CLOS dispatch entirely
for the collection entry point while staying compatible with multi-plan use."
  (let ((collect-fn (lookup-compiled-function plan 'plan-collect)))
    (if collect-fn
        (funcall collect-fn plan :cycle-kind cycle-kind)
        (let ((phase-fn (lookup-compiled-function plan 'plan-collect-phase)))
          (if phase-fn
              (funcall phase-fn plan cycle-kind)
              (call-next-method))))))

;;; --- plan-collect fallback ---
;;; Used when boot-gc hasn't been called (interactive / no compiled table).

(defmethod plan-collect ((plan plan) &key (cycle-kind :major))
  "Default plan-collect: delegates to plan-collect-phase via gc-phase
method combination.  Used when no compiled function table exists."
  (plan-collect-phase plan cycle-kind))

;;; --- Plan initialization ---

(defgeneric plan-initialize-spaces (plan vm heap-size)
  (:documentation "Initialize PLAN's spaces with VM and HEAP-SIZE."))

(defmethod plan-initialize-spaces ((plan plan) vm heap-size)
  "Default no-op. Each plan type provides its own initialization."
  (declare (ignore vm heap-size))
  plan)
