;;;; Bounded hosted finalizer registry; managed-callback admission remains open.
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

(defstruct (finalizer-owner-key (:constructor %make-finalizer-owner-key)))

(defstruct (sequential-finalizer-token
             (:constructor %make-finalizer-token (owner generation)))
  ;; Each object belongs to one historical registration and is never recycled.
  ;; INDEX is filled once, before the token is exposed to its caller.
  (owner nil :read-only t)
  (generation 0 :type fixnum :read-only t)
  (index -1 :type fixnum))

(defclass sequential-finalizer-registry (component)
  ((capacity :initarg :capacity :reader %registry-capacity)
   (registration-capacity :initarg :registration-capacity
                          :reader %registry-registration-capacity)
   (token-reserve :initform nil :accessor %registry-token-reserve)
   (token-owner :initform nil :accessor %registry-token-owner)
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
   (pending-head :initform 0 :accessor %registry-pending-head)
   (next-token :initform 0 :accessor %registry-next-token)
   (locations :initform nil :accessor %registry-locations)
   (provider-token :initform nil :accessor %registry-provider-token)
   (configuration :initform nil :accessor %registry-configuration)
   (callback-failure-count :initform 0 :accessor %registry-callback-failure-count)))

(defun make-sequential-finalizer-registry
    (&key capacity root-client (registration-capacity nil registration-capacity-p))
  "CAPACITY bounds live records; REGISTRATION-CAPACITY bounds lifetime tokens.
Historical tokens are fixed during construction, never recycled or allocated
by registration. Exhaustion rejects before publishing a record."
  (unless (typep capacity '(integer 1 #.most-positive-fixnum))
    (%runtime-reject :invalid-finalizer-capacity))
  (unless registration-capacity-p
    (setf registration-capacity (max capacity 64)))
  (unless (and (typep registration-capacity '(integer 1 #.most-positive-fixnum))
               (>= registration-capacity capacity))
    (%runtime-reject :invalid-finalizer-capacity))
  (make-instance 'sequential-finalizer-registry
                 :capacity capacity :root-client root-client
                 :registration-capacity registration-capacity))

(defmethod component-resources ((registry sequential-finalizer-registry))
  (let ((capacity (%registry-capacity registry))
        (history (%registry-registration-capacity registry)))
    (list
     (make-resource-contribution
      registry (%registry-resource-id registry) :runtime-object-vector
      :minimum-physical-bytes (+ 16 (* 8 (* 5 capacity))) :logical-entry-bound (* 5 capacity)
      :auxiliary-bytes (* 192 (+ (* 2 capacity) 1))
      :allocation-context :construction-only
      :exhaustion-action :reject-before-publication)
     (make-resource-contribution
      registry (%registry-index-resource-id registry) :runtime-index-vector
      :minimum-physical-bytes (+ 16 (* 8 (+ (* 2 capacity) history)))
      :logical-entry-bound (+ (* 2 capacity) history)
      :auxiliary-bytes (+ 64 (* 64 history))
      :allocation-context :construction-only
      :exhaustion-action :reject-before-publication))))

(defmethod initialize-component ((registry sequential-finalizer-registry) context)
  (let ((capacity (%registry-capacity registry))
        (history (%registry-registration-capacity registry)))
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
                   (>= physical (+ 16 (* 8 (+ (* 2 capacity) history))))
                   (>= auxiliary (+ 64 (* 64 history)))
                   (>= entries (+ (* 2 capacity) history))
                   (>= (length indices) (+ (* 2 capacity) history)))
        (%runtime-reject :finalizer-resource-capacity))
      (setf (%registry-tokens registry)
            (make-array capacity :displaced-to indices)
            (%registry-pending registry)
            (make-array capacity :displaced-to indices
                        :displaced-index-offset capacity)
            (%registry-token-reserve registry)
            (make-array history :displaced-to indices
                        :displaced-index-offset (* 2 capacity))))
    (setf (%registry-token-owner registry) (%make-finalizer-owner-key))
    (%register-resource-auxiliary context (%registry-index-resource-id registry)
                                  (%registry-token-owner registry))
    (dotimes (index history)
      (let ((token (%make-finalizer-token (%registry-token-owner registry)
                                         (1+ index))))
        (setf (aref (%registry-token-reserve registry) index) token)
        (%register-resource-auxiliary context (%registry-index-resource-id registry)
                                      token)))
    (fill (%registry-registrations registry) nil)
    (fill (%registry-referents registry) nil)
    (fill (%registry-supports registry) nil)
    (fill (%registry-callbacks registry) nil)
    (fill (%registry-states registry) :free)
    (fill (%registry-tokens registry) nil)
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
                          (%registry-pending registry)
                          (%registry-token-reserve registry)))
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
  (when (and (sequential-finalizer-token-p token)
             (eq (%registry-token-owner registry)
                 (sequential-finalizer-token-owner token)))
    (let ((index (sequential-finalizer-token-index token)))
      (when (and (<= 0 index) (< index (%registry-capacity registry))
                 (eq token (aref (%registry-tokens registry) index)))
        index))))

