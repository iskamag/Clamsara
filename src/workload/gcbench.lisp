;;;; src/workload/gcbench.lisp -- unmodified Boehm GCBench driver.
;;;;
;;;; The default is the checked-in, unmodified Common-Lisp translation under
;;;; test/fixtures/boehm-gc.lisp.  Its provenance is recorded explicitly: it
;;;; is adapted from the Boehm Scheme benchmark, not claimed to be C/Java.
;;;; A caller may supply another exact source pathname and provenance label.

(in-package #:clamsara)

(defparameter *boehm-gcbench-default-depth* 18
  "The original Java/C GCBench stretch-tree depth (about 16 MiB).")

(defun %boehm-entry-form (depth)
  `(gcbench ,depth))

(defun run-unmodified-boehm-gcbench
    (environment &key (source #p"test/fixtures/boehm-gc.lisp") (depth *boehm-gcbench-default-depth*)
          (provenance :checked-in-lisp-translation)
          (stream *standard-output*) (verbose t)
          ;; The caller supplies the configured collection boundary.  Keeping
          ;; this callback explicit prevents this workload from accidentally
          ;; accepting a host-GC run or a legacy PLAN-COLLECT hook.
          collect-finalize)
  "Load SOURCE verbatim and invoke its canonical GCBENCH driver.

SOURCE is loaded byte-for-byte as supplied and PROVENANCE records whether it
is `:checked-in-lisp-translation`, `:upstream-common-lisp`, or another
caller-declared source.  The default source is the checked-in
Scheme-to-Common-Lisp translation; it is not mislabeled as C/Java.  DEPTH
defaults to the upstream 18 and is not scaled for a smoke run.
COLLECTION-FINALIZE, when supplied, receives the workload environment after
execution and must perform the v14 caller-owned collection/report boundary. If
it is omitted, the result says final collection evidence is unavailable; the
function does not claim acceptance."
  (%require-open environment 'run-unmodified-boehm-gcbench)
  (unless (and (integerp depth) (plusp depth))
    (error 'workload-error :operation 'run-unmodified-boehm-gcbench
           :reason (list :invalid-depth depth)))
  (let ((pathname (pathname source)))
    (unless (probe-file pathname)
      (error 'workload-error :operation 'workload-load
             :reason (list :missing-source pathname)))
    (when verbose
      (format stream "~&GCBENCH source=~A provenance=~A depth=~D~%"
              pathname provenance depth))
    ;; Workload-Load reads and compiles the source once.  No source text is
    ;; edited, reduced, or substituted by this driver.
    (workload-load environment pathname)
    (let ((started (get-internal-real-time))
          (value (workload-eval environment (%boehm-entry-form depth)))
          (elapsed nil)
          (final-status :not-run))
      (setf elapsed
            (/ (- (get-internal-real-time) started)
               (float internal-time-units-per-second)))
      (when collect-finalize
        (setf final-status (funcall collect-finalize environment)))
      (list :status :ok :source (namestring pathname) :provenance provenance
            :depth depth :value value :elapsed-seconds elapsed
            :final-collection-status final-status))))

(export '(*boehm-gcbench-default-depth*
          run-unmodified-boehm-gcbench))
