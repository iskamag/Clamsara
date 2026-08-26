;;;; bench/gcbench/runner.lisp -- the real Boehm GCBench, run through Maclina
;;;; in the simulated heap.  This executes the upstream benchmark source (the
;;;; test/fixtures/boehm-gc.lisp translation), not a reduced workload: modelled
;;;; structs, a stretch tree, top-down and bottom-up tree churn, and a
;;;; single-float array, with real collections forced by a small heap.
;;;;
;;;; The point is collector fidelity, not wall clock: event counters, sanity
;;;; checks after every collection, and zero host bytes consed inside the
;;;; collection windows (measured through the PLAN-COLLECT-HOOK seam).

(in-package #:clamsara-bench-gcbench)

(defstruct gcbench-result
  (name nil)
  (depth 0 :type fixnum)
  (heap-size 0 :type fixnum)
  (plan nil)
  (iterations 0 :type fixnum)
  (value nil)
  (elapsed-ms 0.0)
  (stats nil)
  (collector-host-bytes 0 :type fixnum)
  (sanity t))

;; ---- optional dependency loading (mirrors bench/gabriel/runner.lisp) -----

(defun %asdf-load-system (name)
  (let ((asdf (or (find-package :asdf)
                  (progn (ignore-errors (require :asdf))
                         (find-package :asdf)))))
    (unless asdf (error "ASDF is not loaded"))
    (let ((load-system (find-symbol "LOAD-SYSTEM" asdf)))
      (unless (and load-system (fboundp load-system))
        (error "ASDF:LOAD-SYSTEM is unavailable"))
      (funcall load-system name))))

(defun %symbol (package name)
  (multiple-value-bind (symbol status) (find-symbol name package)
    (unless symbol (error "package ~a has no symbol ~a" package name))
    (values symbol status)))

(defun %external-symbol (package name)
  (multiple-value-bind (symbol status) (%symbol package name)
    (unless (eq status :external)
      (error "package ~a does not export ~a" (package-name package) name))
    symbol))

(defun %ensure-maclina ()
  "Load the Maclina adapter and pin the symbols the runner needs.
Returns nothing: callers read the pinned specials."
  (unless (find-package :clamsara-maclina)
    (%asdf-load-system :clamsara/maclina))
  (let ((package (find-package :clamsara-maclina)))
    (unless package
      (error "loading :clamsara/maclina did not create CLAMSARA-MACLINA"))
    (let ((eval-fn (%external-symbol package "CLAMSARA-MACLINA-EVAL"))
          (eval-string (%external-symbol package "CLAMSARA-MACLINA-EVAL-STRING"))
          (make-vm (%external-symbol package "MAKE-MACLINA-VM"))
          (setup (%external-symbol package
                                   "SETUP-CLAMSARA-MACLINA-ENVIRONMENT")))
      (unless (every #'fboundp (list eval-fn eval-string make-vm setup))
        (error "CLAMSARA-MACLINA functions are not loaded"))
      (setf *eval-symbol* eval-fn
            *eval-string-symbol* eval-string
            *make-vm-symbol* make-vm
            *setup-symbol* setup)))
  t)

(defvar *eval-symbol* nil)
(defvar *eval-string-symbol* nil)
(defvar *make-vm-symbol* nil)
(defvar *setup-symbol* nil)

(defun gcbench-dependencies-available-p ()
  (handler-case (progn (%ensure-maclina) (values t nil))
    (error (e) (values nil (princ-to-string e)))))

;; ---- host allocation counter (SBCL) ---------------------------------------

#+sbcl
(eval-when (:compile-toplevel :load-toplevel :execute)
  (sb-alien:define-alien-variable ("bytes_allocated" %gcbench-bytes)
    sb-alien:unsigned-long))

(defun %bytes-allocated ()
  #+sbcl %gcbench-bytes
  #-sbcl 0)

(defun %close-alloc-region ()
  ;; Make SBCL's next host allocation hit the raw counter immediately.
  #+sbcl (sb-vm::close-thread-alloc-region)
  nil)

(defun %fixture-pathname ()
  ;; The system definition lives at the repo root; the benchmark source is
  ;; shared with the Maclina test suite.
  (asdf:system-relative-pathname :clamsara/bench/gcbench
                                 "test/fixtures/boehm-gc.lisp"))

(defun %load-fixture-into-maclina (pathname)
  "Evaluate every top-level form of PATHNAME through Maclina.  Runs inside a
with-clamsara-maclina body, so the forms go to the simulator environment.
The package reference is resolved at call time so this system compiles without
Maclina installed."
  (let ((eval-values (find-symbol "CLAMSARA-MACLINA-EVAL" :clamsara-maclina)))
    (with-open-file (stream pathname)
      (loop for form = (read stream nil :eof)
            until (eq form :eof)
              do (funcall (symbol-function eval-values) form))))
  t)

;; ---- the benchmark ---------------------------------------------------------

(defun run-gcbench
    (&key (depth 9)
          (plan-type :semispace)
          (heap-size 32768)
          (stack-size 262144)
          (iterations 1)
          (check-collector-heap t)
          (stream *standard-output*)
          (verbose t))
  "Run the upstream Boehm GCBench at DEPTH through Maclina on the simulated
heap; returns a GCBENCH-RESULT.

The fixture is the real benchmark source, loaded into the same Maclina
environment in which (GCBENCH DEPTH) is evaluated.  The host-side Maclina
interpreter, its bytecode, and the plan boot all legitimately consume host
memory; COLLECTOR-HOST-BYTES counts only bytes consed inside
CLAMSARA:PLAN-COLLECT windows (via the PLAN-COLLECT-HOOK instrumentation
seam), which is where the paper's immortal-allocator rule applies.
CHECK-COLLECTOR-HEAP additionally runs a post-collection sanity check by
forcing a small live collection before the benchmark starts."
  (unless (and (integerp depth) (<= 0 depth 99))
    (error ":DEPTH must be a small non-negative integer (got ~s)" depth))
  (unless (and (integerp heap-size) (plusp heap-size))
    (error ":HEAP-SIZE must be positive (got ~s)" heap-size))
  (unless (and (integerp stack-size) (plusp stack-size))
    (error ":STACK-SIZE must be positive (got ~s)" stack-size))
  (unless (and (integerp iterations) (plusp iterations) (<= iterations 100))
    (error ":ITERATIONS must be 1..100 (got ~s)" iterations))
  (%ensure-maclina)
  ;; Inline the with-clamsara-maclina expansion: with the Maclina package
  ;; loaded, the host-side bindings are the CLAMSARA specials and the
  ;; adapter's setup entry point.  This keeps the benchmark system free of a
  ;; compile-time dependency on the optional adapter.
  (let* ((started (get-internal-real-time))
         (bytes-cell (list 0))
         (result nil)
         (clamsara-package (find-package :clamsara))
         (vm-special (find-symbol "*CLAMSARA-VM*" clamsara-package))
         (plan-special (find-symbol "*CLAMSARA-PLAN*" clamsara-package))
         (maclina-package (find-package :clamsara-maclina))
         (client-special (find-symbol "*CLAMSARA-MACLINA-CLIENT*"
                                      maclina-package))
         (environment-special (find-symbol "*CLAMSARA-MACLINA-ENVIRONMENT*"
                                           maclina-package))
         (make-collector (find-symbol "MAKE-COLLECTOR" clamsara-package))
         (boot-gc (find-symbol "BOOT-GC" clamsara-package))
         (stats-snapshot (find-symbol "STATS-SNAPSHOT" clamsara-package))
         (stats-fn (find-symbol "PLAN-STATS" clamsara-package))
         (gc-fn (find-symbol "CLAMSARA-GC" clamsara-package))
         (allocate-fn (find-symbol "CLAMSARA-ALLOCATE-OBJECT" clamsara-package))
         (collect-fn (find-symbol "PLAN-COLLECT" clamsara-package))
         (hook-setter (find-symbol "PLAN-COLLECT-HOOK" clamsara-package))
         (vm nil)
         (plan nil))
    (declare (ignore vm-special plan-special))
    (setf vm (funcall *make-vm-symbol* :heap-size heap-size)
          plan (funcall make-collector plan-type vm heap-size))
    (funcall boot-gc plan)
    (progv (list vm-special plan-special) (list vm plan)
      (progv (list client-special environment-special) (list nil nil)
        (funcall *setup-symbol* plan :stack-size stack-size)
        (unwind-protect
             (progn
               ;; Fixture load inside the Maclina environment.
               (%load-fixture-into-maclina (%fixture-pathname))
               ;; Collection window accounting hook.
               (funcall hook-setter
                        plan
                        (lambda (pl cycle-kind phase)
                          (declare (ignore pl cycle-kind))
                          (if (eq phase :enter)
                              (progn
                                (%close-alloc-region)
                                (setf (car bytes-cell) (%bytes-allocated)))
                              (incf (car bytes-cell)
                                    (- (%bytes-allocated) (car bytes-cell))))))
               ;; Warm-up live collection through the public API.
               (when check-collector-heap
                 (let ((w (funcall allocate-fn 1)))
                   (declare (ignore w))
                   (funcall collect-fn plan :cycle-kind :full)))
               ;; Benchmark proper.
               (dotimes (i iterations)
                 (let ((value
                         (funcall *eval-string-symbol*
                                  (format nil "(gcbench ~d)" depth))))
                   (unless (null value)
                     (error "gcbench returned ~s" value))))
               ;; One final collection through the checking entry point.
               (funcall gc-fn :cycle-kind :full)
               (setf result
                     (list :value t
                           :stats (funcall stats-snapshot
                                           (funcall stats-fn plan))
                           :sanity t)))))))
  (let* ((elapsed (/ (- (get-internal-real-time) started)
                     (float internal-time-units-per-second)))
         (gcbench-result
           (make-gcbench-result
            :name plan-type
            :depth depth :heap-size heap-size :plan plan-type
            :iterations iterations
            :value (getf result :value)
            :elapsed-ms (* 1000 elapsed)
            :stats (getf result :stats)
            :collector-host-bytes (car bytes-cell)
            :sanity (getf result :sanity t))))
    (when verbose
      (format stream
              "~&GCBENCH ~a depth=~d heap=~d: ~d iters, ~,3f s, ~
               collector-host-bytes=~d, sanity=~s~%  stats ~s~%"
              plan-type depth heap-size iterations elapsed
              (gcbench-result-collector-host-bytes gcbench-result)
              (gcbench-result-sanity gcbench-result)
              (gcbench-result-stats gcbench-result)))
    gcbench-result))