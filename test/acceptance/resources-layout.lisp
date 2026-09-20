;;;; Adversarial paper-v14 acceptance for hosted resource manifests and layout.
;;;; Load after v14 construction, metadata, host object/root/coordinator,
;;;; resources, and address-space sources. No implementation source is changed.

(defpackage #:clamsara.acceptance.resources-layout
  (:use #:cl #:clamsara)
  (:export #:run-resources-layout-acceptance))
(in-package #:clamsara.acceptance.resources-layout)

(defun check (value control &rest arguments)
  (unless value
    (error "v14 resource/layout acceptance failure: ~?" control arguments))
  t)
(defun construction-rejection (thunk)
  (handler-case (progn (funcall thunk) nil)
    (clamsara::construction-rejected (condition) condition)))
(defun host-rejection (thunk)
  (handler-case (progn (funcall thunk) nil)
    (clamsara::host-protocol-error (condition) condition)))

(defun make-test-clients (&key address-space)
  (clamsara::make-simulator-clients
   :model :model :roots :roots :coordinator :coordinator
   :address-space (or address-space :address-space)
   :atomics :atomics :diagnostics :diagnostics))
(defun make-private-construction (&optional (clients (make-test-clients)))
  (let* ((configuration
           (make-instance 'clamsara::%configuration
                          :plan (make-instance 'component) :clients clients
                          :graph #() :component-order #()))
         (construction
           (make-instance 'clamsara::%construction-context
                          :configuration configuration
                          :target-maximum most-positive-fixnum)))
    (setf (clamsara::%configuration-construction configuration) construction)
    (values construction configuration)))
(defun make-resource-description (identity representation entries minimum auxiliary)
  (clamsara::%make-resource-description
   :owner (make-instance 'component) :path (list :resource identity)
   :position 0 :identity identity :representation representation
   :placement-identity nil :minimum-physical-bytes minimum
   :logical-entry-bound entries :auxiliary-bytes auxiliary
   :allocation-context :construction :exhaustion-action :reject))
(defun acquire-resource (construction clients identity representation
                         &key (entries 4) (minimum 32) (auxiliary 24))
  (clamsara::%acquire-resource
   (make-resource-description identity representation entries minimum auxiliary)
   clients construction most-positive-fixnum))
(defun release-all-resources (construction)
  (setf (clamsara::%context-state construction) :unwinding)
  (maphash
   (lambda (identity state)
     (release-construction-resource
      construction identity (clamsara::%resource-state-handle state)))
   (clamsara::%context-resources construction))
  t)

(defun test-acquisition-failure-publishes-nothing ()
  (let ((clients (make-test-clients)))
    (multiple-value-bind (construction configuration)
        (make-private-construction clients)
      (declare (ignore configuration))
      (check (construction-rejection
              (lambda ()
                (acquire-resource construction clients :bad :unsupported)))
             "unsupported acquisition did not reject")
      (check (and (zerop (hash-table-count
                          (clamsara::%context-resources construction)))
                  (null (clamsara::%context-transaction-log construction)))
             "failed acquisition left resource state or cleanup log")))
  t)

(defun test-manifest-is-closed-deduplicated-and-charged ()
  (let ((clients (make-test-clients)))
    (multiple-value-bind (construction configuration)
        (make-private-construction clients)
      (declare (ignore configuration))
      (let* ((state (acquire-resource construction clients :records
                                      :runtime-object-vector
                                      :entries 3 :minimum 24 :auxiliary 16))
             (owned (make-array 5 :initial-element nil)))
        (clamsara::%register-resource-auxiliary construction :records owned)
        (clamsara::%register-resource-auxiliary construction :records owned)
        (clamsara::%close-resource-manifests construction)
        (let* ((resource (clamsara::%resource-state-release-capability state))
               (manifest (clamsara::%simulator-resource-manifest resource))
               (accounted (clamsara::%resource-state-auxiliary-bytes state))
               (minimum (+ (clamsara::%host-object-storage resource)
                           (clamsara::%host-object-storage manifest)
                           (clamsara::%host-object-storage
                            (clamsara::%simulator-resource-auxiliary-reserve
                             resource))
                           (clamsara::%host-object-storage owned))))
          (check (and (typep manifest 'simple-vector)
                      (= 1 (length manifest)) (eq owned (aref manifest 0)))
                 "manifest did not EQ-deduplicate and freeze")
          (check (= accounted minimum)
                 "auxiliary account ~D did not equal explicit owned manifest ~D"
                 accounted minimum)
          (check (null (clamsara::%simulator-resource-manifest-seen resource))
                 "construction-only manifest dedup scratch survived closure")
          (let ((late (vector :late))
                (before-manifest manifest)
                (before-accounted accounted))
            (check (construction-rejection
                    (lambda ()
                      (clamsara::%register-resource-auxiliary
                       construction :records late)))
                   "closed manifest accepted later persistent storage")
            (check (and (eq before-manifest
                            (clamsara::%simulator-resource-manifest resource))
                        (= before-accounted
                           (clamsara::%resource-state-auxiliary-bytes state))
                        (null (clamsara::%simulator-resource-manifest-seen
                               resource))
                        (not (find late before-manifest :test #'eq)))
                   "failed late registration mutated closed resource state")))
        (release-all-resources construction))))
  t)

(defun test-cross-resource-storage-cannot-be-double-charged ()
  (let ((clients (make-test-clients)))
    (multiple-value-bind (construction configuration)
        (make-private-construction clients)
      (declare (ignore configuration))
      (let* ((left (acquire-resource construction clients :left
                                     :runtime-object-vector))
             (right (acquire-resource construction clients :right
                                      :runtime-object-vector))
             (left-handle (clamsara::%resource-state-handle left)))
        (declare (ignore right))
        ;; A payload handle is already owned/charged by LEFT. It cannot be
        ;; registered as RIGHT auxiliary storage and counted a second time.
        (clamsara::%register-resource-auxiliary
         construction :right left-handle)
        (check (construction-rejection
                (lambda ()
                  (clamsara::%close-resource-manifests construction)))
               "one object was charged as two resources' storage")
        (release-all-resources construction))))
  t)

(defun test-abort-release-is-exact-and-idempotent ()
  (let ((clients (make-test-clients)))
    (multiple-value-bind (construction configuration)
        (make-private-construction clients)
      (declare (ignore configuration))
      (let* ((state (acquire-resource construction clients :one
                                      :runtime-index-vector))
             (handle (clamsara::%resource-state-handle state))
             (resource (clamsara::%resource-state-release-capability state)))
        (setf (clamsara::%context-state construction) :unwinding)
        (check (construction-rejection
                (lambda ()
                  (release-construction-resource construction :one (vector))))
               "wrong handle released resource")
        (check (not (clamsara::%simulator-resource-released-p resource))
               "wrong-handle rejection partially released resource")
        (release-construction-resource construction :one handle)
        (check (and (clamsara::%simulator-resource-released-p resource)
                    (null (clamsara::%simulator-resource-handle resource)))
               "abort did not release provider-owned state")
        (release-construction-resource construction :one handle)
        (check (clamsara::%resource-state-released-p state)
               "repeat release changed terminal state"))))
  t)

;;; Minimal authoritative map/space used only through the actual layout API.
(defclass acceptance-map (component)
  ((base :initarg :base :reader acceptance-map-base)
   (limit :initarg :limit :reader acceptance-map-limit)
   (granularity :initarg :granularity :reader acceptance-map-granularity)))
(defmethod metadata-bounds ((map acceptance-map))
  (values (acceptance-map-base map) (acceptance-map-limit map)
          (acceptance-map-granularity map)))
(defmethod metadata-ref ((map acceptance-map) key)
  (declare (ignore map key)) 0)
(defclass acceptance-space (component)
  ((map :initarg :map :accessor acceptance-space-map)))
(defmethod space-object-start-map ((space acceptance-space))
  (acceptance-space-map space))
(defclass changing-space (component)
  ((maps :initarg :maps :reader changing-space-maps)
   (calls :initform 0 :accessor changing-space-calls)))
(defmethod space-object-start-map ((space changing-space))
  (let* ((maps (changing-space-maps space))
         (index (min (changing-space-calls space) (1- (length maps)))))
    (incf (changing-space-calls space))
    (aref maps index)))

(defun make-reference-layout (client &optional space object-start-map)
  (let* ((offer (managed-arena-offer client))
         (name nil) (base nil) (extent nil) (alignment nil) (page nil)
         (access nil) (width nil) (exclusions nil))
    (multiple-value-setq (name base extent alignment page access width exclusions)
      (describe-managed-arena-offer client offer))
    (let* ((arena (clamsara::%make-arena-description
                   :actual offer :path '(:acceptance-arena) :name name
                   :base base :byte-extent extent :alignment alignment
                   :page-size page :permitted-accesses access
                   :address-width width :exclusions exclusions
                   :exclusive-limit (+ base extent)))
           (assignment (make-hash-table :test #'eql))
           (solutions
             (if space
                 (let* ((description
                          (clamsara::%make-placement-description
                           :owner space :path '(:acceptance-space) :position 0
                           :identity :space :minimum-extent extent
                           :preferred-extent extent :maximum-extent extent
                           :alignment alignment :granularity 16
                           :access '(:read :write) :lifetime :configuration
                           :mobility :fixed :reclaimability :collector
                           :aliasable-p nil :inputs nil :size-function nil
                           :derived-p nil :constraint-count 0))
                        (solution
                          (clamsara::%make-placement-solution
                           :description description :base base
                           :exclusive-limit (+ base extent)
                           :object-start-map object-start-map)))
                   (setf (gethash :space assignment) solution)
                   (vector solution))
                 #())))
      (make-instance 'clamsara::%reference-layout
                     :arena arena :assignments assignment
                     :ordered-solutions solutions :free-intervals nil))))

(defun test-install-does-not-overwrite-active-layout ()
  (let* ((client (clamsara::make-simulator-address-space
                  :byte-extent 4096 :ownership-capacity 2))
         (candidate (make-reference-layout client)))
    (multiple-value-bind (first release) (install-managed-layout client candidate)
      (check (eq first (clamsara::%simulator-active-layout client))
             "installed layout was not active")
      (check (construction-rejection
              (lambda () (install-managed-layout client candidate)))
             "second layout overwrote a live layout")
      (check (eq first (clamsara::%simulator-active-layout client))
             "failed second install changed active layout")
      (release-managed-layout client release)
      (release-managed-layout client release)
      (check (null (clamsara::%simulator-active-layout client))
             "idempotent release left layout active")))
  t)

(defun test-install-failure-and-foreign-release-have-no_effect ()
  (let* ((owner (clamsara::make-simulator-address-space :byte-extent 4096))
         (foreign (clamsara::make-simulator-address-space :byte-extent 4096))
         (foreign-layout (make-reference-layout foreign)))
    (check (construction-rejection
            (lambda () (install-managed-layout owner foreign-layout)))
           "foreign candidate installed")
    (check (null (clamsara::%simulator-active-layout owner))
           "failed install changed active state")
    (multiple-value-bind (layout release)
        (install-managed-layout foreign foreign-layout)
      (check (construction-rejection
              (lambda () (release-managed-layout owner release)))
             "foreign client released layout")
      (check (and (clamsara::%simulator-layout-active-p layout)
                  (eq layout (clamsara::%simulator-active-layout foreign)))
             "foreign release partially changed owner state")
      (release-managed-layout foreign release)))
  t)

(defun test-layout-uses-snapshotted-authoritative-map ()
  (let* ((client (clamsara::make-simulator-address-space :byte-extent 4096))
         (first (make-instance 'acceptance-map :base 4096 :limit 8192
                               :granularity 16))
         (second (make-instance 'acceptance-map :base 4096 :limit 8192
                                :granularity 16))
         (space (make-instance 'changing-space :maps (vector first second)))
         ;; Simulate the builder's required one-time authoritative declaration.
         (snapshot (space-object-start-map space))
         (candidate (make-reference-layout client space snapshot)))
    (multiple-value-bind (layout release)
        (install-managed-layout client candidate)
      (let ((route (aref (clamsara::simulator-layout-ranges layout) 0)))
        (check (eq snapshot (clamsara::%simulator-layout-range-map route))
               "layout called SPACE-OBJECT-START-MAP again and installed a different map"))
      (release-managed-layout client release)))
  t)

(defun test-ownership-update-needs-covering-stop-and-bound-model ()
  (let* ((roots (clamsara::make-simulator-root-client :provider-capacity 1))
         (coordinator (clamsara::make-simulator-coordinator
                       roots :stop-capacity 2 :await-bound 2))
         (client (clamsara::make-simulator-address-space
                  :base 4096 :byte-extent 4096 :coordinator coordinator
                  :ownership-capacity 4))
         (map (make-instance 'acceptance-map :base 4096 :limit 8192
                             :granularity 16))
         (space (make-instance 'acceptance-space :map map))
         (candidate (make-reference-layout client space map)))
    (multiple-value-bind (layout release) (install-managed-layout client candidate)
      (let* ((route (aref (clamsara::simulator-layout-ranges layout) 0))
             (initial-generation
               (clamsara::%simulator-layout-range-generation route))
             (offered (clamsara::make-host-object-model
                       :capacity 256 :kind-capacity 1 :slot-capacity 1
                       :max-object-bytes 16 :handle-capacity 1
                       :stage-capacity 1 :max-interior-displacement 0
                       :tag-capacity 0))
             (binding (make-object-start-binding offered space map))
             (bound (bind-object-model offered layout (vector binding))))
        (multiple-value-bind (capability status reason)
            (prepare-space-ownership-update layout bound (cons 4096 8192) space)
          (check (and (null capability) (eq status :rejected)
                      (eq reason :unprotected-ownership-update))
                 "ownership update admitted without covering stop"))
        (multiple-value-bind (first-stop request-failure)
            (request-safepoint coordinator :all :ownership-first)
          (check (and first-stop (null request-failure))
                 "ownership stop request failed")
          (multiple-value-bind (same coverage await-failure)
              (await-safepoint coordinator first-stop)
            (declare (ignore coverage))
            (check (and (eql same first-stop) (null await-failure))
                   "ownership stop await failed"))
          ;; Arbitrary/foreign model input must return a rejection tuple, not
          ;; dispatch through a partial helper and signal.
          (multiple-value-bind (wrong status reason)
              (prepare-space-ownership-update
               layout offered (cons 4096 8192) space)
            (check (and (null wrong) (eq status :rejected)
                        (eq reason :foreign-bound-model))
                   "offered/unbound model admitted ownership update"))
          ;; Only one capability may be pending for the route.
          (multiple-value-bind (first status reason)
              (prepare-space-ownership-update
               layout bound (cons 4096 8192) space)
            (check (and first (eq status :ready) (null reason))
                   "valid ownership update did not prepare")
            (multiple-value-bind (conflict conflict-status conflict-reason)
                (prepare-space-ownership-update
                 layout bound (cons 4096 8192) space)
              (check (and (null conflict) (eq conflict-status :rejected)
                          (eq conflict-reason :ownership-update-pending))
                     "conflicting route prepare was admitted"))
            ;; Cancellation invalidates the capability without publishing an
            ;; owner/map/generation change and clears the route's pending bit.
            (clamsara::%cancel-simulator-ownership-capability layout first)
            (check (and (eq space
                            (clamsara::%simulator-layout-range-space route))
                        (eq map
                            (clamsara::%simulator-layout-range-map route))
                        (= initial-generation
                           (clamsara::%simulator-layout-range-generation route))
                        (null (clamsara::%simulator-layout-range-pending route)))
                   "cancel changed ownership or left route pending")
            (check (host-rejection
                    (lambda () (update-space-ownership layout first)))
                   "cancelled ownership capability was reusable"))
          ;; Prepare another capability under FIRST-STOP, then deliberately end
          ;; that coverage. It must not commit under a later covered stop.
          (multiple-value-bind (old status reason)
              (prepare-space-ownership-update
               layout bound (cons 4096 8192) space)
            (check (and old (eq status :ready) (null reason))
                   "second ownership prepare failed")
            (check (eq :released (release-safepoint coordinator first-stop))
                   "first ownership stop did not release")
            (multiple-value-bind (second-stop second-request-failure)
                (request-safepoint coordinator :all :ownership-second)
              (check (and second-stop (null second-request-failure))
                     "second ownership stop request failed")
              (multiple-value-bind (same coverage await-failure)
                  (await-safepoint coordinator second-stop)
                (declare (ignore coverage))
                (check (and (eql same second-stop) (null await-failure))
                       "second ownership stop await failed"))
              (check (host-rejection
                      (lambda () (update-space-ownership layout old)))
                     "capability committed under a different covering stop")
              (check (= initial-generation
                        (clamsara::%simulator-layout-range-generation route))
                     "rejected cross-stop commit changed generation")
              (clamsara::%cancel-simulator-ownership-capability layout old)
              ;; A new capability under the exact current coverage commits once.
              (multiple-value-bind (current current-status current-reason)
                  (prepare-space-ownership-update
                   layout bound (cons 4096 8192) space)
                (check (and current (eq current-status :ready)
                            (null current-reason))
                       "current-stop ownership prepare failed")
                (update-space-ownership layout current)
                (check (= (1+ initial-generation)
                          (clamsara::%simulator-layout-range-generation route))
                       "ownership commit did not advance generation once")
                (check (host-rejection
                        (lambda () (update-space-ownership layout current)))
                       "consumed ownership capability was reusable"))
              (check (eq :released (release-safepoint coordinator second-stop))
                     "second ownership covering stop did not release")))))
      (release-managed-layout client release)))
  t)


(defun manifest-has-object-p (manifest object)
  (find object manifest :test #'eq))

(defun test-real-layout-and-bound-model-manifest-is-complete ()
  "Exercise the actual host registrars and check each explicit owned primitive."
  (let* ((client (clamsara::make-simulator-address-space
                  :base 4096 :byte-extent 4096 :ownership-capacity 2))
         (clients (make-test-clients :address-space client))
         (map (make-instance 'acceptance-map :base 4096 :limit 8192
                             :granularity 16))
         (space (make-instance 'acceptance-space :map map))
         (candidate (make-reference-layout client space map))
         (identity-function
           (let ((bias 0)) (lambda (index) (+ bias index))))
         (offered (clamsara::make-host-object-model
                   :capacity 256 :max-object-bytes 32 :variant-capacity 4
                   :location-capacity 2 :handle-capacity 2 :stage-capacity 1
                   :max-interior-displacement 8 :tag-capacity 1
                   :kind-capacity 2 :slot-capacity 1))
         (kind (make-object-kind-description
                offered :manifest-node :size-rule 16 :alignment-rule 16
                :strong-layout '(:edge)))
         (array-rule (clamsara::make-host-variable-size-rule
                      :header-bytes 16 :element-bytes 8
                      :element-kind :reference))
         (array-layout (clamsara::make-host-indexed-layout
                        :identity-function identity-function :base-offset 16
                        :element-word-bytes 8 :element-strength :strong))
         (array-kind (make-object-kind-description
                      offered :manifest-array :size-rule array-rule
                      :alignment-rule 16 :strong-layout array-layout)))
    (declare (ignore kind array-kind))
    (multiple-value-bind (construction configuration)
        (make-private-construction clients)
      (declare (ignore configuration))
      (let ((state (acquire-resource
                    construction clients :configuration-auxiliary
                    :runtime-object-vector :entries 1 :minimum 8 :auxiliary 0)))
        (multiple-value-bind (layout release)
            (install-managed-layout client candidate)
          (unwind-protect
               (let* ((binding (make-object-start-binding offered space map))
                      (bound (bind-object-model offered layout (vector binding)))
                      (expected nil))
                 (labels ((remember (object)
                            (when object (pushnew object expected :test #'eq)))
                          (remember-vector (vector &optional elements-p)
                            (remember vector)
                            (when elements-p
                              (dotimes (index (length vector))
                                (remember (aref vector index))))))
                   ;; Installed-layout owned primitives.
                   (remember layout)
                   (remember-vector (clamsara::simulator-layout-ranges layout) t)
                   (remember-vector (clamsara::%simulator-ownership-reserve
                                     layout) t)
                   ;; Bound-model owned primitives. Keep this list explicit so
                   ;; a newly retained field cannot hide behind graph walking.
                   (remember bound)
                   (remember-vector (clamsara::host-model-bindings bound) t)
                   (remember-vector (clamsara::host-model-routes bound) t)
                   (remember-vector (clamsara::host-model-kinds bound) t)
                   (dotimes (index (length (clamsara::host-model-kinds bound)))
                     (let* ((description
                              (aref (clamsara::host-model-kinds bound) index))
                            (size-rule
                              (clamsara::host-object-kind-description-size-rule
                               description))
                            (strong
                              (clamsara::host-object-kind-description-strong-layout
                               description)))
                       (when (clamsara::host-variable-size-rule-p size-rule)
                         (remember size-rule))
                       (if (clamsara::host-indexed-layout-p strong)
                           (progn
                             (remember strong)
                             (remember
                              (clamsara::host-indexed-layout-identity-function
                               strong)))
                           (remember-vector strong t))
                       (remember-vector
                        (clamsara::host-object-kind-description-weak-descriptions
                         description) t)
                       (remember-vector
                        (clamsara::host-object-kind-description-ephemeron-descriptions
                         description) t)))
                   (dolist (object
                             (list (clamsara::host-model-arena bound)
                                   (clamsara::host-model-words bound)
                                   (clamsara::host-model-sizes bound)
                                   (clamsara::host-model-alignments bound)
                                   (clamsara::host-model-descriptor-kinds bound)
                                   (clamsara::host-model-descriptor-generations
                                    bound)
                                   (clamsara::host-model-descriptor-counts bound)
                                   (clamsara::host-model-variant-hash-descriptors
                                    bound)
                                   (clamsara::host-model-variant-hash-codes bound)
                                   (clamsara::host-model-variant-hash-indices
                                    bound)))
                     (remember object))
                   (remember-vector (clamsara::host-model-base-references bound) t)
                   (remember-vector (clamsara::host-model-variants bound) t)
                   (remember-vector (clamsara::host-model-locations bound) t)
                   (remember-vector (clamsara::host-model-handles bound) t)
                   (remember-vector (clamsara::host-model-stages bound) t)
                   (dotimes (index (length (clamsara::host-model-stages bound)))
                     (let ((stage (aref (clamsara::host-model-stages bound)
                                        index)))
                       (remember (clamsara::host-staged-object-bytes stage))
                       (remember (clamsara::host-staged-object-words stage))))
                   (clamsara::%register-installed-layout-auxiliary
                    construction layout :configuration-auxiliary)
                   (clamsara::%register-bound-object-model-auxiliary
                    construction bound :configuration-auxiliary)
                   (clamsara::%close-resource-manifests construction)
                   (let* ((resource
                            (clamsara::%resource-state-release-capability state))
                          (manifest
                            (clamsara::%simulator-resource-manifest resource)))
                     (dolist (object expected)
                       (check (manifest-has-object-p manifest object)
                              "real host registrar omitted owned object ~S"
                              object))
                     (check (and (typep manifest 'simple-vector)
                                 (null
                                  (clamsara::%simulator-resource-manifest-seen
                                   resource)))
                            "real host manifest did not freeze/drop scratch"))))
            (release-managed-layout client release)))
        (release-all-resources construction))))
  t)

(defun call-test (name function failures)
  (handler-case (progn (funcall function) failures)
    (error (condition) (acons name condition failures))))
(defun run-resources-layout-acceptance ()
  (let ((failures nil))
    (setf failures (call-test :acquisition-failure
                              #'test-acquisition-failure-publishes-nothing failures)
          failures (call-test :manifest-closure
                              #'test-manifest-is-closed-deduplicated-and-charged failures)
          failures (call-test :cross-resource-dedup
                              #'test-cross-resource-storage-cannot-be-double-charged failures)
          failures (call-test :abort-release
                              #'test-abort-release-is-exact-and-idempotent failures)
          failures (call-test :active-layout
                              #'test-install-does-not-overwrite-active-layout failures)
          failures (call-test :layout-failure
                              #'test-install-failure-and-foreign-release-have-no_effect failures)
          failures (call-test :authoritative-map-snapshot
                              #'test-layout-uses-snapshotted-authoritative-map failures)
          failures (call-test :real-host-manifest
                              #'test-real-layout-and-bound-model-manifest-is-complete
                              failures)
          failures (call-test :ownership-update
                              #'test-ownership-update-needs-covering-stop-and-bound-model failures))
    (when failures
      (error "v14 resource/layout acceptance failures: ~{~S: ~A~^; ~}"
             (loop for (name . condition) in (nreverse failures)
                   append (list name condition))))
    (values t :complete)))
