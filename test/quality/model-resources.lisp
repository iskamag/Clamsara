;;;; Independent paper-v14 model/resource quality regressions.
;;;; Load test/quality/support.lisp before this file.

(defpackage #:clamsara.quality.model-resources
  (:use #:cl #:clamsara #:clamsara.quality.support)
  (:export #:run-model-resource-quality
           #:run-model-resource-array-stress))
(in-package #:clamsara.quality.model-resources)

(defstruct (model-world (:constructor %make-model-world))
  configuration construction context clients roots root-provider root-token
  coordinator address-space atomics diagnostics offered-model model from to
  from-map to-map
  from-forwarding to-forwarding registry cons-kind node-kind
  reference-array-kind numeric-array-kind float-array-kind identity-function
  identity-count domains objects)

(defun signals-error-p (function)
  (handler-case (progn (funcall function) nil)
    (error () t)))

(defun align-up (value alignment)
  (* (ceiling value alignment) alignment))

(defun make-model-world (&key (extent 4096) (model-capacity 32)
                           (max-object-bytes 1024) (variant-capacity 32)
                           (location-capacity 4) (handle-capacity 16)
                           (stage-capacity 2) (tag-capacity 4)
                           (maximum-array-elements 1024)
                           (root-registration-capacity 64)
                           (root-capacity 1024))
  (let* ((q 16)
         (actual-extent (align-up (max extent 1024) q))
         (base 4096)
         (roots
           (clamsara::make-simulator-root-client
            :provider-capacity 8
            :registration-capacity root-registration-capacity
            :root-capacity root-capacity))
         (root-provider (clamsara::make-simulator-root-provider 1))
         (root-token
           (register-root-provider roots :quality-application 1 root-provider))
         (coordinator
           (clamsara::make-simulator-coordinator
            roots :stop-capacity 16 :await-bound 16))
         (address-space
           (clamsara::make-simulator-address-space
            :base base :byte-extent (* 2 actual-extent)
            :alignment q :page-size 256 :coordinator coordinator
            :ownership-capacity 4))
         (offered-model
           (make-host-object-model
            :capacity model-capacity :max-object-bytes max-object-bytes
            :variant-capacity variant-capacity
            :location-capacity location-capacity
            :handle-capacity handle-capacity :stage-capacity stage-capacity
            :max-interior-displacement 64 :tag-capacity tag-capacity
            :kind-capacity 6 :slot-capacity 8))
         (cons-kind
           (make-object-kind-description
            offered-model :quality-cons :size-rule 16 :alignment-rule q
            :strong-layout
            (list (clamsara::make-host-slot-description
                   :identity :car :offset 0)
                  (clamsara::make-host-slot-description
                   :identity :cdr :offset 8))))
         (node-kind
           (make-object-kind-description
            offered-model :quality-node :size-rule 32 :alignment-rule q
            :strong-layout
            (list (clamsara::make-host-slot-description
                   :identity :left :offset 0)
                  (clamsara::make-host-slot-description
                   :identity :right :offset 8))))
         (identity-count (list 0))
         (identity-function
           (lambda (index) (incf (car identity-count)) index))
         (reference-rule
           (clamsara::make-host-variable-size-rule
            :header-bytes 16 :element-bytes 8 :minimum-elements 0
            :maximum-elements maximum-array-elements :element-kind :reference))
         (reference-layout
           (clamsara::make-host-indexed-layout
            :identity-function identity-function :identity-base 0
            :base-offset 16 :element-word-bytes 8 :element-strength :strong))
         (reference-array-kind
           (make-object-kind-description
            offered-model :quality-reference-array :size-rule reference-rule
            :alignment-rule q :strong-layout reference-layout))
         (numeric-rule
           (clamsara::make-host-variable-size-rule
            :header-bytes 16 :element-bytes 8 :minimum-elements 0
            :maximum-elements maximum-array-elements :element-kind :numeric))
         (numeric-array-kind
           (make-object-kind-description
            offered-model :array-integer :size-rule numeric-rule
            :alignment-rule q :strong-layout nil))
         (float-rule
           (clamsara::make-host-variable-size-rule
            :header-bytes 16 :element-bytes 8 :minimum-elements 0
            :maximum-elements maximum-array-elements :element-kind :numeric))
         (float-array-kind
           (make-object-kind-description
            offered-model :array-single-float :size-rule float-rule
            :alignment-rule q :strong-layout nil))
         (atomics (clamsara::make-host-atomics))
         (diagnostics (clamsara::make-simulator-diagnostics))
         (clients
           (clamsara::make-simulator-clients
            :model offered-model :roots roots :coordinator coordinator
            :address-space address-space :atomics atomics
            :diagnostics diagnostics))
         (domain-0
           (make-metadata-domain
            :base base :limit (+ base actual-extent) :granularity q))
         (domain-1
           (make-metadata-domain
            :base (+ base actual-extent) :limit (+ base (* 2 actual-extent))
            :granularity q))
         (from-map (make-object-start-marks :domain domain-0))
         (to-map (make-object-start-marks :domain domain-1))
         (from-forwarding (make-side-forwarding :domain domain-0))
         (to-forwarding (make-side-forwarding :domain domain-1))
         (from
           (make-semispace-space
            :name :quality-from :object-start-map from-map
            :forwarding from-forwarding :extent actual-extent
            :packing-quantum q :role :allocation))
         (to
           (make-semispace-space
            :name :quality-to :object-start-map to-map
            :forwarding to-forwarding :extent actual-extent
            :packing-quantum q :role :reserve))
         (registry
           (make-sequential-finalizer-registry :capacity 4 :root-client roots))
         (plan
           (make-semispace-plan
            :from-space from :to-space to :root-client roots
            :coordinator coordinator :diagnostics diagnostics
            :registry registry :trace-capacity (ceiling actual-extent q)
            :conditional-capacity 16 :finalizer-capacity 4
            :packing-quantum q))
         (configuration (construct-plan plan clients))
         (context (bind-mutator configuration :model-resource-quality :default)))
    (%make-model-world
     :configuration configuration
     :construction (clamsara::%configuration-construction configuration)
     :context context :clients clients :roots roots
     :root-provider root-provider :root-token root-token
     :coordinator coordinator :address-space address-space
     :atomics atomics :diagnostics diagnostics
     :offered-model offered-model
     :model (configuration-object-model configuration)
     :from from :to to :from-map from-map :to-map to-map
     :from-forwarding from-forwarding :to-forwarding to-forwarding
     :registry registry :cons-kind cons-kind :node-kind node-kind
     :reference-array-kind reference-array-kind
     :numeric-array-kind numeric-array-kind :float-array-kind float-array-kind
     :identity-function identity-function :identity-count identity-count
     :domains (list domain-0 domain-1) :objects nil)))

(defun world-record-object (world reference map)
  (push (cons reference map) (model-world-objects world))
  reference)

(defun world-initialize-object (world address kind bytes map)
  (world-record-object
   world
   (initialize-object (model-world-model world) address kind bytes kind)
   map))

(defun world-allocate-object (world kind bytes)
  (multiple-value-bind (reference status reason)
      (allocate-object (model-world-context world) kind bytes 16 kind)
    (check (and reference (eq status :allocated) (null reason))
           "quality allocation failed: ~S/~S" status reason)
    (world-record-object world reference (model-world-from-map world))))

(defun retire-world-objects (world)
  (let ((model (model-world-model world)))
    (dolist (entry (model-world-objects world))
      (let* ((reference (car entry))
             (map (cdr entry))
             (descriptor
               (and (typep reference 'clamsara::host-reference)
                    (clamsara::host-reference-descriptor reference))))
        (when (and descriptor
                   (clamsara::%host-descriptor-active-p model descriptor))
          (let ((address (clamsara::host-reference-address reference)))
            (when (eql 1 (metadata-ref map address))
              (metadata-reset map address))
            (clamsara::runtime-retire-object-representation model reference)))))
    (setf (model-world-objects world) nil))
  (values))

(defun call-with-model-world (function &rest arguments)
  (let ((world nil))
    (unwind-protect
         (progn
           (setf world (apply #'make-model-world arguments))
           (funcall function world))
      (when world
        (ignore-errors
          (when (model-world-context world)
            (unbind-mutator (model-world-configuration world)
                            (model-world-context world))
            (setf (model-world-context world) nil)))
        (ignore-errors (retire-world-objects world))
        (ignore-errors
          (shutdown-configuration (model-world-configuration world)))))))

(defun map-value (model object identity)
  (multiple-value-bind (value status reason)
      (clamsara::%call-with-simulator-reference-location
       model object :strong identity
       (lambda (location) (load-reference model location)))
    (check (and (eq status :present) (null reason))
           "location ~S did not resolve: ~S/~S" identity status reason)
    value))

(defun test-authoritative-publication-and-reference-forms ()
  (call-with-model-world
   (lambda (world)
     (let* ((model (model-world-model world))
            (map (model-world-from-map world))
            (address (+ (clamsara::%space-base (model-world-from world)) 128))
            (start
              (world-initialize-object
               world address (model-world-node-kind world) 32 map)))
       (check (valid-reference-p model start)
              "unpublished opaque encoding was not admitted")
       (check (and (not (valid-reference-p model 1))
                   (not (valid-reference-p model 257))
                   (not (reference-encoding-equal-p model start 1))
                   (not (reference-encoding-equal-p model start 257)))
              "numeric immediates 1/257 alias an opaque reference")
       (check (signals-error-p (lambda () (normalize-reference model start)))
              "encoding validity incorrectly implied authoritative publication")
       (metadata-set map address 1)
       (multiple-value-bind (base descriptor) (normalize-reference model start)
         (check (and (eq base start) (eql descriptor 0))
                "authoritative base normalization was not idempotent"))
       (let* ((interior-code (+ #x10000000 8))
              (tag-code (+ #x20000000 1))
              (tagged-interior-code (+ #x30000000 (ash 1 20) 8))
              (interior (rebuild-reference model start interior-code))
              (tagged (rebuild-reference model start tag-code))
              (tagged-interior
                (rebuild-reference model start tagged-interior-code))
              (destination-address
                (+ (clamsara::%space-base (model-world-to world)) 64))
              (destination
                (world-initialize-object
                 world destination-address (model-world-node-kind world) 32
                 (model-world-to-map world)))
              (moved
                (rebuild-reference model destination tagged-interior-code)))
         (check (and (= (+ address 8)
                        (clamsara::simulator-reference-address interior))
                     (reference-equal model start interior)
                     (not (reference-encoding-equal-p model start interior))
                     (eq tagged (rebuild-reference model start tag-code))
                     (eq tagged-interior
                         (rebuild-reference model start tagged-interior-code)))
                "tag/interior encodings were not exact and stable")
         (multiple-value-bind (normalized descriptor)
             (normalize-reference model tagged-interior)
           (check (and (eq normalized start)
                       (= descriptor tagged-interior-code))
                  "normalization lost tagged/interior reconstruction state"))
         (check (= (+ destination-address 8)
                   (clamsara::simulator-reference-address moved))
                "movement reconstruction lost interior displacement")
         (check (signals-error-p (lambda () (normalize-reference model moved)))
                "unpublished destination reconstructed as live")
         (metadata-set (model-world-to-map world) destination-address 1)
         (multiple-value-bind (normalized descriptor)
             (normalize-reference model moved)
           (check (and (eq normalized destination)
                       (= descriptor tagged-interior-code))
                  "published moved reference lost tag/interior state")))
       (metadata-reset map address)
       (check (and (valid-reference-p model start)
                   (signals-error-p (lambda () (normalize-reference model start))))
              "authoritative retirement was confused with encoding validity")))
   :extent 4096 :model-capacity 16 :max-object-bytes 256
   :maximum-array-elements 16)
  ;; Exercise the real allocation publication path as a separate history.
  (call-with-model-world
   (lambda (world)
     (let* ((model (model-world-model world))
            (reference
              (world-allocate-object world (model-world-node-kind world) 32))
            (address (reference-address model reference)))
       (check (eql 1 (metadata-ref (model-world-from-map world) address))
              "runtime allocation returned before authoritative-map publication")
       (multiple-value-bind (base descriptor)
           (normalize-reference model reference)
         (check (and (eq base reference) (eql descriptor 0))
                "runtime-published reference did not normalize"))))
   :extent 4096 :model-capacity 8 :max-object-bytes 128
   :maximum-array-elements 8)
  t)

(defun test-borrowed-locations-and-handles ()
  (call-with-model-world
   (lambda (world)
     (let* ((model (model-world-model world))
            (map (model-world-from-map world))
            (address (+ (clamsara::%space-base (model-world-from world)) 128))
            (start
              (world-initialize-object
               world address (model-world-node-kind world) 32 map))
            (borrowed nil) (handle nil))
       (metadata-set map address 1)
       (map-reference-locations
        model start
        (lambda (identity location)
          (when (eq identity :left)
            (setf borrowed location)
            (store-reference-raw model location 257)
            (multiple-value-bind (made status reason)
                (make-reference-location-handle model start location)
              (check (and made (eq status :complete) (null reason))
                     "valid borrowed location did not preflight a handle")
              (setf handle made)))))
       (check (signals-error-p (lambda () (load-reference model borrowed)))
              "borrowed mapper location escaped its callback extent")
       (let ((resolved nil))
         (check
          (eq :present
              (call-with-reference-location
               model handle
               (lambda (location)
                 (setf resolved location)
                 (check (= 257 (load-reference model location))
                        "stable handle resolved the wrong location"))))
          "stable handle did not resolve after the borrow ended")
         (check (signals-error-p (lambda () (load-reference model resolved)))
                "resolved handle location escaped its callback extent"))
       (multiple-value-bind (made status reason)
           (make-reference-location-handle model start borrowed)
         (check (and (null made) (eq status :failed)
                     (eq reason :invalid-location))
                "expired borrowed location was accepted by handle preflight"))
       (metadata-reset map address)
       (clamsara::runtime-retire-object-representation model start)
       (check (eq :stale
                  (call-with-reference-location
                   model handle (lambda (location) (declare (ignore location)))))
              "handle survived source retirement")
       (setf (model-world-objects world)
             (delete start (model-world-objects world) :key #'car :test #'eq))))
   :extent 4096 :model-capacity 8 :max-object-bytes 128
   :handle-capacity 4 :location-capacity 2 :maximum-array-elements 8)
  t)

(defun object-plane-snapshot (model address bytes)
  (let* ((byte-start (clamsara::%host-arena-byte-index-at-address model address))
         (word-start (clamsara::%host-arena-word-index-at-address model address)))
    (list (subseq (clamsara::host-model-arena model)
                  byte-start (+ byte-start bytes))
          (subseq (clamsara::host-model-words model)
                  word-start (+ word-start (ceiling bytes 8))))))

(defun object-plane-snapshot-equal-p (left right)
  (and (equalp (first left) (first right))
       (equalp (second left) (second right))))

(defun test-staged-copy-and-capacity-failure-atomicity ()
  (call-with-model-world
   (lambda (world)
     (let* ((model (model-world-model world))
            (from-map (model-world-from-map world))
            (to-map (model-world-to-map world))
            (from-base (clamsara::%space-base (model-world-from world)))
            (to-base (clamsara::%space-base (model-world-to world)))
            (source
              (world-initialize-object
               world (+ from-base 64) (model-world-node-kind world) 32 from-map))
            (destination
              (world-initialize-object
               world (+ to-base 64) (model-world-node-kind world) 32 to-map)))
       (metadata-set from-map (+ from-base 64) 1)
       (clamsara::%call-with-simulator-reference-location
        model source :strong :left
        (lambda (location) (store-reference-raw model location 257)))
       (let ((generation
               (clamsara::host-staged-object-generation
                (aref (clamsara::host-model-stages model) 0))))
         (check
          (signals-error-p
           (lambda () (copy-object-to-staging model source 0 31)))
          "undersized staged-copy preflight did not reject")
         (check
          (and (eq :free
                   (clamsara::host-staged-object-state
                    (aref (clamsara::host-model-stages model) 0)))
               (= generation
                  (clamsara::host-staged-object-generation
                   (aref (clamsara::host-model-stages model) 0))))
          "failed staged-copy preflight mutated stage state"))
       (multiple-value-bind (stage used)
           (copy-object-to-staging model source 0 32)
         (check (= used 32) "staged copy reported ~D rather than 32 bytes" used)
         (map-staged-reference-locations
          model stage
          (lambda (identity location)
            (when (eq identity :left)
              (store-reference-raw model location 1))))
         (multiple-value-bind (handle status reason)
             (make-staged-reference-location-handle
              model stage :strong :left destination)
           (check (and handle (eq status :complete) (null reason))
                  "staged handle preflight failed: ~S/~S" status reason)
           (check (eq :stale
                      (call-with-reference-location
                       model handle (lambda (location) (declare (ignore location)))))
                  "staged handle resolved before install/publication")
           ;; Valid admission makes install a bounded successful operation.
           (install-staged-object model stage destination)
           (metadata-set to-map (+ to-base 64) 1)
           (check
            (eq :present
                (call-with-reference-location
                 model handle
                 (lambda (location)
                   (check (= 1 (load-reference model location))
                          "installed staged handle names wrong payload"))))
            "installed staged handle did not resolve")))
       ;; Same-kind but different-size arrays force an install rejection.  It
       ;; must happen before any destination byte/word changes.
       (let* ((array-kind (model-world-reference-array-kind world))
              (small-bytes 32) (large-bytes 40)
              (array-source
                (world-initialize-object
                 world (+ from-base 128) array-kind small-bytes from-map))
              (large-destination-address (+ to-base 128))
              (large-destination
                (world-initialize-object
                 world large-destination-address array-kind large-bytes to-map)))
         (metadata-set from-map (+ from-base 128) 1)
         (multiple-value-bind (stage used)
             (copy-object-to-staging model array-source 0 small-bytes)
           (declare (ignore used))
           (let ((before
                   (object-plane-snapshot
                    model large-destination-address large-bytes)))
             (check
              (signals-error-p
               (lambda ()
                 (install-staged-object model stage large-destination)))
              "mismatched staged install did not reject")
             (check
              (and (eq :active (clamsara::host-staged-object-state stage))
                   (object-plane-snapshot-equal-p
                    before
                    (object-plane-snapshot
                     model large-destination-address large-bytes)))
              "rejected staged install was not failure-atomic"))
           (let ((correct-destination
                   (world-initialize-object
                    world (+ to-base 192) array-kind small-bytes to-map)))
             (install-staged-object model stage correct-destination))))))
   :extent 4096 :model-capacity 12 :max-object-bytes 256
   :stage-capacity 1 :handle-capacity 8 :maximum-array-elements 16)
  ;; Exhaust every fixed pool and verify the rejecting call changes no state.
  (call-with-model-world
   (lambda (world)
     (let* ((model (model-world-model world))
            (map (model-world-from-map world))
            (base (clamsara::%space-base (model-world-from world)))
            (kind (model-world-node-kind world))
            (first (world-initialize-object world (+ base 64) kind 32 map))
            (second (world-initialize-object world (+ base 96) kind 32 map))
            (failed-address (+ base 128))
            (failed-descriptor
              (clamsara::%host-descriptor-index-at-start
               (clamsara::%host-route-at-address model failed-address)
               failed-address))
            (before (object-plane-snapshot model failed-address 32))
            (before-generation
              (aref (clamsara::host-model-descriptor-generations model)
                    failed-descriptor)))
       (metadata-set map (+ base 64) 1)
       (metadata-set map (+ base 96) 1)
       (check
        (signals-error-p
         (lambda () (initialize-object model failed-address kind 32 kind)))
        "object-capacity exhaustion did not reject")
       (check
        (and (= 2 (clamsara::host-model-live-count model))
             (zerop (aref (clamsara::host-model-sizes model)
                          failed-descriptor))
             (= before-generation
                (aref (clamsara::host-model-descriptor-generations model)
                      failed-descriptor))
             (zerop (metadata-ref map failed-address))
             (object-plane-snapshot-equal-p
              before (object-plane-snapshot model failed-address 32)))
        "object-capacity rejection changed representation/map state")
       (let ((variant (rebuild-reference model first (+ #x10000000 8)))
             (count (clamsara::host-model-variant-count model)))
         (check
          (signals-error-p
           (lambda () (rebuild-reference model first (+ #x20000000 1))))
          "variant-capacity exhaustion did not reject")
         (check (and (= count (clamsara::host-model-variant-count model))
                     (eq variant
                         (rebuild-reference model first (+ #x10000000 8))))
                "variant-capacity rejection disturbed published encoding"))
       (let ((first-handle nil))
         (map-reference-locations
          model first
          (lambda (identity location)
            (when (eq identity :left)
              (multiple-value-bind (handle status reason)
                  (make-reference-location-handle model first location)
                (check (and handle (eq status :complete) (null reason))
                       "first handle allocation failed")
                (setf first-handle handle)))))
         (map-reference-locations
          model first
          (lambda (identity location)
            (when (eq identity :left)
              (multiple-value-bind (handle status reason)
                  (make-reference-location-handle model first location)
                (check (and (null handle) (eq status :retry)
                            (eq reason :capacity-exhausted)
                            (= 1 (clamsara::host-model-handle-count model)))
                       "handle-capacity rejection was not stable/atomic")))))
         (check (eq :present
                    (call-with-reference-location
                     model first-handle
                     (lambda (location) (load-reference model location))))
                "handle-capacity failure invalidated existing handle"))
       (map-reference-locations
        model first
        (lambda (identity location)
          (when (eq identity :left)
            (check
             (signals-error-p
              (lambda ()
                (map-reference-locations
                 model second
                 (lambda (nested-identity nested-location)
                   (declare (ignore nested-identity nested-location))))))
             "borrowed-location capacity exhaustion did not reject")
            (check (null (load-reference model location))
                   "nested location failure invalidated outer borrow"))))
       (multiple-value-bind (stage used)
           (copy-object-to-staging model first 0 32)
         (declare (ignore used))
         (let ((generation (clamsara::host-staged-object-generation stage))
               (words (copy-seq (clamsara::host-staged-object-words stage))))
           (check
            (signals-error-p
             (lambda () (copy-object-to-staging model second 0 32)))
            "staging-capacity exhaustion did not reject")
           (check
            (and (eq :active (clamsara::host-staged-object-state stage))
                 (= generation (clamsara::host-staged-object-generation stage))
                 (equalp words (clamsara::host-staged-object-words stage)))
            "staging-capacity rejection disturbed active stage")))))
   :extent 4096 :model-capacity 2 :max-object-bytes 128
   :variant-capacity 1 :location-capacity 1 :handle-capacity 1
   :stage-capacity 1 :maximum-array-elements 8)
  t)

(defun manifest-owner-index (construction)
  (let ((owners (make-hash-table :test #'eq)))
    (labels ((own (object identity)
               (when object
                 (multiple-value-bind (old present-p) (gethash object owners)
                   (check (or (not present-p) (eql old identity))
                          "retained object has two manifest owners: ~S/~S"
                          old identity)
                   (setf (gethash object owners) identity)))))
      (maphash
       (lambda (identity state)
         (let ((resource (clamsara::%resource-state-release-capability state)))
           (when (clamsara::%simulator-resource-p resource)
             (check (and (clamsara::%simulator-resource-closed-p resource)
                         (null (clamsara::%simulator-resource-manifest-seen
                                resource))
                         (typep (clamsara::%simulator-resource-manifest resource)
                                'simple-vector))
                    "resource ~S did not close its manifest" identity)
             (dolist (object
                       (list (clamsara::%simulator-resource-handle resource)
                             (clamsara::%simulator-resource-physical-padding
                              resource)
                             (clamsara::%simulator-resource-auxiliary-reserve
                              resource)
                             resource))
               (own object identity))
             (loop for object across
                   (clamsara::%simulator-resource-manifest resource)
                   do (own object identity)))))
       (clamsara::%context-resources construction)))
    owners))

(defun capacity-account-entry (configuration identity)
  (find identity (clamsara::%configuration-capacity-account configuration)
        :key #'clamsara::%capacity-account-entry-identity :test #'eql))

(defun check-resource-charges (world)
  (let* ((configuration (model-world-configuration world))
         (construction (model-world-construction world)))
    (maphash
     (lambda (identity state)
       (let* ((resource (clamsara::%resource-state-release-capability state))
              (entry (capacity-account-entry configuration identity)))
         (check entry "resource ~S has no immutable capacity-account entry"
                identity)
         (check
          (and (eq (clamsara::%resource-state-handle state)
                   (clamsara::%capacity-account-entry-handle entry))
               (= (clamsara::%resource-state-physical-bytes state)
                  (clamsara::%capacity-account-entry-physical-bytes entry))
               (= (clamsara::%resource-state-entry-capacity state)
                  (clamsara::%capacity-account-entry-entry-capacity entry))
               (= (clamsara::%resource-state-auxiliary-bytes state)
                  (clamsara::%capacity-account-entry-auxiliary-bytes entry)))
          "capacity account is not the actual resource state for ~S" identity)
         (when (clamsara::%simulator-resource-p resource)
           (let* ((manifest
                    (clamsara::%simulator-resource-manifest resource))
                  (padding
                    (clamsara::%simulator-resource-physical-padding resource))
                  (reserve
                    (clamsara::%simulator-resource-auxiliary-reserve resource))
                  (actual-physical
                    (+ (clamsara::%host-object-storage
                        (clamsara::%simulator-resource-handle resource))
                       (if padding (clamsara::%host-object-storage padding) 0)))
                  (actual-auxiliary
                    (+ (clamsara::%host-object-storage resource)
                       (clamsara::%host-object-storage manifest)
                       (clamsara::%host-object-storage reserve)
                       (loop for object across manifest
                             sum (clamsara::%host-object-storage object)))))
             (check
              (= actual-physical
                 (clamsara::%resource-state-physical-bytes state))
              "resource ~S physical charge is estimate, not actual: ~D/~D"
              identity actual-physical
              (clamsara::%resource-state-physical-bytes state))
             (check
              (= actual-auxiliary
                 (clamsara::%resource-state-auxiliary-bytes state))
              "resource ~S auxiliary charge is estimate, not actual: ~D/~D"
              identity actual-auxiliary
              (clamsara::%resource-state-auxiliary-bytes state))))))
     (clamsara::%context-resources construction))))

(defun root-static-service-objects (world)
  (let ((roots (model-world-roots world))
        (coordinator (model-world-coordinator world))
        (address-space (model-world-address-space world)))
    (append
     (list roots
           (clamsara::simulator-root-providers roots)
           (clamsara::simulator-root-directory roots)
           (clamsara::simulator-client-snapshot roots)
           coordinator
           (clamsara::simulator-coordinator-coverage coordinator)
           (clamsara::simulator-joined-providers coordinator)
           (clamsara::simulator-wake-counts coordinator)
           address-space
           (clamsara::%simulator-arena-offer address-space))
     (coerce (clamsara::simulator-coordinator-coverage coordinator) 'list))))

(defun test-manifest-ownership-and-charge ()
  (call-with-model-world
   (lambda (world)
     (let* ((construction (model-world-construction world))
            (owners (manifest-owner-index construction))
            (required
              (append
               (list
                (model-world-configuration world) construction
                (model-world-clients world) (clamsara::configuration-plan
                                             (model-world-configuration world))
                (model-world-roots world) (model-world-coordinator world)
                (model-world-address-space world) (model-world-atomics world)
                (model-world-diagnostics world)
                (model-world-offered-model world)
                (clamsara::host-model-kinds
                 (model-world-offered-model world))
                (model-world-from world) (model-world-to world)
                (model-world-from-map world) (model-world-to-map world)
                (model-world-from-forwarding world)
                (model-world-to-forwarding world)
                (model-world-registry world) (model-world-model world)
                (model-world-identity-function world))
               (model-world-domains world)
               (root-static-service-objects world))))
       (dolist (object required)
         (multiple-value-bind (owner present-p) (gethash object owners)
           (check present-p
                  "persistent construction/runtime object is unowned: ~S (~D bytes)"
                  object (clamsara::%host-object-storage object))
           (check owner "persistent object has NIL manifest owner: ~S" object)))
       (check-resource-charges world)))
   :extent 4096 :model-capacity 16 :max-object-bytes 256
   :maximum-array-elements 16)
  t)


(defun capacity-account-snapshot (configuration)
  (map 'list
       (lambda (entry)
         (list (clamsara::%capacity-account-entry-identity entry)
               (clamsara::%capacity-account-entry-handle entry)
               (clamsara::%capacity-account-entry-physical-bytes entry)
               (clamsara::%capacity-account-entry-entry-capacity entry)
               (clamsara::%capacity-account-entry-auxiliary-bytes entry)))
       (clamsara::%configuration-capacity-account configuration)))

(defun host-error-reason-from (function)
  (handler-case (progn (funcall function) nil)
    (clamsara::host-protocol-error (condition)
      (clamsara::host-error-reason condition))))

(defun check-owned-service-object (object owners)
  (multiple-value-bind (owner present-p) (gethash object owners)
    (check present-p
           "registration created unowned service state: ~S (~D bytes)"
           object (clamsara::%host-object-storage object))
    (check owner "registration service state has NIL owner")))

(defun provider-directory-entries (roots provider)
  (let ((answer nil))
    (map-provider-roots
     provider
     (lambda (location)
       (let ((entry (gethash location
                             (clamsara::simulator-root-directory roots))))
         (check entry "registered root has no service directory entry")
         (push entry answer))))
    (nreverse answer)))

(defun test-postpublication-root-registration-accounting ()
  (call-with-model-world
   (lambda (world)
     (let* ((configuration (model-world-configuration world))
            (construction (model-world-construction world))
            (roots (model-world-roots world))
            (owners-before (manifest-owner-index construction))
            (account-before (capacity-account-snapshot configuration))
            (directory (clamsara::simulator-root-directory roots))
            (directory-bytes-before (clamsara::%host-object-storage directory))
            ;; Provider and physical locations are external payload. Opaque
            ;; tokens and directory-visible records are root-service state.
            (provider (clamsara::make-simulator-root-provider 17))
            (provider-locations
              (clamsara::simulator-provider-locations provider))
            (token nil))
       (unwind-protect
            (progn
              ;; Capacity rejects before provider enumeration and consumes no
              ;; generation, historical token, or root entry.
              (let ((generation (clamsara::simulator-root-generation roots))
                    (next-token (clamsara::simulator-root-next-token roots))
                    (free-entries
                      (clamsara::simulator-root-free-entry-count roots))
                    (directory-count (hash-table-count directory))
                    (too-large (clamsara::make-simulator-root-provider 70)))
                (check
                 (eq :root-capacity-exhausted
                     (host-error-reason-from
                      (lambda ()
                        (register-root-provider
                         roots :too-large 70 too-large))))
                 "root-capacity exhaustion did not return its stable reason")
                (check (and (= generation
                               (clamsara::simulator-root-generation roots))
                            (= next-token
                               (clamsara::simulator-root-next-token roots))
                            (= free-entries
                               (clamsara::simulator-root-free-entry-count roots))
                            (= directory-count (hash-table-count directory)))
                       "root-capacity rejection changed service state"))
              ;; Enumeration failure likewise consumes no fixed reserve.
              (let ((generation (clamsara::simulator-root-generation roots))
                    (next-token (clamsara::simulator-root-next-token roots))
                    (free-entries
                      (clamsara::simulator-root-free-entry-count roots))
                    (directory-count (hash-table-count directory)))
                (check
                 (eq :invalid-provider-enumeration
                     (host-error-reason-from
                      (lambda ()
                        (register-root-provider
                         roots :bad-count 16 provider))))
                 "invalid enumeration did not return its stable reason")
                (check (and (= generation
                               (clamsara::simulator-root-generation roots))
                            (= next-token
                               (clamsara::simulator-root-next-token roots))
                            (= free-entries
                               (clamsara::simulator-root-free-entry-count roots))
                            (= directory-count (hash-table-count directory)))
                       "enumeration failure consumed registration reserve"))
              (setf token
                    (register-root-provider
                     roots :post-publication-quality 17 provider))
              (check-owned-service-object token owners-before)
              (check-owned-service-object directory owners-before)
              (dolist (entry (provider-directory-entries roots provider))
                (check-owned-service-object entry owners-before))
              ;; External provider payload is intentionally not reclassified as
              ;; framework storage.
              (check (and (not (gethash provider owners-before))
                          (not (gethash provider-locations owners-before)))
                     "external root-provider payload was charged as framework state")
              ;; A duplicate attempt must reject before changing published
              ;; generation, provider slots, or directory identities.
              (let ((generation (clamsara::simulator-root-generation roots))
                    (providers (copy-seq
                                (clamsara::simulator-root-providers roots)))
                    (entries (provider-directory-entries roots provider))
                    (directory-count (hash-table-count directory)))
                (check
                 (eq :duplicate-provider-identity
                     (host-error-reason-from
                      (lambda ()
                        (register-root-provider
                         roots :post-publication-quality 17 provider))))
                 "duplicate registration did not return its stable reason")
                (check (and (= generation
                               (clamsara::simulator-root-generation roots))
                            (= directory-count (hash-table-count directory))
                            (equalp providers
                                    (clamsara::simulator-root-providers roots))
                            (equalp entries
                                    (provider-directory-entries roots provider)))
                       "failed root registration changed published state"))
              (unregister-root-provider roots token)
              (check (signals-error-p
                      (lambda ()
                        (root-provider-load
                         roots token (aref provider-locations 0))))
                     "unregistered root token remained usable")
              (let ((old token))
                (setf token
                      (register-root-provider
                       roots :post-publication-quality 17 provider))
                (check (not (eq old token))
                       "token reuse revived a stale root capability")
                (check-owned-service-object token owners-before)
                (dolist (entry (provider-directory-entries roots provider))
                  (check-owned-service-object entry owners-before))
                (check (signals-error-p
                        (lambda ()
                          (root-provider-load
                           roots old (aref provider-locations 0))))
                       "old root token revived after re-registration"))
              ;; Historical tokens are never reused. Repeated unregister/
              ;; re-register eventually reaches the finite declared bound, and
              ;; the rejecting attempt changes no service state.
              (let ((previous token) (exhausted-p nil))
                (unregister-root-provider roots token)
                (setf token nil)
                (loop repeat 16 until exhausted-p
                      do (let ((generation
                                 (clamsara::simulator-root-generation roots))
                               (next-token
                                 (clamsara::simulator-root-next-token roots))
                               (free-entries
                                 (clamsara::simulator-root-free-entry-count roots))
                               (directory-count (hash-table-count directory)))
                           (handler-case
                               (let ((next
                                       (register-root-provider
                                        roots :post-publication-quality
                                        17 provider)))
                                 (check (not (eq next previous))
                                        "historical root token was reused")
                                 (check-owned-service-object next owners-before)
                                 (check (signals-error-p
                                         (lambda ()
                                           (root-provider-load
                                            roots previous
                                            (aref provider-locations 0))))
                                        "stale token revived during history run")
                                 (unregister-root-provider roots next)
                                 (setf previous next))
                             (clamsara::host-protocol-error (condition)
                               (check
                                (eq :registration-history-exhausted
                                    (clamsara::host-error-reason condition))
                                "finite token history failed for ~S"
                                (clamsara::host-error-reason condition))
                               (check
                                (and (= generation
                                        (clamsara::simulator-root-generation roots))
                                     (= next-token
                                        (clamsara::simulator-root-next-token roots))
                                     (= free-entries
                                        (clamsara::simulator-root-free-entry-count
                                         roots))
                                     (= directory-count
                                        (hash-table-count directory)))
                                "history exhaustion changed service state")
                               (setf exhausted-p t)))))
                (check exhausted-p
                       "declared root registration history did not exhaust"))
              (check (equalp account-before
                             (capacity-account-snapshot configuration))
                     "root registration mutated immutable capacity account")
              (check-resource-charges world)
              (check (<= (clamsara::%host-object-storage directory)
                         directory-bytes-before)
                     "root directory backing grew after manifest freeze: ~D -> ~D"
                     directory-bytes-before
                     (clamsara::%host-object-storage directory)))
         (when token
           (ignore-errors (unregister-root-provider roots token))))))
   :extent 4096 :model-capacity 16 :max-object-bytes 256
   :maximum-array-elements 16
   :root-registration-capacity 6 :root-capacity 64)
  t)


(defclass scaling-space (component)
  ((map :initarg :map :reader scaling-space-map)))
(defmethod space-object-start-map ((space scaling-space))
  (scaling-space-map space))

(defun make-scaling-layout (count)
  (let* ((q 16) (base 4096) (extent (* count q))
         (client
           (clamsara::make-simulator-address-space
            :base base :byte-extent extent :alignment q :page-size q
            :ownership-capacity count))
         (offer (managed-arena-offer client))
         (name nil) (offer-base nil) (offer-extent nil) (alignment nil)
         (page nil) (access nil) (width nil) (exclusions nil))
    (multiple-value-setq
        (name offer-base offer-extent alignment page access width exclusions)
      (describe-managed-arena-offer client offer))
    (let ((arena
            (clamsara::%make-arena-description
             :actual offer :path '(:quality-scale) :name name
             :base offer-base :byte-extent offer-extent
             :alignment alignment :page-size page
             :permitted-accesses access :address-width width
             :exclusions exclusions
             :exclusive-limit (+ offer-base offer-extent)))
          (solutions (make-array count))
          (assignments (make-hash-table :test #'eql))
          (spaces (make-array count))
          (maps (make-array count)))
      (dotimes (index count)
        (let* ((range-base (+ base (* index q)))
               (map
                 (make-object-start-marks
                  :domain
                  (make-metadata-domain
                   :base range-base :limit (+ range-base q)
                   :granularity q)))
               (space (make-instance 'scaling-space :map map))
               (description
                 (clamsara::%make-placement-description
                  :owner space :path (list :quality-scale index)
                  :position index :identity index
                  :minimum-extent q :preferred-extent q :maximum-extent q
                  :alignment q :granularity q :access '(:read :write)
                  :lifetime :configuration :mobility :fixed
                  :reclaimability :collector :aliasable-p nil
                  :inputs nil :size-function nil :derived-p nil
                  :constraint-count 0))
               (solution
                 (clamsara::%make-placement-solution
                  :description description :base range-base
                  :exclusive-limit (+ range-base q)
                  :object-start-map map)))
          (setf (aref spaces index) space
                (aref maps index) map
                (aref solutions index) solution
                (gethash index assignments) solution)))
      (values
       client
       (make-instance 'clamsara::%reference-layout
                      :arena arena :assignments assignments
                      :ordered-solutions solutions :free-intervals nil)
       spaces maps))))

(defun call-counting-function (symbol function)
  (if (not (fboundp symbol))
      (progn (funcall function) 0)
      (let ((original (symbol-function symbol)) (count 0))
        (unwind-protect
             (progn
               (setf (symbol-function symbol)
                     (lambda (&rest arguments)
                       (incf count)
                       (apply original arguments)))
               (funcall function)
               count)
          (setf (symbol-function symbol) original)))))


(defun scaling-layout-state (candidate)
  (map 'list
       (lambda (solution)
         (list solution
               (clamsara::%placement-solution-base solution)
               (clamsara::%placement-solution-exclusive-limit solution)))
       (clamsara::%layout-ordered-solutions candidate)))

(defun check-scaling-layout-state (candidate before)
  (let ((after (scaling-layout-state candidate)))
    (check (= (length before) (length after)) "layout vector length changed")
    (mapc (lambda (old now)
            (check (and (eq (first old) (first now))
                        (= (second old) (second now))
                        (= (third old) (third now)))
                   "layout validation mutated authoritative solution state"))
          before after)))

(defun test-layout-adversaries ()
  ;; Unsorted, exact-touching routed intervals are valid and remain in their
  ;; authoritative vector order.
  (multiple-value-bind (client candidate spaces maps)
      (make-scaling-layout 4)
    (declare (ignore spaces maps))
    (let ((solutions (clamsara::%layout-ordered-solutions candidate)))
      (rotatef (aref solutions 0) (aref solutions 2))
      (let ((before (scaling-layout-state candidate)))
        (validate-managed-layout client candidate)
        (check-scaling-layout-state candidate before)
        (multiple-value-bind (installed release)
            (install-managed-layout client candidate)
          (check installed "unsorted exact-touch layout did not install")
          (release-managed-layout client release)))))
  ;; Empty routes are empty sets even when their point lies inside a nonempty
  ;; route.  Validation scratch must not rewrite the solution record.
  (multiple-value-bind (client candidate spaces maps)
      (make-scaling-layout 4)
    (declare (ignore spaces maps))
    (let* ((solutions (clamsara::%layout-ordered-solutions candidate))
           (empty (aref solutions 0))
           (point (+ (clamsara::%placement-solution-base (aref solutions 1)) 4)))
      (setf (clamsara::%placement-solution-base empty) point
            (clamsara::%placement-solution-exclusive-limit empty) point)
      (let ((before (scaling-layout-state candidate)))
        (validate-managed-layout client candidate)
        (check-scaling-layout-state candidate before))))
  ;; True overlap rejects without installing or mutating, and the same host
  ;; offer remains reusable after the caller repairs its private candidate.
  (multiple-value-bind (client candidate spaces maps)
      (make-scaling-layout 4)
    (declare (ignore spaces maps))
    (let* ((solutions (clamsara::%layout-ordered-solutions candidate))
           (left (aref solutions 0))
           (right (aref solutions 1))
           (right-base (clamsara::%placement-solution-base right))
           (right-limit (clamsara::%placement-solution-exclusive-limit right)))
      (setf (clamsara::%placement-solution-base right)
            (+ (clamsara::%placement-solution-base left) 8))
      (let ((before (scaling-layout-state candidate)))
        (check (signals-error-p
                (lambda () (validate-managed-layout client candidate)))
               "overlapping routed intervals were accepted")
        (check-scaling-layout-state candidate before)
        (check (null (clamsara::%simulator-active-layout client))
               "failed layout validation installed host state"))
      (setf (clamsara::%placement-solution-base right) right-base
            (clamsara::%placement-solution-exclusive-limit right) right-limit)
      (multiple-value-bind (installed release)
          (install-managed-layout client candidate)
        (check installed "host offer was not reusable after overlap rejection")
        (release-managed-layout client release))))
  t)

(defun test-binding-adversaries ()
  (multiple-value-bind (client candidate spaces maps)
      (make-scaling-layout 4)
    (multiple-value-bind (layout release)
        (install-managed-layout client candidate)
      (unwind-protect
           (let* ((offered
                    (make-host-object-model
                     :capacity 4 :max-object-bytes 16
                     :kind-capacity 1 :slot-capacity 1))
                  (bindings
                    (map 'vector
                         (lambda (space map)
                           (make-object-start-binding offered space map))
                         spaces maps))
                  (offer-routes (clamsara::host-model-routes offered)))
             (check (bind-object-model offered layout bindings)
                    "valid one-pass object binding failed")
             (check (and (not (clamsara::host-model-bound-p offered))
                         (eq offer-routes (clamsara::host-model-routes offered)))
                    "binding mutated the offered model")
             (let ((duplicate (copy-seq bindings)))
               (setf (aref duplicate 3) (aref duplicate 0))
               (check (signals-error-p
                       (lambda ()
                         (bind-object-model offered layout duplicate)))
                      "duplicate/missing binding coverage was accepted"))
             (check (signals-error-p
                     (lambda ()
                       (bind-object-model offered layout (subseq bindings 0 3))))
                    "short binding coverage was accepted")
             (let* ((foreign
                      (make-host-object-model
                       :capacity 4 :max-object-bytes 16
                       :kind-capacity 1 :slot-capacity 1))
                    (mixed (copy-seq bindings)))
               (setf (aref mixed 3)
                     (make-object-start-binding
                      foreign (aref spaces 3) (aref maps 3)))
               (check (signals-error-p
                       (lambda () (bind-object-model offered layout mixed)))
                      "foreign object-start binding was accepted")))
        (release-managed-layout client release))))
  t)

(defun test-linear-route-and-binding-validation ()
  ;; Operation counts, not elapsed time, make this deterministic.  Sixteen is
  ;; enough to distinguish the former N(N+1)/2 and 2N^2 scans from O(N).
  (let ((count 16))
    (multiple-value-bind (client candidate spaces maps)
        (make-scaling-layout count)
      (let ((layout-calls
              (call-counting-function
               'clamsara::%simulator-solution-space
               (lambda () (validate-managed-layout client candidate)))))
        (check (<= layout-calls (* 4 count))
               "managed-layout validation is superlinear: N=~D calls=~D"
               count layout-calls)
        (when (fboundp 'clamsara::%simulator-solution-space)
          (check (= layout-calls count)
                 "managed-layout route extraction is not exactly one-pass: N=~D calls=~D"
                 count layout-calls))
        (multiple-value-bind (layout release)
            (install-managed-layout client candidate)
          (unwind-protect
               (let* ((offered
                        (make-host-object-model
                         :capacity count :max-object-bytes 16
                         :kind-capacity 1 :slot-capacity 1))
                      (bindings
                        (map 'vector
                             (lambda (space map)
                               (make-object-start-binding offered space map))
                             spaces maps))
                      (binding-calls
                        (call-counting-function
                         'clamsara::%host-binding-matches-range-p
                         (lambda ()
                           (bind-object-model offered layout bindings)))))
                 (check (<= binding-calls (* 4 count))
                        "object-model binding is superlinear: N=~D calls=~D"
                        count binding-calls)
                 (when (fboundp 'clamsara::%host-binding-matches-range-p)
                   (check (zerop binding-calls)
                          "obsolete all-pairs binding matcher still ran ~D times"
                          binding-calls)))
            (release-managed-layout client release))))))
  (test-layout-adversaries)
  (test-binding-adversaries)
  t)


(defun model-fixed-plane-snapshot (model)
  (mapcar (lambda (object)
            (list object (and (arrayp object) (array-total-size object))))
          (list (clamsara::host-model-arena model)
                (clamsara::host-model-words model)
                (clamsara::host-model-sizes model)
                (clamsara::host-model-alignments model)
                (clamsara::host-model-descriptor-kinds model)
                (clamsara::host-model-descriptor-generations model)
                (clamsara::host-model-descriptor-counts model)
                (clamsara::host-model-base-references model)
                (clamsara::host-model-variants model)
                (clamsara::host-model-variant-hash-descriptors model)
                (clamsara::host-model-variant-hash-codes model)
                (clamsara::host-model-variant-hash-indices model)
                (clamsara::host-model-locations model)
                (clamsara::host-model-handles model)
                (clamsara::host-model-stages model))))

(defun check-fixed-plane-snapshot (model snapshot)
  (let ((after (model-fixed-plane-snapshot model)))
    (check (= (length snapshot) (length after))
           "hosted model plane set changed")
    (mapc (lambda (before now)
            (check (and (eq (first before) (first now))
                        (eql (second before) (second now)))
                   "guest allocation replaced/resized a fixed hosted plane"))
          snapshot after)))

(defun call-with-fixed-location (model object identity function)
  (multiple-value-bind (value status reason)
      (clamsara::%call-with-simulator-reference-location
       model object :strong identity function)
    (check (and (eq status :present) (null reason))
           "fixed location ~S failed: ~S/~S" identity status reason)
    value))

(defun test-guest-payload-residency ()
  (let ((elements 32))
    (call-with-model-world
     (lambda (world)
       (let* ((model (model-world-model world))
              (configuration (model-world-configuration world))
              (owners-before (manifest-owner-index
                              (model-world-construction world)))
              (account-before (capacity-account-snapshot configuration))
              (planes-before (model-fixed-plane-snapshot model))
              (bytes (+ 16 (* elements 8)))
              (guest-cons
                (world-allocate-object world (model-world-cons-kind world) 16))
              (guest-struct
                (world-allocate-object world (model-world-node-kind world) 32))
              (reference-array
                (world-allocate-object
                 world (model-world-reference-array-kind world) bytes))
              (numeric-array
                (world-allocate-object
                 world (model-world-numeric-array-kind world) bytes))
              (float-array
                (world-allocate-object
                 world (model-world-float-array-kind world) bytes)))
         ;; The four returned encodings were all provisioned at model binding.
         ;; Guest allocation publishes cells; it does not allocate a host cons,
         ;; structure, or per-object payload array.
         (dolist (reference
                   (list guest-cons guest-struct reference-array numeric-array float-array))
           (check (typep reference 'clamsara::host-reference)
                  "managed guest object fell back to host payload: ~S" reference)
           (multiple-value-bind (owner present-p)
               (gethash reference owners-before)
             (check (and present-p owner)
                    "guest base encoding was not fixed/charged before allocation")))
         (check-fixed-plane-snapshot model planes-before)
         (check (equalp account-before (capacity-account-snapshot configuration))
                "guest allocation changed fixed representation charge")
         (check (= 5 (clamsara::host-model-live-count model))
                "guest allocation count does not match five plane entries")
         (call-with-fixed-location
          model guest-cons :car
          (lambda (location) (store-reference-raw model location guest-struct)))
         (call-with-fixed-location
          model guest-cons :cdr
          (lambda (location) (store-reference-raw model location 1)))
         (call-with-fixed-location
          model guest-struct :left
          (lambda (location) (store-reference-raw model location guest-cons)))
         (call-with-fixed-location
          model guest-struct :right
          (lambda (location) (store-reference-raw model location 257)))
         (check (and (eq guest-struct (map-value model guest-cons :car))
                     (= 1 (map-value model guest-cons :cdr))
                     (eq guest-cons (map-value model guest-struct :left))
                     (= 257 (map-value model guest-struct :right)))
                "managed cons/struct payload escaped or changed outside planes")
         (let ((seen 0))
           (map-reference-locations
            model reference-array
            (lambda (identity location)
              (declare (ignore identity))
              (store-reference-raw
               model location
               (case (mod seen 4)
                 (0 guest-cons) (1 guest-struct) (2 1) (otherwise 257)))
              (incf seen)))
           (check (= seen elements)
                  "reference-array plane did not cover every element"))
         (check-fixed-plane-snapshot model planes-before)
         ;; Immediate integers stay in the fixed word plane and allocate no
         ;; per-element host container.
         (dotimes (index elements)
           (multiple-value-bind (value status reason)
               (clamsara::%call-with-simulator-array-element
                model numeric-array index
                (lambda (location)
                  (store-reference-raw model location
                                       (if (evenp index) 1 257))))
             (check (and (= value (if (evenp index) 1 257))
                         (eq status :present) (null reason))
                    "numeric immediate plane store failed at ~D" index)))
         ;; SBCL single-floats are immediate word encodings (widetag 25 on
         ;; this admitted host), so retaining one in the fixed word plane is not
         ;; a per-value host-heap fallback. Double-floats are heap objects and
         ;; must reject before changing the word.
         (let ((single 1.5f0) (word-index nil))
           (multiple-value-bind (value status reason)
               (clamsara::%call-with-simulator-array-element
                model float-array 0
                (lambda (location)
                  (setf word-index
                        (clamsara::host-reference-location-word-index location))
                  (store-reference-raw model location single)
                  (load-reference model location)))
             (check (and (eq status :present) (null reason) (= value single))
                    "single-float immediate did not round-trip"))
           (let ((retained (aref (clamsara::host-model-words model) word-index)))
             #+sbcl
             (check (and (typep retained 'single-float)
                         (= (sb-kernel:widetag-of retained)
                            sb-vm:single-float-widetag))
                    "numeric plane did not retain an immediate single-float")
             #-sbcl
             (check (typep retained 'single-float)
                    "numeric plane lost admitted single-float")
             (let ((before retained))
               (let ((rejected-p
                       (handler-case
                           (multiple-value-bind
                               (ignored reject-status reject-reason)
                               (clamsara::%call-with-simulator-array-element
                                model float-array 0
                                (lambda (location)
                                  (store-reference-raw model location 1.5d0)))
                             (declare (ignore ignored))
                             (and (not (eq reject-status :present))
                                  reject-reason))
                         (error () t))))
                 (check rejected-p
                        "numeric plane accepted boxed double-float"))
               (check (eql before
                           (aref (clamsara::host-model-words model) word-index))
                      "rejected boxed double changed numeric plane"))))
         ;; Arbitrary host aggregates are not guest numeric values.  Rejection
         ;; must occur before the fixed numeric word changes.
         (multiple-value-bind (old status reason)
             (clamsara::%call-with-simulator-array-element
              model numeric-array 1
              (lambda (location) (load-reference model location)))
           (declare (ignore status reason))
           (let ((host-cons (list :not-guest-numeric)))
             (let ((rejected-p
                     (handler-case
                         (multiple-value-bind (ignored reject-status reject-reason)
                             (clamsara::%call-with-simulator-array-element
                              model numeric-array 1
                              (lambda (location)
                                (store-reference-raw model location host-cons)))
                           (declare (ignore ignored))
                           (and (not (eq reject-status :present)) reject-reason))
                       (error () t))))
               (check rejected-p
                      "numeric plane accepted an untracked host cons"))
             (multiple-value-bind (now now-status now-reason)
                 (clamsara::%call-with-simulator-array-element
                  model numeric-array 1
                  (lambda (location) (load-reference model location)))
               (check (and (eql now old) (eq now-status :present)
                           (null now-reason))
                      "rejected host payload changed numeric plane"))))
         (check-fixed-plane-snapshot model planes-before)
         (check (equalp account-before (capacity-account-snapshot configuration))
                "guest payload activity changed fixed hosted charge")))
     :extent 4096 :model-capacity 8 :max-object-bytes 512
     :variant-capacity 8 :location-capacity 2 :handle-capacity 4
     :stage-capacity 1 :maximum-array-elements elements))
  t)

(defun test-variable-arrays (element-count)
  (check (and (integerp element-count) (>= element-count 2))
         "array element count must be at least two")
  (let* ((bytes (+ 16 (* element-count 8)))
         ;; Two arrays plus explicit slack. The trace bound follows actual
         ;; space geometry and is not reduced to make construction pass.
         (extent (align-up (+ (* 2 bytes) 1024) 16))
         (evidence nil))
    (call-with-model-world
     (lambda (world)
       (let* ((model (model-world-model world))
              (configuration (model-world-configuration world))
              (plan (clamsara::configuration-plan configuration))
              (reference-array
                (world-allocate-object
                 world (model-world-reference-array-kind world) bytes))
              (numeric-array
                (world-allocate-object
                 world (model-world-numeric-array-kind world) bytes)))
         (check (and (= bytes (object-size model reference-array))
                     (= bytes (object-size model numeric-array)))
                "variable arrays lost their practical size")
         ;; Element zero creates the only managed edge. Other entries exercise
         ;; exact numeric immediates 1/257.
         (setf (car (model-world-identity-count world)) 0)
         (let ((seen 0))
           (map-reference-locations
            model reference-array
            (lambda (identity location)
              (check (= identity seen)
                     "generic array identity order broke at ~D/~S" seen identity)
              (let ((value (if (zerop seen) numeric-array
                               (if (evenp seen) 1 257))))
                (when (not (zerop seen))
                  (check (not (valid-reference-p model value))
                         "numeric immediate became a reference: ~D" value))
                (store-reference-raw model location value))
              (incf seen)))
           (check (and (= seen element-count)
                       (= (car (model-world-identity-count world)) element-count))
                  "generic array mapper was not one callback per element"))
         (setf (car (model-world-identity-count world)) 0)
         (let ((seen 0))
           (map-reference-locations
            model reference-array
            (lambda (identity location)
              (check (= identity seen) "generic array rescan identity mismatch")
              (let ((value (load-reference model location)))
                (if (zerop seen)
                    (check (eq value numeric-array)
                           "generic array lost managed numeric-array edge")
                    (check (= (if (evenp seen) 1 257) value)
                           "generic array value mismatch at ~D" seen)))
              (incf seen)))
           (check (and (= seen element-count)
                       (= (car (model-world-identity-count world)) element-count))
                  "generic array rescan did not scale linearly"))
         (check (= (if (evenp (1- element-count)) 1 257)
                   (map-value model reference-array (1- element-count)))
                "O(1) generic-array endpoint lookup failed")
         (let ((strong-count 0))
           (map-reference-locations
            model numeric-array
            (lambda (identity location)
              (declare (ignore identity location)) (incf strong-count)))
           (check (zerop strong-count)
                  "numeric array exposed reference locations"))
         (dotimes (index element-count)
           (multiple-value-bind (stored status reason)
               (clamsara::%call-with-simulator-array-element
                model numeric-array index
                (lambda (location)
                  (store-reference-raw model location
                                       (if (evenp index) 1 257))))
             (check (and (= stored (if (evenp index) 1 257))
                         (eq status :present) (null reason))
                    "numeric array store failed at ~D: ~S/~S"
                    index status reason)))
         (dolist (index (remove-duplicates
                         (list 0 (floor element-count 2) (1- element-count))))
           (multiple-value-bind (value status reason)
               (clamsara::%call-with-simulator-array-element
                model numeric-array index
                (lambda (location) (load-reference model location)))
             (check (and (= value (if (evenp index) 1 257))
                         (eq status :present) (null reason))
                    "numeric array read failed at ~D: ~S/~S"
                    index status reason)))
         ;; Root the generic array and collect both arrays through the real
         ;; SemiSpace trace/correction/retirement path.
         (let ((root-location
                 (clamsara::simulator-root-location
                  (model-world-root-provider world) 0)))
           (multiple-value-bind (effective status)
               (root-provider-store
                (model-world-roots world) (model-world-context world)
                (model-world-root-token world) root-location reference-array)
             (check (and (eq effective reference-array) (eq status :stored))
                    "array root publication failed: ~S" status))
           (let ((record (make-cycle-result-record plan)))
             (collect configuration :all :explicit record)
             (check (eq :complete (cycle-result-status record))
                    "array collection failed: ~S/~S"
                    (cycle-result-status record) (cycle-result-reason record))
             (multiple-value-bind (moved moved-known-p)
                 (cycle-result-count record :objects-moved)
               (multiple-value-bind (moved-bytes bytes-known-p)
                   (cycle-result-count record :bytes-moved)
                 (multiple-value-bind (discovered discovered-known-p)
                     (cycle-result-count record :objects-discovered)
                   (check (and moved-known-p bytes-known-p discovered-known-p
                               (= moved 2) (= discovered 2)
                               (= moved-bytes (* 2 bytes)))
                          "array collection counts disagree: ~S/~S, ~S/~S, ~S/~S"
                          moved moved-known-p moved-bytes bytes-known-p
                          discovered discovered-known-p)
                   (let* ((new-reference-array
                            (root-provider-load
                             (model-world-roots world)
                             (model-world-root-token world) root-location))
                          (new-numeric-array
                            (map-value model new-reference-array 0)))
                     (check (and (signals-error-p
                                  (lambda ()
                                    (normalize-reference model reference-array)))
                                 (signals-error-p
                                  (lambda ()
                                    (normalize-reference model numeric-array))))
                            "array collection did not retire source encodings")
                     (check (= (if (evenp (1- element-count)) 1 257)
                               (map-value model new-reference-array
                                          (1- element-count)))
                            "moved generic array lost endpoint value")
                     (multiple-value-bind (value status reason)
                         (clamsara::%call-with-simulator-array-element
                          model new-numeric-array (1- element-count)
                          (lambda (location) (load-reference model location)))
                       (check (and (= value
                                      (if (evenp (1- element-count)) 1 257))
                                   (eq status :present) (null reason))
                              "moved numeric array lost endpoint value"))
                     ;; Track destination representations for normal fixture
                     ;; cleanup after the collection changed roles.
                     (world-record-object world new-reference-array
                                          (model-world-to-map world))
                     (world-record-object world new-numeric-array
                                          (model-world-to-map world))
                     (multiple-value-bind (effective status)
                         (root-provider-store
                          (model-world-roots world) (model-world-context world)
                          (model-world-root-token world) root-location nil)
                       (declare (ignore effective))
                       (check (eq status :stored) "array root clear failed"))
                     (let* ((account
                              (clamsara::%configuration-capacity-account
                               configuration))
                            (physical
                              (loop for entry across account
                                    sum (clamsara::%capacity-account-entry-physical-bytes
                                         entry)))
                            (auxiliary
                              (loop for entry across account
                                    sum (clamsara::%capacity-account-entry-auxiliary-bytes
                                         entry)))
                            (plane-objects
                              (mapcar #'first (model-fixed-plane-snapshot model)))
                            (model-storage
                              (loop for object in plane-objects
                                    sum (clamsara::%host-object-storage object))))
                       (setf evidence
                             (list
                              :element-count element-count
                              :object-bytes bytes
                              :space-base (clamsara::%space-base
                                           (model-world-from world))
                              :space-extent extent :packing-quantum 16
                              :arena-element-type
                              (array-element-type
                               (clamsara::host-model-arena model))
                              :word-plane-element-type
                              (array-element-type
                               (clamsara::host-model-words model))
                              :fixed-model-plane-bytes model-storage
                              :account-physical-bytes physical
                              :account-auxiliary-bytes auxiliary
                              :reference-callbacks element-count
                              :numeric-strong-callbacks 0
                              :objects-discovered discovered
                              :objects-moved moved :bytes-moved moved-bytes)))))))))))
     :extent extent :model-capacity 8 :max-object-bytes bytes
     :variant-capacity 8 :location-capacity 2 :handle-capacity 4
     :stage-capacity 1 :maximum-array-elements element-count)
    evidence))

(defun run-model-resource-array-stress (&key (element-count 500000))
  (let ((result (test-variable-arrays element-count)))
    (format t "~&MODEL-RESOURCE-ARRAY-STRESS-OK ~S~%" result)
    result))

(defun run-model-resource-quality (&key (element-count 4096))
  (test-authoritative-publication-and-reference-forms)
  (test-borrowed-locations-and-handles)
  (test-staged-copy-and-capacity-failure-atomicity)
  (test-manifest-ownership-and-charge)
  (test-postpublication-root-registration-accounting)
  (test-linear-route-and-binding-validation)
  (test-guest-payload-residency)
  (let ((array-result (test-variable-arrays element-count)))
    (format t "~&MODEL-RESOURCE-QUALITY-OK ~S~%" array-result)
    (values t array-result)))
