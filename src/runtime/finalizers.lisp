;;;; Bounded finalizer registry and its exact root-provider integration.
(in-package #:clamsara)

(defclass finalizer-root-location ()
  ((registry :initarg :registry :reader %finalizer-location-registry)
   (index :initarg :index :reader %finalizer-location-index)
   (kind :initarg :kind :reader %finalizer-location-kind)))

(defmethod host-root-kind ((location finalizer-root-location))
  (declare (ignore location)) :exact)

(defmethod host-root-value ((location finalizer-root-location))
  (let ((registry (%finalizer-location-registry location))
        (index (%finalizer-location-index location)))
    (ecase (%finalizer-location-kind location)
      (:referent (aref (%registry-referents registry) index))
      (:support (aref (%registry-supports registry) index)))))

(defmethod (setf host-root-value) (value (location finalizer-root-location))
  (let ((registry (%finalizer-location-registry location))
        (index (%finalizer-location-index location)))
    (ecase (%finalizer-location-kind location)
      (:referent (setf (aref (%registry-referents registry) index) value))
      (:support (setf (aref (%registry-supports registry) index) value)))))

(defclass sequential-finalizer-registry (component)
  ((capacity :initarg :capacity :reader %registry-capacity)
   (root-client :initarg :root-client :reader %registry-root-client)
   (resource-id :initform (gensym "FINALIZER-OBJECTS-")
                :reader %registry-resource-id)
   (index-resource-id :initform (gensym "FINALIZER-INDICES-")
                      :reader %registry-index-resource-id)
   (registrations :initform nil :accessor %registry-registrations)
   (referents :initform nil :accessor %registry-referents)
   (supports :initform nil :accessor %registry-supports)
   (callbacks :initform nil :accessor %registry-callbacks)
   (states :initform nil :accessor %registry-states)
   (tokens :initform nil :accessor %registry-tokens)
   (pending :initform nil :accessor %registry-pending)
   (pending-count :initform 0 :accessor %registry-pending-count)
   (next-token :initform 0 :accessor %registry-next-token)
   (locations :initform nil :accessor %registry-locations)
   (provider-token :initform nil :accessor %registry-provider-token)
   (configuration :initform nil :accessor %registry-configuration)
   (callback-failure-count :initform 0 :accessor %registry-callback-failure-count)))

(defun make-sequential-finalizer-registry (&key capacity root-client)
  (unless (typep capacity '(integer 1 *))
    (%runtime-reject :invalid-finalizer-capacity))
  (make-instance 'sequential-finalizer-registry
                 :capacity capacity :root-client root-client))

(defmethod component-resources ((registry sequential-finalizer-registry))
  (let ((capacity (%registry-capacity registry)))
    (list
     (make-resource-contribution
      registry (%registry-resource-id registry) :runtime-object-vector
      :minimum-physical-bytes (+ 16 (* 8 (* 5 capacity))) :logical-entry-bound (* 5 capacity)
      :auxiliary-bytes (* 192 (+ (* 2 capacity) 1))
      :allocation-context :construction-only
      :exhaustion-action :reject-before-publication)
     (make-resource-contribution
      registry (%registry-index-resource-id registry) :runtime-index-vector
      :minimum-physical-bytes (+ 16 (* 8 (* 2 capacity))) :logical-entry-bound (* 2 capacity)
      :auxiliary-bytes 64 :allocation-context :construction-only
      :exhaustion-action :reject-before-publication))))

(defmethod initialize-component ((registry sequential-finalizer-registry) context)
  (let ((capacity (%registry-capacity registry)))
    (multiple-value-bind (objects present-p physical entries auxiliary)
        (construction-resource context (%registry-resource-id registry))
      (unless (and present-p (typep objects 'simple-vector)
                   (>= physical (+ 16 (* 8 (* 5 capacity))))
                   (>= auxiliary (* 192 (+ (* 2 capacity) 1)))
                   (>= entries (* 5 capacity))
                   (>= (length objects) (* 5 capacity)))
        (%runtime-reject :finalizer-resource-capacity))
      (setf (%registry-registrations registry)
            (make-array capacity :displaced-to objects)
            (%registry-referents registry)
            (make-array capacity :displaced-to objects
                        :displaced-index-offset capacity)
            (%registry-supports registry)
            (make-array capacity :displaced-to objects
                        :displaced-index-offset (* 2 capacity))
            (%registry-callbacks registry)
            (make-array capacity :displaced-to objects
                        :displaced-index-offset (* 3 capacity))
            (%registry-states registry)
            (make-array capacity :displaced-to objects
                        :displaced-index-offset (* 4 capacity))))
    (multiple-value-bind (indices present-p physical entries auxiliary)
        (construction-resource context (%registry-index-resource-id registry))
      (unless (and present-p (typep indices 'simple-vector)
                   (>= physical (+ 16 (* 8 (* 2 capacity))))
                   (>= auxiliary 64)
                   (>= entries (* 2 capacity))
                   (>= (length indices) (* 2 capacity)))
        (%runtime-reject :finalizer-resource-capacity))
      (setf (%registry-tokens registry)
            (make-array capacity :displaced-to indices)
            (%registry-pending registry)
            (make-array capacity :displaced-to indices
                        :displaced-index-offset capacity)))
    (fill (%registry-registrations registry) nil)
    (fill (%registry-referents registry) nil)
    (fill (%registry-supports registry) nil)
    (fill (%registry-callbacks registry) nil)
    (fill (%registry-states registry) :free)
    (fill (%registry-tokens registry) 0)
    (fill (%registry-pending registry) 0)
    (let ((locations (make-array (* 2 capacity))))
      (dotimes (index capacity)
        (setf (aref locations index)
              (make-instance 'finalizer-root-location
                             :registry registry :index index :kind :referent)
              (aref locations (+ capacity index))
              (make-instance 'finalizer-root-location
                             :registry registry :index index :kind :support)))
      (setf (%registry-locations registry) locations)
      (dolist (object (list (%registry-registrations registry)
                            (%registry-referents registry)
                            (%registry-supports registry)
                            (%registry-callbacks registry)
                            (%registry-states registry)
                            locations))
        (%register-resource-auxiliary context (%registry-resource-id registry)
                                      object))
      (dotimes (index (length locations))
        (%register-resource-auxiliary context (%registry-resource-id registry)
                                      (aref locations index))))
    (dolist (object (list (%registry-tokens registry)
                          (%registry-pending registry)))
      (%register-resource-auxiliary context
                                    (%registry-index-resource-id registry)
                                    object))
    (setf (%registry-configuration registry) (construction-configuration context)
          (%registry-provider-token registry)
          (register-root-provider (%registry-root-client registry)
                                  registry (* 2 capacity) registry))
    ;; The root service owns the provider token and its copied location vector.
    ;; Registry-owned FINALIZER-ROOT-LOCATION records remain manifested above.
  (values)))

(defmethod deactivate-component ((registry sequential-finalizer-registry) context)
  (declare (ignore context))
  (when (%registry-provider-token registry)
    (unregister-root-provider (%registry-root-client registry)
                              (%registry-provider-token registry))
    (setf (%registry-provider-token registry) nil))
  (values))

(defmethod map-provider-roots ((registry sequential-finalizer-registry) function)
  (let ((locations (%registry-locations registry)))
    (dotimes (index (length locations))
      (funcall function (aref locations index))))
  (values))

(defun %registry-token-index (registry token)
  (when (typep token '(integer 1 *))
    (let ((index (mod (1- token) (%registry-capacity registry))))
      (when (= token (aref (%registry-tokens registry) index)) index))))

(defmethod register-finalizer ((registry sequential-finalizer-registry)
                               (context sequential-execution-context)
                               referent callback)
  (unless (and (eq (%context-configuration context)
                   (%registry-configuration registry))
               (eq (%context-state context) :bound)
               (functionp callback))
    (%runtime-reject :invalid-finalizer-registration))
  (unless (eq (%plan-state (%context-plan context)) :open)
    (%runtime-reject :collection-busy))
  (let ((index (position :free (%registry-states registry) :test #'eq)))
    (unless index (%runtime-reject :weak-storage-exhausted))
    (when (= (%registry-next-token registry) most-positive-fixnum)
      (%runtime-reject :generation-exhausted))
    (let ((token (incf (%registry-next-token registry))))
      ;; Active registrations are conditional registry entries, not strong
      ;; roots.  Their provider root slot stays NIL until a candidate freezes.
      (setf (aref (%registry-registrations registry) index) referent
            (aref (%registry-referents registry) index) nil
            (aref (%registry-supports registry) index) nil
            (aref (%registry-callbacks registry) index) callback
            (aref (%registry-tokens registry) index) token
            (aref (%registry-states registry) index) :active)
      token)))

(defmethod cancel-finalizer ((registry sequential-finalizer-registry)
                             (context sequential-execution-context) token)
  (unless (and (eq (%context-configuration context)
                   (%registry-configuration registry))
               (eq (%context-state context) :bound))
    (%runtime-reject :invalid-finalizer-context))
  (unless (eq (%plan-state (%context-plan context)) :open)
    (%runtime-reject :collection-busy))
  (let ((index (%registry-token-index registry token)))
    (if (and index (eq :active (aref (%registry-states registry) index)))
        (progn
          (setf (aref (%registry-registrations registry) index) nil
                (aref (%registry-referents registry) index) nil
                (aref (%registry-supports registry) index) nil
                (aref (%registry-callbacks registry) index) nil
                (aref (%registry-states registry) index) :free)
          :canceled)
        :already-finalized)))

(defmethod map-finalizer-registrations
    ((registry sequential-finalizer-registry) function)
  (dotimes (index (%registry-capacity registry))
    (when (eq :active (aref (%registry-states registry) index))
      (funcall function (aref (%registry-tokens registry) index)
               (aref (%registry-registrations registry) index))))
  (values))

(defmethod correct-finalizer-referent
    ((registry sequential-finalizer-registry) token expected corrected)
  (let ((index (%registry-token-index registry token)))
    (if (and index (eq :active (aref (%registry-states registry) index))
             (reference-encoding-equal-p
              (configuration-object-model (%registry-configuration registry))
              expected (aref (%registry-registrations registry) index)))
        (progn (setf (aref (%registry-registrations registry) index) corrected)
               :corrected)
        :stale)))

(defmethod freeze-finalizer-candidate
    ((registry sequential-finalizer-registry) token expected corrected)
  (let ((index (%registry-token-index registry token)))
    (unless (and index (eq :active (aref (%registry-states registry) index))
                 (reference-encoding-equal-p
                  (configuration-object-model (%registry-configuration registry))
                  expected (aref (%registry-registrations registry) index)))
      (%runtime-reject :fatal-invariant))
    (setf (aref (%registry-registrations registry) index) corrected
          ;; Candidate referent becomes a strong provider root only now, in
          ;; the closed commit after its support closure is retained.
          (aref (%registry-referents registry) index) corrected
          (aref (%registry-states registry) index) :frozen))
  (values))

(defmethod publish-pending-finalizers ((registry sequential-finalizer-registry))
  (dotimes (index (%registry-capacity registry))
    (when (eq :frozen (aref (%registry-states registry) index))
      (let ((position (%registry-pending-count registry)))
        (when (>= position (%registry-capacity registry))
          ;; Preflight made this unreachable; it is a closed fatal fault.
          (%runtime-reject :fatal-invariant))
        (setf (aref (%registry-pending registry) position) index
              (aref (%registry-states registry) index) :pending)
        (incf (%registry-pending-count registry)))))
  (values))

(defmethod drain-pending-finalizers
    ((registry sequential-finalizer-registry)
     (context sequential-execution-context))
  (unless (and (eq (%context-configuration context)
                   (%registry-configuration registry))
               (eq (%context-state context) :bound))
    (%runtime-reject :invalid-finalizer-context))
  (unless (eq (%plan-state (%context-plan context)) :open)
    (%runtime-reject :collection-busy))
  (let ((count (%registry-pending-count registry))
        (ran 0))
    (dotimes (position count)
      (let* ((index (aref (%registry-pending registry) position))
             (callback (aref (%registry-callbacks registry) index))
             (referent (aref (%registry-referents registry) index)))
        ;; State changes first, so nonlocal callback failure cannot invoke it
        ;; twice.  Callback errors are recorded and later callbacks still run.
        (setf (aref (%registry-states registry) index) :finalized)
        (handler-case (funcall callback referent)
          (error () (incf (%registry-callback-failure-count registry))))
        (incf ran)
        (setf (aref (%registry-registrations registry) index) nil
              (aref (%registry-referents registry) index) nil
              (aref (%registry-supports registry) index) nil
              (aref (%registry-callbacks registry) index) nil
              (aref (%registry-states registry) index) :free
              (aref (%registry-pending registry) position) 0)))
    (setf (%registry-pending-count registry) 0)
    ran))

(defmethod store-provider-root ((client t)
                                (context sequential-execution-context)
                                token location reference)
  ;; ROOT-PROVIDER-STORE has already validated TOKEN/LOCATION ownership and
  ;; the active provider generation.  Runtime verifies the context-selected
  ;; root service and then uses the sole composed :ROOT-STORE exposure.
  (declare (ignore token))
  (unless (and (eq client (%plan-root-client (%context-plan context)))
               (eq (%context-configuration context)
                   (%plan-configuration (%context-plan context)))
               (eq (%context-state context) :bound))
    (%runtime-reject :invalid-root-location))
  (%barrier-store-operation
   (configuration-barrier (%context-configuration context))
   context location reference :root-store))
