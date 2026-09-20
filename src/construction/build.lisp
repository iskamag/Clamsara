;;;; src/construction/build.lisp -- transactional v14 construction.

(in-package #:clamsara)

(defun %call-client-selector (clients name function)
  (let ((value
          (handler-case (funcall function clients)
            (error (condition)
              (%reject :client-selector-signaled
                       (list (list :clients name)) condition)))))
    (unless value
      (%reject :missing-required-client (list (list :clients name))))
    value))

(defun %record-transaction (construction kind identity payload)
  (let ((entry (%make-transaction-entry
                :kind kind :identity identity :payload payload
                :released-p nil)))
    ;; Newest first is the strict reverse-acquisition traversal.
    (push entry (%context-transaction-log construction))
    entry))

(defun %resource-placement-pair (description construction)
  (let ((identity (%resource-description-placement-identity description)))
    (when identity
      (multiple-value-bind (base limit present-p)
          (construction-placement construction identity)
        (unless present-p
          (%reject :missing-solved-resource-placement
                   (list (%resource-description-path description))))
        (cons base limit)))))

(defun %acquire-resource (description clients construction target-maximum)
  (let* ((identity (%resource-description-identity description))
         (placement (%resource-placement-pair description construction))
         (path (%resource-description-path description))
         (values
           (handler-case
               (multiple-value-list
                (%acquire-construction-resource clients construction description
                                                (and placement
                                                     (cons (car placement)
                                                           (cdr placement)))))
             (error (condition)
               (%reject :resource-acquisition-signaled (list path) condition)))))
    ;; Returning the wrong shape after an effect is a provider contract fault.
    ;; A conforming provider returns the release capability in the same atomic
    ;; handoff; it signals before effects otherwise.
    (unless (= (length values) 5)
      (%reject :wrong-resource-acquisition-values (list path)))
    (destructuring-bind
        (handle physical-bytes entry-capacity auxiliary-bytes release-capability)
        values
      (let ((state (%make-resource-state
                    :description description :handle handle
                    :physical-bytes physical-bytes
                    :entry-capacity entry-capacity
                    :auxiliary-bytes auxiliary-bytes
                    :release-capability release-capability :released-p nil)))
        ;; Log before validating any returned field.
        (setf (gethash identity (%context-resources construction)) state)
        (%record-transaction construction :resource identity state)
        (dolist (pair `((,physical-bytes
                         . ,(%resource-description-minimum-physical-bytes
                             description))
                        (,entry-capacity
                         . ,(%resource-description-logical-entry-bound
                             description))
                        (,auxiliary-bytes
                         . ,(%resource-description-auxiliary-bytes
                             description))))
          (unless (and (%nonnegative-integer-p (car pair))
                       (<= (car pair) target-maximum)
                       (>= (car pair) (cdr pair)))
            (%reject :insufficient-or-invalid-resource-capacity (list path))))
        (when (and placement
                   (> physical-bytes (- (cdr placement) (car placement))))
          (%reject :resource-does-not-fit-placement (list path)))
        state))))

(defmethod release-construction-resource
    ((construction %construction-context) identity handle)
  (let ((state (gethash identity (%context-resources construction))))
    ;; Cleanup explicitly tolerates absent and repeated local release.
    (unless state (return-from release-construction-resource (values)))
    (when (%resource-state-released-p state)
      (return-from release-construction-resource (values)))
    (unless (eq handle (%resource-state-handle state))
      (%reject :resource-release-handle-mismatch
               (list (%resource-description-path
                      (%resource-state-description state)))))
    (unless (member (%context-state construction)
                    '(:unwinding :closing :released) :test #'eql)
      (%reject :resource-release-outside-lifecycle
               (list (%resource-description-path
                      (%resource-state-description state)))))
    (%release-acquired-construction-resource
     (configuration-clients (construction-configuration construction))
     (%resource-state-release-capability state))
    (setf (%resource-state-released-p state) t)
    (values)))

(defun %release-transaction-entry (entry configuration)
  (when (%transaction-entry-released-p entry)
    (return-from %release-transaction-entry (values)))
  (ecase (%transaction-entry-kind entry)
    (:resource
     (let ((state (%transaction-entry-payload entry)))
       (release-construction-resource
        (%configuration-construction configuration)
        (%transaction-entry-identity entry)
        (%resource-state-handle state))))
    (:layout
     (destructuring-bind (address-client release-capability)
         (%transaction-entry-payload entry)
       (release-managed-layout address-client release-capability))))
  (setf (%transaction-entry-released-p entry) t)
  (values))

(defun %install-reference-layout
    (reference-layout address-client configuration construction)
  (handler-case (validate-managed-layout address-client reference-layout)
    (error (condition)
      (%reject :managed-layout-validation-signaled
               (list '(:clients :address-space :validate-managed-layout))
               condition)))
  (let ((values
          (handler-case
              (multiple-value-list
               (install-managed-layout address-client reference-layout))
            (error (condition)
              ;; A signaling install is required to retain no state.
              (%reject :managed-layout-install-signaled
                       (list '(:clients :address-space
                               :install-managed-layout))
                       condition)))))
    (unless (= (length values) 2)
      (%reject :wrong-managed-layout-install-values
               (list '(:clients :address-space :install-managed-layout))))
    (let ((installed-layout (first values))
          (release-capability (second values)))
      (unless installed-layout
        (%reject :nil-installed-layout
                 (list '(:clients :address-space :install-managed-layout))))
      ;; Log before any use or later validation.
      (%record-transaction construction :layout :managed-layout
                           (list address-client release-capability))
      (setf (%configuration-layout configuration) installed-layout)
      installed-layout)))

(defun %checked-claim-sums (barriers resource-table construction target-maximum)
  (let ((sums (make-hash-table :test #'eql)))
    (loop for barrier across barriers
          do (dolist (claim (%barrier-description-claims barrier))
               (let* ((key (second (%claim-description-resource-designator
                                    claim)))
                      (old (gethash key sums 0))
                      (new (%checked-target-add
                            old (%claim-description-maximum-live-entries claim)
                            target-maximum (%claim-description-path claim))))
                 (setf (gethash key sums) new))))
    (maphash
     (lambda (identity required)
       (multiple-value-bind (handle present-p physical capacity auxiliary)
           (construction-resource construction identity)
         (declare (ignore handle physical auxiliary))
         (unless present-p
           (%reject :barrier-claim-resource-not-acquired
                    (list (%resource-description-path
                           (gethash identity resource-table)))))
         (when (> required capacity)
           (%reject :barrier-claim-capacity-exhausted
                    (list (%resource-description-path
                           (gethash identity resource-table)))))))
     sums)
    sums))

(defun %validate-complete-constraints
    (constraints construction address-client resource-table placement-table
     target-maximum)
  (dolist (constraint constraints)
    (multiple-value-bind (satisfied-p ready-p)
        (%constraint-satisfied-p constraint construction address-client
                                 resource-table placement-table target-maximum)
      (unless ready-p
        (%reject :incomplete-constraint-values
                 (%constraint-paths constraint resource-table placement-table)))
      (unless satisfied-p
        (%reject :construction-constraint-false
                 (%constraint-paths constraint resource-table placement-table))))))

(defun %validate-space-map-declarations (nodes)
  (loop for node across nodes
        when (%component-node-space-p node)
          do (let ((map (%component-node-object-start-map node)))
               (unless (typep map 'component)
                 (%reject :object-start-map-is-not-component
                          (list (%component-node-path node))))
               (unless (member map (%component-node-dependencies node)
                               :test #'eq)
                 (%reject :object-start-map-is-not-direct-dependency
                          (list (%component-node-path node))))
               (unless (%find-node nodes map)
                 (%reject :object-start-map-outside-graph
                          (list (%component-node-path node)))))))

(defun %binding-phase-groups (groups nodes)
  "Return pre-binding and post-binding groups, rejecting a map held behind a
space/model-consuming group before any component initialization occurs."
  (let ((post-table (make-hash-table :test #'eq))
        (pre nil)
        (post nil))
    (dolist (group groups)
      (let ((post-p
              (or (some (lambda (node)
                          (or (%component-node-space-p node)
                              (handler-case
                                  (component-requires-bound-object-model-p
                                   (%component-node-component node))
                                (error (condition)
                                  (%reject :binding-marker-signaled
                                           (list (%component-node-path node))
                                           condition)))))
                        (%initialization-group-nodes group))
                  (some (lambda (dependency)
                          (gethash dependency post-table))
                        (%initialization-group-dependencies group)))))
        (setf (gethash group post-table) post-p)
        (if post-p (push group post) (push group pre))))
    (setf pre (nreverse pre)
          post (nreverse post))
    (loop for node across nodes
          when (%component-node-space-p node)
            do (let* ((map (%component-node-object-start-map node))
                      (map-node (%find-node nodes map))
                      (map-group
                        (find-if (lambda (group)
                                   (member map-node
                                           (%initialization-group-nodes group)
                                           :test #'eq))
                                 groups)))
                 (when (gethash map-group post-table)
                   (%reject :object-model-binding-order-impossible
                            (list (%component-node-path node)
                                  (%component-node-path map-node))))))
    (values pre post)))

(defun %initialize-group (group configuration construction)
  (dolist (node (%initialization-group-nodes group))
    (let ((component (%component-node-component node)))
      ;; Begun is recorded before entry, so partial initialization unwinds.
      (setf (%configuration-initialization-order configuration)
            (append (%configuration-initialization-order configuration)
                    (list component)))
      (initialize-component component construction)
      (setf (%component-node-initialized-p node) t))))

(defun %bind-configuration-object-model
    (nodes offered-model configuration construction)
  (declare (ignore construction))
  (let ((bindings
          (loop for node across nodes
                when (%component-node-space-p node)
                  collect
                  (let* ((space (%component-node-component node))
                         (map (%component-node-object-start-map node))
                         (path (append (%component-node-path node)
                                       (list :object-start-binding)))
                         (binding
                           (handler-case
                               (make-object-start-binding offered-model space map)
                             (error (condition)
                               (%reject :object-start-binding-signaled
                                        (list path) condition))))
                         (description
                           (%multiple-at-path
                            (append path (list :description))
                            #'describe-object-start-binding offered-model
                            binding)))
                    (unless (= (length description) 2)
                      (%reject :wrong-object-start-binding-values (list path)))
                    (unless (and (eq (first description) space)
                                 (eq (second description) map))
                      (%reject :object-start-binding-mismatch (list path)))
                    binding))))
    (let ((bound
            (handler-case
                (bind-object-model offered-model
                                   (%configuration-layout configuration)
                                   (coerce bindings 'simple-vector))
              (error (condition)
                (%reject :bind-object-model-signaled
                         (list '(:clients :object-model :bind)) condition)))))
      (unless bound
        (%reject :nil-bound-object-model
                 (list '(:clients :object-model :bind))))
      (setf (%configuration-object-model configuration) bound
            (%configuration-object-model-bound-p configuration) t)
      bound)))

(defun %admit-continuing-cohorts (groups coordinator construction)
  (dolist (group groups)
    (when (and (%initialization-group-cyclic-p group)
               (%initialization-group-continuing-p group))
      (let ((values
              (handler-case
                  (multiple-value-list
                   (%admit-continuing-cohort-progress
                    coordinator
                    (coerce (mapcar #'%component-node-component
                                    (%initialization-group-nodes group))
                            'simple-vector)
                    construction))
                (error (condition)
                  (%reject :cohort-progress-admission-signaled
                           (mapcar #'%component-node-path
                                   (%initialization-group-nodes group))
                           condition)))))
        (unless (first values)
          (%reject (or (second values) :cohort-progress-not-admitted)
                   (mapcar #'%component-node-path
                           (%initialization-group-nodes group))))))))

(defun %register-configuration-auxiliary (construction object)
  (unless (fboundp '%register-resource-auxiliary)
    (%reject :resource-auxiliary-registrar-unavailable))
  (handler-case
      (%register-resource-auxiliary construction :configuration-auxiliary object)
    (error (condition)
      (%reject :configuration-auxiliary-registration-failed nil condition)))
  object)

(defun %register-owner-auxiliary-storage (construction clients nodes)
  "Charge each explicitly owned retained object once, without graph reflection."
  (let ((storage-seen (make-hash-table :test #'eq))
        (*construction-auxiliary-owner-seen* (make-hash-table :test #'eq)))
    (labels ((register (object)
               (when (and object (not (gethash object storage-seen)))
                 (setf (gethash object storage-seen) t)
                 (%register-configuration-auxiliary construction object)))
             (map-owner (owner path)
               (handler-case
                   (%map-construction-auxiliary-once owner #'register)
                 (error (condition)
                   (%reject :auxiliary-storage-enumeration-failed
                            (list path) condition)))))
      (map-owner clients '(:clients))
      (dotimes (index (length nodes))
        (let ((node (aref nodes index)))
          (map-owner (%component-node-component node)
                     (%component-node-path node))))))
  (values))

(defun %register-builder-tree (construction root)
  "Register every builder-owned retained object and every cons/vector/hash
backing it.  Component/client/host objects are registered by their owners."
  (let ((seen (make-hash-table :test #'eq)))
    (labels ((walk (object)
               (when (and object
                          (or (consp object)
                              (vectorp object)
                              (hash-table-p object)
                              (typep object 'structure-object)
                              (typep object '%configuration)
                              (typep object '%construction-context)
                              (typep object '%reference-layout)))
                 (unless (gethash object seen)
                   (setf (gethash object seen) t)
                   (%register-configuration-auxiliary construction object)
                   (typecase object
                     (cons
                      (walk (car object))
                      (walk (cdr object)))
                     (string nil)
                     (vector (map nil #'walk object))
                     (hash-table
                      (maphash (lambda (key value)
                                 (declare (ignore key))
                                 (walk value))
                               object))
                     (%configuration
                      (walk (%configuration-graph object))
                      (walk (%configuration-component-order object))
                      (walk (%configuration-construction object))
                      (walk (%configuration-barrier object))
                      (walk (%configuration-capacity-account object))
                      (walk (%configuration-result-schema object))
                      (walk (%configuration-initialization-order object)))
                     (%construction-context
                      (walk (%context-resources object))
                      (walk (%context-placements object))
                      (walk (%context-transaction-log object)))
                     (%reference-layout
                      (walk (%layout-arena object))
                      (walk (%layout-assignments object))
                      (walk (%layout-ordered-solutions object))
                      (walk (%layout-free-intervals object)))
                     (%arena-description
                      (walk (%arena-description-path object))
                      (walk (%arena-description-permitted-accesses object))
                      (walk (%arena-description-exclusions object)))
                     (%component-node
                      (walk (%component-node-path object))
                      (walk (%component-node-dependencies object))
                      (walk (%component-node-resources object))
                      (walk (%component-node-placements object))
                      (walk (%component-node-constraints object))
                      (walk (%component-node-barriers object))
                      (walk (%component-node-results object)))
                     (%resource-description
                      (walk (%resource-description-path object)))
                     (%placement-description
                      (walk (%placement-description-path object))
                      (walk (%placement-description-access object))
                      (walk (%placement-description-inputs object)))
                     (%constraint-description
                      (walk (%constraint-description-path object))
                      (walk (%constraint-description-identities object))
                      (walk (%constraint-description-parameters object))
                      (walk (%constraint-description-description object)))
                     (%claim-description
                      (walk (%claim-description-path object))
                      (walk (%claim-description-resource-designator object)))
                     (%barrier-description
                      (walk (%barrier-description-actual object))
                      (walk (%barrier-description-path object))
                      (walk (%barrier-description-events object))
                      (walk (%barrier-description-claims object))
                      (walk (%barrier-description-before object))
                      (walk (%barrier-description-after object)))
                     (%result-description
                      (walk (%result-description-path object))
                      (walk (%result-description-stable-description object)))
                     (%placement-solution
                      (walk (%placement-solution-description object))
                      (walk (%placement-solution-alias-of object)))
                     (%resource-state
                      (walk (%resource-state-description object)))
                     (%transaction-entry
                      (walk (%transaction-entry-payload object)))
                     (%capacity-account-entry nil)
                     (t nil))))))
      (walk root)))
  root)

(defun %call-runtime-barrier-composer (barriers bound-model construction)
  (unless (fboundp 'make-composed-barrier)
    (%reject :barrier-composer-unavailable))
  (let ((actuals
          (map 'simple-vector #'%barrier-description-actual barriers))
        (facts
          (map 'simple-vector
               (lambda (description)
                 (list :events
                       (copy-list (%barrier-description-events description))
                       :needs-old-p
                       (%barrier-description-needs-old-p description)
                       :needs-new-p
                       (%barrier-description-needs-new-p description)
                       :replacement-policy
                       (%barrier-description-replacement-policy description)))
               barriers)))
    ;; Runtime retains these exact objects.  Register all vector/list/actual
    ;; roots before the manifest closes.
    (%register-builder-tree construction actuals)
    (%register-builder-tree construction facts)
    (let ((barrier
            (handler-case
                (make-composed-barrier actuals facts bound-model)
              (error (condition)
                (%reject :barrier-composition-signaled
                         (loop for description across barriers
                               collect (%barrier-description-path description))
                         condition)))))
      (unless barrier
        (%reject :barrier-composer-returned-no-route
                 (loop for description across barriers
                       collect (%barrier-description-path description))))
      (%register-configuration-auxiliary construction barrier)
      barrier)))

(defun %register-installed-layout-storage (construction configuration)
  (unless (fboundp '%register-installed-layout-auxiliary)
    (%reject :installed-layout-auxiliary-registrar-unavailable))
  (handler-case
      (%register-installed-layout-auxiliary
       construction (%configuration-layout configuration)
       :configuration-auxiliary)
    (error (condition)
      (%reject :installed-layout-auxiliary-registration-failed nil condition)))
  ;; The installed layout does not retain its opaque release capability, but
  ;; the exact transaction log does.  Charge that record explicitly.
  (let ((entry (find :layout (%context-transaction-log construction)
                     :key #'%transaction-entry-kind :test #'eql)))
    (unless entry (%reject :layout-transaction-missing))
    (%register-builder-tree construction (%transaction-entry-payload entry)))
  (values))

(defun %register-bound-model-storage (construction bound-model)
  (unless (fboundp '%register-bound-object-model-auxiliary)
    (%reject :bound-model-auxiliary-registrar-unavailable))
  (handler-case
      (%register-bound-object-model-auxiliary
       construction bound-model :configuration-auxiliary)
    (error (condition)
      (%reject :bound-model-auxiliary-registration-failed nil condition)))
  (values))

(defun %validate-final-resource-state (state target-maximum)
  (let* ((description (%resource-state-description state))
         (path (%resource-description-path description)))
    (dolist (pair `((,(%resource-state-physical-bytes state)
                       . ,(%resource-description-minimum-physical-bytes
                           description))
                      (,(%resource-state-entry-capacity state)
                       . ,(%resource-description-logical-entry-bound
                           description))
                      (,(%resource-state-auxiliary-bytes state)
                       . ,(%resource-description-auxiliary-bytes
                           description))))
      (unless (and (%nonnegative-integer-p (car pair))
                   (<= (car pair) target-maximum)
                   (>= (car pair) (cdr pair)))
        (%reject :invalid-final-resource-capacity (list path))))))

(defun %make-capacity-account (resources construction)
  (map 'simple-vector
       (lambda (description)
         (let* ((identity (%resource-description-identity description))
                (state (gethash identity (%context-resources construction))))
           (%make-capacity-account-entry
            :identity identity
            :representation (%resource-description-representation description)
            :placement-identity
            (%resource-description-placement-identity description)
            :allocation-context
            (%resource-description-allocation-context description)
            :exhaustion-action
            (%resource-description-exhaustion-action description)
            :handle (%resource-state-handle state)
            :physical-bytes (%resource-state-physical-bytes state)
            :entry-capacity (%resource-state-entry-capacity state)
            :auxiliary-bytes (%resource-state-auxiliary-bytes state))))
       (coerce resources 'vector)))

(defun %close-resource-capacity-account
    (resources construction account target-maximum)
  ;; ACCOUNT and all retained graph objects already exist and are registered.
  (unless (fboundp '%close-resource-manifests)
    (%reject :resource-manifest-closer-unavailable))
  (handler-case (%close-resource-manifests construction)
    (error (condition)
      (%reject :resource-manifest-closure-signaled nil condition)))
  (loop for description in resources
        for entry across account
        do (let* ((identity (%resource-description-identity description))
                  (state (gethash identity (%context-resources construction))))
             (%validate-final-resource-state state target-maximum)
             (let ((placement
                     (%resource-placement-pair description construction)))
               (when (and placement
                          (> (%resource-state-physical-bytes state)
                             (- (cdr placement) (car placement))))
                 (%reject :final-resource-does-not-fit-placement
                          (list (%resource-description-path description)))))
             ;; Finalize the already registered snapshot; no persistent object
             ;; is allocated after manifest closure.
             (setf (%capacity-account-entry-physical-bytes entry)
                   (%resource-state-physical-bytes state)
                   (%capacity-account-entry-entry-capacity entry)
                   (%resource-state-entry-capacity state)
                   (%capacity-account-entry-auxiliary-bytes entry)
                   (%resource-state-auxiliary-bytes state))))
  account)

(defun %prepublication-unwind (configuration original-failure)
  "Release abandoned private construction; signal only cleanup-contract faults."
  (let* ((construction (%configuration-construction configuration))
         (faults nil))
    (setf (%context-state construction) :unwinding
          (%configuration-state configuration) :failed)
    ;; Consumers before dependencies, and reverse initialization within cohort.
    (dolist (component
             (reverse (%configuration-initialization-order configuration)))
      (handler-case (deactivate-component component construction)
        (error (condition) (push condition faults))))
    ;; The list is already strict reverse acquisition order.
    (dolist (entry (%context-transaction-log construction))
      (handler-case (%release-transaction-entry entry configuration)
        (error (condition) (push condition faults))))
    (setf (%context-state construction) :released)
    (when faults
      (error 'construction-rejected :reason :cleanup-contract-fault
             :paths nil :cause (list :original original-failure
                                     :cleanup-faults (nreverse faults))))
    (values)))

(defmethod construct-plan ((plan component) clients)
  ;; All mandatory selectors and declarations run before the first host effect.
  (let* ((profile (%call-client-selector clients :profile
                                         #'construction-client-profile))
         (offered-model (%call-client-selector clients :object-model
                                               #'construction-object-model))
         (coordinator (%call-client-selector clients :stop-coordinator
                                             #'construction-stop-coordinator))
         (address-client (%call-client-selector clients :address-space
                                                #'construction-address-space-client)))
    (unless (eql profile :sequential-host)
      (%reject :unsupported-construction-profile
               (list '(:clients :profile))))
    (unless (typep coordinator 'component)
      (%reject :stop-coordinator-is-not-component
               (list '(:clients :stop-coordinator))))
    (let* ((nodes (%discover-component-graph plan coordinator))
           (groups (%build-initialization-groups nodes))
           (arena (%snapshot-arena address-client)))
      (%validate-space-map-declarations nodes)
      (multiple-value-bind
          (resources placements constraints barriers ordered-barriers schema
           resource-table placement-table barrier-table)
          (%validate-declarations nodes address-client)
        (declare (ignore barriers barrier-table))
        (let* ((binding-groups
                 (multiple-value-list (%binding-phase-groups groups nodes)))
               (pre-binding (first binding-groups))
               (post-binding (second binding-groups))
               (component-order
                 (coerce (loop for group in groups
                               append (mapcar #'%component-node-component
                                              (%initialization-group-nodes group)))
                         'simple-vector))
               (configuration
                 (make-instance '%configuration :plan plan :clients clients
                                :graph nodes :component-order component-order))
               (construction
                 (make-instance '%construction-context
                                :configuration configuration
                                :target-maximum
                                (%target-maximum
                                 (%arena-description-address-width arena)))))
          (setf (%configuration-construction configuration) construction
                (%configuration-result-schema configuration) schema)
          (let ((result nil) (failure nil))
            ;; ERROR is not the only way a client can abandon construction.
            ;; Defer resignal until cleanup has completed, and let UNWIND-PROTECT
            ;; preserve other nonlocal exits and all their values unchanged.
            (unwind-protect
                 (handler-case
                     (setf result
                           (progn
                              (%admit-continuing-cohorts groups coordinator construction)
                              (multiple-value-bind (reference-layout target-maximum)
                                  (%solve-placements placements constraints arena construction
                                                     address-client resource-table
                                                     placement-table)
                                (setf (%context-target-maximum construction) target-maximum)
                                (%install-reference-layout reference-layout address-client
                                                           configuration construction)
                                ;; Stable graph/list order is the acquisition order.
                                (dolist (resource resources)
                                  (%acquire-resource resource clients construction
                                                     target-maximum))
                                ;; The installed host layout retains this exact solved object.
                                (%register-builder-tree construction reference-layout)
                                (%register-installed-layout-storage construction configuration)
                                (%checked-claim-sums ordered-barriers resource-table
                                                     construction target-maximum)
                                (%validate-complete-constraints
                                 constraints construction address-client resource-table
                                 placement-table target-maximum)
                                (dolist (group pre-binding)
                                  (%initialize-group group configuration construction))
                                (%bind-configuration-object-model
                                 nodes offered-model configuration construction)
                                (%register-bound-model-storage
                                 construction (%configuration-object-model configuration))
                                (setf (%configuration-barrier configuration)
                                      (%call-runtime-barrier-composer
                                       ordered-barriers
                                       (%configuration-object-model configuration)
                                       construction)
                                      (%configuration-barrier-bound-p configuration) t)
                                (dolist (group post-binding)
                                  (%initialize-group group configuration construction))
                                ;; Owners enumerate preexisting retained headers/backing
                                ;; which no acquired component resource already owns.  The
                                ;; builder registers their exact EQ identities once; it does
                                ;; not reflect over arbitrary host graphs.
                                (%register-owner-auxiliary-storage
                                 construction clients nodes)
                                ;; Host manifests include every persistent fixed record/view
                                ;; created during initialization.  Closure may raise the
                                ;; actual capacities; requested auxiliary bytes are minima.
                                (setf (%configuration-capacity-account configuration)
                                      (%make-capacity-account resources construction))
                                ;; Register the complete persistent builder graph, including
                                ;; the capacity vector itself, before closure.
                                (%register-builder-tree construction configuration)
                                (%close-resource-capacity-account
                                 resources construction
                                 (%configuration-capacity-account configuration)
                                 target-maximum)
                                ;; Validation cannot repair; activation remains private.
                                (dolist (group groups)
                                  (dolist (node (%initialization-group-nodes group))
                                    (validate-component (%component-node-component node)
                                                        configuration)))
                                (dolist (group groups)
                                  (dolist (node (%initialization-group-nodes group))
                                    (let ((component (%component-node-component node)))
                                      (activate-component component construction)
                                      (setf (%component-node-activated-p node) t))))
                                ;; The one core publication point.
                                (setf (%context-state construction) :published
                                      (%configuration-state configuration) :published)
                                configuration)))
                   (error (condition) (setf failure condition)))
              (unless (eq (%configuration-state configuration) :published)
                (%prepublication-unwind configuration
                                        (or failure :non-local-exit))))
            (when failure (error failure))
            result))))))

(defun %close-runtime-for-shutdown (configuration)
  (unless (fboundp '%close-configuration-runtime)
    (%reject :runtime-close-unavailable))
  (%close-configuration-runtime configuration))

(defun %drain-runtime-for-shutdown (configuration)
  (unless (fboundp '%drain-configuration-runtime)
    (%reject :runtime-drain-unavailable))
  (multiple-value-call #'values
    (%drain-configuration-runtime configuration)))

(defmethod shutdown-configuration ((configuration %configuration))
  (case (%configuration-state configuration)
    (:complete (return-from shutdown-configuration (values :complete nil)))
    (:published
     ;; Runtime first proves that closing cannot strand reachable objects, then
     ;; atomically closes its fixed routes.  A signal therefore leaves the
     ;; configuration published and usable.  The admitted sequential profile
     ;; has no concurrent construction-state writer in this handoff.
     (%close-runtime-for-shutdown configuration)
     (setf (%configuration-state configuration) :closing
           (%context-state (%configuration-construction configuration))
           :closing))
    (:closing nil)
    (otherwise
     (%reject :configuration-not-published)))
  (multiple-value-bind (status reason)
      (%drain-runtime-for-shutdown configuration)
    (case status
      (:retained
       (setf (%configuration-shutdown-reason configuration) reason)
       (return-from shutdown-configuration (values :retained reason)))
      (:complete nil)
      (otherwise
       (%reject :invalid-runtime-drain-result))))
  ;; Drained: consumers before dependencies, then exact transaction reverse.
  (let ((construction (%configuration-construction configuration)))
    (loop with reverse-order =
            (reverse (%configuration-initialization-order configuration))
          for index from (%configuration-shutdown-deactivation-index
                          configuration)
          below (length reverse-order)
          for component = (nth index reverse-order)
          do (deactivate-component component construction)
             (setf (%configuration-shutdown-deactivation-index configuration)
                   (1+ index)))
    (loop for entry in (%context-transaction-log construction)
          for index from 0
          when (>= index (%configuration-shutdown-release-index configuration))
            do (%release-transaction-entry entry configuration)
               (setf (%configuration-shutdown-release-index configuration)
                     (1+ index)))
    (setf (%context-state construction) :released
          (%configuration-state configuration) :complete
          (%configuration-shutdown-reason configuration) nil)
    (values :complete nil)))
