;;;; Clamsara v11 -- component construction kernel (standalone).
;;;;
;;;; Implements the construction protocol of paper-v11/chapters/composition.tex:
;;;; an ordinary CLOS component graph is compiled into exactly one published
;;;; runtime configuration through exactly seven phases
;;;;   :construct-discover :merge :layout-callback :bind :initialize
;;;;   :validate :activate
;;;; A failure in any phase publishes nothing; initialized components are
;;;; deactivated in reverse dependency order before the error escapes.

(defpackage :clamsara-core
  (:use :cl)
  (:export #:component
           #:component-dependencies
           #:component-resources
           #:component-constraints
           #:validate-component
           #:initialize-component
           #:activate-component
           #:deactivate-component
           #:component-cohort
           #:resource
           #:make-resource
           #:resource-name
           #:resource-role
           #:resource-size
           #:resource-granularity
           #:resource-ownership
           #:resource-lifetime
           #:resource-atomicity
           #:resource-providers
           #:resource-consumers
           #:resource-start
           #:resource-extent
           #:resource-sealed-p
           #:configuration
           #:configuration-components
           #:configuration-resources
           #:configuration-constraints
           #:configuration-layout
           #:configuration-state
           #:configuration-phases
           #:configuration-topological-order
           #:configuration-active-p
           #:find-resource
           #:component-bindings
           #:build-configuration
           #:deactivate-configuration
           #:*published-configurations*
           #:*most-recent-configuration*
           #:construction-error
           #:construction-error-component
           #:construction-error-fact
           #:construction-error-path
           #:dependency-cycle
           #:resource-conflict
           #:missing-resource
           #:component-failure
           #:component-failure-phase
           #:component-failure-cause
           #:configuration-sealed
           #:context
           #:context-configuration))

(in-package :clamsara-core)

;;; ---------------------------------------------------------------------
;;; Reference component protocol.
;;;
;;; The seven generic lambda lists below are copied verbatim from
;;; paper-v11/chapters/composition.tex, section "Components".

(defclass component () ())

(defgeneric component-dependencies (component))
(defgeneric component-resources (component))
(defgeneric component-constraints (component))
(defgeneric validate-component (component configuration))
(defgeneric initialize-component (component context))
(defgeneric activate-component (component context))
(defgeneric deactivate-component (component context))

(defmethod component-dependencies ((component component)) nil)
(defmethod component-resources ((component component)) nil)
(defmethod component-constraints ((component component)) nil)

;; Lifecycle-hook defaults: a component declaring only structure
;; participates in construction; validation defaults to success.
(defmethod validate-component ((component component) configuration)
  (declare (ignore configuration))
  t)
(defmethod initialize-component ((component component) context)
  (declare (ignore context))
  nil)
(defmethod activate-component ((component component) context)
  (declare (ignore context))
  nil)
(defmethod deactivate-component ((component component) context)
  (declare (ignore context))
  nil)

(defgeneric component-cohort (component)
  (:method ((component component)) nil)
  (:documentation "Cohort designator of COMPONENT, or NIL.  Components whose
cohort designators are EQL and non-NIL may depend on each other: the cycle is
a declared, mutually-initialized cohort, not an ordinary cycle.  Cohort
members are initialized and activated as one contiguous batch, and their
construction protocol must not read unbound state."))

;;; ---------------------------------------------------------------------
;;; Resources.

(defclass resource ()
  ((name :initarg :name :reader resource-name)
   (role :initarg :role :initform :require :reader resource-role)
   (size :initarg :size :initform nil :reader resource-size)
   (granularity :initarg :granularity :initform nil :reader resource-granularity)
   (ownership :initarg :ownership :initform nil :reader resource-ownership)
   (lifetime :initarg :lifetime :initform nil :reader resource-lifetime)
   (atomicity :initarg :atomicity :initform nil :reader resource-atomicity)
   (providers :initform nil :accessor resource-providers)
   (consumers :initform nil :accessor resource-consumers)
   (start :initform nil :accessor resource-start)
   (extent :initform nil :accessor resource-extent)
   ;; SEALED has no public writer.  Lifecycle code changes it with SLOT-VALUE;
   ;; otherwise callers could unseal an active resource and mutate geometry.
   (sealed :initform nil :reader resource-sealed-p))
  (:documentation "Implementation record for a named logical resource fact
(NOT a target address).  Declaration attributes: NAME (semantic identity),
SIZE, GRANULARITY, OWNERSHIP, LIFETIME, ATOMICITY.  ROLE is :REQUIRE (the
declaring component consumes the fact) or :PROVIDE (it supplies the fact).

Merge rule (phase :MERGE): two facts with the same NAME merge only when every
declaration attribute agrees pairwise under EQUAL, treating NIL as an
unspecified value that refines or is refined; otherwise construction fails
with RESOURCE-CONFLICT.  Merged records preserve provider/consumer provenance
in PROVIDERS and CONSUMERS, in deterministic discovery order, deduplicated.

Geometry: START and EXTENT are assigned by the layout phase.  Their setters and
all provenance setters reject mutation once the owning configuration has been
activated.  RESOURCE-SEALED-P has no public writer (component runtime slots
remain mutable)."))

(defun make-resource (&key name (role :require) size granularity ownership lifetime atomicity)
  "Declare a resource fact: ROLE is :REQUIRE or :PROVIDE; the remaining
keyword arguments are the declaration attributes (NIL = unspecified)."
  (make-instance 'resource :name name :role role :size size
                 :granularity granularity :ownership ownership
                 :lifetime lifetime :atomicity atomicity))

(defmethod (setf resource-start) :before (value (resource resource))
  (declare (ignore value))
  (when (resource-sealed-p resource)
    (error 'configuration-sealed
           :fact (list :resource-geometry-immutable (resource-name resource)))))

(defmethod (setf resource-extent) :before (value (resource resource))
  (declare (ignore value))
  (when (resource-sealed-p resource)
    (error 'configuration-sealed
           :fact (list :resource-geometry-immutable (resource-name resource)))))

(defmethod (setf resource-providers) :before (value (resource resource))
  (declare (ignore value))
  (when (resource-sealed-p resource)
    (error 'configuration-sealed
           :fact (list :resource-provenance-immutable (resource-name resource)))))

(defmethod (setf resource-consumers) :before (value (resource resource))
  (declare (ignore value))
  (when (resource-sealed-p resource)
    (error 'configuration-sealed
           :fact (list :resource-provenance-immutable (resource-name resource)))))

;;; ---------------------------------------------------------------------
;;; Conditions.

(define-condition construction-error (error)
  ((component :initarg :component :initform nil
              :reader construction-error-component)
   (fact :initarg :fact :initform nil
         :reader construction-error-fact)
   (path :initarg :path :initform nil
         :reader construction-error-path))
  (:documentation "Every construction failure names the requiring COMPONENT,
the missing or conflicting FACT, and the dependency PATH from the
configuration root to COMPONENT.  Silent fallback is non-conforming."))

(define-condition dependency-cycle (construction-error) ())
(define-condition resource-conflict (construction-error) ())
(define-condition missing-resource (construction-error) ())
(define-condition component-failure (construction-error)
  ((phase :initarg :phase :reader component-failure-phase)
   (cause :initarg :cause :initform nil :reader component-failure-cause)))
(define-condition configuration-sealed (construction-error) ())

;;; ---------------------------------------------------------------------
;;; Configuration.

(defclass configuration ()
  ((components :initarg :components :accessor configuration-components)
   ;; Lifecycle code owns STATE.  It is readable but has no public SETF seam.
   (state :initform :building :reader configuration-state)
   (resources :initform nil :accessor configuration-resources)
   (resource-table :initform (make-hash-table :test #'equal)
                   :reader configuration-resource-table)
   (resource-facts :initform nil :accessor configuration-resource-facts)
   (bindings :initform (make-hash-table :test #'eq)
             :reader configuration-bindings)
   (constraints :initform nil :accessor configuration-constraints)
   (layout :initform nil :accessor configuration-layout)
   (phases :initform nil :accessor configuration-phases)
   (topological-order :initform nil :accessor configuration-topological-order)
   (initialized :initform nil :accessor configuration-initialized-components)
   (parent :initform (make-hash-table :test #'eq)
           :reader configuration-parent))
  (:documentation "Implementation record for one derived runtime
configuration (paper-v11: a plan is the root of an ordinary CLOS component
graph; construction derives a closed runtime configuration, it does not
invent an alternate collector language).

Lifecycle: BUILD-CONFIGURATION runs exactly seven phases --
:CONSTRUCT-DISCOVER, :MERGE, :LAYOUT-CALLBACK, :BIND, :INITIALIZE, :VALIDATE,
:ACTIVATE -- and records each completed phase in PHASES.  The configuration is
published (STATE :ACTIVE, setters sealed, entry appended to
*PUBLISHED-CONFIGURATIONS*) only after every earlier phase succeeds; a
failure in any earlier phase publishes nothing.

Immutable after activation: the component graph (COMPONENTS), the selected
LAYOUT, and resource geometry (RESOURCE-START / RESOURCE-EXTENT).  Runtime
counters, queues, marks, and component slots remain mutable."))

(defun configuration-active-p (configuration)
  (eq (configuration-state configuration) :active))

(defun %configuration-ever-activated-p (configuration)
  (member (configuration-state configuration) '(:active :inactive)))

(defun %set-configuration-state (configuration state)
  (setf (slot-value configuration 'state) state))

(defun %reject-sealed-configuration-write (configuration fact)
  (when (%configuration-ever-activated-p configuration)
    (error 'configuration-sealed :fact (list fact))))

(defmethod (setf configuration-components) :before (value (configuration configuration))
  (declare (ignore value))
  (%reject-sealed-configuration-write configuration :configuration-graph-immutable))

(defmethod (setf configuration-resources) :before (value (configuration configuration))
  (declare (ignore value))
  (%reject-sealed-configuration-write configuration :configuration-resources-immutable))

(defmethod (setf configuration-constraints) :before (value (configuration configuration))
  (declare (ignore value))
  (%reject-sealed-configuration-write configuration :configuration-constraints-immutable))

(defmethod (setf configuration-layout) :before (value (configuration configuration))
  (declare (ignore value))
  (%reject-sealed-configuration-write configuration :layout-immutable))

(defmethod (setf configuration-topological-order) :before
    (value (configuration configuration))
  (declare (ignore value))
  (%reject-sealed-configuration-write configuration :configuration-order-immutable))

(defmethod (setf configuration-phases) :before (value (configuration configuration))
  (declare (ignore value))
  (%reject-sealed-configuration-write configuration :configuration-phases-immutable))

(defmethod (setf configuration-resource-facts) :before
    (value (configuration configuration))
  (declare (ignore value))
  (%reject-sealed-configuration-write configuration :configuration-facts-immutable))

(defclass context ()
  ((configuration :initarg :configuration :reader context-configuration))
  (:documentation "Runtime context handed to INITIALIZE-, ACTIVATE-, and
DEACTIVATE-COMPONENT; carries the configuration being constructed."))

(defun find-resource (configuration name)
  "Bounded lookup: merged resource record named NAME, or NIL."
  (gethash name (configuration-resource-table configuration)))

(defun component-bindings (configuration component)
  "Resolved resource handles that replaced COMPONENT's resource
specifications during :BIND.  A fresh spine prevents callers from mutating the
activated configuration's binding table; the resource handles themselves are
sealed after activation."
  (copy-list (gethash component (configuration-bindings configuration))))

(defparameter *configuration-ledger-capacity* 2
  "Maximum number of published configurations retained in
*PUBLISHED-CONFIGURATIONS*.  NIL keeps every configuration.  The ledger is
a diagnostic registry: each entry retains the configuration's whole
component graph (plans, spaces, VM state), so an unbounded default is a
host-memory leak for any process that constructs many ephemeral
configurations.  *MOST-RECENT-CONFIGURATION* is always retained
regardless.")

(defparameter *published-configurations* ()
  "Bounded ledger of the most recently published configurations
(*CONFIGURATION-LEDGER-CAPACITY* controls the bound; NIL is unbounded).")

(defun %record-published-configuration (configuration)
  (push configuration *published-configurations*)
  (let ((capacity *configuration-ledger-capacity*))
    (when (and capacity (> (length *published-configurations*) capacity))
      (setf *published-configurations*
            (subseq *published-configurations* 0 capacity)))))

(defparameter *most-recent-configuration* nil
  "The configuration object of the most recent BUILD-CONFIGURATION call,
published or not; exists so diagnostics and tests can inspect failures.")

;;; ---------------------------------------------------------------------
;;; Deterministic helpers.

(defun path-to (configuration component)
  "Dependency path from a configuration root to COMPONENT (first-parent
order, deterministic)."
  (let ((parent (configuration-parent configuration))
        (path (list component)))
    (do ((ancestor (gethash component parent) (gethash ancestor parent)))
        ((null ancestor) path)
      (push ancestor path))))

(defun call-component-phase (configuration component phase fact thunk)
  "Invoke a component-supplied hook and preserve construction diagnostics.
Other errors are wrapped with the requiring component, phase, dependency path,
and original cause instead of escaping without construction context."
  (handler-case (funcall thunk)
    (construction-error (condition) (error condition))
    (error (cause)
      (error 'component-failure
             :component component :phase phase :fact fact
             :path (and component (path-to configuration component))
             :cause cause))))

(defun attribute-compatible-p (a b)
  "EQUAL agreement; NIL counts as an unspecified value that either side may
refine."
  (or (equal a b) (null a) (null b)))

(defun resource-compatible-p (new existing)
  (and (attribute-compatible-p (resource-size new) (resource-size existing))
       (attribute-compatible-p (resource-granularity new) (resource-granularity existing))
       (attribute-compatible-p (resource-ownership new) (resource-ownership existing))
       (attribute-compatible-p (resource-lifetime new) (resource-lifetime existing))
       (attribute-compatible-p (resource-atomicity new) (resource-atomicity existing))))

(defun resource-attributes (resource)
  (list :size (resource-size resource)
        :granularity (resource-granularity resource)
        :ownership (resource-ownership resource)
        :lifetime (resource-lifetime resource)
        :atomicity (resource-atomicity resource)))

(defun merge-resource-attributes (existing new)
  "Refine unspecified canonical attributes from NEW after compatibility was
proved.  This prevents a first, underspecified requirement from erasing a
later provider's concrete size, granularity, ownership, lifetime, or
atomicity."
  (dolist (slot '(size granularity ownership lifetime atomicity))
    (when (and (null (slot-value existing slot))
               (slot-value new slot))
      (setf (slot-value existing slot) (slot-value new slot))))
  existing)

(defun note-provenance (configuration resource component role)
  (case role
    (:provide
     (unless (member component (resource-providers resource) :test #'eq)
       (setf (resource-providers resource)
             (append (resource-providers resource) (list component)))))
    (:require
     (unless (member component (resource-consumers resource) :test #'eq)
       (setf (resource-consumers resource)
             (append (resource-consumers resource) (list component)))))
    (t (error 'resource-conflict
              :component component
              :fact (list :bad-resource-role role)
              :path (path-to configuration component)))))

;;; ---------------------------------------------------------------------
;;; The seven phases.

(defun phase-construct-discover (configuration)
  ;; Deterministic depth-first traversal in declaration order.  Postorder
  ;; yields dependency-first order; finished nodes deduplicate diamonds.
  (let ((topo ()) (facts ())
        (color (make-hash-table :test #'eq))
        (parent (configuration-parent configuration))
        (stack ()))
    (labels ((proper-list-p (value)
               (or (null value)
                   (let ((length (ignore-errors (list-length value))))
                     (integerp length))))
             (component-list (component operation thunk)
               (let ((value (call-component-phase
                             configuration component :construct-discover
                             (list operation) thunk)))
                 (unless (proper-list-p value)
                   (error 'component-failure
                          :component component :phase :construct-discover
                          :fact (list operation :expected-proper-list value)
                          :path (path-to configuration component)))
                 value))
             (visit (component)
               (unless (typep component 'component)
                 (error 'component-failure
                        :component (first stack) :phase :construct-discover
                        :fact (list :invalid-dependency component)
                        :path (and (first stack)
                                   (path-to configuration (first stack)))))
               (ecase (gethash component color :white)
                 (:white
                  (setf (gethash component color) :gray)
                  (push component stack)
                  (dolist (dependency
                           (component-list
                            component :component-dependencies
                            (lambda () (component-dependencies component))))
                    ;; Presence, not the parent value, matters: roots are
                    ;; deliberately present with NIL parents.  A back-edge
                    ;; must never overwrite one and create a cyclic PATH-TO.
                    (multiple-value-bind (old present-p)
                        (gethash dependency parent)
                      (declare (ignore old))
                      (unless present-p
                        (setf (gethash dependency parent) component)))
                    (visit dependency))
                  (pop stack)
                  (setf (gethash component color) :black)
                  (push component topo)
                  (dolist (fact
                           (component-list
                            component :component-resources
                            (lambda () (component-resources component))))
                    (unless (typep fact 'resource)
                      (error 'component-failure
                             :component component :phase :construct-discover
                             :fact (list :invalid-resource fact)
                             :path (path-to configuration component)))
                    (push (cons component fact) facts)))
                 (:gray
                  (let* ((requiring (first stack))
                         (requiring-cohort
                           (call-component-phase
                            configuration requiring :construct-discover
                            (list :component-cohort)
                            (lambda () (component-cohort requiring))))
                         (target-cohort
                           (call-component-phase
                            configuration component :construct-discover
                            (list :component-cohort)
                            (lambda () (component-cohort component)))))
                    (unless (and requiring-cohort
                                 (eql requiring-cohort target-cohort))
                      (error 'dependency-cycle
                             :component requiring
                             :fact (list :ordinary-dependency-cycle)
                             :path (reverse (cons component stack))))))
                 (:black))))
      (unless (configuration-components configuration)
        (error 'component-failure :component nil :phase :construct-discover
               :fact (list :missing-configuration-root) :path nil))
      (dolist (root (configuration-components configuration))
        (unless (typep root 'component)
          (error 'component-failure :component root
                 :phase :construct-discover
                 :fact (list :invalid-configuration-root root)
                 :path (list root)))
        (setf (gethash root parent) nil))
      (dolist (root (configuration-components configuration))
        (visit root)))
    (setf (configuration-topological-order configuration) (nreverse topo)
          (configuration-resource-facts configuration) (nreverse facts))))

(defun phase-merge (configuration)
  ;; Merge requirements and constraints before layout.  A missing provider is
  ;; a merge failure, so no layout callback observes an impossible graph.
  (let ((table (configuration-resource-table configuration))
        (constraints ()))
    (dolist (component (configuration-topological-order configuration))
      (let ((declared
              (call-component-phase
               configuration component :merge (list :component-constraints)
               (lambda () (component-constraints component)))))
        (unless (or (null declared)
                    (integerp (ignore-errors (list-length declared))))
          (error 'component-failure
                 :component component :phase :merge
                 :fact (list :component-constraints :expected-proper-list
                             declared)
                 :path (path-to configuration component)))
        (dolist (constraint declared)
          (pushnew constraint constraints :test #'equal))))
    (dolist (entry (configuration-resource-facts configuration))
      (let* ((component (car entry))
             (fact (cdr entry))
             (name (resource-name fact)))
        (unless name
          (error 'resource-conflict :component component
                 :fact (list :unnamed-resource)
                 :path (path-to configuration component)))
        (unless (member (resource-role fact) '(:provide :require))
          (error 'resource-conflict :component component
                 :fact (list :bad-resource-role (resource-role fact))
                 :path (path-to configuration component)))
        (let ((existing (gethash name table)))
          (cond ((null existing)
                 (setf (gethash name table) fact)
                 (note-provenance configuration fact component
                                  (resource-role fact)))
                ((resource-compatible-p fact existing)
                 (merge-resource-attributes existing fact)
                 (note-provenance configuration existing component
                                  (resource-role fact)))
                (t
                 (error 'resource-conflict
                        :component component
                        :fact (list :resource-conflict name
                                    :existing (resource-attributes existing)
                                    :offending (resource-attributes fact))
                        :path (path-to configuration component)))))))
    (let ((merged ()) (seen ()))
      (dolist (entry (configuration-resource-facts configuration))
        (let ((record (gethash (resource-name (cdr entry)) table)))
          (unless (member record seen :test #'eq)
            (push record seen)
            (push record merged))))
      (setf (configuration-resources configuration) (nreverse merged)
            (configuration-constraints configuration) (nreverse constraints)))
    (dolist (resource (configuration-resources configuration))
      (when (and (resource-consumers resource)
                 (null (resource-providers resource)))
        (let ((requiring (first (resource-consumers resource))))
          (error 'missing-resource
                 :component requiring
                 :fact (list :missing-resource (resource-name resource))
                 :path (path-to configuration requiring)))))))

(defun phase-layout-callback (configuration layout)
  ;; The client callback solves managed ranges within client-offered arenas,
  ;; assigns resource geometry, and returns the immutable layout product.
  (when layout
    (let ((root (first (configuration-components configuration))))
      (setf (configuration-layout configuration)
            (call-component-phase
             configuration root :layout-callback (list :layout-callback)
             (lambda () (funcall layout configuration)))))))

(defun phase-bind (configuration)
  ;; Missing providers were rejected during merge.  Replace each requirement
  ;; declaration by the one canonical resolved handle.
  (let ((bindings (configuration-bindings configuration))
        (table (configuration-resource-table configuration)))
    (dolist (entry (configuration-resource-facts configuration))
      (let ((component (car entry))
            (fact (cdr entry)))
        (when (eq (resource-role fact) :require)
          (setf (gethash component bindings)
                (append (gethash component bindings)
                        (list (gethash (resource-name fact) table)))))))))

(defun phase-initialize (configuration)
  (let ((context (make-instance 'context :configuration configuration)))
    (dolist (component (configuration-topological-order configuration))
      (call-component-phase
       configuration component :initialize (list :initialize-component)
       (lambda () (initialize-component component context)))
      (setf (configuration-initialized-components configuration)
            (append (configuration-initialized-components configuration)
                    (list component))))))

(defun phase-validate (configuration)
  (dolist (component (configuration-topological-order configuration))
    (unless (call-component-phase
             configuration component :validate (list :validate-component)
             (lambda () (validate-component component configuration)))
      (error 'component-failure
             :component component :phase :validate
             :fact (list :validation-failed)
             :path (path-to configuration component)))))

(defun phase-activate (configuration)
  ;; Hooks run before publication and are wrapped with component/path context.
  ;; If one fails, BUILD-CONFIGURATION deactivates every initialized component
  ;; in reverse order and never publishes the configuration.
  (let ((context (make-instance 'context :configuration configuration)))
    (dolist (component (configuration-topological-order configuration))
      (call-component-phase
       configuration component :activate (list :activate-component)
       (lambda () (activate-component component context))))))

(defun rollback-configuration (configuration)
  "Best-effort reverse cleanup after initialization began but publication did
not occur.  Cleanup failures cannot replace the original construction error."
  (let ((context (make-instance 'context :configuration configuration)))
    (dolist (component (reverse
                        (configuration-initialized-components configuration)))
      (ignore-errors (deactivate-component component context))))
  (setf (configuration-initialized-components configuration) nil)
  configuration)

(defun publish-configuration (configuration)
  "Seal and publish after every fallible construction action succeeded."
  (dolist (resource (configuration-resources configuration))
    (setf (slot-value resource 'sealed) t))
  ;; Internal lifecycle writes use SLOT-VALUE; no public state or seal writer
  ;; exists that could reopen an activated configuration.
  (setf (slot-value configuration 'phases)
        (append (configuration-phases configuration) (list :activate)))
  (%set-configuration-state configuration :active)
  (%record-published-configuration configuration)
  configuration)

;;; ---------------------------------------------------------------------
;;; Construction entry point.

(defun build-configuration (roots &key layout)
  "Construct and publish the runtime configuration for ROOTS (a component or
proper list of components).  LAYOUT, when supplied, is a client callback of
one argument that returns the installed layout product.  Returns the activated
configuration; every failure publishes nothing and carries phase/context."
  (let* ((root-list (if (typep roots 'component)
                        (list roots)
                        (if (or (null roots)
                                (integerp (ignore-errors (list-length roots))))
                            (copy-list roots)
                            (list roots))))
         (configuration (make-instance 'configuration :components root-list))
         (current-phase :construct-discover))
    (setf *most-recent-configuration* configuration)
    (labels ((record-completed-phase (name)
               (setf (configuration-phases configuration)
                     (append (configuration-phases configuration) (list name))))
             (run-phase (name thunk)
               (setf current-phase name)
               (funcall thunk)
               (record-completed-phase name)))
      (handler-case
          (progn
            (run-phase :construct-discover
                       (lambda () (phase-construct-discover configuration)))
            (run-phase :merge (lambda () (phase-merge configuration)))
            (run-phase :layout-callback
                       (lambda () (phase-layout-callback configuration layout)))
            (run-phase :bind (lambda () (phase-bind configuration)))
            (run-phase :initialize (lambda () (phase-initialize configuration)))
            (run-phase :validate (lambda () (phase-validate configuration)))
            (setf current-phase :activate)
            (phase-activate configuration)
            (publish-configuration configuration))
        (construction-error (condition)
          (unless (configuration-active-p configuration)
            (rollback-configuration configuration))
          (error condition))
        (error (cause)
          (unless (configuration-active-p configuration)
            (rollback-configuration configuration))
          (let ((root (first (configuration-components configuration))))
            (error 'component-failure
                   :component root :phase current-phase
                   :fact (list :construction-phase-failed current-phase)
                   :path (and root (list root)) :cause cause)))))
    configuration))

(defun deactivate-configuration (configuration)
  "Deactivate in reverse dependency order.  Deactivation changes lifecycle
state but never unseals graph, layout, provenance, or geometry: a configuration
that was once activated remains immutable."
  (when (configuration-active-p configuration)
    (let ((context (make-instance 'context :configuration configuration)))
      (dolist (component (reverse (configuration-topological-order configuration)))
        (call-component-phase
         configuration component :deactivate (list :deactivate-component)
         (lambda () (deactivate-component component context)))))
    (setf (configuration-initialized-components configuration) nil)
    (%set-configuration-state configuration :inactive))
  configuration)
