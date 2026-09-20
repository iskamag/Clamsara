;;;; src/workload/gabriel.lisp -- canonical Gabriel workload driver.
;;;;
;;;; The checked-in files under bench/gabriel/reference/ are the benchmark
;;;; inputs.  This driver never edits, translates, reduces, or substitutes a
;;;; file.  Every entry below is loaded by WORKLOAD-LOAD and then invokes the
;;;; source file's own TEST* entrypoint.  A source/load/runtime error is a
;;;; failure, not an explicit skip.

(in-package #:clamsara)

(defparameter *canonical-gabriel-workloads*
  '((:tak "tak.cl" testtak)
    (:takr "takr.cl" testtakr)
    (:takl "takl.cl" testtakl)
    (:frpoly "frpoly.cl" testfrpoly)
    (:dderiv "dderiv.cl" testdderiv)
    (:fprint "fprint.cl" testfprint)
    (:stak "stak.cl" teststak)
    (:div2 "div2.cl" testdiv2)
    (:browse "browse.cl" testbrowse)
    (:fread "fread.cl" testfread)
    (:tprint "tprint.cl" testtprint)
    (:boyer "boyer.cl" testboyer)
    (:fft "fft.cl" testfft)
    (:traverse "traverse.cl" testtraverse)
    (:deriv "deriv.cl" testderiv)
    (:ctak "ctak.cl" testctak)
    (:triang "triang.cl" testtriang)
    (:puzzle "puzzle.cl" testpuzzle)
    (:destru "destru.cl" testdestru))
  "The complete checked-in Gabriel reference set (19 files).

The old runner admitted only TAK/TAKR and labelled three sources skipped;
that is not an acceptance policy.  This list deliberately includes every
reference file and has no skip ledger.")

(defun %gabriel-reference-path (directory file)
  (merge-pathnames file (pathname directory)))

(defun %gabriel-entry-form (symbol)
  `(,symbol))

(defun run-canonical-gabriel
    (environment &key (directory "bench/gabriel/reference/")
                       (workloads *canonical-gabriel-workloads*)
                       (stream *standard-output*) (verbose t))
  "Run every canonical Gabriel file in one fresh guest environment.

The order is the checked-in inventory order; FPRINT precedes FREAD so the
canonical file-I/O pair can exchange its own /tmp/fprint.tst artifact.  The
source's TEST* return value is recorded without imposing a translated scalar
oracle: the canonical tests use PRINT/TIME and many intentionally return NIL.
The function signals on any source or workload failure."
  (%require-open environment 'run-canonical-gabriel)
  (let ((results nil))
    (dolist (entry workloads (nreverse results))
      (destructuring-bind (name file entrypoint) entry
        (let ((pathname (%gabriel-reference-path directory file)))
          (unless (probe-file pathname)
            (error 'workload-error :operation 'workload-load
                   :reason (list :missing-reference pathname)))
          (when verbose
            (format stream "~&GABRIEL ~A source=~A entry=~A~%"
                    name file entrypoint))
          ;; No source form is synthesized.  The bytes on PATHNAME are loaded
          ;; exactly once through the guest reader/compiler.
          (workload-load environment pathname)
          (let ((started (get-internal-real-time))
                (value (workload-eval environment
                                      (%gabriel-entry-form entrypoint))))
            (push (list :name name :reference-file file
                        :entrypoint entrypoint :status :ok
                        :value value
                        :elapsed-seconds
                        (/ (- (get-internal-real-time) started)
                           (float internal-time-units-per-second)))
                  results)))))))

(defun run-canonical-gabriel-tests
    (environment &key (directory "bench/gabriel/reference/")
                       (stream *standard-output*))
  "Run and enforce the complete 19-file Gabriel inventory."
  (let ((results (run-canonical-gabriel environment :directory directory
                                         :stream stream :verbose nil)))
    (unless (= (length results) (length *canonical-gabriel-workloads*))
      (error "Gabriel completed ~D files, expected ~D"
             (length results) (length *canonical-gabriel-workloads*)))
    (dolist (result results)
      (unless (eq (getf result :status) :ok)
        (error "Gabriel source did not complete: ~S" result)))
    (format stream "~&Gabriel canonical suite: ~D files completed; no skips.~%"
            (length results))
    results))

(export '(*canonical-gabriel-workloads* run-canonical-gabriel
          run-canonical-gabriel-tests))
