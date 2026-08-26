;;;; bench/gabriel/runner.lisp -- optional Maclina benchmark runner.

(in-package #:clamsara-gabriel-bench)

(defvar *gabriel-window-cell* nil)


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

(defun %evaluate-workload (with-macro eval-string workload iterations plan-type
                           heap-size stack-size collector-host-bytes-cell)
  "Evaluate one workload in a fresh Maclina/Clamsara environment.

The fresh environment is warmed by one unmeasured iteration before the
measured ones: it compiles the interpreted workload and resolves every
first-contact dispatch while Maclina closures are live, so measured
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
                        (declare (ignore pl cycle-kind))
                        (cond
                          ((and (eq phase :enter) (not window-open))
                           ;; The first close flushes whatever interpreter
                           ;; churn is still pending; only a further exact
                           ;; read gives the residue-free baseline.
                           (%close-region)
                           (%close-region)
                           (setf (car base-cell) (%host-bytes)
                                 window-open t))
                          ((and (eq phase :exit) window-open)
                           (incf (car *gabriel-window-cell*)
                                 ;; A host GC inside the window shrinks
                                 ;; bytes_allocated, so a negative delta
                                 ;; means that window's total is unknowable;
                                 ;; clamp rather than report garbage.
                                 (max 0 (- (%host-bytes) (car base-cell))))
                           ;; Drain the collector's own pending region now so
                           ;; the next window's baseline starts clean.
                           (%close-region)
                           (setf window-open nil)))))
                    (stats nil))
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
               ;; Now install the accounting hook for measured runs only.
               (setf (clamsara:plan-collect-hook clamsara:*clamsara-plan*)
                     accounting-hook)
               ;; Drain the warmup's own pending region so the first
               ;; measured window's baseline starts clean.
               (%close-region)
               (dotimes (iteration ,iterations)
                 (let ((value (funcall ',eval-string ,source)))
                   (unless (equal value ',expected)
                     (error 'gabriel-benchmark-failure
                            :workload ',name
                            :iteration iteration
                            :expected ,expected
                            :actual value))
                   (push value values)))
               (setf stats (clamsara:stats-snapshot
                             (clamsara:plan-stats clamsara:*clamsara-plan*)))
               (values (nreverse values) stats))))))

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
        (let ((started (get-internal-real-time))
              (bytes-cell (cons 0 nil)))
          (multiple-value-bind (values stats)
              (%evaluate-workload with-macro eval-string workload iterations
                                  plan-type heap-size stack-size bytes-cell)
            (let* ((elapsed (/ (- (get-internal-real-time) started)
                               (float internal-time-units-per-second)))
                   (result (list :name (gabriel-workload-name workload)
                                 :iterations iterations
                                 :elapsed-seconds elapsed
                                 :values values
                                 :collector-host-bytes (car bytes-cell)
                                 :stats stats)))
              (push result results)
              (when verbose
                (format stream
                        "  ~a: ~d iterations, ~,3f sec, ~
                         collector-host-bytes=~d, stats ~s~%"
                        (getf result :name)
                        iterations
                        elapsed
                        (getf result :collector-host-bytes)
                        stats)))))))))
