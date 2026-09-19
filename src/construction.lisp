;;;; construction.lisp -- the paper-v11 construction engine (composition.tex).
;;;;
;;;; A plan is the root of an ordinary CLOS component graph.  CONSTRUCT-PLAN
;;;; compiles that graph through exactly seven phases into exactly one
;;;; published runtime configuration:
;;;;
;;;;   construct-discover : dependencies, logical resources, constraints,
;;;;                        metadata specifications (composition.lisp seams)
;;;;   merge              : resource compatibility with provenance
;;;;   layout-callback    : the plan solves managed ranges within the
;;;;                        client-offered arenas (build-managed-layout),
;;;;                        adopts the solution's regions, and binds every
;;;;                        logical metadatum (merge-metadata + bind-metadata)
;;;;   bind               : resolved resource handles replace declarations
;;;;   initialize         : fallible allocator/storage construction
;;;;                        (spaces) and plan-owned runtime storage
;;;;   validate           : cross-component coherence checks
;;;;   activate           : publication; activation hooks stay short
;;;;
;;;; Algorithm bodies (tracing, barriers, phases, allocators) remain in the
;;;; domain protocols: construction derives their ranges, metadata
;;;; placements, and published configuration, and does not restate them
;;;; (composition.tex: collection behavior is not descriptors).
;;;;
;;;; Simulator profile facts this engine states explicitly:
;;;;   - One machine address unit is one simulator word; the offered arena
;;;;     is the word-addressed heap, page 0 an implementation reservation.
;;;;   - Collection-time work storage (tracer, barrier buffers, finalizer
;;;;     vectors, published-root sets) is host storage in this profile, so
;;;;     it is provisioned once during :INITIALIZE from the heap geometry
;;;;     rather than placed as an in-arena :WORK-STORAGE region.  It is
;;;;     boot-sized once and never grows: hidden emergency allocation is
;;;;     still forbidden (managed-layout.tex section 4, invariant 6).

