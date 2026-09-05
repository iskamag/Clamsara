;;;; bench/gabriel/runner.lisp -- optional Maclina benchmark runner.

(in-package #:clamsara-gabriel-bench)

(defvar *gabriel-window-cell* nil)


(defconstant +gabriel-hard-max-iterations+ 25
  "Non-configurable ceiling that keeps this diagnostic harness bounded.")
(defparameter *gabriel-default-iterations* 3
  "Iterations used by RUN-GABRIEL-BENCH when none is supplied.")
(defparameter *gabriel-max-iterations* +gabriel-hard-max-iterations+
  "Optional lower bound for one invocation; never raises the hard ceiling.")
(defparameter *gabriel-suite-heap-size* 32768
  "Shared first-attempt heap size for every plan in RUN-GABRIEL-SUITE.
All nine plans pass the current canonical/smoke set at this size, so normal
cross-plan evidence does not conceal a capacity retry.")
(defparameter *gabriel-suite-plans*
  '(:semispace :marksweep :immix :gencopy :genms :genimmix
    :stickyimmix :stickyms :zgcish)
  "Collector plans exercised by RUN-GABRIEL-SUITE.")

(define-condition maclina-benchmark-unavailable (error)
  ((reason :initarg :reason :reader maclina-benchmark-unavailable-reason))
  (:report (lambda (condition stream)
             (format stream
                     "Maclina benchmark unavailable: ~a"
                     (maclina-benchmark-unavailable-reason condition)))))

(define-condition gabriel-benchmark-failure (error)
  ((workload :initarg :workload :reader gabriel-failure-workload)
   (iteration :initarg :iteration :reader gabriel-failure-iteration)
   (expected :initarg :expected :reader gabriel-failure-expected)
   (actual :initarg :actual :reader gabriel-failure-actual))
  (:report (lambda (condition stream)
             (format stream
                     "Gabriel workload ~a failed at iteration ~d: "
                     (gabriel-failure-workload condition)
                     (gabriel-failure-iteration condition))
             (format stream "expected ~s, got ~s"
                     (gabriel-failure-expected condition)
                     (gabriel-failure-actual condition)))))

(defun %asdf-load-system (name)
  "Load NAME without putting an ASDF package reference in this optional file.

The benchmark system itself depends only on CLAMSARA.  This late lookup lets a
missing Quicklisp/ASDF Maclina installation produce our actionable condition
instead of making the core system depend on any workload package."
  (let ((asdf (or (find-package :asdf)
                  (progn
                    (ignore-errors (require :asdf))
                    (find-package :asdf)))))
    (unless asdf
      (error "ASDF is not loaded"))
    (let ((load-system (find-symbol "LOAD-SYSTEM" asdf)))
      (unless (and load-system (fboundp load-system))
        (error "ASDF:LOAD-SYSTEM is unavailable"))
      (funcall load-system name))))

(defun %maclina-symbol (package name)
  (multiple-value-bind (symbol status) (find-symbol name package)
    (unless (and symbol (eq status :external))
      (error "package ~a does not export ~a"
             (package-name package) name))
    symbol))

(defun %ensure-maclina ()
  "Return the package and symbols needed by the evaluator.

Loading is deliberately deferred until the benchmark is invoked.  Thus
`(asdf:load-system :clamsara)` and all core tests remain dependency-free."
  (handler-case
      (progn
        (unless (find-package :clamsara-maclina)
          (%asdf-load-system :clamsara/maclina))
        (let ((package (find-package :clamsara-maclina)))
          (unless package
            (error "loading :clamsara/maclina did not create CLAMSARA-MACLINA"))
          (let ((with-macro (%maclina-symbol package "WITH-CLAMSARA-MACLINA"))
                (eval-string (%maclina-symbol package
                                              "CLAMSARA-MACLINA-EVAL-STRING"))
                (load-file (%maclina-symbol package
                                            "LOAD-MACLINA-SOURCE-FILE")))
            ;; ASDF can leave a package behind if an earlier component failed;
            ;; reject that partial load with the same actionable condition.
            (unless (macro-function with-macro)
              (error "CLAMSARA-MACLINA:WITH-CLAMSARA-MACLINA is not loaded"))
            (unless (fboundp eval-string)
              (error
               "CLAMSARA-MACLINA:CLAMSARA-MACLINA-EVAL-STRING is not loaded"))
            (unless (fboundp load-file)
              (error
               "CLAMSARA-MACLINA:LOAD-MACLINA-SOURCE-FILE is not loaded"))
            (values package with-macro eval-string load-file))))
    (maclina-benchmark-unavailable (condition)
      (error condition))
    (error (condition)
      (error 'maclina-benchmark-unavailable
             :reason (princ-to-string condition)))))

(defun maclina-dependencies-available-p ()
  "Return true when Maclina and its adapter can be loaded.

A second value contains a human-readable reason when false.  This predicate
never signals for an absent optional dependency, which is useful to scripts
that want to skip rather than run the benchmark."
  (handler-case
      (progn (%ensure-maclina) (values t nil))
    (maclina-benchmark-unavailable (condition)
      (values nil (princ-to-string condition)))))

(defparameter *gabriel-reference-directory* "bench/gabriel/reference/"
  "Repo-relative location of the checked-in canonical benchmark sources,
resolved against the :clamsara/bench/gabriel system at call time.")

(defun %reference-pathname (filename)
  "Resolve FILENAME under the checked-in canonical reference directory.

The system definition lives at the repository root, so resolving through the
registered system stays correct under ASDF output translations, which move
compiled files away from the sources."
  (let ((asdf (or (find-package :asdf)
                  (progn (ignore-errors (require :asdf))
                         (find-package :asdf)))))
    (unless asdf
      (error "ASDF is not loaded"))
    (let ((relative (find-symbol "SYSTEM-RELATIVE-PATHNAME" asdf)))
      (unless (and relative (fboundp relative))
        (error "ASDF:SYSTEM-RELATIVE-PATHNAME is unavailable"))
      (funcall relative :clamsara/bench/gabriel
               (merge-pathnames filename *gabriel-reference-directory*)))))

(defun %assert-plan-sane (plan workload cycle-kind)
  "Signal when a completed workload collection leaves invalid simulator state."
  (let ((errors (clamsara:sanity-check
                 plan :check-mark (not (clamsara::plan-sticky-p plan)))))
    (when errors
      (error "Gabriel workload ~S failed sanity after ~S collection:~%~
              ~{  ~A~%~}"
             workload cycle-kind errors))))

(defun %evaluate-workload (with-macro eval-string load-file workload
                           iterations plan-type heap-size stack-size
                           collector-host-bytes-cell)
  "Evaluate one workload in a fresh Maclina/Clamsara environment.

The fresh environment is warmed before the measured iterations: this compiles
the interpreted workload and resolves every first-contact dispatch while
Maclina closures are live, so measured
collections see only real collector work.  COLLECTOR-HOST-BYTES-CELL is a
cons whose CAR accumulates host bytes consed inside plan-collect windows."
  ;; The eval'd WITH-CLAMSARA-MACLINA form cannot close over lexical
  ;; variables, so the accumulator is read through the special below.
  (let ((source (gabriel-workload-source workload))
        (expected (gabriel-workload-expected workload))
        (name (gabriel-workload-name workload))
        ;; Canonical workloads load their checked-in reference source into
        ;; every fresh environment; style workloads have no file to load.
        (reference (and (gabriel-workload-canonical-p workload)
                        (%reference-pathname
                         (canonical-gabriel-workload-reference-file
                          workload))))
        (*gabriel-window-cell* collector-host-bytes-cell))
    ;; WITH-CLAMSARA-MACLINA is a macro in an optional package.  Constructing
    ;; this form after the package has loaded keeps the benchmark source
    ;; readable and avoids a compile-time dependency on that package.
    ;; Benchmark source strings are read in the Maclina source package,
    ;; mirroring LOAD-MACLINA-SOURCE-FILE's read semantics for files, so an
    ;; invocation name resolves to the definitions the canonical file (or the
    ;; inline source itself) installed in this environment.
    (let ((*package* (find-package '#:clamsara-maclina)))
    (eval `(,with-macro
             (:plan-type ,plan-type
              :heap-size ,heap-size
              :stack-size ,stack-size)
             (let* ((values nil)
                    (window-open nil)
                    (base-cell (cons 0 nil))
                    (accounting-hook
                      (lambda (pl cycle-kind phase)
                        (cond
                          ((and (eq phase :enter) (not window-open))
                           ;; Close-region is idempotent and allocation-free;
                           ;; call it before the baseline read as
                           ;; belt-and-braces against deferred updates.
                           (%close-region)
                           (setf (car base-cell) (%host-bytes)
                                 window-open t))
                          ((and (or (eq phase :exit) (eq phase :abort))
                                window-open)
                           (incf (car *gabriel-window-cell*)
                                 (- (%host-bytes) (car base-cell)))
                           ;; Drain the collector's own pending region now so
                           ;; the next window's baseline starts clean.
                           (%close-region)
                           (setf window-open nil)
                           ;; Only a completed collection has a coherent
                           ;; post-state.  Sanity runs after the byte window is
                           ;; closed, so checker allocations are not charged to
                           ;; the collector.
                           (when (eq phase :exit)
                             (%assert-plan-sane pl ',name cycle-kind)
                             (incf (cdr *gabriel-window-cell*)))))))
                    (stats nil)
                    (elapsed 0.0))
               ;; Canonical workloads load their checked-in source into this
               ;; fresh environment exactly like an interactive load, before
               ;; any warmup or measured iteration.
               (when ',reference
                 (funcall ',load-file ',reference))
               ;; Warmup first: unmeasured, no hook installed.  Three
               ;; passes settle the interpreted workload's one-time host
               ;; costs; a single pass does not (first-contact dispatches
               ;; still land inside measured collection windows).
               (dotimes (warmup 3)
                 (let ((value (funcall ',eval-string ,source)))
                   (unless (or (null ',expected) (equal value ',expected))
                     (error 'gabriel-benchmark-failure
                            :workload ',name
                            :iteration (list 'warmup warmup)
                            :expected ',expected
                            :actual value))))
               ;; Warmup activity is not part of the benchmark counters.
               (clamsara:stats-reset
                (clamsara:plan-stats clamsara:*clamsara-plan*))
               (%close-region)
               (clamsara:with-plan-collect-hook
                   (clamsara:*clamsara-plan* accounting-hook)
                 (let ((started (get-internal-real-time)))
                   (dotimes (iteration ,iterations)
                     (let ((value (funcall ',eval-string ,source)))
                       (unless (equal value ',expected)
                         (error 'gabriel-benchmark-failure
                                :workload ',name
                                :iteration iteration
                                :expected ,expected
                                :actual value))
                       (push value values)))
                   (setf elapsed
                         (/ (- (get-internal-real-time) started)
                            (float internal-time-units-per-second))))
                 ;; Every workload performs at least one checked collection,
                 ;; including allocation-free TAK and the small DDERIV case.
                 (clamsara:plan-collect clamsara:*clamsara-plan*
                                        :cycle-kind :full))
               (setf stats (clamsara:stats-snapshot
                             (clamsara:plan-stats clamsara:*clamsara-plan*)))
               (values (nreverse values) stats elapsed)))))))

#+sbcl
(eval-when (:compile-toplevel :load-toplevel :execute)
  (sb-alien:define-alien-variable ("bytes_allocated" %gabriel-host-bytes-var)
    sb-alien:unsigned-long))

(defun %host-bytes ()
  #+sbcl %gabriel-host-bytes-var
  #-sbcl 0)

;; Window accounting needs a closed thread region for exact counter reads.
(defun %close-region ()
  #+sbcl (sb-vm::close-thread-alloc-region)
  #-sbcl nil)

(defun %validate-options (iterations heap-size stack-size)
  (let ((limit (min *gabriel-max-iterations*
                    +gabriel-hard-max-iterations+)))
    (unless (and (integerp iterations)
                 (plusp iterations)
                 (<= iterations limit))
      (error ":ITERATIONS must be an integer from 1 through ~d (got ~s)"
             limit iterations)))
  (unless (and (integerp heap-size) (plusp heap-size))
    (error ":HEAP-SIZE must be a positive integer (got ~s)" heap-size))
  (unless (and (integerp stack-size) (plusp stack-size))
    (error ":STACK-SIZE must be a positive integer (got ~s)" stack-size)))

(defun run-gabriel-bench
    (&key (workloads *gabriel-workloads*)
          (iterations *gabriel-default-iterations*)
          (plan-type :semispace)
          (heap-size 8192)
          (stack-size 65536)
          (stream *standard-output*)
          (verbose t))
  "Run the supported canonical Gabriel and clearly labelled smoke workloads.

Each workload gets a fresh Clamsara/Maclina environment.  ITERATIONS is
bounded to keep this diagnostic harness from becoming an accidental stress
suite.  The return value is a list of plists containing elapsed seconds,
values, and Clamsara event statistics.  Maclina dependencies are loaded only
here, and missing packages signal MACLINA-BENCHMARK-UNAVAILABLE with a clear
message."
  (%validate-options iterations heap-size stack-size)
  (multiple-value-bind (package with-macro eval-string load-file)
      (%ensure-maclina)
    (declare (ignore package))
    (when verbose
      (format stream
              "~&Gabriel Maclina workloads: canonical TAK and TAKR loaded ~
               from ~a; ctak.cl, stak.cl, and takl.cl skipped (see ~
               forms.lisp for the exact load and safety reasons)~%"
              *gabriel-reference-directory*))
    (let (results)
      (dolist (workload workloads (nreverse results))
        (unless (typep workload 'gabriel-workload)
          (error "Not a GABRIEL-WORKLOAD: ~s" workload))
        (let ((bytes-cell (cons 0 0)))
          (multiple-value-bind (values stats elapsed)
              (%evaluate-workload with-macro eval-string load-file workload
                                  iterations plan-type heap-size stack-size
                                  bytes-cell)
            (let ((result (list :name (gabriel-workload-name workload)
                                :plan plan-type
                                :heap-size heap-size
                                :iterations iterations
                                :elapsed-seconds elapsed
                                :values values
                                :status :ok
                                :attempted-heap-sizes (list heap-size)
                                :allocation-retries 0
                                :aborted nil
                                :reference-file
                                (and (gabriel-workload-canonical-p workload)
                                     (canonical-gabriel-workload-reference-file
                                      workload))
                                :collector-host-bytes (car bytes-cell)
                                :collections-checked (cdr bytes-cell)
                                :stats stats)))
              (push result results)
              (when verbose
                (format stream
                        "  ~a~@[ [canonical ~a]~]: ~d iterations, ~,3f sec, ~
                         collector-host-bytes=~d, sanity-checks=~d, stats ~s~%"
                        (getf result :name)
                        (getf result :reference-file)
                        iterations
                        elapsed
                        (getf result :collector-host-bytes)
                        (getf result :collections-checked)
                        stats)))))))))

(defun run-gabriel-suite (&key (stream *standard-output*) verbose
                               (iterations *gabriel-default-iterations*))
  "Run every admitted workload across all plans and return explicit evidence.

Every plan first gets the same *GABRIEL-SUITE-HEAP-SIZE*.  Unexpected capacity
retries remain bounded, printed, and recorded in each successful result.  The
final report also contains one :SKIPPED record for each canonical source that
cannot safely execute; those records are never multiplied into passing plan
results."
  (let ((results nil))
    (dolist (plan *gabriel-suite-plans*)
      (let ((heap-size *gabriel-suite-heap-size*)
            (attempts nil)
            (plan-results nil))
        (loop while (<= heap-size (* 16 *gabriel-suite-heap-size*))
              do (push heap-size attempts)
                 (handler-case
                     (progn
                       (setf plan-results
                             (run-gabriel-bench
                              :plan-type plan :heap-size heap-size
                              :iterations iterations :stream stream
                              :verbose verbose))
                       (return))
                   (clamsara:heap-exhausted ()
                     (let ((failed-size heap-size))
                       (setf heap-size (* heap-size 2))
                       (format stream
                               "~&~A exhausted ~D words; retrying at ~D~%"
                               plan failed-size heap-size)))))
        (unless plan-results
          (error "~A exhausted every Gabriel suite heap size; attempts ~S"
                 plan (nreverse attempts)))
        (let ((ordered-attempts (nreverse attempts)))
          (dolist (result plan-results)
            (setf (getf result :status) :ok
                  (getf result :attempted-heap-sizes) ordered-attempts
                  (getf result :allocation-retries)
                  (1- (length ordered-attempts))
                  (getf result :aborted) nil)
            (push result results)))))
    ;; COPY-TREE keeps callers from mutating the static skip ledger.
    (nconc (nreverse results) (copy-tree *gabriel-canonical-skips*))))

(defun run-gabriel-tests (&key (stream *standard-output*) (verbose t))
  "Run and enforce the Gabriel harness's correctness and evidence contracts."
  (let* ((results (run-gabriel-suite :stream stream :verbose nil))
         (ran (remove-if-not (lambda (r) (eq (getf r :status) :ok))
                             results))
         (skipped (remove-if-not
                   (lambda (r) (eq (getf r :status) :skipped)) results))
         (expected-ran (* (length *gabriel-suite-plans*)
                          (length *gabriel-workloads*))))
    (unless (= (length ran) expected-ran)
      (error "Gabriel suite produced ~D completed results, expected ~D"
             (length ran) expected-ran))
    (unless (= (length skipped) (length *gabriel-canonical-skips*))
      (error "Gabriel suite reported ~D canonical skips, expected ~D"
             (length skipped) (length *gabriel-canonical-skips*)))
    (dolist (skip skipped)
      (unless (and (getf skip :canonical)
                   (stringp (getf skip :reference-file))
                   (getf skip :missing-feature)
                   (plusp (length (getf skip :reason))))
        (error "Malformed canonical skip evidence: ~S" skip)))
    (dolist (result ran)
      (let ((cycles (cdr (assoc :gc-cycles (getf result :stats))))
            (host-bytes (getf result :collector-host-bytes)))
        (unless (plusp cycles)
          (error "Gabriel workload ~S performed no checked collection"
                 (getf result :name)))
        (unless (= cycles (getf result :collections-checked))
          (error "Gabriel workload ~S checked ~D of ~D collections"
                 (getf result :name)
                 (getf result :collections-checked) cycles))
        (unless (and (consp (getf result :attempted-heap-sizes))
                     (= (getf result :allocation-retries)
                        (1- (length (getf result :attempted-heap-sizes))))
                     (not (getf result :aborted)))
          (error "Gabriel workload ~S has incomplete attempt evidence: ~S"
                 (getf result :name) result))
        #+sbcl
        (unless (zerop host-bytes)
          (error "Gabriel workload ~S collector consed ~D host bytes"
                 (getf result :name) host-bytes))))
    (when verbose
      (format stream
              "~&Gabriel regression suite: ~D checked results, ~D explicit canonical skips~%"
              (length ran) (length skipped)))
    results))
