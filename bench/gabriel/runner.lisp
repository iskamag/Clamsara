;;;; bench/gabriel/runner.lisp -- one collector, several Gabriel workloads.
;;;;
;;;; This is a development harness, not a conformance or acceptance gate.  It
;;;; builds a real workload runtime for a selected collector plan, runs the
;;;; requested checked-in Gabriel files through the guest reader/compiler, and
;;;; prints one machine-readable RESULT line per workload plus a SUMMARY line.
;;;;
;;;; One process runs exactly one collector: the hosted Maclina VM is a fixed,
;;;; image-global resource (a fresh process per collector also isolates host
;;;; allocation measurement).  The Python driver spawns these processes and
;;;; aggregates the lines into curves.
;;;;
;;;; Metrics per workload:
;;;;   :elapsed      wall seconds in the workload entrypoint
;;;;   :host-bytes   host bytes consed during the workload (sb-ext:get-bytes-consed)
;;;;   :gc.count     collection cycles entered
;;;;   :gc.time      wall seconds spent inside those cycles
;;;;   :gc.moved     objects moved/copied
;;;;   :gc.bytes     representation bytes moved/copied
;;;;   :gc.dead      objects proved dead
;;;;   :gc.discovered  first discoveries (live closure size at collection)
;;;;   :gc.pause-max  longest single cycle
;;;; A failed workload records :status :error and its condition; it does not
;;;; abort the run.

(require :asdf)
(handler-case (progn (asdf:load-system :clamsara/workload)
                     ;; The optional generational profile is a separate system.
                     (asdf:load-system :clamsara/generational))
  (error (e)
    (format *error-output* "~&harness: cannot load clamsara systems: ~A~%" e)
    (sb-ext:exit :code 2)))

