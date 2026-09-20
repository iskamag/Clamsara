;;;; src/construction/protocol.lisp -- v14 construction declarations.
;;;;
;;;; This is the dependency-light declaration layer.  It defines the exact
;;;; public construction protocol and builder-owned private seams.  It does
;;;; not install host capability fallbacks.

(in-package #:clamsara)

;;; Rejections keep stable machine-readable reasons and the declaration paths
;;; that led to them.  The original condition is retained where one exists.
(define-condition construction-rejected (error)
  ((reason :initarg :reason :reader construction-rejection-reason)
   (paths :initarg :paths :initform nil :reader construction-rejection-paths)
   (cause :initarg :cause :initform nil :reader construction-rejection-cause))
  (:report (lambda (condition stream)
             (format stream "Construction rejected (~S)~@[ at ~S~]~@[; cause: ~A~]"
                     (construction-rejection-reason condition)
                     (construction-rejection-paths condition)
                     (construction-rejection-cause condition)))))

(defclass component () ())

;;; Graph declarations.  NIL is the unique empty proper list; nonempty values
;;; are copied and frozen by the builder after exactly one call.
(defgeneric component-dependencies (component))
(defgeneric component-resources (component))
(defgeneric component-constraints (component))
(defgeneric component-placement-requests (component))
(defgeneric component-barrier-contributions (component))
(defgeneric component-result-contributions (component))
(defgeneric component-cohort (component))
(defgeneric initialize-component (component context))
(defgeneric validate-component (component configuration))
(defgeneric activate-component (component context))
(defgeneric deactivate-component (component context))

(defmethod component-dependencies ((component component))
  (declare (ignore component)) nil)
(defmethod component-resources ((component component))
  (declare (ignore component)) nil)
(defmethod component-constraints ((component component))
  (declare (ignore component)) nil)
(defmethod component-placement-requests ((component component))
  (declare (ignore component)) nil)
(defmethod component-barrier-contributions ((component component))
  (declare (ignore component)) nil)
(defmethod component-result-contributions ((component component))
  (declare (ignore component)) nil)
(defmethod component-cohort ((component component))
  (declare (ignore component)) nil)
(defmethod initialize-component ((component component) context)
  (declare (ignore component context)) (values))
(defmethod validate-component ((component component) configuration)
  (declare (ignore component configuration)) (values))
(defmethod activate-component ((component component) context)
  (declare (ignore component context)) (values))
(defmethod deactivate-component ((component component) context)
  (declare (ignore component context)) (values))

;;; Opaque public contribution constructors/describers.
(defgeneric make-resource-contribution
    (component identity representation
     &key placement-identity minimum-physical-bytes logical-entry-bound
       auxiliary-bytes allocation-context exhaustion-action))
(defgeneric describe-resource-contribution (contribution))

(defgeneric make-placement-request
    (component identity minimum-extent preferred-extent maximum-extent
     &key alignment granularity access lifetime mobility reclaimability
       aliasable-p inputs size-function))
(defgeneric describe-placement-request (request))

(defgeneric make-construction-constraint
    (component kind identities &key parameters predicate description))
(defgeneric describe-construction-constraint (constraint))

(defgeneric make-barrier-reservation-claim
    (component resource-designator entry-representation maximum-live-entries))
(defgeneric describe-barrier-reservation-claim (claim))
(defgeneric make-barrier-contribution
    (component identity events
     &key reservation-claims needs-old-p needs-new-p before after
       replacement-policy failure-policy))
(defgeneric describe-barrier-contribution (contribution))

(defgeneric make-result-contribution
    (component kind identity &key description))
(defgeneric describe-result-contribution (contribution))

;;; Builder and lifecycle API.
(defgeneric construct-plan (plan clients))
(defgeneric shutdown-configuration (configuration))
(defgeneric configuration-object-model (configuration))
(defgeneric construction-resource (construction identity))
(defgeneric construction-placement (construction identity))
(defgeneric release-construction-resource (construction identity handle))

;;; Normative managed-layout protocol.  Offers, installed layouts and release
;;; capabilities remain opaque to this declaration layer.
(defgeneric managed-arena-offer (address-space-client))
(defgeneric describe-managed-arena-offer (address-space-client offer))
(defgeneric validate-managed-layout (address-space-client layout))
(defgeneric install-managed-layout (address-space-client layout))
(defgeneric release-managed-layout (address-space-client release-capability))
(defgeneric space-of-reference (layout start-reference))
(defgeneric prepare-space-ownership-update (layout bound-model range owner))
(defgeneric update-space-ownership (layout commit-capability))

;;; The metadata chapter's exact space-to-authoritative-map declaration.  Space
;;; implementations provide methods; there is deliberately no default method,
;;; so applicability (not a parallel registry) identifies spaces.
(defgeneric space-object-start-map (space))

;;; Builder-owned client selection.  Concrete aggregate clients must implement
;;; every selector used by their graph; no plist or global-variable fallback is
;;; supplied here.
(defgeneric construction-object-model (clients))
(defgeneric construction-stop-coordinator (clients))
(defgeneric construction-address-space-client (clients))
(defgeneric construction-root-client (clients))
(defgeneric construction-atomics-client (clients))
(defgeneric construction-diagnostics-client (clients))
(defgeneric construction-client-profile (clients))

;;; Resource provisioning.  DESCRIPTION is a frozen builder record, and
;;; PLACEMENT is NIL or a (BASE . EXCLUSIVE-LIMIT) pair.  The acquisition must
;;; leave no state if it signals.  Its release capability must be bounded,
;;; non-failing and idempotent.
(defgeneric %acquire-construction-resource
    (clients construction description placement))
(defgeneric %release-acquired-construction-resource (clients release-capability))

;;; Explicit address-space admission.  Policy KIND is one of :LIFETIME,
;;; :MOBILITY or :RECLAIMABILITY.  Unknown identities return false.
(defgeneric %address-space-policy-supported-p
    (address-space-client kind identity))

;;; Domain-specific constraint solvers return SATISFIED-P, KNOWN-P.  The
;;; standard kinds never call this hook.
(defgeneric %evaluate-construction-constraint
    (address-space-client kind tagged-values parameters))

;;; A cyclic cohort containing continuing stopped-mode services requires an
;;; explicit progress proof supplied by the selected coordinator integration.
(defgeneric %component-continuing-service-p (component))
(defmethod %component-continuing-service-p ((component component))
  (declare (ignore component)) nil)
(defgeneric %admit-continuing-cohort-progress
    (coordinator components construction))

;;; Binding order extension.  This is a private implementation marker, not a
;;; parallel behavioral registry.  Spaces are detected through the normative
;;; SPACE-OBJECT-START-MAP generic and are always delayed through binding.
(defgeneric component-requires-bound-object-model-p (component))
(defmethod component-requires-bound-object-model-p ((component component))
  (declare (ignore component)) nil)

;;; Barrier composition is deliberately not declared as a client-specialized
;;; protocol here.  The runtime module owns the ordinary private function
;;; %COMPOSE-CONFIGURATION-BARRIER.  It consumes the ordered frozen facts,
;;; checks applicability of authored BARRIER-CONTRIBUTION-* methods, and
;;; retains the actual opaque contribution objects.

;;; Private configuration access used by sibling v14 implementation modules.
(defgeneric configuration-plan (configuration))
(defgeneric configuration-clients (configuration))
(defgeneric configuration-layout (configuration))
(defgeneric configuration-construction-context (configuration))
(defgeneric construction-configuration (construction))

;;; The runtime module owns ordinary private %CLOSE-CONFIGURATION-RUNTIME and
;;; %DRAIN-CONFIGURATION-RUNTIME functions over configuration-owned admitted
;;; routes and bounded active counts.  They are not another component lifecycle.
