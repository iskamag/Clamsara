;;;; src/construction/records.lisp -- opaque inputs and private snapshots.

(in-package #:clamsara)

;;; Core constructors return opaque values.  Callers have no contract on these
;;; classes or slots; the matching DESCRIBE generic is the only observation.
(defstruct (%resource-contribution
            (:constructor %make-resource-contribution
                (identity representation placement-identity
                 minimum-physical-bytes logical-entry-bound auxiliary-bytes
                 allocation-context exhaustion-action)))
  identity representation placement-identity minimum-physical-bytes
  logical-entry-bound auxiliary-bytes allocation-context exhaustion-action)

(defmethod make-resource-contribution
    ((component component) identity representation
     &key placement-identity (minimum-physical-bytes 0)
       (logical-entry-bound 0) (auxiliary-bytes 0)
       allocation-context exhaustion-action)
  (declare (ignore component))
  (%make-resource-contribution identity representation placement-identity
                               minimum-physical-bytes logical-entry-bound
                               auxiliary-bytes allocation-context
                               exhaustion-action))

(defmethod describe-resource-contribution ((value %resource-contribution))
  (values (%resource-contribution-identity value)
          (%resource-contribution-representation value)
          (%resource-contribution-placement-identity value)
          (%resource-contribution-minimum-physical-bytes value)
          (%resource-contribution-logical-entry-bound value)
          (%resource-contribution-auxiliary-bytes value)
          (%resource-contribution-allocation-context value)
          (%resource-contribution-exhaustion-action value)))

(defstruct (%placement-request
            (:constructor %make-placement-request
                (identity minimum-extent preferred-extent maximum-extent
                 alignment granularity access lifetime mobility reclaimability
                 aliasable-p inputs size-function)))
  identity minimum-extent preferred-extent maximum-extent alignment granularity
  access lifetime mobility reclaimability aliasable-p inputs size-function)

(defmethod make-placement-request
    ((component component) identity minimum-extent preferred-extent maximum-extent
     &key (alignment 1) (granularity 1) access lifetime mobility reclaimability
       aliasable-p inputs size-function)
  (declare (ignore component))
  (%make-placement-request identity minimum-extent preferred-extent
                           maximum-extent alignment granularity access lifetime
                           mobility reclaimability aliasable-p inputs
                           size-function))

(defmethod describe-placement-request ((value %placement-request))
  (values (%placement-request-identity value)
          (%placement-request-minimum-extent value)
          (%placement-request-preferred-extent value)
          (%placement-request-maximum-extent value)
          (%placement-request-alignment value)
          (%placement-request-granularity value)
          (%placement-request-access value)
          (%placement-request-lifetime value)
          (%placement-request-mobility value)
          (%placement-request-reclaimability value)
          (%placement-request-aliasable-p value)
          (%placement-request-inputs value)
          (%placement-request-size-function value)))

(defstruct (%construction-constraint
            (:constructor %make-construction-constraint
                (kind identities parameters predicate description)))
  kind identities parameters predicate description)

(defmethod make-construction-constraint
    ((component component) kind identities &key parameters predicate description)
  (declare (ignore component))
  (%make-construction-constraint kind identities parameters predicate
                                 description))

(defmethod describe-construction-constraint ((value %construction-constraint))
  (values (%construction-constraint-kind value)
          (%construction-constraint-identities value)
          (%construction-constraint-parameters value)
          (%construction-constraint-predicate value)
          (%construction-constraint-description value)))

(defstruct (%barrier-reservation-claim
            (:constructor %make-barrier-reservation-claim
                (resource-designator entry-representation
                 maximum-live-entries)))
  resource-designator entry-representation maximum-live-entries)

(defmethod make-barrier-reservation-claim
    ((component component) resource-designator entry-representation
     maximum-live-entries)
  (declare (ignore component))
  (%make-barrier-reservation-claim resource-designator entry-representation
                                   maximum-live-entries))

(defmethod describe-barrier-reservation-claim
    ((value %barrier-reservation-claim))
  (values (%barrier-reservation-claim-resource-designator value)
          (%barrier-reservation-claim-entry-representation value)
          (%barrier-reservation-claim-maximum-live-entries value)))

(defstruct (%barrier-contribution
            (:constructor %make-barrier-contribution
                (identity events reservation-claims needs-old-p needs-new-p
                 before after replacement-policy failure-policy)))
  identity events reservation-claims needs-old-p needs-new-p before after
  replacement-policy failure-policy)

(defmethod make-barrier-contribution
    ((component component) identity events
     &key reservation-claims needs-old-p needs-new-p before after
       replacement-policy failure-policy)
  (declare (ignore component))
  (%make-barrier-contribution identity events reservation-claims needs-old-p
                              needs-new-p before after replacement-policy
                              failure-policy))

(defmethod describe-barrier-contribution ((value %barrier-contribution))
  (values (%barrier-contribution-identity value)
          (%barrier-contribution-events value)
          (%barrier-contribution-reservation-claims value)
          (%barrier-contribution-needs-old-p value)
          (%barrier-contribution-needs-new-p value)
          (%barrier-contribution-before value)
          (%barrier-contribution-after value)
          (%barrier-contribution-replacement-policy value)
          (%barrier-contribution-failure-policy value)))

(defstruct (%result-contribution
            (:constructor %make-result-contribution
                (kind identity stable-description)))
  kind identity stable-description)

(defmethod make-result-contribution
    ((component component) kind identity &key description)
  (declare (ignore component))
  (%make-result-contribution kind identity description))

(defmethod describe-result-contribution ((value %result-contribution))
  (values (%result-contribution-kind value)
          (%result-contribution-identity value)
          (%result-contribution-stable-description value)))

;;; Frozen descriptions.  The implementation passes these only to private
;;; integration hooks.  Actual opaque contribution objects are retained.
(defstruct (%component-node (:constructor %make-component-node))
  component index path dependencies resources placements constraints barriers
  results cohort space-p object-start-map initialized-p activated-p)

(defstruct (%resource-description (:constructor %make-resource-description))
  actual owner path position identity representation placement-identity
  minimum-physical-bytes logical-entry-bound auxiliary-bytes allocation-context
  exhaustion-action)

(defstruct (%placement-description (:constructor %make-placement-description))
  actual owner path position identity minimum-extent preferred-extent
  maximum-extent alignment granularity access lifetime mobility reclaimability
  aliasable-p inputs size-function derived-p constraint-count object-start-map)

(defstruct (%constraint-description (:constructor %make-constraint-description))
  actual owner path position kind identities parameters predicate description)

(defstruct (%claim-description (:constructor %make-claim-description))
  actual path resource-designator entry-representation maximum-live-entries)

(defstruct (%barrier-description (:constructor %make-barrier-description))
  actual owner path position identity events claims needs-old-p needs-new-p
  before after replacement-policy failure-policy)

(defstruct (%result-description (:constructor %make-result-description))
  actual owner path position kind identity stable-description)


(defstruct (%initialization-group (:constructor %make-initialization-group))
  identity nodes index cyclic-p continuing-p dependencies)

(defstruct (%arena-description (:constructor %make-arena-description))
  actual path name base byte-extent alignment page-size permitted-accesses
  address-width exclusions exclusive-limit)

(defstruct (%placement-solution (:constructor %make-placement-solution))
  description base exclusive-limit derived-size alias-of object-start-map)

(defstruct (%resource-state (:constructor %make-resource-state))
  description handle physical-bytes entry-capacity auxiliary-bytes
  release-capability released-p)

(defstruct (%capacity-account-entry (:constructor %make-capacity-account-entry))
  identity representation placement-identity allocation-context
  exhaustion-action handle physical-bytes entry-capacity auxiliary-bytes)

(defstruct (%transaction-entry (:constructor %make-transaction-entry))
  kind identity payload released-p)

(defclass %reference-layout ()
  ((arena :initarg :arena :reader %layout-arena)
   (assignments :initarg :assignments :reader %layout-assignments)
   (ordered-solutions :initarg :ordered-solutions
                      :reader %layout-ordered-solutions)
   (free-intervals :initarg :free-intervals :reader %layout-free-intervals)))

(defclass %construction-context ()
  ((configuration :initarg :configuration :accessor %context-configuration)
   (resources :initform (make-hash-table :test #'eql)
              :reader %context-resources)
   (placements :initform (make-hash-table :test #'eql)
               :reader %context-placements)
   (transaction-log :initform nil :accessor %context-transaction-log)
   (target-maximum :initarg :target-maximum :accessor %context-target-maximum)
   (state :initform :building :accessor %context-state)))

(defclass %configuration ()
  ((plan :initarg :plan :reader %configuration-plan)
   (clients :initarg :clients :reader %configuration-clients)
   (graph :initarg :graph :accessor %configuration-graph)
   (component-order :initarg :component-order
                    :accessor %configuration-component-order)
   (construction :accessor %configuration-construction)
   (layout :initform nil :accessor %configuration-layout)
   (object-model :initform nil :accessor %configuration-object-model)
   (object-model-bound-p :initform nil
                         :accessor %configuration-object-model-bound-p)
   (barrier :initform nil :accessor %configuration-barrier)
   (barrier-bound-p :initform nil :accessor %configuration-barrier-bound-p)
   (runtime-state :initform nil :accessor %configuration-runtime-state)
   (capacity-account :initform #() :accessor %configuration-capacity-account)
   (result-schema :initform #() :accessor %configuration-result-schema)
   (state :initform :private :accessor %configuration-state)
   (initialization-order :initform nil
                         :accessor %configuration-initialization-order)
   (activation-order :initform nil :accessor %configuration-activation-order)
   (shutdown-deactivation-index :initform 0
                                :accessor %configuration-shutdown-deactivation-index)
   (shutdown-release-index :initform 0
                           :accessor %configuration-shutdown-release-index)
   (shutdown-reason :initform nil :accessor %configuration-shutdown-reason)))

(defmethod configuration-plan ((configuration %configuration))
  (%configuration-plan configuration))
(defmethod configuration-clients ((configuration %configuration))
  (%configuration-clients configuration))
(defmethod configuration-layout ((configuration %configuration))
  (%configuration-layout configuration))
(defmethod configuration-construction-context ((configuration %configuration))
  (%configuration-construction configuration))
(defmethod construction-configuration ((construction %construction-context))
  (%context-configuration construction))
(defmethod configuration-object-model ((configuration %configuration))
  (unless (%configuration-object-model-bound-p configuration)
    (error 'construction-rejected :reason :object-model-not-bound))
  (%configuration-object-model configuration))

(defmethod construction-resource ((construction %construction-context) identity)
  (let ((state (gethash identity (%context-resources construction))))
    (if state
        (values (%resource-state-handle state) t
                (%resource-state-physical-bytes state)
                (%resource-state-entry-capacity state)
                (%resource-state-auxiliary-bytes state))
        (values nil nil nil nil nil))))

(defmethod construction-placement ((construction %construction-context) identity)
  (let ((solution (gethash identity (%context-placements construction))))
    (if solution
        (values (%placement-solution-base solution)
                (%placement-solution-exclusive-limit solution) t)
        (values nil nil nil))))
