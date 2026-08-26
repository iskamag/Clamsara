;;;; bench/gabriel/runner.lisp -- optional Maclina benchmark runner.

(in-package #:clamsara-gabriel-bench)

(defvar *gabriel-window-cell* nil)


(defconstant +gabriel-hard-max-iterations+ 25
  "Non-configurable ceiling that keeps this diagnostic harness bounded.")
(defparameter *gabriel-default-iterations* 3
  "Iterations used by RUN-GABRIEL-BENCH when none is supplied.")
(defparameter *gabriel-max-iterations* +gabriel-hard-max-iterations+
  "Optional lower bound for one invocation; never raises the hard ceiling.")
(defparameter *gabriel-suite-heap-size* 8192
  "Starting heap size for each plan in RUN-GABRIEL-SUITE.")
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
                     "Gabriel-style workload ~a failed at iteration ~d: "
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
                                              "CLAMSARA-MACLINA-EVAL-STRING")))
            ;; ASDF can leave a package behind if an earlier component failed;
            ;; reject that partial load with the same actionable condition.
            (unless (macro-function with-macro)
              (error "CLAMSARA-MACLINA:WITH-CLAMSARA-MACLINA is not loaded"))
            (unless (fboundp eval-string)
              (error
               "CLAMSARA-MACLINA:CLAMSARA-MACLINA-EVAL-STRING is not loaded"))
            (values package with-macro eval-string))))
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

(defun %assert-plan-sane (plan workload cycle-kind)
  "Signal when a completed workload collection leaves invalid simulator state."
  (let ((errors (clamsara:sanity-check
                 plan :check-mark (not (clamsara::plan-sticky-p plan)))))
    (when errors
      (error "Gabriel workload ~S failed sanity after ~S collection:~%~
              ~{  ~A~%~}"
             workload cycle-kind errors))))

(defun %evaluate-workload (with-macro eval-string workload iterations plan-type
                           heap-size stack-size collector-host-bytes-cell)
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
        (*gabriel-window-cell* collector-host-bytes-cell))
    ;; WITH-CLAMSARA-MACLINA is a macro in an optional package.  Constructing
    ;; this form after the package has loaded keeps the benchmark source
    ;; readable and avoids a compile-time dependency on that package.
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
               (values (nreverse values) stats elapsed))))))

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
  "Run the small optional Gabriel-style workload subset.

Each workload gets a fresh Clamsara/Maclina environment.  ITERATIONS is
bounded to keep this diagnostic harness from becoming an accidental stress
suite.  The return value is a list of plists containing elapsed seconds,
values, and Clamsara event statistics.  Maclina dependencies are loaded only
here, and missing packages signal MACLINA-BENCHMARK-UNAVAILABLE with a clear
message."
  (%validate-options iterations heap-size stack-size)
  (multiple-value-bind (package with-macro eval-string)
      (%ensure-maclina)
    (declare (ignore package))
    (when verbose
      (format stream
              "~&Gabriel-style Maclina subset (not full Gabriel coverage)~%"
              ))
    (let (results)
      (dolist (workload workloads (nreverse results))
        (unless (typep workload 'gabriel-workload)
          (error "Not a GABRIEL-WORKLOAD: ~s" workload))
        (let ((bytes-cell (cons 0 0)))
          (multiple-value-bind (values stats elapsed)
              (%evaluate-workload with-macro eval-string workload iterations
                                  plan-type heap-size stack-size bytes-cell)
            (let ((result (list :name (gabriel-workload-name workload)
                                :plan plan-type
                                :heap-size heap-size
                                :iterations iterations
                                :elapsed-seconds elapsed
                                :values values
                                :collector-host-bytes (car bytes-cell)
                                :collections-checked (cdr bytes-cell)
                                :stats stats)))
              (push result results)
              (when verbose
                (format stream
                        "  ~a: ~d iterations, ~,3f sec, ~
                         collector-host-bytes=~d, sanity-checks=~d, stats ~s~%"
                        (getf result :name)
                        iterations
                        elapsed
                        (getf result :collector-host-bytes)
                        (getf result :collections-checked)
                        stats)))))))))

(defun run-gabriel-suite (&key (stream *standard-output*) verbose
                               (iterations *gabriel-default-iterations*))
  "Run every Gabriel workload across the tracing textbook collector plans.

Each plan starts at *GABRIEL-SUITE-HEAP-SIZE*.  A plan whose retained mature
set exhausts that heap is retried at successively doubled sizes, matching the
GCBench suite's bounded capacity protocol."
  (let ((results nil))
    (dolist (plan *gabriel-suite-plans*
                  (nreverse results))
      (let ((heap-size *gabriel-suite-heap-size*)
            (plan-results nil))
        (loop while (<= heap-size (* 16 *gabriel-suite-heap-size*))
              do (handler-case
                     (progn
                       (setf plan-results
                             (run-gabriel-bench
                              :plan-type plan :heap-size heap-size
                              :iterations iterations :stream stream
                              :verbose verbose))
                       (return))
                   (clamsara:heap-exhausted ()
                     (setf heap-size (* heap-size 2))
                     (format stream
                             "~&~A exhausted ~D words; retrying at ~D~%"
                             plan (/ heap-size 2) heap-size))))
        (unless plan-results
          (error "~A exhausted every Gabriel suite heap size" plan))
        (dolist (result plan-results)
          (push result results))))))

(defun run-gabriel-tests (&key (stream *standard-output*) (verbose t))
  "Run and enforce the Gabriel harness's correctness contracts."
  (let ((results (run-gabriel-suite :stream stream :verbose nil)))
    (unless (= (length results)
               (* (length *gabriel-suite-plans*)
                  (length *gabriel-workloads*)))
      (error "Gabriel suite produced ~D results, expected ~D"
             (length results)
             (* (length *gabriel-suite-plans*)
                (length *gabriel-workloads*))))
    (dolist (result results)
      (let ((cycles (cdr (assoc :gc-cycles (getf result :stats))))
            (host-bytes (getf result :collector-host-bytes)))
        (unless (plusp cycles)
          (error "Gabriel workload ~S performed no checked collection"
                 (getf result :name)))
        (unless (= cycles (getf result :collections-checked))
          (error "Gabriel workload ~S checked ~D of ~D collections"
                 (getf result :name)
                 (getf result :collections-checked) cycles))
        #+sbcl
        (unless (zerop host-bytes)
          (error "Gabriel workload ~S collector consed ~D host bytes"
                 (getf result :name) host-bytes))))
    (when verbose
      (format stream "~&Gabriel regression suite: ~D checked results~%"
              (length results)))
    results))
