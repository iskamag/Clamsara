;;;; bench/gcbench/runner.lisp -- the real Boehm GCBench, run through Maclina
;;;; in the simulated heap.  This executes the upstream benchmark source (the
;;;; test/fixtures/boehm-gc.lisp translation), not a reduced workload: modelled
;;;; structs, a stretch tree, top-down and bottom-up tree churn, and a
;;;; single-float array, with real collections forced by a small heap.
;;;;
;;;; The point is collector fidelity, not wall clock: event counters and sanity
;;;; checks after every collection, plus zero host bytes consed inside the
;;;; collection windows.  The windows are measured through PLAN-COLLECT-HOOK,
;;;; the plan's instrumentation seam.  The accounting part of the hook reads
;;;; an alien counter into a preallocated cell without consing; sanity runs
;;;; only after that window has closed.

(in-package #:clamsara-bench-gcbench)

(defstruct gcbench-result
  "One benchmark run's numbers.

COLLECTOR-HOST-BYTES sums the per-collection window deltas of SBCL's
bytes_allocated counter.  The runner warms every dispatch before measuring,
so a correct collector must report zero; any nonzero value is evidence of
host allocation on the collection path."
  (name nil)
  (depth 0 :type fixnum)
  (heap-size 0 :type fixnum)
  (plan nil)
  (iterations 0 :type fixnum)
  (value nil :type boolean)
  (elapsed-ms 0.0)
  (stats nil)
  (collector-host-bytes 0 :type fixnum)
  (gc-cycles 0 :type fixnum)
  (words-copied 0 :type fixnum)
  (objects-copied 0 :type fixnum)
  (barrier-transfers 0 :type fixnum)
  (collections-checked 0 :type fixnum)
  (sanity-errors nil))

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

(defun %external-symbol (package name)
  (multiple-value-bind (symbol status) (find-symbol name package)
    (unless (and symbol (eq status :external))
      (error "package ~a does not export ~a" (package-name package) name))
    symbol))

(defvar *eval-string-symbol* nil)
(defvar *make-vm-symbol* nil)
(defvar *setup-symbol* nil)

(defun %ensure-maclina ()
  "Load the Maclina adapter and pin the symbols the runner needs.
Returns nothing: callers read the pinned specials."
  (unless (find-package :clamsara-maclina)
    (%asdf-load-system :clamsara/maclina))
  (let ((package (find-package :clamsara-maclina)))
    (unless package
      (error "loading :clamsara/maclina did not create CLAMSARA-MACLINA"))
    (let ((eval-string (%external-symbol package
                                         "CLAMSARA-MACLINA-EVAL-STRING"))
          (make-vm (%external-symbol package "MAKE-MACLINA-VM"))
          (setup (%external-symbol package
                                   "SETUP-CLAMSARA-MACLINA-ENVIRONMENT")))
      (unless (every #'fboundp (list eval-string make-vm setup))
        (error "CLAMSARA-MACLINA functions are not loaded"))
      (setf *eval-string-symbol* eval-string
            *make-vm-symbol* make-vm
            *setup-symbol* setup)))
  t)

(defun gcbench-dependencies-available-p ()
  (handler-case (progn (%ensure-maclina) (values t nil))
    (error (e) (values nil (princ-to-string e)))))

;; ---- host allocation counter (SBCL) ---------------------------------------
;;
;; SBCL's global bytes_allocated is exact once the current thread's allocation
;; region is closed; the closing call turns deferred region bumps into counter
;; updates.  On non-SBCL hosts there is no portable equivalent, so the window
;; accounting reports zero and the result structure records that honestly.

#+sbcl
(eval-when (:compile-toplevel :load-toplevel :execute)
  (sb-alien:define-alien-variable ("bytes_allocated" %gcbench-bytes)
    sb-alien:unsigned-long))

;; Keep the hot hook's counter values in a bounded fixnum domain.  Windows only
;; ever compute (now - base) deltas, so every read is reduced modulo 2^32 and
;; each delta uses wraparound arithmetic over the same modulus.  A window's
;; true size is far below 4 GiB, making the modular result exact.
(defconstant +host-bytes-modulus+ (ash 1 32))

(declaim (inline %wrap-bytes))
(defun %wrap-bytes (n)
  #+sbcl (ldb (byte 32 0) n)
  #-sbcl 0)

(defun %bytes-allocated ()
  #+sbcl (%wrap-bytes %gcbench-bytes)
  #-sbcl 0)

(defun %bytes-delta (now base)
  "NOW-BASE modulo the 32-bit counter domain."
  (mod (- now base) +host-bytes-modulus+))

(defun %close-alloc-region ()
  ;; Make SBCL's next host allocation hit the raw counter immediately.
  #+sbcl (sb-vm::close-thread-alloc-region)
  #-sbcl nil)

(defun %host-bytes-supported-p ()
  #+sbcl t #-sbcl nil)

(defun %assert-plan-sane (plan cycle-kind)
  "Signal when a completed benchmark collection leaves invalid state."
  (let ((errors (clamsara:sanity-check
                 plan :check-mark (not (clamsara::plan-sticky-p plan)))))
    (when errors
      (error "GCBench failed sanity after ~S collection:~%~{  ~A~%~}"
             cycle-kind errors))))

(defun %fixture-pathname ()
  "The system definition lives at the repo root; the benchmark source is
shared with the Maclina test suite."
  (asdf:system-relative-pathname :clamsara/bench/gcbench
                                 "test/fixtures/boehm-gc.lisp"))

(defun %load-fixture-into-maclina (pathname)
  "Evaluate every top-level form of PATHNAME through Maclina.  Runs inside a
with-clamsara-maclina body, so the forms go to the simulator environment.
The package reference is resolved at call time so this system compiles without
Maclina installed."
  (let ((loader (find-symbol "LOAD-MACLINA-SOURCE-FILE" :clamsara-maclina)))
    (if loader
        (funcall loader pathname)
        (progn
          (setf loader (find-symbol "CLAMSARA-MACLINA-EVAL" :clamsara-maclina))
          (with-open-file (stream pathname)
            (loop for form = (read stream nil :eof)
                  until (eq form :eof)
                    do (funcall (symbol-function loader) form))))))
  t)

(defun %maclina-eval-source-string (string)
  "Evaluate STRING with READ bound to Maclina's source package.
LOAD-MACLINA-SOURCE-FILE establishes this binding for files; benchmark
strings deserve the identical read semantics."
  (let ((*package* (find-package '#:clamsara-maclina)))
    (funcall *eval-string-symbol* string)))

;; ---- the benchmark ---------------------------------------------------------

(defun run-gcbench
    (&key (depth 9)
          (plan-type :semispace)
          (heap-size 32768)
          (stack-size 262144)
          (iterations 1)
          (stream *standard-output*)
          (verbose t))
  "Run the upstream Boehm GCBench at DEPTH through Maclina on the simulated
heap; returns a GCBENCH-RESULT.

The fixture is the real benchmark source, loaded into the same Maclina
environment in which (GCBENCH depth) is evaluated.  The host-side Maclina
interpreter, its bytecode, and the plan boot all legitimately consume host
memory; COLLECTOR-HOST-BYTES counts only bytes consed inside PLAN-COLLECT
windows, which is where the specification's immortal-allocator rule applies.
The count is meaningful only on SBCL; elsewhere it is reported as zero with
an explicit unsupported note."
  (unless (and (integerp depth) (<= 0 depth 99))
    (error ":DEPTH must be a small non-negative integer (got ~s)" depth))
  (unless (and (integerp heap-size) (plusp heap-size))
    (error ":HEAP-SIZE must be positive (got ~s)" heap-size))
  (unless (and (integerp stack-size) (plusp stack-size))
    (error ":STACK-SIZE must be positive (got ~s)" stack-size))
  (unless (and (integerp iterations) (plusp iterations) (<= iterations 100))
    (error ":ITERATIONS must be 1..100 (got ~s)" iterations))
  (%ensure-maclina)
  (let ((result (%gcbench-run depth plan-type heap-size stack-size iterations)))
    (when verbose
      (format stream
              "~&GCBENCH ~a depth=~d heap=~d: ~d iter(s), ~,3f s, value=~s~
               ~%  gc-cycles=~d words-copied=~d objects-copied=~d ~
               barrier-transfers=~d"
              plan-type depth heap-size
              (gcbench-result-iterations result)
              (/ (gcbench-result-elapsed-ms result) 1000.0)
              (gcbench-result-value result)
              (gcbench-result-gc-cycles result)
              (gcbench-result-words-copied result)
              (gcbench-result-objects-copied result)
              (gcbench-result-barrier-transfers result))
      (if (gcbench-result-sanity-errors result)
          (format stream "~%  sanity-errors=~{~a~^; ~}"
                  (gcbench-result-sanity-errors result))
          (format stream "~%  sanity-errors=none"))
      (format stream "~%  collections-checked=~d"
              (gcbench-result-collections-checked result))
      (format stream
              "~%  collector-host-bytes=~d~@[ ~
               (byte accounting unsupported here)~]~%"
              (gcbench-result-collector-host-bytes result)
              (not (%host-bytes-supported-p))))
    result))

(defun %gcbench-run (depth plan-type heap-size stack-size iterations)
  ;; Inline the with-clamsara-maclina expansion: with the Maclina package
  ;; loaded, the host-side bindings are the CLAMSARA specials and the
  ;; adapter's setup entry point.  This keeps the benchmark system free of a
  ;; compile-time dependency on the optional adapter.
  ;;
  ;; Protocol: unmeasured warmup iterations compile the interpreted
  ;; workload's code paths and resolve every first-contact dispatch while
  ;; live Maclina closures are on the stack; the measured iterations then run
  ;; identical work under the accounting hook.  A conforming collector reports
  ;; exactly zero collector host bytes across all measured windows.
  (%ensure-maclina)
  (let* ((host-bytes (cons 0 0))          ; window base / accumulated total
         (window-open nil)
         (maclina-package (find-package :clamsara-maclina))
         (client-special (%external-symbol maclina-package
                                           "*CLAMSARA-MACLINA-CLIENT*"))
         (environment-special (%external-symbol maclina-package
                                                "*CLAMSARA-MACLINA-ENVIRONMENT*"))
         (make-collector (find-symbol "MAKE-COLLECTOR" :clamsara))
         (boot-gc (find-symbol "BOOT-GC" :clamsara))
         (stats-fn (find-symbol "PLAN-STATS" :clamsara))
         (reset-stats-fn (find-symbol "STATS-RESET" :clamsara))
         (snapshot-fn (find-symbol "STATS-SNAPSHOT" :clamsara))
         (sanity-fn (find-symbol "SANITY-CHECK" :clamsara))
         (gc-fn (find-symbol "CLAMSARA-GC" :clamsara))
         (plan-special (find-symbol "*CLAMSARA-PLAN*" :clamsara))
         (vm-special (find-symbol "*CLAMSARA-VM*" :clamsara))
         (vm (funcall *make-vm-symbol* :heap-size heap-size))
         (plan (funcall make-collector plan-type vm heap-size))
         (value nil) (stats nil) (errors nil) (elapsed-ms 0.0)
         (collections-checked 0)
         (accounting-hook
          ;; Only paired windows contribute.  The hook is installed after
          ;; warmup, so one-time dispatch costs never pollute the sum.
          (lambda (pl cycle-kind phase)
            (cond
              ((and (eq phase :enter) (not window-open))
               ;; Close-region is idempotent and allocation-free; the call
               ;; here is belt-and-braces against deferred counter updates
               ;; before the baseline read.
               (%close-alloc-region)
               (setf (car host-bytes) (%bytes-allocated)
                     window-open t))
              ((and (or (eq phase :exit) (eq phase :abort)) window-open)
               (incf (cdr host-bytes)
                     (%bytes-delta (%bytes-allocated) (car host-bytes)))
               ;; Drain the collector's own pending region now so the next
               ;; window's baseline cannot inherit it.
               (%close-alloc-region)
               (setf window-open nil)
               ;; ABORT means the collector did not produce a coherent
               ;; post-state.  Preserve its original condition; completed
               ;; collections get checked after their accounting window.
               (when (eq phase :exit)
                 (%assert-plan-sane pl cycle-kind)
                 (incf collections-checked))))))
         (bench-source (format nil "(gcbench ~d)" depth))
         (bench-string
          (lambda ()
            (%maclina-eval-source-string bench-source)))
         (collect-stats
          ;; Report measured-workload counters only; warmup and final
          ;; verification collections are outside this snapshot.
          (lambda () (funcall snapshot-fn (funcall stats-fn plan)))))
    (funcall boot-gc plan)
    (progv (list client-special environment-special plan-special vm-special)
        (list nil nil plan vm)
      (funcall *setup-symbol* plan :stack-size stack-size)
      (%load-fixture-into-maclina (%fixture-pathname))
      ;; Warmup iterations: unmeasured.  Three passes settle the
      ;; interpreted workload's one-time host costs; a single pass can
      ;; leave first-contact dispatches inside measured windows.
      (dotimes (warmup 3)
        (declare (ignorable warmup))
        (unless (funcall bench-string)
          (error "gcbench warmup returned NIL")))
      (funcall reset-stats-fn (funcall stats-fn plan))
      ;; Measured iterations under the hook.
      (clamsara:with-plan-collect-hook (plan accounting-hook)
        (let ((started (get-internal-real-time)))
          (loop repeat iterations do
            (let ((v (funcall bench-string)))
              (unless v (error "gcbench returned NIL"))
              (setf value (not (null v)))))
          (setf elapsed-ms
                (* 1000 (/ (- (get-internal-real-time) started)
                           (float internal-time-units-per-second))))))
      (setf stats (funcall collect-stats))
      ;; Verify final reclamation through the public checked entry point, but
      ;; keep this diagnostic collection outside measured counters/windows.
      (funcall gc-fn :cycle-kind :full))
    ;; Hook-free invariant pass over the final heap state.  Sticky plans
    ;; keep their mark bits between minors by design, so the checker must
    ;; not demand a clear stratum from them.
    (let ((check-mark-fn (find-symbol "PLAN-STICKY-P" :clamsara)))
      (handler-case
          (setf errors
                (funcall sanity-fn plan
                         :check-mark (not (funcall check-mark-fn plan))))
        (error (condition)
          (setf errors (list (princ-to-string condition))))))
    (make-gcbench-result
     :name plan-type
     :depth depth :heap-size heap-size :plan plan-type
     :iterations iterations
     :value (and value t)
     :elapsed-ms elapsed-ms
     :stats stats
     :collector-host-bytes (cdr host-bytes)
     :gc-cycles (cdr (assoc :gc-cycles stats))
     :words-copied (cdr (assoc :words-copied stats))
     :objects-copied (cdr (assoc :objects-copied stats))
     :barrier-transfers (cdr (assoc :barrier-transfers stats))
     :collections-checked collections-checked
     :sanity-errors errors)))

(defparameter *gcbench-suite-heap-size* 16384)
(defparameter *gcbench-suite-plans*
  '(:semispace :marksweep :immix :gencopy :genms :genimmix
    :stickyimmix :stickyms :zgcish)
  "Collector plans exercised by RUN-GCBENCH-SUITE.")

(defun run-gcbench-suite (&key (stream *standard-output*) verbose
                            (depth 8) (iterations 1))
  "Run the GCBench across the tracing textbook plans at one shared depth.
HEAP-SIZE starts at *GCBENCH-SUITE-HEAP-SIZE* and, when a plan exhausts it,
the run retries that plan at twice the size: mark/sweep families need a larger
mature space than copying families at the same live footprint."
  (let ((results nil))
    (dolist (plan *gcbench-suite-plans*
                  (nreverse results))
      (let ((heap-size *gcbench-suite-heap-size*)
            (result nil))
        (loop until (> heap-size (* 16 *gcbench-suite-heap-size*))
              do (handler-case
                     (progn
                       (setf result
                             (run-gcbench :depth depth :plan-type plan
                                          :heap-size heap-size
                                          :iterations iterations
                                          :stream stream :verbose verbose))
                       (return))
                   (clamsara:heap-exhausted ()
                     (setf heap-size (* heap-size 2))
                     (format stream
                             "~&~a exhausted ~d words; retrying at ~d~%"
                             plan (/ heap-size 2) heap-size))))
        (if result
            (push result results)
            (error "~A exhausted every GCBench suite heap size" plan))))))

(defun %validate-gcbench-result (result)
  (unless (gcbench-result-value result)
    (error "GCBench ~S returned a false result" (gcbench-result-plan result)))
  (unless (plusp (gcbench-result-gc-cycles result))
    (error "GCBench ~S measured iteration performed no collection"
           (gcbench-result-plan result)))
  (unless (= (gcbench-result-collections-checked result)
             (gcbench-result-gc-cycles result))
    (error "GCBench ~S checked ~D of ~D measured collections"
           (gcbench-result-plan result)
           (gcbench-result-collections-checked result)
           (gcbench-result-gc-cycles result)))
  (when (gcbench-result-sanity-errors result)
    (error "GCBench ~S reported sanity errors: ~S"
           (gcbench-result-plan result)
           (gcbench-result-sanity-errors result)))
  #+sbcl
  (unless (zerop (gcbench-result-collector-host-bytes result))
    (error "GCBench ~S collector consed ~D host bytes"
           (gcbench-result-plan result)
           (gcbench-result-collector-host-bytes result)))
  result)

(defun run-gcbench-tests (&key (stream *standard-output*) (verbose t))
  "Run GCBench and enforce its accounting, output, and all-plan contracts."
  ;; Synthetic counter values make the 2^32 boundary deterministic instead of
  ;; waiting for a long-lived Lisp process to happen to cross it.
  (unless (and (= 200 (%bytes-delta 300 100))
               (= 196 (%bytes-delta 100 (- +host-bytes-modulus+ 96))))
    (error "GCBench wrapped host-byte delta regression"))
  (let* ((capture (make-string-output-stream))
         (default-result (run-gcbench :stream capture :verbose t))
         (rendered (get-output-stream-string capture))
         (suite-results
           (run-gcbench-suite :stream stream :verbose nil)))
    (%validate-gcbench-result default-result)
    (unless (and (search "sanity-errors=none" rendered)
                 (search "collections-checked=" rendered)
                 (search "collector-host-bytes=0" rendered)
                 (not (search "collector-host-bytes=NIL" rendered)))
      (error "GCBench rendered invalid diagnostics:~%~A" rendered))
    (unless (= (length suite-results) (length *gcbench-suite-plans*))
      (error "GCBench suite produced ~D results, expected ~D"
             (length suite-results) (length *gcbench-suite-plans*)))
    (dolist (result suite-results)
      (%validate-gcbench-result result))
    (when verbose
      (write-string rendered stream)
      (format stream "~&GCBench regression suite: ~D checked plans~%"
              (length suite-results)))
    suite-results))
