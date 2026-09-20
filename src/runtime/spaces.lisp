;;;; Sequential spaces and authored SemiSpace/MarkSweep plan components.
(in-package #:clamsara)

(defclass runtime-allocator ()
  ((last-valid-p :initform nil :accessor %allocator-last-valid-p)))

(defclass bump-runtime-allocator (runtime-allocator)
  ((space :initarg :space :reader %allocator-space)
   (cursor :initform 0 :accessor %allocator-cursor)
   (limit :initform 0 :accessor %allocator-limit)
   (last-cursor :initform 0 :accessor %allocator-last-cursor)))

(defclass free-list-runtime-allocator (runtime-allocator)
  ((space :initarg :space :reader %allocator-space)
   (starts :initform nil :accessor %free-starts)
   (limits :initform nil :accessor %free-limits)
   (count :initform 0 :accessor %free-count)
   (last-index :initform 0 :accessor %free-last-index)
   (last-start :initform 0 :accessor %free-last-start)))

(defclass runtime-space (component)
  ((name :initarg :name :reader %space-name)
   (object-start-map :initarg :object-start-map :reader %space-object-start-map)
   (extent :initarg :extent :reader %space-extent)
   (placement-id :initform (gensym "RUNTIME-SPACE-")
                 :reader %space-placement-id)
   (state-resource-id :initform (gensym "RUNTIME-SPACE-STATE-")
                      :reader %space-state-resource-id)
   (packing-quantum :initarg :packing-quantum :reader %space-packing-quantum)
   (base :initform nil :accessor %space-base)
   (limit :initform nil :accessor %space-limit)
   (range :initform nil :accessor %space-range)
   (configuration :initform nil :accessor %space-configuration)
   (model :initform nil :accessor %space-model)
   (allocator :initform nil :accessor %space-allocator)))

(defmethod space-object-start-map ((space runtime-space))
  (%space-object-start-map space))

(defmethod component-resources ((space runtime-space))
  (list (make-resource-contribution
         space (%space-state-resource-id space) :runtime-object-vector
         :minimum-physical-bytes 16 :logical-entry-bound 0
         :auxiliary-bytes 1024 :allocation-context :construction-only
         :exhaustion-action :reject-before-publication)))

(defmethod component-dependencies ((space runtime-space))
  (list (%space-object-start-map space)))

(defmethod component-requires-bound-object-model-p ((space runtime-space))
  (declare (ignore space)) t)

(defmethod component-placement-requests ((space runtime-space))
  (list (make-placement-request
         space (%space-placement-id space)
         (%space-extent space) (%space-extent space) (%space-extent space)
         :alignment (%space-packing-quantum space)
         :granularity (%space-packing-quantum space)
         :access '(:read :write)
         :lifetime :configuration :mobility :fixed
         :reclaimability :collector :aliasable-p nil)))

(defmethod initialize-component ((space runtime-space) context)
  (multiple-value-bind (base limit present-p)
      (construction-placement context (%space-placement-id space))
    (unless (and present-p (typep base '(integer 0 *))
                 (typep limit '(integer 1 *))
                 (= (- limit base) (%space-extent space))
                 (zerop (mod base (%space-packing-quantum space))))
      (%runtime-reject :invalid-space-placement))
    (setf (%space-base space) base
          (%space-limit space) limit
          (%space-range space) (cons base limit)
          (%space-configuration space) (construction-configuration context)
          (%space-model space)
          (configuration-object-model (construction-configuration context))))
  (multiple-value-bind (handle present-p physical entries auxiliary)
      (construction-resource context (%space-state-resource-id space))
    (unless (and present-p (typep handle 'simple-vector)
                 (zerop entries) (>= physical 16) (>= auxiliary 1024))
      (%runtime-reject :resource-capacity-mismatch)))
  (%register-resource-auxiliary context (%space-state-resource-id space)
                                (%space-range space))
  (values))

(defmethod validate-component ((space runtime-space) configuration)
  (unless (and (eq configuration (%space-configuration space))
               (%space-model space)
               (%positive-power-of-two-p (%space-packing-quantum space)))
    (%runtime-reject :invalid-space))
  (multiple-value-bind (base limit granularity)
      (metadata-bounds (%space-object-start-map space))
    (unless (and (= base (%space-base space)) (= limit (%space-limit space))
                 (<= granularity (%space-packing-quantum space)))
      (%runtime-reject :object-start-coverage)))
  (values))

(defun %space-contains-address-p (space address)
  (and (<= (%space-base space) address) (< address (%space-limit space))))

(defmethod allocate-raw ((allocator bump-runtime-allocator) bytes alignment kind)
  (declare (ignore kind))
  (let* ((old (%allocator-cursor allocator))
         (start (%align-up old alignment))
         (end (+ start bytes)))
    (if (or (< end start) (> end (%allocator-limit allocator)))
        (progn (setf (%allocator-last-valid-p allocator) nil)
               (values nil nil))
        (progn
          (setf (%allocator-last-cursor allocator) old
                (%allocator-cursor allocator) end
                (%allocator-last-valid-p allocator) t)
          (values start t)))))

(defmethod allocate-raw ((allocator free-list-runtime-allocator)
                         bytes alignment kind)
  (declare (ignore kind))
  (dotimes (index (%free-count allocator) (values nil nil))
    (let* ((old (aref (%free-starts allocator) index))
           (start (%align-up old alignment))
           (end (+ start bytes)))
      (when (and (>= end start) (<= end (aref (%free-limits allocator) index)))
        ;; Runtime plans admit ALIGNMENT <= Q and Q-aligned extents.  A prefix
        ;; would otherwise need another bounded free descriptor.
        (unless (= old start) (%runtime-reject :invalid-alignment))
        (setf (%free-last-index allocator) index
              (%free-last-start allocator) old
              (aref (%free-starts allocator) index) end
              (%allocator-last-valid-p allocator) t)
        (return (values start t))))))

(defgeneric %cancel-raw-allocation (allocator))
(defmethod %cancel-raw-allocation ((allocator bump-runtime-allocator))
  (when (%allocator-last-valid-p allocator)
    (setf (%allocator-cursor allocator) (%allocator-last-cursor allocator)
          (%allocator-last-valid-p allocator) nil))
  (values))
(defmethod %cancel-raw-allocation ((allocator free-list-runtime-allocator))
  (when (%allocator-last-valid-p allocator)
    (setf (aref (%free-starts allocator) (%free-last-index allocator))
          (%free-last-start allocator)
          (%allocator-last-valid-p allocator) nil))
  (values))

(defun %commit-raw-allocation (allocator)
  (setf (%allocator-last-valid-p allocator) nil)
  (values))

(defmethod refill-mutator ((allocator runtime-allocator)
                           (context sequential-execution-context) request)
  ;; The sequential reference configuration allocates directly from its
  ;; bounded space allocator.  It has no hidden TLAB refill source.
  (declare (ignore allocator context request))
  nil)

;;; ------------------------------------------------------------------
;;; SemiSpace.

(defclass semispace-space (runtime-space)
  ((partner :initform nil :accessor %semispace-partner)
   (role :initarg :role :accessor %semispace-role)
   (candidate-role :initform nil :accessor %semispace-candidate-role)
   (forwarding :initarg :forwarding :reader %space-forwarding)))

(defmethod component-dependencies ((space semispace-space))
  (append (call-next-method) (list (%space-forwarding space))))

(defmethod initialize-component :after ((space semispace-space) context)
  (unless (typep (%space-forwarding space) 'forwarding-metadata)
    (%runtime-reject :invalid-forwarding-metadata))
  (multiple-value-bind (base limit granularity)
      (metadata-bounds (%space-forwarding space))
    (unless (and (= base (%space-base space)) (= limit (%space-limit space))
                 (= granularity (%space-packing-quantum space)))
      (%runtime-reject :forwarding-capacity-mismatch)))
  (let ((allocator (make-instance 'bump-runtime-allocator :space space)))
    (setf (%allocator-cursor allocator) (%space-base space)
          (%allocator-limit allocator) (%space-limit space)
          (%space-allocator space) allocator)
    (%register-resource-auxiliary context (%space-state-resource-id space)
                                  allocator))
  (metadata-reset-range (%space-object-start-map space) (%space-range space))
  (metadata-reset-range (%space-forwarding space) (%space-range space))
  (values))

(defun make-semispace-space (&key name object-start-map forwarding
                                      extent packing-quantum role)
  (unless (member role '(:allocation :reserve))
    (%runtime-reject :invalid-space-role))
  (unless (and (typep extent '(integer 1 *))
               (%positive-power-of-two-p packing-quantum)
               (zerop (mod extent packing-quantum)))
    (%runtime-reject :invalid-space-extent))
  (make-instance 'semispace-space :name name :object-start-map object-start-map
                 :extent extent :packing-quantum packing-quantum :role role
                 :forwarding forwarding))

(defun %forwarding-key (space start)
  (let ((address (reference-address (%space-model space) start)))
    (unless (%space-contains-address-p space address)
      (%runtime-reject :fatal-invariant))
    address))

(defun %copying-destination (space cycle start)
  (declare (ignore cycle start))
  (%semispace-partner space))

(defmethod %space-in-cycle-scope-p ((space semispace-space) cycle start)
  (declare (ignore start))
  (and (member (%cycle-scope cycle) '(:all :minor))
       (eq (%semispace-role space) :allocation)))

(defmethod prepare-space ((space semispace-space) cycle)
  (declare (ignore cycle))
  (setf (%semispace-candidate-role space)
        (if (eq (%semispace-role space) :allocation) :reserve :allocation))
  (when (eq (%semispace-role space) :reserve)
    (let ((allocator (%space-allocator space)))
      (setf (%allocator-cursor allocator) (%space-base space)
            (%allocator-last-valid-p allocator) nil)
      (metadata-reset-range (%space-object-start-map space) (%space-range space))))
  (metadata-reset-range (%space-forwarding space) (%space-range space))
  (values))

(defmethod trace-object ((space semispace-space)
                         (context sequential-trace-context) start)
  (multiple-value-bind (status claim reservation)
      (trace-claim-object context space start)
    (case status
      (:seen
       (unless (eq :complete (trace-await-claim context space start))
         (trace-fail context :fatal-invariant)
         (return-from trace-object start))
       (or (metadata-ref (%space-forwarding space) (%forwarding-key space start))
           (progn (trace-fail context :fatal-invariant) start)))
      (:failed start)
      (:first
       (let* ((cycle (trace-context-cycle context))
              (destination (%copying-destination space cycle start))
              (model (%space-model space))
              (bytes (object-size model start))
              (alignment (object-alignment model start))
              (quantum (%space-packing-quantum space)))
         (unless (and (typep bytes '(integer 1 *))
                      (%positive-power-of-two-p alignment)
                      (<= alignment quantum))
           (trace-abandon-object context claim reservation :fatal-invariant)
           (return-from trace-object start))
         (let ((charged (%align-up bytes quantum)))
           (multiple-value-bind (address success-p)
               (allocate-raw (%space-allocator destination) charged quantum
                             (object-kind model start))
             (unless success-p
               (trace-abandon-object context claim reservation
                                     :capacity-exhausted)
               (return-from trace-object start))
             (let ((new nil)
                   (destination-start-p nil))
               (handler-case
                   (let* ((kind (object-kind model start))
                          (descriptor (object-kind-descriptor model kind)))
                     (setf new
                           (initialize-object model address kind bytes descriptor))
                     (copy-object-representation model start new)
                     (metadata-set (%space-object-start-map destination) address 1)
                     (setf destination-start-p t)
                     ;; Forwarding becomes visible only after the destination
                     ;; ABI and authoritative object-start fact exist.
                     (metadata-set (%space-forwarding space)
                                   (%forwarding-key space start) new)
                     (setf (%cycle-forwarding-published-p cycle) t)
                     (%commit-raw-allocation (%space-allocator destination))
                     (unless (%record-cycle-movement cycle start new)
                       (trace-fail context :post-publication-failure)
                       (return-from trace-object start))
                     (%cycle-counter-incf cycle :bytes-moved bytes)
                     (unless (eq :complete
                                 (trace-commit-object context claim reservation
                                                      destination new))
                       (trace-fail context :post-publication-failure)
                       (return-from trace-object start))
                     new)
                 (error ()
                   (if (%cycle-forwarding-published-p cycle)
                       (trace-fail context :post-publication-failure)
                       (progn
                         ;; A pre-forwarding copy fault is reversible.  Clear
                         ;; any authoritative destination fact before retiring
                         ;; its exact representation; use no post-clear lookup.
                         (when destination-start-p
                           (metadata-reset (%space-object-start-map destination)
                                           address))
                         (when new
                           (runtime-retire-object-representation model new))
                         (%cancel-raw-allocation
                          (%space-allocator destination))
                         (trace-abandon-object context claim reservation
                                               :preflight-failed)))
                   start))))))))))

(defmethod object-live-p ((space semispace-space) cycle reference)
  (declare (ignore cycle))
  (let ((model (%space-model space)))
    (if (not (valid-reference-p model reference))
        nil
        (multiple-value-bind (start descriptor) (normalize-reference model reference)
          (declare (ignore descriptor))
          (and (%space-contains-address-p space (reference-address model start))
               (or (metadata-ref (%space-forwarding space)
                                 (%forwarding-key space start))
                   nil))))))

(defun %stage-semispace-retirement (cycle address)
  (let* ((space (%cycle-current-retirement-space cycle))
         (model (%space-model space))
         (index (%cycle-retirement-count cycle)))
    (when (>= index (length (%cycle-retirement-starts cycle)))
      (trace-fail (%cycle-trace cycle) :capacity-exhausted)
      (return-from %stage-semispace-retirement (values)))
    (let ((start (runtime-start-reference model space address)))
      (setf (aref (%cycle-retirement-starts cycle) index) start)
      (incf (%cycle-retirement-count cycle))
      (unless (object-live-p space cycle start)
        (unless (%record-cycle-death cycle space start)
          (trace-fail (%cycle-trace cycle) :capacity-exhausted)))))
  (values))

(defmethod reclaim-space ((space semispace-space) cycle)
  ;; Enumerate every source representation while authoritative starts still
  ;; exist.  The callback cannot mutate traversed metadata, so actual clear and
  ;; retirement remain a later closed commit obligation.
  (when (eq (%semispace-role space) :allocation)
    (setf (%cycle-current-retirement-space cycle) space)
    (metadata-map-present (%space-object-start-map space) (%space-range space)
                          (%cycle-retirement-callback cycle))
    (setf (%cycle-current-retirement-space cycle) nil)
    (when (%trace-failed-reason (%cycle-trace cycle))
      (return-from reclaim-space
        (values :failed (%trace-failed-reason (%cycle-trace cycle))))))
  ;; Equal Q-charged extents make destination capacity order-independent.
  ;; Copy allocation already checked every bound before forwarding.
  (values :ready nil))

(defmethod cancel-reclaim-space ((space semispace-space) cycle)
  (declare (ignore cycle))
  (setf (%semispace-candidate-role space) nil)
  (values))

(defmethod finish-space ((space semispace-space) cycle)
  (when (eq (%semispace-role space) :allocation)
    (metadata-reset-range (%space-object-start-map space) (%space-range space))
    ;; The authoritative clear precedes bounded retirement of every source
    ;; representation, not only live objects that have movement records.
    (dotimes (index (%cycle-retirement-count cycle))
      ;; The retirement batch belongs to the sole source role staged above.
      ;; Do not normalize or ask the public model for an address after the
      ;; authoritative start range has been cleared.
      (runtime-retire-object-representation
       (%space-model space) (aref (%cycle-retirement-starts cycle) index)))
    (metadata-reset-range (%space-forwarding space) (%space-range space))
    (let ((allocator (%space-allocator space)))
      (setf (%allocator-cursor allocator) (%space-base space)
            (%allocator-last-valid-p allocator) nil))
    (setf (%semispace-role space) :reserve))
  (when (%semispace-candidate-role space)
    (setf (%semispace-role space) (%semispace-candidate-role space)
          (%semispace-candidate-role space) nil))
  (values))

(defclass semispace-plan (sequential-runtime-plan) ())

(defmethod component-constraints ((plan semispace-plan))
  (let ((spaces (%plan-spaces plan)))
    (list (make-construction-constraint
           plan :equal-extent
           (mapcar (lambda (space) (list :placement (%space-placement-id space)))
                   spaces)
           :description "SemiSpace ranges have equal Q-charged capacity"))))

(defun make-semispace-plan (&key from-space to-space root-client coordinator
                              diagnostics registry trace-capacity
                              conditional-capacity finalizer-capacity
                              packing-quantum allocation-routes)
  (unless (and (typep from-space 'semispace-space)
               (typep to-space 'semispace-space)
               (= (%space-extent from-space) (%space-extent to-space))
               (= (%space-packing-quantum from-space) packing-quantum)
               (= (%space-packing-quantum to-space) packing-quantum)
               (eq (%semispace-role from-space) :allocation)
               (eq (%semispace-role to-space) :reserve))
    (%runtime-reject :invalid-semispace-pair))
  (setf (%semispace-partner from-space) to-space
        (%semispace-partner to-space) from-space)
  (%make-common-plan-instance
   'semispace-plan
   :root-client root-client :coordinator coordinator :diagnostics diagnostics
   :registry registry :spaces (list from-space to-space)
   :trace-capacity trace-capacity :conditional-capacity conditional-capacity
   :finalizer-capacity finalizer-capacity :packing-quantum packing-quantum
   :allocation-routes (or allocation-routes (list (list :default from-space :all)))
   :default-algorithm :semispace :algorithms '(:semispace)))

;;; ------------------------------------------------------------------
;;; MarkSweep.

(defclass marksweep-space (runtime-space)
  ((marks :initarg :marks :reader %space-marks)
   (descriptor-capacity :initarg :descriptor-capacity
                        :reader %marksweep-descriptor-capacity)
   (free-resource-id :initform (gensym "MARKSWEEP-FREE-")
                     :reader %marksweep-free-resource-id)
   (active-starts :initform nil :accessor %marksweep-active-starts)
   (active-limits :initform nil :accessor %marksweep-active-limits)
   (candidate-starts :initform nil :accessor %marksweep-candidate-starts)
   (candidate-limits :initform nil :accessor %marksweep-candidate-limits)
   (candidate-count :initform 0 :accessor %marksweep-candidate-count)
   (candidate-ready-p :initform nil :accessor %marksweep-candidate-ready-p)
   (reclaim-cycle :initform nil :accessor %marksweep-reclaim-cycle)
   (reclaim-cursor :initform 0 :accessor %marksweep-reclaim-cursor)
   (reclaim-free-start :initform 0 :accessor %marksweep-reclaim-free-start)
   (reclaim-callback :initform nil :accessor %marksweep-reclaim-callback)))

(defmethod component-dependencies ((space marksweep-space))
  (append (call-next-method) (list (%space-marks space))))

(defmethod component-resources ((space marksweep-space))
  (let ((entries (* 4 (%marksweep-descriptor-capacity space))))
    (append (call-next-method)
            (list (make-resource-contribution
                   space (%marksweep-free-resource-id space) :runtime-index-vector
                   :minimum-physical-bytes (+ 16 (* 8 entries))
                   :logical-entry-bound entries
                   :auxiliary-bytes 1024 :allocation-context :construction-only
                   :exhaustion-action :reject-before-publication)))))

(defmethod initialize-component :after ((space marksweep-space) context)
  (let ((capacity (%marksweep-descriptor-capacity space)))
    (multiple-value-bind (handle present-p physical entries auxiliary)
        (construction-resource context (%marksweep-free-resource-id space))
      (unless (and present-p (typep handle 'simple-vector)
                   (>= physical (+ 16 (* 8 (* 4 capacity))))
                   (>= auxiliary 1024)
                   (>= entries (* 4 capacity))
                   (>= (length handle) (* 4 capacity)))
        (%runtime-reject :free-descriptor-capacity))
      (setf (%marksweep-active-starts space)
            (make-array capacity :displaced-to handle)
            (%marksweep-active-limits space)
            (make-array capacity :displaced-to handle
                        :displaced-index-offset capacity)
            (%marksweep-candidate-starts space)
            (make-array capacity :displaced-to handle
                        :displaced-index-offset (* 2 capacity))
            (%marksweep-candidate-limits space)
            (make-array capacity :displaced-to handle
                        :displaced-index-offset (* 3 capacity))))
    (let ((allocator (make-instance 'free-list-runtime-allocator :space space)))
      (setf (aref (%marksweep-active-starts space) 0) (%space-base space)
            (aref (%marksweep-active-limits space) 0) (%space-limit space)
            (%free-starts allocator) (%marksweep-active-starts space)
            (%free-limits allocator) (%marksweep-active-limits space)
            (%free-count allocator) 1
            (%space-allocator space) allocator)
      (%register-resource-auxiliary context (%space-state-resource-id space)
                                    allocator))
    (setf (%marksweep-reclaim-callback space)
          (lambda (key value)
            (declare (ignore value))
            (%marksweep-visit-start space key)))
    (dolist (object (list (%marksweep-active-starts space)
                          (%marksweep-active-limits space)
                          (%marksweep-candidate-starts space)
                          (%marksweep-candidate-limits space)
                          (%marksweep-reclaim-callback space)))
      (%register-resource-auxiliary context (%marksweep-free-resource-id space)
                                    object)))
  (metadata-reset-range (%space-object-start-map space) (%space-range space))
  (metadata-reset-range (%space-marks space) (%space-range space))
  (values))

(defun make-marksweep-space (&key name object-start-map marks extent
                               packing-quantum descriptor-capacity)
  (unless (and (typep descriptor-capacity '(integer 1 *))
               (typep extent '(integer 1 *))
               (%positive-power-of-two-p packing-quantum)
               (zerop (mod extent packing-quantum)))
    (%runtime-reject :invalid-marksweep-space))
  (make-instance 'marksweep-space :name name
                 :object-start-map object-start-map :marks marks
                 :extent extent :packing-quantum packing-quantum
                 :descriptor-capacity descriptor-capacity))

(defmethod %space-in-cycle-scope-p ((space marksweep-space) cycle start)
  (declare (ignore space start))
  (eq (%cycle-scope cycle) :all))

(defmethod prepare-space ((space marksweep-space) cycle)
  (declare (ignore cycle))
  (metadata-reset-range (%space-marks space) (%space-range space))
  (setf (%marksweep-candidate-count space) 0
        (%marksweep-candidate-ready-p space) nil)
  (values))

(defmethod trace-object ((space marksweep-space)
                         (context sequential-trace-context) start)
  (multiple-value-bind (status claim reservation)
      (trace-claim-object context space start)
    (case status
      (:seen start)
      (:failed start)
      (:first
       (handler-case
           (progn
             (metadata-set-bit (%space-marks space)
                               (reference-address (%space-model space) start))
             (if (eq :complete
                     (trace-commit-object context claim reservation space start))
                 start
                 (progn (trace-fail context :fatal-invariant) start)))
         (error ()
           (trace-abandon-object context claim reservation :preflight-failed)
           start))))))

(defmethod object-live-p ((space marksweep-space) cycle reference)
  (declare (ignore cycle))
  (let ((model (%space-model space)))
    (if (not (valid-reference-p model reference))
        nil
        (multiple-value-bind (start descriptor) (normalize-reference model reference)
          (declare (ignore descriptor))
          (and (%space-contains-address-p space (reference-address model start))
               (eql 1 (metadata-ref (%space-marks space)
                                    (reference-address model start))))))))

(defun %marksweep-add-free (space start limit)
  (when (< start limit)
    (let ((index (%marksweep-candidate-count space)))
      (when (>= index (%marksweep-descriptor-capacity space))
        (return-from %marksweep-add-free nil))
      (setf (aref (%marksweep-candidate-starts space) index) start
            (aref (%marksweep-candidate-limits space) index) limit)
      (incf (%marksweep-candidate-count space))))
  t)

(defun %marksweep-visit-start (space address)
  (let* ((cycle (%marksweep-reclaim-cycle space))
         (model (%space-model space))
         ;; Canonical start encodings in the reference host are rebuilt by
         ;; normalizing an allocated base obtained from the map binding.
         (start (runtime-start-reference model space address))
         (bytes (object-size model start))
         (end (+ address (%align-up bytes (%space-packing-quantum space)))))
    (unless (and (>= address (%marksweep-reclaim-cursor space))
                 (> end address) (<= end (%space-limit space)))
      (%runtime-reject :fatal-invariant))
    (if (eql 1 (metadata-ref (%space-marks space) address))
        (progn
          (unless (%marksweep-add-free space
                                       (%marksweep-reclaim-free-start space)
                                       address)
            (%runtime-reject :capacity-exhausted))
          (setf (%marksweep-reclaim-free-start space) end))
        (unless (%record-cycle-death cycle space start)
          (%runtime-reject :capacity-exhausted)))
    (setf (%marksweep-reclaim-cursor space) end)))

(defmethod reclaim-space ((space marksweep-space) cycle)
  (setf (%marksweep-reclaim-cycle space) cycle
        (%marksweep-reclaim-cursor space) (%space-base space)
        (%marksweep-reclaim-free-start space) (%space-base space)
        (%marksweep-candidate-count space) 0)
  (handler-case
      (progn
        (metadata-map-present (%space-object-start-map space)
                              (%space-range space)
                              (%marksweep-reclaim-callback space))
        (unless (%marksweep-add-free space
                                     (%marksweep-reclaim-free-start space)
                                     (%space-limit space))
          (return-from reclaim-space
            (values :retained :capacity-exhausted)))
        (setf (%marksweep-candidate-ready-p space) t)
        (values :ready nil))
    (error ()
      (setf (%marksweep-candidate-ready-p space) nil)
      (values :retained :preflight-failed))))

(defmethod cancel-reclaim-space ((space marksweep-space) cycle)
  (declare (ignore cycle))
  (setf (%marksweep-candidate-ready-p space) nil
        (%marksweep-candidate-count space) 0)
  (values))

(defmethod finish-space ((space marksweep-space) cycle)
  (unless (%marksweep-candidate-ready-p space)
    (%runtime-reject :fatal-invariant))
  ;; Death enumeration was completely validated during preflight.  Clearing
  ;; authoritative starts is now a bounded non-failing commit obligation.
  (dotimes (index (%cycle-death-count cycle))
    (when (eq space (aref (%cycle-death-spaces cycle) index))
      (let ((start (aref (%cycle-death-starts cycle) index)))
        (metadata-reset (%space-object-start-map space)
                        (reference-address (%space-model space) start))
        (runtime-retire-object-representation (%space-model space) start))))
  (rotatef (%marksweep-active-starts space) (%marksweep-candidate-starts space))
  (rotatef (%marksweep-active-limits space) (%marksweep-candidate-limits space))
  (let ((allocator (%space-allocator space)))
    (setf (%free-starts allocator) (%marksweep-active-starts space)
          (%free-limits allocator) (%marksweep-active-limits space)
          (%free-count allocator) (%marksweep-candidate-count space)
          (%allocator-last-valid-p allocator) nil))
  (setf (%marksweep-candidate-ready-p space) nil)
  (values))

(defclass marksweep-plan (sequential-runtime-plan) ())

(defun make-marksweep-plan (&key space root-client coordinator diagnostics registry
                              trace-capacity conditional-capacity
                              finalizer-capacity packing-quantum allocation-routes)
  (unless (and (typep space 'marksweep-space)
               (= (%space-packing-quantum space) packing-quantum))
    (%runtime-reject :invalid-marksweep-space))
  (%make-common-plan-instance
   'marksweep-plan :root-client root-client
   :coordinator coordinator :diagnostics diagnostics :registry registry
   :spaces (list space) :trace-capacity trace-capacity
   :conditional-capacity conditional-capacity
   :finalizer-capacity finalizer-capacity :packing-quantum packing-quantum
   :allocation-routes (or allocation-routes (list (list :default space :all)))
   :default-algorithm :marksweep :algorithms '(:marksweep)))
