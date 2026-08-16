;;;; bench/gabriel/runner.lisp -- optional Maclina benchmark runner.

(in-package #:clamsara-gabriel-bench)

(defconstant +gabriel-hard-max-iterations+ 25
  "Non-configurable ceiling that keeps this diagnostic harness bounded.")
(defparameter *gabriel-default-iterations* 3
  "Iterations used by RUN-GABRIEL-BENCH when none is supplied.")
(defparameter *gabriel-max-iterations* +gabriel-hard-max-iterations+
  "Optional lower bound for one invocation; never raises the hard ceiling.")

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
          (values package
                  (%maclina-symbol package "WITH-CLAMSARA-MACLINA")
                  (%maclina-symbol package "CLAMSARA-MACLINA-EVAL-STRING"))))
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

(defun %evaluate-workload (with-macro eval-string workload iterations plan-type
                           heap-size stack-size)
  "Evaluate one workload in a fresh Maclina/Clamsara environment." 
  (let ((source (gabriel-workload-source workload))
        (expected (gabriel-workload-expected workload))
        (name (gabriel-workload-name workload)))
    ;; WITH-CLAMSARA-MACLINA is a macro in an optional package.  Constructing
    ;; this form after the package has loaded keeps the benchmark source
    ;; readable and avoids a compile-time dependency on that package.
    (eval `(,with-macro
             (:plan-type ,plan-type
              :heap-size ,heap-size
              :stack-size ,stack-size)
             (let ((values nil))
               (dotimes (iteration ,iterations)
                 (let ((value
                         (funcall ',eval-string ,source)))
                   (unless (equal value ,expected)
                     (error 'gabriel-benchmark-failure
                            :workload ',name
                            :iteration iteration
                            :expected ,expected
                            :actual value))
                   (push value values)))
               (values (nreverse values)
                       (clamsara:stats-snapshot
                        (clamsara:plan-stats clamsara:*clamsara-plan*))))))))

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
          (heap-size 4096)
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
        (let ((started (get-internal-real-time)))
          (multiple-value-bind (values stats)
              (%evaluate-workload with-macro eval-string workload iterations
                                  plan-type heap-size stack-size)
            (let* ((elapsed (/ (- (get-internal-real-time) started)
                               (float internal-time-units-per-second)))
                   (result (list :name (gabriel-workload-name workload)
                                 :iterations iterations
                                 :elapsed-seconds elapsed
                                 :values values
                                 :stats stats)))
              (push result results)
              (when verbose
                (format stream
                        "  ~a: ~d iterations, ~,3f sec, stats ~s~%"
                        (getf result :name)
                        iterations
                        elapsed
                        stats)))))))))