(defun %registry-local-referent-p (registry referent)
  ;; Encoding recognition is not a liveness test. Normalize, then require the
  ;; authoritative allocated-object entry in this configuration's own spaces.
  (let* ((configuration (%registry-configuration registry))
         (model (configuration-object-model configuration)))
    (and (valid-reference-p model referent)
         (handler-case
             (multiple-value-bind (start descriptor)
                 (normalize-reference model referent)
               (declare (ignore descriptor))
               (let ((space (space-of-reference
                             (configuration-layout configuration) start)))
                 (and (member space (%plan-spaces
                                     (%configuration-runtime-plan configuration))
                              :test #'eq)
                      (%metadata-present-p (%space-object-start-map space)
                                           (reference-address model start)))))
           (error () nil)))))

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
  (unless (%registry-local-referent-p registry referent)
    (%runtime-reject :invalid-finalizer-registration))
  (let ((index (position :free (%registry-states registry) :test #'eq)))
    (unless index (%runtime-reject :weak-storage-exhausted))
    (when (>= (%registry-next-token registry)
              (%registry-registration-capacity registry))
      (%runtime-reject :generation-exhausted))
    (let ((token (aref (%registry-token-reserve registry)
                       (%registry-next-token registry))))
      (setf (sequential-finalizer-token-index token) index)
      (incf (%registry-next-token registry))
      ;; Active registrations are conditional registry entries, not strong
      ;; roots.  Their provider root slot stays NIL until a candidate freezes.
      (setf (aref (%registry-registrations registry) index) referent
            (aref (%registry-referents registry) index) nil
            (aref (%registry-supports registry) index) nil
            (aref (%registry-callbacks registry) index) callback
            (aref (%registry-tokens registry) index) token
            (aref (%registry-states registry) index) :active)
      token)))

(defun %release-finalizer-record (registry index terminal-state)
  ;; Caller owns the record in an open configuration. Keep the physical slot
  ;; unavailable until all retained values have been cleared. Token identities
  ;; stay historical; :FREE invalidates this generation before any reuse.
  (setf (aref (%registry-states registry) index) terminal-state
        (aref (%registry-registrations registry) index) nil
        (aref (%registry-referents registry) index) nil
        (aref (%registry-supports registry) index) nil
        (aref (%registry-callbacks registry) index) nil
        (aref (%registry-states registry) index) :free)
  (values))

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
          (%release-finalizer-record registry index :canceled)
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

(defun %registry-pending-tail (registry)
  ;; Compute (MOD (+ head count) capacity) without an overflowing sum.
  (let* ((head (%registry-pending-head registry))
         (count (%registry-pending-count registry))
         (remaining (- (%registry-capacity registry) head)))
    (if (< count remaining) (+ head count) (- count remaining))))

(defmethod publish-pending-finalizers ((registry sequential-finalizer-registry))
  (dotimes (index (%registry-capacity registry))
    (when (eq :frozen (aref (%registry-states registry) index))
      (when (>= (%registry-pending-count registry) (%registry-capacity registry))
        ;; Whole-batch preflight made this unreachable; it is a closed fault.
        (%runtime-reject :fatal-invariant))
      (setf (aref (%registry-pending registry) (%registry-pending-tail registry)) index
            (aref (%registry-states registry) index) :pending)
      (incf (%registry-pending-count registry))))
  (values))

(defun %claim-pending-finalizer (registry)
  "Remove one FIFO entry and acquire its record before calling application code."
  (when (plusp (%registry-pending-count registry))
    (let* ((head (%registry-pending-head registry))
           (index (aref (%registry-pending registry) head)))
      (unless (and (typep index 'fixnum) (<= 0 index) (< index (%registry-capacity registry))
                   (eq :pending (aref (%registry-states registry) index)))
        (%runtime-reject :fatal-invariant))
      (setf (aref (%registry-states registry) index) :running
            (aref (%registry-pending registry) head) 0
            (%registry-pending-head registry)
            (if (= (1+ head) (%registry-capacity registry)) 0 (1+ head)))
      (decf (%registry-pending-count registry))
      index)))

(defun %finish-finalizer-callback (registry context index completed-p)
  (unless (eq :running (aref (%registry-states registry) index))
    (%runtime-reject :fatal-invariant))
  ;; Each historical registration can fail once, so this count is bounded by H.
  (unless completed-p (incf (%registry-callback-failure-count registry)))
  (when (eq :open (%plan-state (%context-plan context)))
    (%release-finalizer-record registry index :done))
  ;; A callback can return/escape after a nested collector retained the stop.
  ;; Do not mutate its managed roots or recycle its still-owned record then.
  ;; It stays claimed, outside the queue, in the irrecoverably closed registry.
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
  ;; This invocation takes at most its entry queue length. Nested drains may
  ;; consume some of that work; nested collections may append newer work.
  ;; Neither can revive this invocation's claimed record or extend its budget.
  (let ((budget (%registry-pending-count registry)) (ran 0))
    (dotimes (unused budget)
      (declare (ignorable unused))
      (let ((index (%claim-pending-finalizer registry)))
        (unless index (return))
        (let ((completed-p nil))
          (incf (%context-finalizer-depth context))
          (unwind-protect
               (handler-case
                   (progn
                     (funcall (aref (%registry-callbacks registry) index)
                              (aref (%registry-referents registry) index))
                     (setf completed-p t))
                 (error () nil))
            (unwind-protect
                 (%finish-finalizer-callback registry context index completed-p)
              (decf (%context-finalizer-depth context)))))
        (incf ran)
        (unless (eq (%plan-state (%context-plan context)) :open)
          (%runtime-reject :collection-busy))))
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