(defpackage #:clamsara.bench.gabriel
  (:use #:cl #:clamsara)
  (:export #:run-benchmarks))
(in-package #:clamsara.bench.gabriel)

;;; ------------------------------------------------------------------
;;; GC instrumentation: record every collection the configuration enters.

(defvar *gc-events* nil
  "List of (list :SECONDS seconds) for each collection, newest first.  The
driver resets this global before each workload and reads it afterwards; runs
are sequential and single-threaded.")

(defmethod collect :around (configuration scope cause record &key algorithm)
  (declare (ignore configuration scope cause record algorithm))
  (let ((start (get-internal-real-time)))
    ;; A rejection signals before the primary method runs; the event is then not
    ;; recorded and the condition propagates unchanged.
    (prog1 (call-next-method)
      (push (list :seconds (/ (- (get-internal-real-time) start)
                              (float internal-time-units-per-second)))
            *gc-events*))))

(defun %counter (record name)
  (multiple-value-bind (value known) (cycle-result-count record name)
    (if (and known value) value 0)))

;;; ------------------------------------------------------------------
;;; Collector plan factories.  Each receives the shared services and must
;;; cover exactly [base, base+byte-extent).

(defun %span-domain (base byte-extent quantum)
  (make-metadata-domain :base base :limit (+ base byte-extent)
                        :granularity quantum))

(defun semispace-factory
    (&key base byte-extent quantum packing-quantum trace-capacity
          conditional-capacity finalizer-capacity root-client coordinator
          diagnostics registry &allow-other-keys)
  "Default plan: two equal SemiSpace halves over the managed extent."
  (declare (ignore trace-capacity))
  (let* ((half (/ byte-extent 2))
         (from (make-semispace-space
                :name :bench-from
                :object-start-map (make-object-start-marks
                                   :domain (%span-domain base half quantum))
                :forwarding (make-side-forwarding
                             :domain (%span-domain base half packing-quantum))
                :extent half :packing-quantum packing-quantum :role :allocation))
         (to (make-semispace-space
              :name :bench-to
              :object-start-map (make-object-start-marks
                                 :domain (%span-domain (+ base half) half quantum))
              :forwarding (make-side-forwarding
                           :domain (%span-domain (+ base half) half packing-quantum))
              :extent half :packing-quantum packing-quantum :role :reserve)))
    (make-semispace-plan
     :from-space from :to-space to :root-client root-client
     :coordinator coordinator :diagnostics diagnostics :registry registry
     :trace-capacity (ceiling half packing-quantum)
     :conditional-capacity conditional-capacity
     :finalizer-capacity finalizer-capacity :packing-quantum packing-quantum)))

(defun marksweep-factory
    (&key base byte-extent quantum packing-quantum conditional-capacity
          finalizer-capacity root-client coordinator diagnostics registry
          &allow-other-keys)
  "Nonmoving mark-sweep over the whole managed extent."
  (let* ((domain (%span-domain base byte-extent quantum))
         (space (make-marksweep-space
                 :name :bench-marksweep
                 :object-start-map (make-object-start-marks :domain domain)
                 :marks (make-side-marks :domain domain)
                 :extent byte-extent :packing-quantum packing-quantum
                 :descriptor-capacity (ceiling byte-extent packing-quantum))))
    (make-marksweep-plan
     :space space :root-client root-client :coordinator coordinator
     :diagnostics diagnostics :registry registry
     :trace-capacity (ceiling byte-extent packing-quantum)
     :conditional-capacity conditional-capacity
     :finalizer-capacity finalizer-capacity :packing-quantum packing-quantum)))

(defun immix-factory
    (&key base byte-extent quantum packing-quantum conditional-capacity
          finalizer-capacity root-client coordinator diagnostics registry
          &allow-other-keys)
  "Nonmoving mark-region over the whole managed extent."
  (let* ((domain (%span-domain base byte-extent quantum))
         (space (make-immix-space
                 :name :bench-immix
                 :object-start-map (make-object-start-marks :domain domain)
                 :marks (make-side-marks :domain domain)
                 :extent byte-extent :packing-quantum packing-quantum
                 :line-size 64 :block-size 1024)))
    (make-immix-plan
     :space space :root-client root-client :coordinator coordinator
     :diagnostics diagnostics :registry registry
     :trace-capacity (ceiling byte-extent packing-quantum)
     :conditional-capacity conditional-capacity
     :finalizer-capacity finalizer-capacity :packing-quantum packing-quantum)))

(defun nogc-factory
    (&key base byte-extent quantum packing-quantum conditional-capacity
          finalizer-capacity root-client coordinator diagnostics registry
          &allow-other-keys)
  "Monotone bump allocation; exhaustion is an ordinary allocation failure."
  (let* ((space (make-nogc-space
                 :name :bench-nogc
                 :object-start-map (make-object-start-marks
                                    :domain (%span-domain base byte-extent quantum))
                 :extent byte-extent :packing-quantum packing-quantum)))
    (make-nogc-plan
     :space space :root-client root-client :coordinator coordinator
     :diagnostics diagnostics :registry registry
     :trace-capacity 8 :conditional-capacity conditional-capacity
     :finalizer-capacity finalizer-capacity :packing-quantum packing-quantum)))

(defun generational-factory
    (&key base byte-extent quantum packing-quantum conditional-capacity
          finalizer-capacity root-client coordinator diagnostics registry
          &allow-other-keys)
  "Copying nursery (one quarter) plus a nonmoving mature MarkSweep space."
  (let* ((nursery (/ byte-extent 4))
         (mature-base (+ base (* 2 nursery)))
         (mature-extent (- byte-extent (* 2 nursery)))
         (from (make-generational-nursery-space
                :name :bench-nursery-from
                :object-start-map (make-object-start-marks
                                   :domain (%span-domain base nursery quantum))
                :forwarding (make-side-forwarding
                             :domain (%span-domain base nursery packing-quantum))
                :extent nursery :packing-quantum packing-quantum :role :allocation))
         (to (make-generational-nursery-space
              :name :bench-nursery-to
              :object-start-map (make-object-start-marks
                                 :domain (%span-domain (+ base nursery) nursery quantum))
              :forwarding (make-side-forwarding
                           :domain (%span-domain (+ base nursery) nursery packing-quantum))
              :extent nursery :packing-quantum packing-quantum :role :reserve))
         (mature (make-generational-mature-space
                  :name :bench-mature
                  :object-start-map (make-object-start-marks
                                     :domain (%span-domain mature-base mature-extent quantum))
                  :extent mature-extent :packing-quantum packing-quantum
                  :descriptor-capacity (ceiling mature-extent packing-quantum))))
    (make-generational-plan
     :nursery-from from :nursery-to to :mature mature
     :root-client root-client :coordinator coordinator :diagnostics diagnostics
     :registry registry
     ;; The plan validation conservatively sums every space's cells.
     :trace-capacity (ceiling byte-extent packing-quantum)
     :conditional-capacity conditional-capacity
     :finalizer-capacity finalizer-capacity :packing-quantum packing-quantum)))

(defparameter *collector-factories*
  '((:semispace . semispace-factory)
    (:marksweep . marksweep-factory)
    (:immix . immix-factory)
    (:nogc . nogc-factory)
    (:generational . generational-factory)))

(defparameter *default-workloads*
  ;; The subset the hosted guest currently runs to completion; the driver can
  ;; name any of the 19 checked-in files instead.
  '((:tak "tak.cl" testtak)
    (:takr "takr.cl" testtakr)
    (:takl "takl.cl" testtakl)
    (:dderiv "dderiv.cl" testdderiv)
    (:deriv "deriv.cl" testderiv)
    (:destru "destru.cl" testdestru)))

;;; ------------------------------------------------------------------
;;; Driver-local option parsing and result printing.

(defun %json-escape (string)
  (with-output-to-string (out)
    (loop for char across string
          do (case char
               (#\" (write-string "\\\"" out))
               (#\\ (write-string "\\\\" out))
               (t (write-char char out))))))

(defun %print-result (collector workload status value load elapsed host-bytes gc)
  (format t "~&RESULT {\"collector\":\"~A\",\"workload\":\"~A\",\"status\":\"~A\"~
               ,\"value\":~A,\"load\":~,6F,\"elapsed\":~,6F,\"host-bytes\":~D~
               ,\"gc\":{\"count\":~D,\"time\":~,6F,\"pause-max\":~,6F}}~%"
          collector workload status
          (if (and (numberp value) (not (floatp value))) value "null")
          (float load 1d0) (float elapsed 1d0) host-bytes
          (getf gc :count) (float (getf gc :time) 1d0)
          (float (getf gc :pause-max) 1d0))
  (finish-output))

(defun %gc-summary (events)
  (let ((count (length events))
        (time 0d0)
        (pause 0d0))
    (dolist (event events)
      (let ((seconds (getf event :seconds)))
        (incf time seconds)
        (setf pause (max pause seconds))))
    (list :count count :time (float time 1d0) :pause-max (float pause 1d0))))

(defun %harness-arg (args name)
  (let ((prefix (concatenate 'string name "=")))
    (dolist (arg args)
      (when (and (>= (length arg) (length prefix))
                 (string= prefix arg :end2 (length prefix)))
        (return (subseq arg (length prefix)))))))

(defun %split-comma (string)
  (when (and string (plusp (length string)))
    (loop with start = 0
          for comma = (position #\, string :start start)
          collect (subseq string start (or comma (length string)))
          while comma
          do (setf start (1+ comma)))))

(defun %selected-workloads (names)
  (if (null names)
      *default-workloads*
      (mapcar (lambda (name)
                (let* ((key (intern (string-upcase name) :keyword))
                       (entry (assoc key *default-workloads*)))
                  (or entry (error "unknown workload ~A" name))))
              names)))
(defun run-benchmarks (&key collector extent workloads directory
                            (stream *standard-output*))
  "Run COLLECTOR over WORKLOADS at the configured heap EXTENT."
  (let* ((factory-cell (assoc collector *collector-factories*))
         (factory (and factory-cell (symbol-function (cdr factory-cell)))))
    (unless factory (error "unknown collector ~S" collector))
    (let* ((runtime
             (make-workload-runtime
              :extent extent :plan-factory factory :plan-extent extent))
           (environment (workload-runtime-environment runtime))
           (plan (workload-runtime-plan runtime))
           (collector-name (string-downcase (symbol-name collector)))
           (summary (list :collector collector-name :extent extent
                          :workloads nil)))
      (unwind-protect
           (progn
             (dolist (entry workloads)
               (destructuring-bind (name file entrypoint) entry
                 (let* ((pathname (merge-pathnames
                                   file (pathname (or directory
                                                      "bench/gabriel/reference/"))))
                        (load-before (get-internal-real-time))
                        (host-before (sb-ext:get-bytes-consed))
                        (status "ok")
                        (value nil)
                        (load-seconds nil)
                        (elapsed nil))
                   ;; Reader/compiler work is setup, not collection evidence.
                   (handler-case
                       (progn
                         (workload-load environment pathname)
                         (setf load-seconds
                               (/ (- (get-internal-real-time) load-before)
                                  (float internal-time-units-per-second))))
                     (error (condition)
                       (setf status "error")
                       (format *error-output* "~&harness: ~A load failed: ~A~%"
                               name condition)))
                   ;; Only the entrypoint execution is timed and counted.
                   (setf clamsara.bench.gabriel::*gc-events* nil)
                   (when (string= status "ok")
                     (let ((run-before (get-internal-real-time)))
                       (handler-case
                           (setf value
                                 (workload-eval
                                  environment
                                  ;; Gabriel sources are read in package CLAMSARA.
                                  `(,(intern (symbol-name entrypoint)
                                             '#:clamsara))))
                         (error (condition)
                           (setf status "error" value nil)
                           (format *error-output* "~&harness: ~A failed: ~A~%"
                                   name condition)))
                       (setf elapsed
                             (/ (- (get-internal-real-time) run-before)
                                (float internal-time-units-per-second)))))
                   (let* ((host-bytes (- (sb-ext:get-bytes-consed) host-before))
                          (gc (%gc-summary clamsara.bench.gabriel::*gc-events*)))
                     (%print-result collector-name (string-downcase (symbol-name name))
                                    status value (or load-seconds 0d0)
                                    (or elapsed 0d0) host-bytes gc)
                     (push (list :name (string-downcase (symbol-name name))
                                 :status status :load load-seconds
                                 :elapsed elapsed :host-bytes host-bytes :gc gc)
                           (getf summary :workloads))))))
             (setf (getf summary :workloads) (nreverse (getf summary :workloads)))
             (format t "~&SUMMARY ~S~%" summary))
        ;; Best-effort teardown; a NoGC run cannot discharge reachable objects.
        (handler-case (close-workload-runtime runtime)
          (error (condition)
            (format *error-output* "~&harness: close: ~A~%" condition))))
      summary)))

;;; ------------------------------------------------------------------
;;; Command line: collector=... extent=... workloads=a,b,c directory=...

(defun main ()
  (let* ((args (rest sb-ext:*posix-argv*))
         (collector (intern (string-upcase (or (%harness-arg args "collector")
                                               "semispace"))
                            :keyword))
         (extent (parse-integer (or (%harness-arg args "extent")
                                    (format nil "~D" (* 8 1024 1024)))))
         (workloads (%selected-workloads (%split-comma (%harness-arg args "workloads"))))
         (directory (%harness-arg args "directory")))
    (run-benchmarks :collector collector :extent extent :workloads workloads
                    :directory directory)
    (sb-ext:exit :code 0)))

(main)
