;;;; trace-capacity-probe.lisp -- prepared diagnostic probe (NOT run by the reviewer).
;;;;
;;;; Question it answers
;;;;   At fixed heap, object and reference geometry, does per-collection cost
;;;;   track the DECLARED trace capacity (the fixed plane fills performed by
;;;;   %reset-trace-context and %reset-cycle) rather than the live graph size?
;;;;
;;;; Design (frozen 9dd8629 only)
;;;;   * Two newly constructed worlds per round come from the existing
;;;;     test/quality/support.lisp fixture. Every offer is identical except
;;;;     :TRACE-CAPACITY (128 vs 8324). No repository or fixture source is
;;;;     changed, no bound plan is mutated, and no global Lisp function,
;;;;     method, macro or compiler override is installed. The probe only
;;;;     calls existing functions and reads existing slots.
;;;;   * Geometry: two 128-byte semispaces, packing quantum 16, packed object
;;;;     starts, map granularity 16, model capacity 16 = 2*extent/Q (the exact
;;;;     binding admission floor), trace required = 8 cells (extent/Q).
;;;;   * Graph: eight 16-byte leaves (two words: id, next), chain-linked, one
;;;;     root per leaf. All eight survive every collection. Peak simultaneous
;;;;     representations = 16 = capacity (derived: 8 sources + 8 destinations).
;;;;   * Timing: get-internal-real-time around the (collect ...) call only.
;;;;     Nothing inside the collector is instrumented or wrapped, so the
;;;;     measured hot path is unchanged.
;;;;
;;;; Observed vs derived
;;;;   OBSERVED  = read from live objects during the run: capacities, vector
;;;;               lengths, primitive object sizes, cycle counters, trace
;;;;               context counters, and external wall-clock deltas.
;;;;   DERIVED   = computed from frozen source structure and labelled as such:
;;;;               the 6 trace-plane fill arrays per collection and the
;;;;               derived fill-slot counts. These are NOT observed writes.
;;;;
;;;; Scope
;;;;   Diagnostic for one 4096-scale question. Not Gabriel, not GCBench, not
;;;;   target acceptance. Not a benchmark: single-process, unisolated timings.
;;;;
;;;; Run
;;;;   python3 run-trace-capacity-probe.py   (see PROBE-NOTES.md)