(in-package #:clamsara)

(defmethod component-dependencies ((p plan))
  "The plan's component graph: its spaces, then its barrier and
  publication strategy.  Discovery traverses exactly these, so every
  space's logical resource merges before layout and every component's
  metadata specifications bind.  Allocators are not in the graph: they
  are derived state built during :INITIALIZE from the solved geometry."
  (remove nil (append (plan-spaces p)
                      (and (plan-barrier p) (list (plan-barrier p)))
                      (and (plan-publication p) (list (plan-publication p))))))

(defmethod component-placement-requests ((p plan))
  "A plan contributes the placement requests of its component graph: its
  own shared requests plus every dependency's (spaces and, later, other
  components)."
  (mapcan #'component-placement-requests (plan-spaces p)))

(defmethod component-metadata-specifications ((p plan))
  "The default metadata set every plan contributes at discovery: the
  tracing mark, the movement forwarding result, and weak-pointer identity.
  Specialized plans append or narrow it."
  (let ((vm (plan-vm p)))
    (list (mark-specification vm)
          (forwarding-specification vm)
          (weak-specification vm))))

(defun compute-space-pages (total-pages fractions
                            &key (los-fraction 1/16) (los-minimum 4))
  "Preferred page counts for a plan's spaces: split the usable pages
  (page 0 is the null-sentinel reservation) among FRACTIONS after the
  large-object space takes its share, so the preferred extents sum to what
  the offered arena can actually assign.  The last fraction absorbs the
  rounding slack.  Returns (VALUES COUNTS LOS-PAGES); placement itself is
  the layout builder's decision."
  (let* ((usable (max 0 (1- total-pages)))
         (los (min (max los-minimum (floor (* usable los-fraction)))
                   (max 0 (- usable (length fractions)))))
         (shared (- usable los))
         (head-counts (mapcar (lambda (f) (floor (* shared f)))
                              (butlast fractions)))
         (counts (append head-counts
                         (list (max 0 (- shared
                                         (reduce #'+ head-counts
                                                 :initial-value 0)))))))
    (values counts los)))

(defun make-plan-spaces (vm specs &key (los-fraction 1/16))
  "Instantiate a plan's spaces plus the shared large-object space from
SPECS, each spec a (CLASS FRACTION NAME . INITARGS) list.  Preferred page
counts come from the budget split over the client's offered arena;
geometry itself is the layout builder's decision at construction, and the
returned list ends with the LOS space (whole-page allocations, its own
region, minimum four pages)."
  (multiple-value-bind (counts los-pages)
      (compute-space-pages (vm-page-count vm)
                           (mapcar #'second specs)
                           :los-fraction los-fraction)
    (append
     (mapcar (lambda (spec count)
               (destructuring-bind (class fraction name . initargs) spec
                 (declare (ignore fraction))
                 (apply #'make-instance class
                        :vm vm :name name :preferred-pages count initargs)))
             specs counts)
     (list (make-instance 'los-space :vm vm :name :los
                          :preferred-pages los-pages :min-pages 4)))))

;;; ---------------------------------------------------------------------
;;; The layout callback (composition.tex "Lay out" + strata.tex "binding").

(defun %check-request-consistency (plan configuration requests)
  "Every space of the plan contributes exactly one request and one logical
  resource under the same semantic name; a space the solver cannot name is
  a construction defect, never a fallback case."
  (dolist (space (plan-spaces plan))
    (let ((name (space-name space)))
      (unless (find name requests :key #'request-name)
        (error 'clamsara-error
               :message (format nil "space ~a contributed no placement request"
                                name)))
      (unless (find-resource configuration name)
        (error 'clamsara-error
               :message (format nil "space ~a contributed no logical resource"
                                name))))))

(defun solve-plan-layout (plan configuration)
  "The plan's :LAYOUT-CALLBACK phase: solve the managed layout for the
  graph's placement requests inside the client's offered arenas, assign
  merged-resource geometry, adopt the solution's regions into the spaces,
  and bind every logical metadatum.  Returns the installed layout product
  (the configuration's immutable layout)."
  (let* ((vm (plan-vm plan))
         (requests (component-placement-requests plan))
         (layout (progn
                   (%check-request-consistency plan configuration requests)
                   (build-managed-layout vm requests))))
    ;; Assign merged-resource geometry from the solved regions; the bind
    ;; phase then hands each requiring component its resolved handle.
    (dolist (resource (configuration-resources configuration))
      (let ((region (find-solution-region layout (resource-name resource))))
        (setf (resource-start resource) (region-start region)
              (resource-extent resource) (region-extent region))))
    ;; Adopt the regions into the spaces (spaces.tex: a space's start
    ;; address is a result of layout construction, not authored
    ;; configuration).
    (dolist (space (plan-spaces plan))
      (let ((region (find-solution-region layout (space-name space))))
        (unless region
          (error 'clamsara-error
                 :message (format nil
                                  "the solved layout assigned no region to space ~a"
                                  (space-name space))))
        (%assign-space-region space region)))
    ;; Merge and bind every logical metadatum contributed at discovery.
    (let* ((contributions
             (loop for component in (configuration-topological-order configuration)
                   nconc (mapcar (lambda (spec)
                                   (make-contribution component spec))
                                 (component-metadata-specifications component))))
           (registry (merge-metadata contributions))
           (binding (bind-metadata registry
                       :object-model vm
                       :field-guarantees #'simulator-field-guarantees
                       :layout (simulator-metadata-supply vm)
                       :base (vm-heap-base vm)
                       :extent (vm-heap-size vm))))
      (setf (plan-metadata-registry plan) registry
            (plan-metadata-binding plan) binding)
      (install-bound-metadata vm binding))
    (setf (plan-managed-layout plan) layout)
    layout))

(defgeneric construct-plan (plan)
  (:documentation "Compile the plan's component graph through the seven
  paper-v11 construction phases and publish exactly one runtime
  configuration.  Every failure publishes nothing and names the requiring
  component, the conflicting fact, and the dependency path
  (composition.tex).")
  (:method ((plan plan))
    (let ((configuration
            (build-configuration
             plan
             :layout (lambda (configuration)
                       (solve-plan-layout plan configuration)))))
      (setf (plan-configuration plan) configuration)
      plan)))

;;; ---------------------------------------------------------------------
;;; Plan construction-phase hooks.  Spaces are dependencies of the plan, so
;;; their :INITIALIZE (storage + allocator construction) runs first; the
;;; plan's own hook then builds plan-owned runtime storage, and :VALIDATE
;;; runs the cross-component checks.  :ACTIVATE is the short publication
;;; step: every fallible action already ran.

(defmethod initialize-component ((p plan) context)
  (declare (ignore context))
  (let ((vm (plan-vm p)))
    ;; Finalization storage is part of normal plan setup (weak.tex §2).
    (%initialize-finalization-vectors p vm)
    ;; Plan-owned runtime storage: boot-sized once, never grown at runtime.
    (setf (plan-tracer p) (or (plan-tracer p) (make-tracer vm))
          (plan-stats p) (or (plan-stats p) (make-stats)))
    (stats-prepare (plan-stats p))
    (when (plan-barrier p)
      (initialize-barrier-buffers (plan-barrier p) vm))
    (when (plan-publication p)
      (initialize-publication-work (plan-publication p) vm))
    ;; The SFT is the dense page-descriptor realization of the installed
    ;; solution (managed-layout.tex section 5 names the realization family).
    (plan-build-sft p)))

(defmethod validate-component ((p plan) configuration)
  ;; The plan's coherence checks (plans.tex §1), after every component's
  ;; fallible initialization succeeded: plan constraints, space/allocator
  ;; coherence, and barrier-rule coherence.
  (declare (ignore configuration))
  (component-validate p)
  (dolist (space (plan-spaces p))
    (component-validate space)
    (when (and (slot-boundp space 'allocator) (space-allocator space))
      (component-validate (space-allocator space))))
  (when (plan-barrier p)
    (barrier-check (plan-barrier p) p))
  p)

(defmethod activate-component ((p plan) context)
  ;; Activation is the short publication step (composition.tex): the kernel
  ;; publishes the configuration after every activate hook succeeds.
  (declare (ignore context))
  (setf (plan-booted-p p) t))

(defmethod deactivate-component ((p plan) context)
  (declare (ignore context))
  (setf (plan-booted-p p) nil))
