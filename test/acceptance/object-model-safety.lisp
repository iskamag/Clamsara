;;;; Dense hosted object-model semantic acceptance.
(defpackage #:clamsara.acceptance.object-model
  (:use #:cl #:clamsara)
  (:export #:run-object-model-safety-acceptance))
(in-package #:clamsara.acceptance.object-model)

(defun check (value control &rest arguments)
  (unless value (error "object-model acceptance failure: ~?" control arguments))
  value)

(defun signals-p (function)
  (handler-case (progn (funcall function) nil)
    (error () t)))

(defclass object-model-map ()
  ((base :initarg :base :reader object-model-map-base)
   (limit :initarg :limit :reader object-model-map-limit)
   (granularity :initarg :granularity :reader object-model-map-granularity)
   (values :initarg :values :reader object-model-map-values)))
(defmethod metadata-bounds ((map object-model-map))
  (values (object-model-map-base map) (object-model-map-limit map)
          (object-model-map-granularity map)))
(defun object-model-map-index (map key)
  (unless (and (integerp key)
               (<= (object-model-map-base map) key)
               (< key (object-model-map-limit map))
               (zerop (mod (- key (object-model-map-base map))
                           (object-model-map-granularity map))))
    (error "invalid object-model map key"))
  (floor (- key (object-model-map-base map))
         (object-model-map-granularity map)))
(defmethod metadata-ref ((map object-model-map) key)
  (aref (object-model-map-values map) (object-model-map-index map key)))
(defmethod metadata-set ((map object-model-map) key value)
  (setf (aref (object-model-map-values map) (object-model-map-index map key))
        value))
(defmethod metadata-reset ((map object-model-map) key)
  (setf (aref (object-model-map-values map) (object-model-map-index map key)) 0))

(defclass object-model-space (component)
  ((map :initarg :map :reader object-model-space-map)))
(defmethod space-object-start-map ((space object-model-space))
  (object-model-space-map space))

(defun make-test-layout (client space map)
  (let* ((offer (managed-arena-offer client))
         (name nil) (base nil) (extent nil) (alignment nil) (page nil)
         (access nil) (width nil) (exclusions nil))
    (multiple-value-setq (name base extent alignment page access width exclusions)
      (describe-managed-arena-offer client offer))
    (let* ((arena (clamsara::%make-arena-description
                   :actual offer :path '(:object-model-arena) :name name
                   :base base :byte-extent extent :alignment alignment
                   :page-size page :permitted-accesses access
                   :address-width width :exclusions exclusions
                   :exclusive-limit (+ base extent)))
           (description
             (clamsara::%make-placement-description
              :owner space :path '(:object-model-space) :position 0
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
              :exclusive-limit (+ base extent) :object-start-map map))
           (assignment (make-hash-table :test #'eql)))
      (setf (gethash :space assignment) solution)
      (make-instance 'clamsara::%reference-layout
                     :arena arena :assignments assignment
                     :ordered-solutions (vector solution)
                     :free-intervals nil))))

(defun call-with-test-model (function)
  (let* ((base 4096) (limit 8192) (q 16)
         (map (make-instance 'object-model-map
                             :base base :limit limit :granularity q
                             :values (make-array (floor (- limit base) q)
                                                 :initial-element 0)))
         (space (make-instance 'object-model-space :map map))
         (client (clamsara::make-simulator-address-space
                  :base base :byte-extent (- limit base)
                  :alignment q :page-size 256 :ownership-capacity 2))
         (offered (make-host-object-model
                   :capacity (/ (- limit base) q) :max-object-bytes 1024
                   :variant-capacity (* 3 (/ (- limit base) q)) :location-capacity 8
                   :handle-capacity 16 :stage-capacity 2
                   :max-interior-displacement 64 :tag-capacity 4
                   :kind-capacity 4 :slot-capacity 8))
         (weak (make-weak-location-description
                offered
                (clamsara::make-host-slot-description :identity :weak :offset 8)
                :node :weak-cleared))
         (ephemeron
           (make-ephemeron-description
            offered
            (clamsara::make-host-ephemeron-location-description
             :identity :eph :key-offset 16 :value-offset 24)
            t :key-cleared :value-cleared))
         (node (make-object-kind-description
                offered :node :size-rule 32 :alignment-rule q
                :strong-layout
                (list (clamsara::make-host-slot-description
                       :identity :left :offset 0))
                :weak-descriptions (list weak)
                :ephemeron-descriptions (list ephemeron)))
         (array-rule (clamsara::make-host-variable-size-rule
                      :header-bytes 16 :element-bytes 8
                      :element-kind :reference :minimum-elements 0))
         (array-layout (clamsara::make-host-indexed-layout
                        :identity-function #'identity :base-offset 16
                        :element-word-bytes 8 :element-strength :strong))
         (array-kind (make-object-kind-description
                      offered :array :size-rule array-rule
                      :alignment-rule q :strong-layout array-layout))
         (numeric-rule (clamsara::make-host-variable-size-rule
                        :header-bytes 16 :element-bytes 8
                        :element-kind :numeric :minimum-elements 0))
         (numeric-kind (make-object-kind-description
                        offered :numeric-array :size-rule numeric-rule
                        :alignment-rule q :strong-layout nil))
         (candidate (make-test-layout client space map)))
    (multiple-value-bind (layout release)
        (install-managed-layout client candidate)
      (unwind-protect
           (let* ((binding (make-object-start-binding offered space map))
                  (bound (bind-object-model offered layout (vector binding))))
             (funcall function bound map space node array-kind numeric-kind))
        (release-managed-layout client release)))))

(defun test-reference-representation-and-locations ()
  (call-with-test-model
   (lambda (model map space node array-kind numeric-kind)
     (declare (ignore space array-kind numeric-kind))
     (let* ((address 4096)
            (start (initialize-object model address node 32 node)))
       (check (= address (reference-address model start))
              "unexposed reference-address failed")
       (check (signals-p (lambda () (normalize-reference model start)))
              "unexposed reference normalized before start publication")
       (metadata-set map address 1)
       (multiple-value-bind (base descriptor) (normalize-reference model start)
         (check (and (eq base start) (eql descriptor 0))
                "base normalization was not idempotent"))
       (check (and (= 32 (object-size model start))
                   (= 16 (object-alignment model start))
                   (eq node (object-kind model start)))
              "published object facts disagree")
       (let ((strong-location nil) (weak-seen nil) (ephemeron-seen nil))
         (map-reference-locations
          model start
          (lambda (identity location)
            (check (eq identity :left) "wrong strong identity")
            (check (null (load-reference model location))
                   "strong location was not scanner-safe NIL")
            (setf strong-location location)
            (store-reference-raw model location :strong-value)))
         (check (signals-p
                 (lambda () (load-reference model strong-location)))
                "borrowed strong location survived callback")
         (map-weak-descriptors
          model start
          (lambda (identity location cleared)
            (setf weak-seen t)
            (check (and (eq identity :weak) (eq cleared :weak-cleared)
                        (eq (load-reference model location) :weak-cleared))
                   "weak descriptor/initial value mismatch")))
         (map-ephemeron-descriptors
          model start
          (lambda (identity key value clear-key-p cleared-key cleared-value)
            (setf ephemeron-seen t)
            (check (and (eq identity :eph) clear-key-p
                        (eq cleared-key :key-cleared)
                        (eq cleared-value :value-cleared)
                        (eq (load-reference model key) :key-cleared)
                        (eq (load-reference model value) :value-cleared))
                   "ephemeron descriptor/initial values mismatch")))
         (check (and weak-seen ephemeron-seen)
                "conditional locations were not enumerated"))
       (let* ((interior-code (+ #x10000000 8))
              (tag-code (+ #x20000000 1))
              (tag-interior-code (+ #x30000000 (ash 1 20) 8))
              (interior (rebuild-reference model start interior-code))
              (tagged (rebuild-reference model start tag-code))
              (tagged-interior
                (rebuild-reference model start tag-interior-code)))
         (check (and (eq interior
                         (rebuild-reference model start interior-code))
                     (= (+ address 8)
                        (clamsara::simulator-reference-address interior))
                     (reference-equal model start interior)
                     (not (reference-encoding-equal-p model start interior)))
                "interior encoding identity/normalization failed")
         (check (and (eq tagged (rebuild-reference model start tag-code))
                     (eq tagged-interior
                         (rebuild-reference model start tag-interior-code)))
                "tagged encoding was not exact and stable")
         (multiple-value-bind (normalized rebuilt-code)
             (normalize-reference model tagged-interior)
           (check (and (eq normalized start)
                       (= rebuilt-code tag-interior-code))
                  "tagged interior normalization lost its descriptor")))
       (let ((handle nil))
         (map-reference-locations
          model start
          (lambda (identity location)
            (declare (ignore identity))
            (multiple-value-bind (made status reason)
                (make-reference-location-handle model start location)
              (check (and made (eq status :complete) (null reason))
                     "location handle preflight failed")
              (setf handle made))))
         (check (eq :present
                    (call-with-reference-location
                     model handle
                     (lambda (location)
                       (check (eq (load-reference model location) :strong-value)
                              "resolved handle named wrong word"))))
                "fresh handle did not resolve")
         (metadata-reset map address)
         (clamsara::runtime-retire-object-representation model start)
         (check (and (valid-reference-p model start)
                     (signals-p (lambda () (normalize-reference model start)))
                     (eq :stale
                         (call-with-reference-location model handle
                                                       (lambda (x)
                                                         (declare (ignore x))))))
                "retirement did not preserve encoding/stale handle semantics")
         ;; Address reuse keeps native pointer bits but advances location
         ;; generation, so the old handle must not regain validity.
         (let ((reused (initialize-object model address node 32 node)))
           (check (eq reused start) "canonical base encoding was not per-cell")
           (metadata-set map address 1)
           (check (eq :stale
                      (call-with-reference-location model handle
                                                    (lambda (x)
                                                      (declare (ignore x)))))
                  "ABA address reuse revived an old location handle")
           (metadata-reset map address)
           (clamsara::runtime-retire-object-representation model reused))))))
  t)

(defun test-copy-stage-and-dense-indexed-layouts ()
  (call-with-test-model
   (lambda (model map space node array-kind numeric-kind)
     (declare (ignore space))
     (let* ((source-address 4096) (destination-address 4128)
            (source (initialize-object model source-address node 32 node))
            (destination
              (initialize-object model destination-address node 32 node)))
       (metadata-set map source-address 1)
       (clamsara::%call-with-simulator-reference-location
        model source :strong :left
        (lambda (location)
          (store-reference-raw model location :copied-value)))
       (copy-object-representation model source destination)
       (metadata-set map destination-address 1)
       (clamsara::%call-with-simulator-reference-location
        model destination :strong :left
        (lambda (location)
          (check (eq :copied-value (load-reference model location))
                 "dense word plane did not copy a strong value")))
       (let* ((staged-destination-address 4160)
              (staged-destination
                (initialize-object model staged-destination-address node 32 node)))
         (multiple-value-bind (stage used)
             (copy-object-to-staging model source 0 32)
           (check (= used 32) "staging reported wrong byte count")
           (map-staged-reference-locations
            model stage
            (lambda (identity location)
              (when (eq identity :left)
                (store-reference-raw model location :staged-value))))
           (multiple-value-bind (handle status reason)
               (make-staged-reference-location-handle
                model stage :strong :left staged-destination)
             (check (and handle (eq status :complete) (null reason))
                    "staged location handle preflight failed")
             (check (eq :stale
                        (call-with-reference-location
                         model handle (lambda (x) (declare (ignore x)))))
                    "staged handle resolved before install/publication")
             (install-staged-object model stage staged-destination)
             (metadata-set map staged-destination-address 1)
             (check (eq :present
                        (call-with-reference-location
                         model handle
                         (lambda (location)
                           (check (eq :staged-value
                                      (load-reference model location))
                                  "staged handle named wrong installed word"))))
                    "staged handle did not resolve after commit"))))
       (let* ((array-address 4192) (count 4) (bytes (+ 16 (* count 8)))
              (array (initialize-object
                      model array-address array-kind bytes array-kind)))
         (metadata-set map array-address 1)
         (let ((seen 0))
           (map-reference-locations
            model array
            (lambda (identity location)
              (check (= identity seen) "indexed identity order mismatch")
              (store-reference-raw model location identity)
              (incf seen)))
           (check (= seen count) "indexed mapper count mismatch"))
         (multiple-value-bind (result status reason)
             (clamsara::%call-with-simulator-reference-location
              model array :strong 3
              (lambda (location) (load-reference model location)))
           (check (and (= result 3) (eq status :present) (null reason))
                  "O(1) indexed reference resolver failed"))
         (check (signals-p
                 (lambda ()
                   (clamsara::%call-with-simulator-reference-location
                    model array :strong 0
                    (lambda (location)
                      (declare (ignore location))
                      (error "callback fault")))))
                "private indexed resolver swallowed a callback fault")
         (clamsara::%call-with-simulator-reference-location
          model array :strong 0
          (lambda (location)
            (check (signals-p
                    (lambda ()
                      (store-reference-raw model location
                                           (list :host-payload))))
                   "strong word accepted an arbitrary host container")
            (check (signals-p
                    (lambda () (store-reference-raw model location 1.5d0)))
                   "strong word accepted an unsupported boxed number")
            (check (zerop (load-reference model location))
                   "rejected strong values changed the word")))
         (multiple-value-bind (result status reason)
             (clamsara::%call-with-simulator-reference-location
              model array :strong count (lambda (x) (declare (ignore x))))
           (declare (ignore result reason))
           (check (eq status :stale) "out-of-range indexed location resolved")))
       (let* ((numeric-address 4240) (count 4) (bytes (+ 16 (* count 8)))
              (numeric (initialize-object
                        model numeric-address numeric-kind bytes numeric-kind)))
         (metadata-set map numeric-address 1)
         (let ((strong-count 0))
           (map-reference-locations
            model numeric
            (lambda (identity location)
              (declare (ignore identity location)) (incf strong-count)))
           (check (zerop strong-count) "numeric array exposed strong edges"))
         (multiple-value-bind (stored status reason)
             (clamsara::%call-with-simulator-array-element
              model numeric 3
              (lambda (location)
                (store-reference-raw model location 12345)))
           (check (and (= stored 12345) (eq status :present) (null reason))
                  "numeric array direct store failed"))
         (multiple-value-bind (loaded status reason)
             (clamsara::%call-with-simulator-array-element
              model numeric 3
              (lambda (location) (load-reference model location)))
           (check (and (= loaded 12345) (eq status :present) (null reason))
                  "numeric array direct load failed"))
         (clamsara::%call-with-simulator-array-element
          model numeric 3
          (lambda (location)
            (check (signals-p
                    (lambda ()
                      (store-reference-raw model location
                                           (list :host-payload))))
                   "numeric word accepted an arbitrary host container")
            (check (signals-p
                    (lambda () (store-reference-raw model location 1.5d0)))
                   "numeric word accepted unsupported DOUBLE-FLOAT")
            (check (= 12345 (load-reference model location))
                   "rejected numeric store changed the word")
            (store-reference-raw model location 2.5f0)
            (check (signals-p
                    (lambda ()
                      (cas-reference-raw model location 2.5f0
                                         (list :host-payload) :sequential)))
                   "numeric CAS accepted an arbitrary host container")
            (check (= 2.5f0 (load-reference model location))
                   "rejected numeric CAS changed the word")))))))
  t)

(defun run-object-model-safety-acceptance ()
  (test-reference-representation-and-locations)
  (test-copy-stage-and-dense-indexed-layouts)
  (values t :complete))
