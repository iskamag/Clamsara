;;;; Fixed sequential runtime state and opaque report records.
(in-package #:clamsara)

(define-condition runtime-rejection (error)
  ((reason :initarg :reason :reader runtime-rejection-reason))
  (:report (lambda (condition stream)
             (format stream "v14 runtime rejected entry: ~S"
                     (runtime-rejection-reason condition)))))

(defun %runtime-reject (reason)
  (error 'runtime-rejection :reason reason))

(defun %checked-nonnegative-integer (value reason)
  (unless (typep value '(integer 0 *)) (%runtime-reject reason))
  value)

(defun %positive-power-of-two-p (value)
  (and (typep value '(integer 1 *)) (zerop (logand value (1- value)))))

(defun %align-up (value alignment)
  (unless (and (typep value '(integer 0 *))
               (%positive-power-of-two-p alignment))
    (%runtime-reject :arithmetic-overflow))
  (let ((sum (+ value (1- alignment))))
    (when (< sum value) (%runtime-reject :arithmetic-overflow))
    (logand sum (- alignment))))

(defparameter +sequential-core-counters+
  '((:objects-discovered . "Committed first object discoveries")
    (:objects-moved . "Objects copied or promoted")
    (:bytes-moved . "Representation bytes copied or promoted")
    (:objects-dead . "Objects proved dead at reclaim preflight")
    (:weak-corrections . "Weak or ephemeron descriptors committed")
    (:finalizers-enqueued . "Finalizer registrations published pending")))

(defparameter +sequential-core-causes+
  '((:explicit . "Caller requested collection")
    (:allocation-route . "Configured allocation route exhausted")
    (:allocation-full . "Full-heap escalation from allocation")))

(defparameter +sequential-core-reasons+
  '((:complete . "Collection completed and published")
    (:preflight-failed . "A fallible preflight did not become ready")
    (:unsupported-scope . "The requested collection scope is not admitted")
    (:capacity-exhausted . "A construction-bounded runtime capacity was exhausted")
    (:cancelled . "Collection was cancelled before publication")
    (:weak-storage-exhausted . "Conditional or finalizer staging capacity was exhausted")
    (:post-publication-failure . "Failure followed forwarding or commit publication")
    (:heap-exhausted . "No admitted allocation destination has capacity")
    (:collection-busy . "Another owner or retained cycle owns collection")
    (:unsupported-algorithm . "The requested algorithm is not bound")
    (:unsupported-cause . "The requested cause is not registered")
    (:foreign-result-record . "The result record belongs to another entry owner")
    (:fatal-invariant . "A closed runtime invariant was violated")
    (:coverage-failed . "The coordinator could not establish declared coverage")))

(defclass sequential-cycle-result ()
  ((owner :initarg :owner :reader cycle-result-owner)
   (status :initform :uninitialized :accessor %result-status)
   (phase :initform nil :accessor %result-phase)
   (scope :initform nil :accessor %result-scope)
   (algorithm :initform nil :accessor %result-algorithm)
   (cause :initform nil :accessor %result-cause)
   (reason :initform nil :accessor %result-reason)
   (counts :initarg :counts :reader %result-counts)
   (known :initarg :known :reader %result-known)))

(defmethod cycle-result-status ((record sequential-cycle-result))
  (%result-status record))
(defmethod cycle-result-phase ((record sequential-cycle-result))
  (%result-phase record))
(defmethod cycle-result-scope ((record sequential-cycle-result))
  (%result-scope record))
(defmethod cycle-result-algorithm ((record sequential-cycle-result))
  (%result-algorithm record))
(defmethod cycle-result-cause ((record sequential-cycle-result))
  (%result-cause record))
(defmethod cycle-result-reason ((record sequential-cycle-result))
  (%result-reason record))


(defclass sequential-trace-context ()
  ((cycle :initarg :cycle :reader trace-context-cycle)
   (scope :initform nil :accessor %trace-scope)
   (generation :initform 0 :accessor %trace-generation)
   (capacity :initarg :capacity :reader %trace-capacity)
   (source-spaces :initarg :source-spaces :reader %trace-source-spaces)
   (source-starts :initarg :source-starts :reader %trace-source-starts)
   (states :initarg :states :reader %trace-states)
   (work-spaces :initarg :work-spaces :reader %trace-work-spaces)
   (work-starts :initarg :work-starts :reader %trace-work-starts)
   (reserved-count :initform 0 :accessor %trace-reserved-count)
   (committed-count :initform 0 :accessor %trace-committed-count)
   (take-index :initform 0 :accessor %trace-take-index)
   (active-index :initform nil :accessor %trace-active-index)
   (failed-reason :initform nil :accessor %trace-failed-reason)))

(defmethod trace-context-scope ((context sequential-trace-context))
  (%trace-scope context))
(defmethod trace-discovery-count ((context sequential-trace-context))
  (%trace-committed-count context))

(defclass sequential-cycle ()
  ((plan :initarg :plan :reader %cycle-plan)
   (configuration :initform nil :accessor %cycle-configuration)
   (scope :initform nil :accessor %cycle-scope)
   (algorithm :initform nil :accessor %cycle-algorithm)
   (cause :initform nil :accessor %cycle-cause)
   (phase :initform nil :accessor %cycle-phase)
   (trace :initarg :trace :accessor %cycle-trace)
   (stop-token :initform nil :accessor %cycle-stop-token)
   (coverage :initform nil :accessor %cycle-coverage)
   (forwarding-published-p :initform nil :accessor %cycle-forwarding-published-p)
   (commit-started-p :initform nil :accessor %cycle-commit-started-p)
   (retained-p :initform nil :accessor %cycle-retained-p)
   (retained-reason :initform nil :accessor %cycle-retained-reason)
   ;; Movement/death vectors are filled in commit order.
   (movement-old :initarg :movement-old :reader %cycle-movement-old)
   (movement-new :initarg :movement-new :reader %cycle-movement-new)
   (movement-count :initform 0 :accessor %cycle-movement-count)
   (death-spaces :initarg :death-spaces :reader %cycle-death-spaces)
   (death-starts :initarg :death-starts :reader %cycle-death-starts)
   (death-count :initform 0 :accessor %cycle-death-count)
   ;; Every representation in a retiring SemiSpace, including unreachable
   ;; objects, is staged before authoritative starts are cleared.  This is
   ;; separate from semantic death enumeration.
   (retirement-starts :initarg :retirement-starts
                      :reader %cycle-retirement-starts)
   (retirement-count :initform 0 :accessor %cycle-retirement-count)
   (current-retirement-space :initform nil
                             :accessor %cycle-current-retirement-space)
   ;; Conditional descriptor staging.  A record is keyed by source start,
   ;; strength and descriptor identity; no borrowed location is retained.
   (conditional-source :initarg :conditional-source :reader %conditional-source)
   (conditional-kind :initarg :conditional-kind :reader %conditional-kind)
   (conditional-id :initarg :conditional-id :reader %conditional-id)
   (conditional-original-key :initarg :conditional-original-key
                             :reader %conditional-original-key)
   (conditional-original-value :initarg :conditional-original-value
                               :reader %conditional-original-value)
   (conditional-new-key :initarg :conditional-new-key
                        :reader %conditional-new-key)
   (conditional-new-value :initarg :conditional-new-value
                          :reader %conditional-new-value)
   (conditional-clear-key-p :initarg :conditional-clear-key-p
                            :reader %conditional-clear-key-p)
   (conditional-count :initform 0 :accessor %conditional-count)
   ;; Finalizer batch: token, exact original and corrected encodings.
   (finalizer-token :initarg :finalizer-token :reader %finalizer-token)
   (finalizer-original :initarg :finalizer-original :reader %finalizer-original)
   (finalizer-corrected :initarg :finalizer-corrected :reader %finalizer-corrected)
   (finalizer-candidate-p :initarg :finalizer-candidate-p
                          :reader %finalizer-candidate-p)
   (finalizer-seen-p :initarg :finalizer-seen-p :reader %finalizer-seen-p)
   (finalizer-count :initform 0 :accessor %finalizer-count)
   (counts :initarg :counts :reader %cycle-counts)
   ;; These callbacks are allocated before the configuration is published.
   (root-callback :initform nil :accessor %cycle-root-callback)
   (strong-callback :initform nil :accessor %cycle-strong-callback)
   (snapshot-callback :initform nil :accessor %cycle-snapshot-callback)
   (discovery-callback :initform nil :accessor %cycle-discovery-callback)
   (ephemeron-callback :initform nil :accessor %cycle-ephemeron-callback)
   (weak-callback :initform nil :accessor %cycle-weak-callback)
   (conditional-ephemeron-callback :initform nil
                                   :accessor %cycle-conditional-ephemeron-callback)
   (finalizer-callback :initform nil :accessor %cycle-finalizer-callback)
   (revalidate-finalizer-callback :initform nil
                                  :accessor %cycle-revalidate-finalizer-callback)
   (retirement-callback :initform nil :accessor %cycle-retirement-callback)
   (conditional-weak-check-callback :initform nil
                                    :accessor %cycle-conditional-weak-check-callback)
   (conditional-ephemeron-check-callback :initform nil
                                         :accessor %cycle-conditional-ephemeron-check-callback)
   (current-start :initform nil :accessor %cycle-current-start)
   (current-conditional-index :initform 0
                              :accessor %cycle-current-conditional-index)
   (conditional-mode :initform nil :accessor %cycle-conditional-mode)
   (conditional-match-p :initform nil :accessor %cycle-conditional-match-p)))


(defun %runtime-object-entry-count (trace-capacity conditional-capacity
                                          finalizer-capacity)
  (+ (* 10 trace-capacity) (* 8 conditional-capacity)
     (* 5 finalizer-capacity)))

(defun %make-cycle (plan trace-capacity conditional-capacity finalizer-capacity
                    object-storage index-storage construction)
  ;; OBJECT-STORAGE and INDEX-STORAGE are the exact acquired construction
  ;; resources.  Displaced headers and capability records are covered by the
  ;; contribution's auxiliary-byte charge and are allocated only here, before
  ;; publication.
  (let ((object-offset 0))
    (labels ((objects (count)
               (prog1 (make-array count :displaced-to object-storage
                                  :displaced-index-offset object-offset)
                 (incf object-offset count))))
      (let* ((trace-source-spaces (objects trace-capacity))
             (trace-source-starts (objects trace-capacity))
             (trace-states (objects trace-capacity))
             (trace-work-spaces (objects trace-capacity))
             (trace-work-starts (objects trace-capacity))
             (cycle (make-instance
                     'sequential-cycle :plan plan :trace nil
                     :movement-old (objects trace-capacity)
                     :movement-new (objects trace-capacity)
                     :death-spaces (objects trace-capacity)
                     :death-starts (objects trace-capacity)
                     :retirement-starts (objects trace-capacity)
                     :conditional-source (objects conditional-capacity)
                     :conditional-kind (objects conditional-capacity)
                     :conditional-id (objects conditional-capacity)
                     :conditional-original-key (objects conditional-capacity)
                     :conditional-original-value (objects conditional-capacity)
                     :conditional-new-key (objects conditional-capacity)
                     :conditional-new-value (objects conditional-capacity)
                     :conditional-clear-key-p (objects conditional-capacity)
                     :finalizer-token (objects finalizer-capacity)
                     :finalizer-original (objects finalizer-capacity)
                     :finalizer-corrected (objects finalizer-capacity)
                     :finalizer-candidate-p (objects finalizer-capacity)
                     :finalizer-seen-p (objects finalizer-capacity)
                     :counts (make-array (length +sequential-core-counters+)
                                         :displaced-to index-storage))))
        (setf (%cycle-trace cycle)
              (make-instance 'sequential-trace-context
                             :cycle cycle :capacity trace-capacity
                             :source-spaces trace-source-spaces
                             :source-starts trace-source-starts
                             :states trace-states
                             :work-spaces trace-work-spaces
                             :work-starts trace-work-starts)
              (%cycle-root-callback cycle)
              (lambda (location) (%trace-root-location cycle location))
              (%cycle-strong-callback cycle)
              (lambda (identity location)
                (declare (ignore identity))
                (%trace-strong-location cycle location))
              (%cycle-snapshot-callback cycle)
              (lambda (snapshot)
                (map-root-locations snapshot (%cycle-root-callback cycle)))
              (%cycle-discovery-callback cycle)
              (lambda (space start)
                (declare (ignore space))
                (%inspect-discovery-ephemerons cycle start))
              (%cycle-ephemeron-callback cycle)
              (lambda (identity key-location value-location clear-key-p
                       cleared-key cleared-value)
                (%inspect-ephemeron cycle identity key-location value-location
                                    clear-key-p cleared-key cleared-value))
              (%cycle-weak-callback cycle)
              (lambda (identity location cleared-value)
                (%stage-weak-descriptor cycle identity location cleared-value))
              (%cycle-conditional-ephemeron-callback cycle)
              (lambda (identity key-location value-location clear-key-p
                       cleared-key cleared-value)
                (%stage-ephemeron-descriptor
                 cycle identity key-location value-location clear-key-p
                 cleared-key cleared-value))
              (%cycle-finalizer-callback cycle)
              (lambda (token referent)
                (%stage-finalizer-registration cycle token referent))
              (%cycle-revalidate-finalizer-callback cycle)
              (lambda (token referent)
                (%revalidate-finalizer-registration cycle token referent))
              (%cycle-retirement-callback cycle)
              (lambda (address value)
                (declare (ignore value))
                (%stage-semispace-retirement cycle address))
              (%cycle-conditional-weak-check-callback cycle)
              (lambda (identity location cleared-value)
                (%conditional-check-or-commit-weak
                 cycle identity location cleared-value))
              (%cycle-conditional-ephemeron-check-callback cycle)
              (lambda (identity key-location value-location clear-key-p
                       cleared-key cleared-value)
                (%conditional-check-or-commit-ephemeron
                 cycle identity key-location value-location clear-key-p
                 cleared-key cleared-value)))
        (unless (= object-offset (length object-storage))
          (%runtime-reject :resource-capacity-mismatch))
        ;; Register every persistent construction allocation, not merely its
        ;; estimated byte budget.  EQ dedup covers displaced arrays backed by
        ;; one acquired vector without hiding their headers.
        (dolist (object
                  (list cycle (%cycle-trace cycle)
                        trace-source-spaces trace-source-starts trace-states
                        trace-work-spaces trace-work-starts
                        (%cycle-movement-old cycle) (%cycle-movement-new cycle)
                        (%cycle-death-spaces cycle) (%cycle-death-starts cycle)
                        (%cycle-retirement-starts cycle)
                        (%conditional-source cycle) (%conditional-kind cycle)
                        (%conditional-id cycle) (%conditional-original-key cycle)
                        (%conditional-original-value cycle)
                        (%conditional-new-key cycle) (%conditional-new-value cycle)
                        (%conditional-clear-key-p cycle)
                        (%finalizer-token cycle) (%finalizer-original cycle)
                        (%finalizer-corrected cycle) (%finalizer-candidate-p cycle)
                        (%finalizer-seen-p cycle)
                        (%cycle-root-callback cycle) (%cycle-strong-callback cycle)
                        (%cycle-snapshot-callback cycle)
                        (%cycle-discovery-callback cycle)
                        (%cycle-ephemeron-callback cycle)
                        (%cycle-weak-callback cycle)
                        (%cycle-conditional-ephemeron-callback cycle)
                        (%cycle-finalizer-callback cycle)
                        (%cycle-revalidate-finalizer-callback cycle)
                        (%cycle-retirement-callback cycle)
                        (%cycle-conditional-weak-check-callback cycle)
                        (%cycle-conditional-ephemeron-check-callback cycle)))
          (%register-resource-auxiliary
           construction (%plan-object-resource-id plan) object))
        (%register-resource-auxiliary
         construction (%plan-index-resource-id plan) (%cycle-counts cycle))
        cycle))))

(defclass sequential-runtime-plan (component)
  ((root-client :initarg :root-client :reader %plan-root-client)
   (coordinator :initarg :coordinator :reader %plan-coordinator)
   (diagnostics :initarg :diagnostics :reader %plan-diagnostics)
   (registry :initarg :registry :reader %plan-registry)
   (spaces :initarg :spaces :reader %plan-spaces)
   (movement-participants :initarg :movement-participants :initform nil
                          :reader %plan-movement-participants)
   (trace-capacity :initarg :trace-capacity :reader %plan-trace-capacity)
   (conditional-capacity :initarg :conditional-capacity
                         :reader %plan-conditional-capacity)
   (finalizer-capacity :initarg :finalizer-capacity
                       :reader %plan-finalizer-capacity)
   (packing-quantum :initarg :packing-quantum :reader %plan-packing-quantum)
   (configuration :initform nil :accessor %plan-configuration)
   (cycle :initform nil :accessor %plan-cycle)
   (automatic-result :initform nil :accessor %plan-automatic-result)
   (state :initform :construction :accessor %plan-state)
   (retained-cycle :initform nil :accessor %plan-retained-cycle)
   (active-context-count :initform 0 :accessor %plan-active-context-count)
   (next-context-generation :initform 0 :accessor %plan-next-context-generation)
   (allocation-routes :initarg :allocation-routes :initform nil
                      :reader %plan-allocation-routes)
   (default-algorithm :initarg :default-algorithm :reader %plan-default-algorithm)
   (algorithms :initarg :algorithms :reader %plan-algorithms)
   (causes :initarg :causes :reader %plan-causes)
   (reasons :initarg :reasons :reader %plan-reasons)
   (counters :initarg :counters :reader %plan-counters)
   (object-resource-id :initform (gensym "RUNTIME-OBJECTS-")
                       :reader %plan-object-resource-id)
   (index-resource-id :initform (gensym "RUNTIME-INDICES-")
                      :reader %plan-index-resource-id)))

(defun %make-common-plan-instance (class &rest initargs &key
                                     root-client coordinator diagnostics registry
                                     spaces (movement-participants nil)
                                     trace-capacity conditional-capacity
                                     finalizer-capacity packing-quantum
                                     allocation-routes default-algorithm algorithms
                                     (causes +sequential-core-causes+)
                                     (reasons +sequential-core-reasons+)
                                     (counters +sequential-core-counters+)
                                     &allow-other-keys)
  (declare (ignore root-client coordinator diagnostics registry spaces
                   movement-participants allocation-routes))
  (%checked-nonnegative-integer trace-capacity :invalid-trace-capacity)
  (when (zerop trace-capacity) (%runtime-reject :invalid-trace-capacity))
  (%checked-nonnegative-integer conditional-capacity :invalid-conditional-capacity)
  (%checked-nonnegative-integer finalizer-capacity :invalid-finalizer-capacity)
  (unless (%positive-power-of-two-p packing-quantum)
    (%runtime-reject :invalid-packing-quantum))
  (unless (and default-algorithm (member default-algorithm algorithms :test #'eq))
    (%runtime-reject :unsupported-algorithm))
  (let ((plan (apply #'make-instance class
                     :causes causes :reasons reasons :counters counters initargs)))
    plan))

(defmethod component-resources ((plan sequential-runtime-plan))
  (let* ((objects (%runtime-object-entry-count
                   (%plan-trace-capacity plan)
                   (%plan-conditional-capacity plan)
                   (%plan-finalizer-capacity plan)))
         (indices (length (%plan-counters plan)))
         ;; Capability records, displaced headers and the two callbacks are
         ;; ordinary construction allocations, but their bound is charged.
         (auxiliary 16384))
    (list (make-resource-contribution
           plan :configuration-auxiliary :runtime-object-vector
           :minimum-physical-bytes 16 :logical-entry-bound 0
           :auxiliary-bytes 65536 :allocation-context :construction-only
           :exhaustion-action :reject-before-publication)
          (make-resource-contribution
           plan (%plan-object-resource-id plan) :runtime-object-vector
           :minimum-physical-bytes (+ 16 (* 8 objects)) :logical-entry-bound objects
           :auxiliary-bytes auxiliary :allocation-context :construction-only
           :exhaustion-action :reject-before-publication)
          (make-resource-contribution
           plan (%plan-index-resource-id plan) :runtime-index-vector
           :minimum-physical-bytes (+ 16 (* 8 indices)) :logical-entry-bound indices
           :auxiliary-bytes 64 :allocation-context :construction-only
           :exhaustion-action :reject-before-publication))))

(defmethod component-dependencies ((plan sequential-runtime-plan))
  (append (copy-list (%plan-spaces plan))
          (copy-list (%plan-movement-participants plan))
          (list (%plan-registry plan) (%plan-coordinator plan))))

(defmethod component-requires-bound-object-model-p
    ((plan sequential-runtime-plan))
  (declare (ignore plan)) t)

(defmethod initialize-component ((plan sequential-runtime-plan) context)
  (multiple-value-bind (objects present-p physical entries auxiliary)
      (construction-resource context (%plan-object-resource-id plan))
    (let ((expected (%runtime-object-entry-count
                     (%plan-trace-capacity plan)
                     (%plan-conditional-capacity plan)
                     (%plan-finalizer-capacity plan))))
      (unless (and present-p (typep objects 'simple-vector)
                   (>= physical (+ 16 (* 8 expected)))
                   (>= auxiliary 16384)
                   (>= entries expected) (>= (length objects) expected))
        (%runtime-reject :resource-capacity-mismatch))
      (multiple-value-bind (indices indices-present-p index-physical
                            index-entries index-auxiliary)
          (construction-resource context (%plan-index-resource-id plan))
        (unless (and indices-present-p (typep indices 'simple-vector)
                     (>= index-physical (+ 16 (* 8 (length (%plan-counters plan)))))
                     (>= index-auxiliary 64)
                     (>= index-entries (length (%plan-counters plan)))
                     (>= (length indices) (length (%plan-counters plan))))
          (%runtime-reject :resource-capacity-mismatch))
        ;; The provider can legally return a larger handle.  Use exact displaced
        ;; views so unclaimed storage remains visible in the capacity account.
        (let ((object-view (make-array expected :displaced-to objects))
              (index-view (make-array (length (%plan-counters plan))
                                      :displaced-to indices)))
          (setf (%plan-cycle plan)
                (%make-cycle plan (%plan-trace-capacity plan)
                             (%plan-conditional-capacity plan)
                             (%plan-finalizer-capacity plan)
                             object-view index-view context)
                (%plan-automatic-result plan) (make-cycle-result-record plan))
          (%register-resource-auxiliary
           context (%plan-object-resource-id plan) object-view)
          (%register-resource-auxiliary
           context (%plan-index-resource-id plan) index-view)
          (%register-resource-auxiliary
           context (%plan-object-resource-id plan) (%plan-automatic-result plan))
          (%register-resource-auxiliary
           context (%plan-index-resource-id plan)
           (%result-counts (%plan-automatic-result plan)))
          (%register-resource-auxiliary
           context (%plan-index-resource-id plan)
           (%result-known (%plan-automatic-result plan)))))))
  (setf (%plan-configuration plan) (construction-configuration context)
        (%plan-state plan) :initialized)
  (values))

(defmethod validate-component ((plan sequential-runtime-plan) configuration)
  (unless (eq configuration (%plan-configuration plan))
    (%runtime-reject :foreign-configuration))
  (unless (eq (configuration-plan configuration) plan)
    (%runtime-reject :foreign-plan))
  (unless (configuration-object-model configuration)
    (%runtime-reject :unbound-object-model))
  (let ((required
          (if (typep plan 'semispace-plan)
              (loop for space in (%plan-spaces plan)
                    maximize (ceiling (%space-extent space)
                                      (%space-packing-quantum space)))
              (loop for space in (%plan-spaces plan)
                    sum (ceiling (%space-extent space)
                                 (%space-packing-quantum space))))))
    (when (> required (%plan-trace-capacity plan))
      (%runtime-reject :invalid-trace-capacity)))
  (values))

(defmethod activate-component ((plan sequential-runtime-plan) context)
  (declare (ignore context))
  (setf (%plan-state plan) :open)
  (values))

(defmethod deactivate-component ((plan sequential-runtime-plan) context)
  (declare (ignore context))
  (setf (%plan-state plan) :closed)
  (values))

(defmethod make-cycle-result-record ((plan sequential-runtime-plan))
  (make-instance 'sequential-cycle-result :owner plan
                 :counts (make-array (length (%plan-counters plan))
                                     :initial-element nil)
                 :known (make-array (length (%plan-counters plan))
                                    :initial-element nil)))

(defun %schema-find (key schema)
  (position key schema :key #'car :test #'eq))

(defmethod cycle-counter-known-p ((plan sequential-runtime-plan) counter)
  (not (null (%schema-find counter (%plan-counters plan)))))
(defmethod cycle-counter-description ((plan sequential-runtime-plan) counter)
  (cdr (assoc counter (%plan-counters plan) :test #'eq)))
(defmethod cycle-cause-known-p ((plan sequential-runtime-plan) cause)
  (not (null (%schema-find cause (%plan-causes plan)))))
(defmethod cycle-cause-description ((plan sequential-runtime-plan) cause)
  (cdr (assoc cause (%plan-causes plan) :test #'eq)))
(defmethod cycle-reason-known-p ((plan sequential-runtime-plan) reason)
  (not (null (%schema-find reason (%plan-reasons plan)))))
(defmethod cycle-reason-description ((plan sequential-runtime-plan) reason)
  (cdr (assoc reason (%plan-reasons plan) :test #'eq)))

(defmethod cycle-result-count ((record sequential-cycle-result) counter)
  (let* ((owner (cycle-result-owner record))
         (index (%schema-find counter (%plan-counters owner))))
    (unless index (%runtime-reject :unknown-counter))
    (if (aref (%result-known record) index)
        (values (aref (%result-counts record) index) t)
        (values nil nil))))

(defun %cycle-counter-incf (cycle counter &optional (delta 1))
  (let ((index (%schema-find counter (%plan-counters (%cycle-plan cycle)))))
    (unless index (%runtime-reject :unknown-counter))
    (incf (aref (%cycle-counts cycle) index) delta)))

(defun %fill-result (record cycle status reason)
  (setf (%result-status record) status
        (%result-phase record) (%cycle-phase cycle)
        (%result-scope record) (%cycle-scope cycle)
        (%result-algorithm record) (%cycle-algorithm cycle)
        (%result-cause record) (%cycle-cause cycle)
        (%result-reason record) reason)
  (dotimes (index (length (%result-counts record)))
    (setf (aref (%result-counts record) index) (aref (%cycle-counts cycle) index)
          (aref (%result-known record) index) t))
  record)

(defclass sequential-execution-context ()
  ((configuration :initarg :configuration :reader %context-configuration)
   (plan :initarg :plan :reader %context-plan)
   (execution :initarg :execution :reader %context-execution)
   (allocation-domain :initarg :allocation-domain :reader %context-domain)
   (allocator :initarg :allocator :accessor %context-allocator)
   (cursor :initform 0 :accessor %context-cursor)
   (limit :initform 0 :accessor %context-limit)
   (generation :initarg :generation :reader %context-generation)
   (refill-request :initarg :refill-request :reader %context-refill-request)
   (barrier-reservations :initarg :barrier-reservations
                         :reader %context-barrier-reservations)
   (barrier-reserved-p :initarg :barrier-reserved-p
                       :reader %context-barrier-reserved-p)
   (state :initform :bound :accessor %context-state)))

(defun %configuration-runtime-plan (configuration)
  (let ((plan (configuration-plan configuration)))
    (unless (typep plan 'sequential-runtime-plan)
      (%runtime-reject :unsupported-algorithm))
    plan))