(defpackage #:clamsara.review.trace-capacity-probe
  (:use #:cl)
  (:import-from #:clamsara.quality.support
                #:check
                #:check-equal
                #:make-quality-world
                #:world-configuration
                #:world-context
                #:world-model
                #:world-plan
                #:world-registry
                #:world-coordinator
                #:set-node-slot
                #:read-node-slot
                #:set-world-root
                #:read-world-root
                #:live-reference-p)
  (:export #:run-trace-capacity-probe))

(in-package #:clamsara.review.trace-capacity-probe)

;;; ------------------------------------------------------------ probe offers

(defparameter *probe-root*
  (let ((from-environment (sb-ext:posix-getenv "CLAMSARA_PROBE_ROOT")))
    (cond ((null from-environment) "/tmp/clamsara-description-review-7p14doks/")
          ((char= (char from-environment (1- (length from-environment))) #\/)
           from-environment)
          (t (concatenate 'string from-environment "/"))))
  "Frozen snapshot root. The ASDF truename assertion below must still pass.")

(defparameter *probe-subdirectory* "independent-review/deepseek-performance/")

(defparameter *probe-load-truename*
  (or *load-truename* *compile-file-truename*)
  "Pathname of this file, captured at load time. *LOAD-TRUENAME* is NIL when the
entry point is invoked from a later --eval, so it must not be read there.")

(defparameter *trace-capacity-low* 128)
(defparameter *trace-capacity-high* 8324)

(defparameter *probe-extent* 128)
(defparameter *probe-packing-quantum* 16)
(defparameter *probe-model-capacity* 16)
(defparameter *probe-leaf-size-bytes* 16)
(defparameter *probe-object-count* 8)
(defparameter *probe-conditional-capacity* 128)
(defparameter *probe-finalizer-capacity* 16)
(defparameter *probe-finalizer-registration-capacity* 64)
(defparameter *probe-stop-capacity* 64)
(defparameter *probe-await-bound* 32)

(defparameter *warmup-collections* 1)
(defparameter *measured-collections* 24)
(defparameter *probe-rounds* 2)

;;; ------------------------------------------------------- frozen source pins

(defparameter *pinned-sources*
  '(("src/host/object-model.lisp"
     . "6290798c9aa0b914770c1154effd18d0c1e20b5e927b4ee81ca167e88839af13")
    ("src/runtime/records.lisp"
     . "62d6651531bd53f99e0b5f0039b70cc5db320893ac1cdfcc4c63aeaee25c7703")
    ("src/runtime/trace.lisp"
     . "b99b8702e07dab9214e2f1fbe68a42e9560a1395f39aabd20e9b025acba0e0ef")
    ("src/runtime/cycle.lisp"
     . "e2df176a2e539935268db8184f51f8e1dc38046793729d80574ff9eec5124fa0")
    ("src/runtime/spaces.lisp"
     . "6a907fcd5d1ce550534eb1ec533bfb864611e9431bb304faf0aea1a70e72a62d")
    ("src/host/resources.lisp"
     . "bb6215f40247b9051ec1ddb7633b0002e8f90181d081c140e82716e63b538c85")
    ("src/construction/build.lisp"
     . "d91dec8423938a5330eea3907bcb9a4c2ec37b641bbe8a9491fb875c934f3ea8")
    ("test/quality/support.lisp"
     . "f370778fbf508c2543400efea3de841448611d5594a1cdba5661db4ad1c1f582"))
  "Files whose semantics this probe depends on, with frozen-tree sha256.
test/quality/support.lisp is not in review-snapshot.json; its pin was computed
from the frozen tree (it is byte-identical to the live tree copy).")

;;; ------------------------------------------------------------- small tools

(defparameter *clock-name*
  (if (and (find-symbol "GET-TIME-OF-DAY" :sb-ext)
           (fboundp (find-symbol "GET-TIME-OF-DAY" :sb-ext)))
      :sb-ext-get-time-of-day
      :get-internal-real-time)
  "Microsecond wall clock chosen for this run. The chosen name is printed and
recorded in every report; the fallback reports the platform unit resolution.")

(defun %now-microseconds ()
  (case *clock-name*
    (:sb-ext-get-time-of-day
     (multiple-value-bind (seconds microseconds)
         (funcall (symbol-function (find-symbol "GET-TIME-OF-DAY" :sb-ext)))
       (+ (* seconds 1000000) microseconds)))
    (otherwise
     (round (* (get-internal-real-time) 1000000)
            internal-time-units-per-second))))

(defun %clock-granularity-microseconds ()
  "Smallest positive delta over 1000 consecutive reads. Observed, and reported so
that overlapping sample ranges are not over-read."
  (let ((smallest nil) (previous (%now-microseconds)))
    (dotimes (index 1000)
      (let* ((now (%now-microseconds))
             (delta (- now previous)))
        (when (and (plusp delta) (or (null smallest) (< delta smallest)))
          (setf smallest delta))
        (setf previous now)))
    smallest))

(defun %microseconds->seconds (microseconds)
  (coerce (/ microseconds 1000000) 'double-float))

(defun %median (numbers)
  (let ((sorted (sort (copy-list numbers) #'<)))
    (cond ((null sorted) nil)
          ((oddp (length sorted)) (nth (floor (length sorted) 2) sorted))
          (t (round (/ (+ (nth (1- (floor (length sorted) 2)) sorted)
                          (nth (floor (length sorted) 2) sorted))
                       2))))))

(defun %sha256sum (pathname)
  "Return (values HEX :SHA256SUM) or (values NIL REASON). Runs the sha256sum
program through SB-EXT:RUN-PROGRAM; no Lisp function is overridden."
  (handler-case
      (let ((runner (find-symbol "RUN-PROGRAM" :sb-ext)))
        (if (and runner (fboundp runner))
            (let* ((text (with-output-to-string (stream)
                           (funcall (symbol-function runner)
                                    "sha256sum" (list (namestring pathname))
                                    :output stream :search t)))
                   (hex (and (>= (length text) 64)
                             (string-downcase (subseq text 0 64)))))
              (if (and hex
                       (every (lambda (character) (digit-char-p character 16)) hex))
                  (values hex :sha256sum)
                  (values nil :unparsable-output)))
            (values nil :no-run-program)))
    (error () (values nil :unavailable))))

(defun %hash-report (label)
  (let ((files '()) (all-match t) (method nil) (failure-reason nil))
    (dolist (entry *pinned-sources*)
      (multiple-value-bind (actual row-method)
          (%sha256sum (merge-pathnames (car entry) *probe-root*))
        (let ((match (and actual (string= actual (cdr entry)))))
          (unless match (setf all-match nil))
          (if actual
              (unless method (setf method row-method))
              (unless failure-reason (setf failure-reason row-method)))
          (push (list (car entry) actual (cdr entry) match (or row-method :n-a))
                files))))
    (list :label label
          :all-match all-match
          :hash-available (not (null method))
          :hash-method (or method failure-reason :unknown)
          :files (nreverse files))))

(defun %assert-frozen-source ()
  (check (find-package :asdf) "ASDF is not loaded")
  (check (typep *probe-load-truename* 'pathname)
         "Probe load truename was not captured at load time: ~S"
         *probe-load-truename*)
  (let* ((system (asdf:find-system :clamsara))
         (directory (asdf:system-source-directory system))
         (root-name (string-right-trim "/" (namestring (truename *probe-root*))))
         (directory-name (string-right-trim "/" (namestring (truename directory))))
         (probe-name (namestring (truename *probe-load-truename*)))
         (expected-probe-prefix (concatenate 'string root-name "/" *probe-subdirectory*)))
    (check (string= directory-name root-name)
           "Selected :clamsara source directory ~S is not the frozen root ~S"
           directory-name root-name)
    (check (search expected-probe-prefix probe-name)
           "Probe was not loaded from ~S (load truename ~S)"
           expected-probe-prefix probe-name)
    (format t "~&TRACE-CAPACITY-PROBE :ASDF-SELECTION (:SOURCE-DIRECTORY ~S :SYSTEM-FILE ~S :ASDF-VERSION ~S :CENTRAL-REGISTRY ~S :CL-SOURCE-REGISTRY ~S :CLASSPATH ~S :LISP ~S :PROBE-FILE ~S)~%"
            directory-name
            (namestring (asdf:system-source-file system))
            (handler-case (asdf:asdf-version) (error () :unavailable))
            (handler-case asdf:*central-registry* (error () :unavailable))
            (sb-ext:posix-getenv "CL_SOURCE_REGISTRY")
            (sb-ext:posix-getenv "CLASSPATH")
            (lisp-implementation-version)
            probe-name)
    (values)))

;;; ------------------------------------------------------------ world reports

(defun %capacity-account-entry (configuration identity)
  (find identity (clamsara::%configuration-capacity-account configuration)
        :key #'clamsara::%capacity-account-entry-identity
        :test #'eq))

(defun %geometry-plist (world)
  "Every capacity/geometry the two probe worlds share. TRACE CAPACITY IS NOT
HERE: it is the independent variable and is reported separately."
  (let* ((model (world-model world))
         (plan (world-plan world))
         (spaces (clamsara::%plan-spaces plan))
         (space (first spaces))
         (map (clamsara::%space-object-start-map space)))
    (multiple-value-bind (map-base map-limit granularity)
        (clamsara:metadata-bounds map)
      (list :spaces (length spaces)
            :space-extent (clamsara::%space-extent space)
            :space-base (clamsara::%space-base space)
            :space-packing-quantum (clamsara::%space-packing-quantum space)
            :map-base map-base :map-limit map-limit :map-granularity granularity
            :map-representation (type-of map)
            :model-capacity (clamsara::host-model-capacity model)
            :model-max-object-bytes (clamsara::host-model-max-object-bytes model)
            :model-variant-capacity (clamsara::host-model-variant-capacity model)
            :model-location-capacity (clamsara::host-model-location-capacity model)
            :model-handle-capacity (clamsara::host-model-handle-capacity model)
            :model-stage-capacity (clamsara::host-model-stage-capacity model)
            :model-kind-capacity (clamsara::host-model-kind-capacity model)
            :model-slot-capacity (clamsara::host-model-slot-capacity model)
            :model-max-interior-displacement
            (clamsara::host-model-max-interior-displacement model)
            :arena-length (length (clamsara::host-model-arena model))
            :words-length (length (clamsara::host-model-words model))
            :sizes-length (length (clamsara::host-model-sizes model))
            :alignments-length (length (clamsara::host-model-alignments model))
            :descriptor-kinds-length
            (length (clamsara::host-model-descriptor-kinds model))
            :descriptor-generations-length
            (length (clamsara::host-model-descriptor-generations model))
            :descriptor-counts-length
            (length (clamsara::host-model-descriptor-counts model))
            :base-references-length
            (length (clamsara::host-model-base-references model))
            :variants-length (length (clamsara::host-model-variants model))
            :locations-length (length (clamsara::host-model-locations model))
            :handles-length (length (clamsara::host-model-handles model))
            :stages-length (length (clamsara::host-model-stages model))
            :conditional-capacity (clamsara::%plan-conditional-capacity plan)
            :finalizer-capacity (clamsara::%plan-finalizer-capacity plan)
            :root-count (clamsara.quality.support::world-root-count world)
            :stop-capacity (length (clamsara::simulator-coordinator-coverage
                                    (world-coordinator world)))
            :await-bound (clamsara::simulator-await-bound
                          (world-coordinator world))
            :registry-capacity (clamsara::%registry-capacity (world-registry world))
            :registration-capacity
            (clamsara::%registry-registration-capacity (world-registry world))))))

(defun %plan-resource-report (world)
  (let* ((configuration (world-configuration world))
         (plan (world-plan world))
         (identity (clamsara::%plan-object-resource-id plan))
         (entry (%capacity-account-entry configuration identity)))
    (check entry "plan object resource ~S is missing from the capacity account"
           identity)
    (let* ((handle (clamsara::%capacity-account-entry-handle entry))
           (formula (clamsara::%runtime-object-entry-count
                     (clamsara::%plan-trace-capacity plan)
                     (clamsara::%plan-conditional-capacity plan)
                     (clamsara::%plan-finalizer-capacity plan))))
      (list :plan-handle-length (length handle)
            :plan-handle-storage-bytes (clamsara::%host-object-storage handle)
            :plan-physical-bytes
            (clamsara::%capacity-account-entry-physical-bytes entry)
            :plan-entry-capacity
            (clamsara::%capacity-account-entry-entry-capacity entry)
            :plan-auxiliary-bytes
            (clamsara::%capacity-account-entry-auxiliary-bytes entry)
            :plan-displaced-array-length
            (length (clamsara::%cycle-movement-old
                     (clamsara::%plan-cycle plan)))
            :plan-entries-formula formula
            :plan-formula-matches-handle (= (length handle) formula)
            :plan-entries-formula-note
            "the 10*trace+8*conditional+5*finalizer formula is source-derived and cross-checked against the observed handle length"))))

(defun %base-reference-report (model)
  (let* ((vector (clamsara::host-model-base-references model))
         (first (aref vector 0)))
    (list :descriptor-cells (length vector)
          :base-references-length (length vector)
          :first-base-reference-type (type-of first)
          :base-reference-primitive-bytes
          (sb-ext:primitive-object-size first)
          :base-reference-primitive-bytes-note
          "shallow primitive size of one per-cell host-reference struct; the FIXED-MODEL-PLANE-BYTES figure sums top-level plane vectors only and does not include these structs")))

(defun %derived-fills (trace-capacity)
  (list :peak-representations-derived (* 2 *probe-object-count*)
        :peak-representations-note
        "DERIVED from the semispace source/destination coexistence rule (8 sources + 8 destinations = capacity 16). The probe installs no in-collection instrumentation, so the peak is NOT observed."
        :fill-arrays-per-collection 6
        :fill-slots-per-collection (* 6 trace-capacity)
        :conditional-fill-slots (* 8 *probe-conditional-capacity*)
        :finalizer-fill-slots (* 5 *probe-finalizer-capacity*)
        :note "DERIVED FROM FROZEN SOURCE, NOT OBSERVED WRITES. src/runtime/trace.lisp:22-26 fills five arrays of trace capacity (source-spaces, source-starts, states, work-spaces, work-starts); src/runtime/cycle.lisp:26-40 fills retirement-starts of trace capacity plus the counter, conditional and finalizer arrays. The probe installs no instrumentation."))

;;; --------------------------------------------------------------- the graph

(defun %make-probe-world (label trace-capacity)
  (let ((leaf-kind nil)
        (started (%now-microseconds))
        (world nil))
    (setf world
          (handler-case
              (make-quality-world
               :algorithm :semispace
               :object-starts :packed
               :base 4096
               :extent *probe-extent*
               :packing-quantum *probe-packing-quantum*
               :map-granularity *probe-packing-quantum*
               :root-count *probe-object-count*
               :trace-capacity trace-capacity
               :conditional-capacity *probe-conditional-capacity*
               :finalizer-capacity *probe-finalizer-capacity*
               :finalizer-registration-capacity
               *probe-finalizer-registration-capacity*
               :stop-capacity *probe-stop-capacity*
               :await-bound *probe-await-bound*
               :object-capacity *probe-model-capacity*
               :configure-model
               (lambda (model)
                 (setf leaf-kind
                       (clamsara:make-object-kind-description
                        model :probe-leaf
                        :size-rule *probe-leaf-size-bytes*
                        :alignment-rule *probe-packing-quantum*
                        :strong-layout '(:probe-id :probe-next)))))
            (error (condition)
              (format t "~&TRACE-CAPACITY-PROBE :CONSTRUCTION-FAILED (:LABEL ~S :TRACE-CAPACITY ~S :CONDITION ~S)~%"
                      label trace-capacity condition)
              (error condition))))
    (check leaf-kind "~A: configure-model did not create the probe leaf kind" label)
    (values world leaf-kind (- (%now-microseconds) started))))

(defun %populate-graph (world leaf-kind label)
  (let ((references '()))
    (dotimes (index *probe-object-count*)
      (multiple-value-bind (reference status reason)
          (clamsara:allocate-object (world-context world) :probe-leaf
                                    *probe-leaf-size-bytes*
                                    *probe-packing-quantum* leaf-kind)
        (check (and reference (eq status :allocated) (null reason))
               "~A: leaf ~D allocation failed: ~S/~S" label index status reason)
        (check (= (clamsara:object-size (world-model world) reference)
                  *probe-leaf-size-bytes*)
               "~A: leaf ~D reported size ~S" label index
               (clamsara:object-size (world-model world) reference))
        (set-node-slot world reference 0 index)
        (push reference references)))
    (setf references (nreverse references))
    (loop for cell on references
          for index from 0
          do (set-node-slot world (first cell) 1 (second cell))
             (check (= index (read-node-slot world (first cell) 0))
                    "~A: leaf ~D lost its published id" label index))
    (loop for reference in references
          for index from 0
          do (set-world-root world index reference))
    (check (= *probe-object-count*
              (clamsara::host-model-live-count (world-model world)))
           "~A: ~D representations after populating a ~D-object graph" label
           (clamsara::host-model-live-count (world-model world))
           *probe-object-count*)
    references))

(defun %current-root-refs (world)
  (loop for index below *probe-object-count*
        collect (read-world-root world index)))

(defun %graph-state (world references)
  "Capture live references and their addresses before any collection can retire
them. REFERENCE-ADDRESS validates canonical bases, so it must never be called on
a retired source encoding."
  (let ((model (world-model world)))
    (list :references references
          :addresses (mapcar (lambda (reference)
                               (clamsara:reference-address model reference))
                             references))))

(defun %check-graph (world label cycle previous)
  "Assert real movement and payload preservation. PREVIOUS is a %GRAPH-STATE
plist or NIL. Return the current %GRAPH-STATE."
  (let* ((model (world-model world))
         (current (%current-root-refs world)))
    (check (= (length current) *probe-object-count*)
           "~A cycle ~S: root count ~D" label cycle (length current))
    (loop for reference in current
          for index from 0
          do (check reference "~A cycle ~S: root ~D is empty" label cycle index)
             (check (live-reference-p world reference)
                    "~A cycle ~S: root ~D is not live" label cycle index)
             (check (= index (read-node-slot world reference 0))
                    "~A cycle ~S: root ~D payload ~S" label cycle index
                    (read-node-slot world reference 0)))
    (loop for reference in current
          for index from 0
          for successor = (read-node-slot world reference 1)
          do (if (< index (1- *probe-object-count*))
                 (progn
                   (check successor "~A cycle ~S: chain broken at ~D" label cycle index)
                   (check (= (clamsara:reference-address model successor)
                             (clamsara:reference-address model
                                                         (nth (1+ index) current)))
                          "~A cycle ~S: link ~D addresses differ" label cycle index))
                 (check (null successor)
                        "~A cycle ~S: last leaf gained a successor" label cycle)))
    (let ((addresses (mapcar (lambda (reference)
                               (clamsara:reference-address model reference))
                             current)))
      (when previous
        (loop for old-address in (getf previous :addresses)
              for new-address in addresses
              for index from 0
              do (check (not (eql old-address new-address))
                        "~A cycle ~S: object ~D did not move" label cycle index))
        (check (handler-case
                   (progn (clamsara:normalize-reference
                           model (first (getf previous :references)))
                          nil)
                 (error () t))
               "~A cycle ~S: retired source encoding still normalizes" label cycle))
      (check (= *probe-object-count* (clamsara::host-model-live-count model))
             "~A cycle ~S: ~D representations after collection" label cycle
             (clamsara::host-model-live-count model))
      (list :references current :addresses addresses))))


;;; ---------------------------------------------------------- one collection

(defun %collect-timed (world label cycle)
  (let* ((plan (world-plan world))
         (configuration (world-configuration world))
         (record (clamsara:make-cycle-result-record plan))
         (started (%now-microseconds)))
    (clamsara:collect configuration :all :explicit record)
    (let* ((microseconds (- (%now-microseconds) started))
           (trace (clamsara::%cycle-trace (clamsara::%plan-cycle plan))))
      (check (eq :complete (clamsara:cycle-result-status record))
             "~A cycle ~S status ~S reason ~S" label cycle
             (clamsara:cycle-result-status record)
             (clamsara:cycle-result-reason record))
      (check-equal *probe-object-count*
                   (nth-value 0 (clamsara:cycle-result-count record :objects-discovered))
                   (format nil "~A cycle ~S discovered" label cycle))
      (check-equal *probe-object-count*
                   (nth-value 0 (clamsara:cycle-result-count record :objects-moved))
                   (format nil "~A cycle ~S moved" label cycle))
      (check-equal (* *probe-object-count* *probe-leaf-size-bytes*)
                   (nth-value 0 (clamsara:cycle-result-count record :bytes-moved))
                   (format nil "~A cycle ~S bytes moved" label cycle))
      (list :cycle cycle
            :microseconds microseconds
            :seconds (%microseconds->seconds microseconds)
            :status (clamsara:cycle-result-status record)
            :discovered (nth-value 0 (clamsara:cycle-result-count record :objects-discovered))
            :moved (nth-value 0 (clamsara:cycle-result-count record :objects-moved))
            :bytes-moved (nth-value 0 (clamsara:cycle-result-count record :bytes-moved))
            :live-after (clamsara::host-model-live-count (world-model world))
            :observed-trace
            (list :trace-capacity (clamsara::%trace-capacity trace)
                  :trace-reserved-count (clamsara::%trace-reserved-count trace)
                  :trace-committed-count (clamsara::%trace-committed-count trace)
                  :trace-take-index (clamsara::%trace-take-index trace)
                  :trace-generation (clamsara::%trace-generation trace))))))

(defun %summarise (samples)
  (let ((microseconds (mapcar (lambda (sample) (getf sample :microseconds))
                              samples)))
    (list :count (length microseconds)
          :min-microseconds (reduce #'min microseconds)
          :median-microseconds (%median microseconds)
          :max-microseconds (reduce #'max microseconds)
          :min-seconds (%microseconds->seconds (reduce #'min microseconds))
          :median-seconds (%microseconds->seconds (%median microseconds))
          :max-seconds (%microseconds->seconds (reduce #'max microseconds)))))

;;; ----------------------------------------------------- discharge and close

(defun %discharge-and-close (world label)
  (let* ((configuration (world-configuration world))
         (context (world-context world))
         (model (world-model world))
         (plan (world-plan world)))
    (dotimes (index *probe-object-count*)
      (set-world-root world index nil))
    (check (loop for index below *probe-object-count*
                 always (null (read-world-root world index)))
           "~A: root discharge left a published root" label)
    (clamsara:drain-pending-finalizers (world-registry world) context)
    (let* ((record (clamsara:make-cycle-result-record plan))
           (started (%now-microseconds)))
      (clamsara:collect configuration :all :explicit record)
      (let ((microseconds (- (%now-microseconds) started))
            (coordinator (world-coordinator world)))
        (check (eq :complete (clamsara:cycle-result-status record))
               "~A: discharge status ~S reason ~S" label
               (clamsara:cycle-result-status record)
               (clamsara:cycle-result-reason record))
        (check-equal 0 (nth-value 0 (clamsara:cycle-result-count record :objects-moved))
                     (format nil "~A discharge moved objects" label))
        (check (zerop (clamsara::host-model-live-count model))
               "~A: ~D representations retained after discharge" label
               (clamsara::host-model-live-count model))
        (let ((stop-capacity (length (clamsara::simulator-coordinator-coverage
                                      coordinator)))
              (stop-next (clamsara::simulator-stop-next coordinator)))
          (check (< stop-next stop-capacity)
                 "~A: ~D safepoint requests reached the ~D-entry stop history"
                 label stop-next stop-capacity)
          (let ((unbind (clamsara:unbind-mutator configuration context)))
            (check (eq :unbound unbind) "~A: unbind returned ~S" label unbind))
          (multiple-value-bind (status reason)
              (clamsara:shutdown-configuration configuration)
            (check (and (eq status :complete) (null reason))
                   "~A: shutdown ~S/~S" label status reason)
            (list :roots-cleared t
                  :discharge-microseconds microseconds
                  :discharge-seconds (%microseconds->seconds microseconds)
                  :discharge-status (clamsara:cycle-result-status record)
                  :discharge-moved 0
                  :live-after-discharge 0
                  :observed-stop (list :stop-capacity stop-capacity
                                       :stop-next stop-next
                                       :stop-token-base
                                       (clamsara::simulator-stop-base
                                        coordinator))
                  :unbind :unbound
                  :shutdown-status status
                  :shutdown-reason reason)))))))

(defun %hard-close (world)
  "Best-effort hygiene close after an assertion failure. Never masks the
original failure; the caller's error propagates."
  (ignore-errors
    (dotimes (index *probe-object-count*)
      (ignore-errors (set-world-root world index nil))))
  (ignore-errors
    (clamsara:drain-pending-finalizers (world-registry world) (world-context world)))
  (ignore-errors
    (let ((configuration (world-configuration world)))
      (ignore-errors (clamsara:unbind-mutator configuration (world-context world)))
      (ignore-errors (clamsara:shutdown-configuration configuration))))
  (values))

;;; ------------------------------------------------------------- one world

(defun %run-probe-world (label trace-capacity)
  (multiple-value-bind (world leaf-kind construction-units)
      (%make-probe-world label trace-capacity)
    (let ((closed-p nil)
          (report nil))
      (unwind-protect
           (let ((references (%populate-graph world leaf-kind label))
                 (samples '()))
             (let ((geometry (%geometry-plist world))
                   (plan-resource (%plan-resource-report world))
                   (base-reference (%base-reference-report (world-model world)))
                   (declared-trace (clamsara::%plan-trace-capacity
                                    (world-plan world)))
                   (context-trace (clamsara::%trace-capacity
                                   (clamsara::%cycle-trace
                                    (clamsara::%plan-cycle (world-plan world))))))
               (let* ((initial (%graph-state world references))
                      (warmup (%collect-timed world label :warmup))
                      (previous (%check-graph world label :warmup initial)))
                 (dotimes (iteration *measured-collections*)
                   (let ((sample (%collect-timed world label (1+ iteration))))
                     (setf previous (%check-graph world label (1+ iteration) previous))
                     (push sample samples)))
                 (setf samples (nreverse samples))
                 (let ((discharge (%discharge-and-close world label)))
                   (setf closed-p t)
                   (setf report
                         (list :label label
                               :trace-capacity trace-capacity
                               :trace-capacity-declared declared-trace
                               :trace-capacity-context context-trace
                               :construction-seconds
                               (%microseconds->seconds construction-units)
                               :warmup warmup
                               :geometry geometry
                               :plan-resource plan-resource
                               :base-reference base-reference
                               :samples samples
                               :summary (%summarise samples)
                               :discharge discharge
                               :derived (%derived-fills trace-capacity)
                               :observed (list :live-count-after-populate
                                               *probe-object-count*
                                               :collections-performed
                                               (+ *warmup-collections*
                                                  *measured-collections* 1)
                                               :stop-token-base
                                               (clamsara::simulator-stop-base
                                                (world-coordinator world))
                                               :clock *clock-name*)))))))
        (unless closed-p
          (format t "~&TRACE-CAPACITY-PROBE :HARD-CLOSE (:LABEL ~S)~%" label)
          (%hard-close world)))
      (format t "~&TRACE-CAPACITY-PROBE :WORLD ~S~%" report)
      (when report
        (format t "~&TRACE-CAPACITY-PROBE :WORLD-SUMMARY (:LABEL ~S :TRACE-CAPACITY ~S :MEDIAN-SECONDS ~,6F :MIN-SECONDS ~,6F :MAX-SECONDS ~,6F :PLAN-HANDLE-LENGTH ~D :PLAN-PHYSICAL-BYTES ~D :DERIVED-FILL-SLOTS ~D)~%"
                (getf report :label)
                (getf report :trace-capacity)
                (getf (getf report :summary) :median-seconds)
                (getf (getf report :summary) :min-seconds)
                (getf (getf report :summary) :max-seconds)
                (getf (getf report :plan-resource) :plan-handle-length)
                (getf (getf report :plan-resource) :plan-physical-bytes)
                (getf (getf report :derived) :fill-slots-per-collection)))
      report)))

;;; ------------------------------------------------------------ entry point

(defun %round-label (trace-capacity round)
  (intern (format nil "~A-R~D"
                  (if (= trace-capacity *trace-capacity-low*)
                      "TRACE-128"
                      "TRACE-8324")
                  round)
          :keyword))

(defun run-trace-capacity-probe ()
  (let ((before (%hash-report :before))
        (low-worlds '())
        (high-worlds '()))
    (format t "~&TRACE-CAPACITY-PROBE :START (:MEASURED-PER-WORLD ~D :WARMUP ~D :ROUNDS ~D :COLLECTIONS-PER-WORLD ~D :STOP-CAPACITY-OFFER ~D :CLOCK ~S :CLOCK-GRANULARITY-MICROSECONDS ~S :INTERNAL-TIME-UNITS-PER-SECOND ~D)~%"
            *measured-collections* *warmup-collections* *probe-rounds*
            (+ *warmup-collections* *measured-collections* 1)
            *probe-stop-capacity*
            *clock-name* (%clock-granularity-microseconds)
            internal-time-units-per-second)
    (%assert-frozen-source)
    (format t "~&TRACE-CAPACITY-PROBE :SOURCE-HASHES-BEFORE ~S~%" before)
    (if (getf before :hash-available)
        (check (getf before :all-match)
               "Pinned frozen sources do not match before the run (hash method ~S)"
               (getf before :hash-method))
        (format t "~&TRACE-CAPACITY-PROBE :WARNING (:HASH-METHOD ~S :ACTION ~S)~%"
                (getf before :hash-method)
                "pinned hashes are unavailable in-process; the ASDF truename assertion passed; run run-trace-capacity-probe.py --check-only for the authoritative hash record"))
    (format t "~&TRACE-CAPACITY-PROBE :PRECONSTRUCTION-OFFER (:EXTENT ~D :PACKING-QUANTUM ~D :MAP-GRANULARITY ~D :OBJECT-STARTS :PACKED :ALGORITHM :SEMISPACE :MODEL-CAPACITY ~D :LEAF-SIZE ~D :OBJECT-COUNT ~D :CONDITIONAL-CAPACITY ~D :FINALIZER-CAPACITY ~D :FINALIZER-REGISTRATION-CAPACITY ~D :ROOT-COUNT ~D :STOP-CAPACITY ~D :AWAIT-BOUND ~D :TRACE-CAPACITIES (~D ~D))~%"
            *probe-extent* *probe-packing-quantum* *probe-packing-quantum*
            *probe-model-capacity* *probe-leaf-size-bytes* *probe-object-count*
            *probe-conditional-capacity* *probe-finalizer-capacity*
            *probe-finalizer-registration-capacity* *probe-object-count*
            *probe-stop-capacity* *probe-await-bound*
            *trace-capacity-low* *trace-capacity-high*)
    (dotimes (round *probe-rounds*)
      (dolist (trace-capacity (list *trace-capacity-low* *trace-capacity-high*))
        (let ((report (%run-probe-world (%round-label trace-capacity round)
                                        trace-capacity)))
          (if (= trace-capacity *trace-capacity-low*)
              (push report low-worlds)
              (push report high-worlds)))))
    (setf low-worlds (nreverse low-worlds) high-worlds (nreverse high-worlds))
    (check (= *probe-rounds* (length low-worlds) (length high-worlds))
           "Probe rounds did not produce one world per trace capacity")
    (let ((geometries (mapcar (lambda (world) (getf world :geometry))
                              (append low-worlds high-worlds))))
      (check (every (lambda (geometry) (equal geometry (first geometries)))
                    geometries)
             "Heap/object/reference geometry differs between probe worlds")
      (format t "~&TRACE-CAPACITY-PROBE :GEOMETRY-MATCH T :GEOMETRY ~S~%"
              (first geometries)))
    (check (every (lambda (world)
                    (= (getf (getf (first low-worlds) :plan-resource)
                             :plan-handle-length)
                       (getf (getf world :plan-resource) :plan-handle-length)))
                  low-worlds)
           "TRACE-128 worlds disagree on the plan handle length")
    (check (every (lambda (world)
                    (= (getf (getf (first high-worlds) :plan-resource)
                             :plan-handle-length)
                       (getf (getf world :plan-resource) :plan-handle-length)))
                  high-worlds)
           "TRACE-8324 worlds disagree on the plan handle length")
    (let* ((low-samples (apply #'append
                               (mapcar (lambda (world) (getf world :samples))
                                       low-worlds)))
           (high-samples (apply #'append
                                (mapcar (lambda (world) (getf world :samples))
                                        high-worlds)))
           (low (%summarise low-samples))
           (high (%summarise high-samples))
           (median-delta (- (getf high :median-microseconds)
                            (getf low :median-microseconds)))
           (min-delta (- (getf high :min-microseconds)
                         (getf low :min-microseconds)))
           (ranges-disjoint (> (getf high :min-microseconds)
                               (getf low :max-microseconds))))
      (format t "~&TRACE-CAPACITY-PROBE :COMPARISON (:CLOCK ~S :CLOCK-GRANULARITY-MICROSECONDS ~S :TRACE-128 (:SAMPLES ~D :MIN-MICROSECONDS ~D :MEDIAN-MICROSECONDS ~D :MAX-MICROSECONDS ~D :MEDIAN-SECONDS ~,6F) :TRACE-8324 (:SAMPLES ~D :MIN-MICROSECONDS ~D :MEDIAN-MICROSECONDS ~D :MAX-MICROSECONDS ~D :MEDIAN-SECONDS ~,6F) :MEDIAN-DELTA-MICROSECONDS ~D :MIN-DELTA-MICROSECONDS ~D :RANGES-DISJOINT ~S :PLAN-HANDLE-LENGTH-LOW ~D :PLAN-HANDLE-LENGTH-HIGH ~D :PLAN-PHYSICAL-LOW ~D :PLAN-PHYSICAL-HIGH ~D :DERIVED-FILL-SLOTS-LOW ~D :DERIVED-FILL-SLOTS-HIGH ~D :STOP-HISTORY-CHECK ~S)~%"
              *clock-name* (%clock-granularity-microseconds)
              (getf low :count) (getf low :min-microseconds)
              (getf low :median-microseconds) (getf low :max-microseconds)
              (getf low :median-seconds)
              (getf high :count) (getf high :min-microseconds)
              (getf high :median-microseconds) (getf high :max-microseconds)
              (getf high :median-seconds)
              median-delta min-delta ranges-disjoint
              (getf (getf (first low-worlds) :plan-resource) :plan-handle-length)
              (getf (getf (first high-worlds) :plan-resource) :plan-handle-length)
              (getf (getf (first low-worlds) :plan-resource) :plan-physical-bytes)
              (getf (getf (first high-worlds) :plan-resource) :plan-physical-bytes)
              (getf (getf (first low-worlds) :derived) :fill-slots-per-collection)
              (getf (getf (first high-worlds) :derived) :fill-slots-per-collection)
              (every (lambda (world)
                       (let ((stop (getf (getf world :discharge) :observed-stop)))
                         (and stop (< (getf stop :stop-next)
                                      (getf stop :stop-capacity)))))
                     (append low-worlds high-worlds)))
      (format t "~&TRACE-CAPACITY-PROBE :COMPARISON-NOTE ~S~%"
              "DERIVED fill-slot counts are source-derived, not observed writes. RANGES-DISJOINT compares [min,max] of the two sample sets; disjoint ranges with a positive MIN-DELTA are the strongest available signal for this single-process diagnostic. All timings include startup-adjacent first-touch effects only through the warm-up collection, which is excluded from the sample sets. The measured hot path is unchanged: only two wall-clock reads bracket each (collect ...) call, and the clock granularity is reported in the START line."))
    (let ((after (%hash-report :after)))
      (format t "~&TRACE-CAPACITY-PROBE :SOURCE-HASHES-AFTER ~S~%" after)
      (when (getf after :hash-available)
        (check (getf after :all-match)
               "Pinned frozen sources changed during the run (hash method ~S)"
               (getf after :hash-method))))
    (format t "~&TRACE-CAPACITY-PROBE :REPORT ~S~%"
            (list :rounds *probe-rounds*
                  :low low-worlds
                  :high high-worlds))
    (format t "~&TRACE-CAPACITY-PROBE :DONE~%")
    t))
