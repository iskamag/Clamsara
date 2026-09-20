;;;; Mutator binding and exact sequential allocation retry protocol.
(in-package #:clamsara)

(defun %allocation-route (plan domain)
  (find domain (%plan-allocation-routes plan) :key #'first :test #'eql))

(defun %route-space (plan route)
  (let ((declared (second route)))
    (if (typep declared 'semispace-space)
        (or (find :allocation (%plan-spaces plan)
                  :key (lambda (space)
                         (and (typep space 'semispace-space)
                              (%semispace-role space)))
                  :test #'eq)
            declared)
        declared)))

(defmethod bind-mutator (configuration execution allocation-domain)
  (let* ((plan (%configuration-runtime-plan configuration))
         (route (%allocation-route plan allocation-domain)))
    (unless (eq (%plan-state plan) :open)
      (%runtime-reject :collection-busy))
    (unless route (%runtime-reject :invalid-kind))
    (when (= (%plan-next-context-generation plan) most-positive-fixnum)
      (%runtime-reject :generation-exhausted))
    (let* ((barrier (configuration-barrier configuration))
           (barrier-count (length (%barrier-contributions barrier)))
           (space (%route-space plan route))
           (context
             (make-instance
              'sequential-execution-context
              :configuration configuration :plan plan :execution execution
              :allocation-domain allocation-domain
              :allocator (%space-allocator space)
              :generation (incf (%plan-next-context-generation plan))
              :refill-request (make-array 3 :initial-element nil)
              :barrier-reservations
              (make-array barrier-count :initial-element nil)
              :barrier-reserved-p
              (make-array barrier-count :initial-element nil))))
      ;; Publication follows complete context provisioning.
      (incf (%plan-active-context-count plan))
      context)))

(defmethod unbind-mutator (configuration
                           (context sequential-execution-context))
  (let ((plan (%configuration-runtime-plan configuration)))
    (unless (and (eq configuration (%context-configuration context))
                 (eq plan (%context-plan context)))
      (%runtime-reject :foreign-context))
    (case (%context-state context)
      (:unbound :already-unbound)
      (:bound
       (when (member (%plan-state plan) '(:collecting :retained))
         (return-from unbind-mutator :retry))
       (setf (%context-state context) :unbound
             (%context-allocator context) nil
             (%context-cursor context) 0
             (%context-limit context) 0)
       (fill (%context-refill-request context) nil)
       (fill (%context-barrier-reservations context) nil)
       (fill (%context-barrier-reserved-p context) nil)
       (decf (%plan-active-context-count plan))
       :unbound)
      (otherwise (%runtime-reject :fatal-invariant)))))

(defun %validate-allocation (context kind bytes alignment descriptor)
  (let* ((configuration (%context-configuration context))
         (model (configuration-object-model configuration))
         (plan (%context-plan context))
         (expected (handler-case (object-kind-descriptor model kind)
                     (error () nil))))
    (cond ((or (null expected) (not (eq expected descriptor))) :invalid-kind)
          ((not (typep bytes '(integer 1 *))) :invalid-size)
          ((not (%positive-power-of-two-p alignment)) :invalid-alignment)
          ((> alignment (%plan-packing-quantum plan)) :invalid-alignment)
          ((null (%allocation-route plan (%context-domain context))) :invalid-kind)
          (t nil))))

(defun %attempt-object-allocation (context kind bytes descriptor)
  (let* ((configuration (%context-configuration context))
         (model (configuration-object-model configuration))
         (plan (%context-plan context))
         (route (%allocation-route plan (%context-domain context)))
         (space (%route-space plan route))
         (allocator (%space-allocator space))
         (charged (%align-up bytes (%plan-packing-quantum plan))))
    (setf (%context-allocator context) allocator)
    (multiple-value-bind (address success-p)
        (allocate-raw allocator charged (%plan-packing-quantum plan) kind)
      (unless success-p (return-from %attempt-object-allocation (values nil nil)))
      (let ((start-set-p nil)
            (reference nil))
        (handler-case
            (progn
              (setf reference
                    (initialize-object model address kind bytes descriptor))
              (unless (and (valid-reference-p model reference)
                           (= address (reference-address model reference)))
                (%runtime-reject :fatal-invariant))
              (metadata-set (%space-object-start-map space) address 1)
              (setf start-set-p t)
              ;; Other allocation metadata roles have zero/default state from
              ;; space preparation.  The authoritative start publishes last.
              (%commit-raw-allocation allocator)
              (values reference t))
          (error (condition)
            (when start-set-p
              (metadata-reset (%space-object-start-map space) address))
            (when reference
              (runtime-retire-object-representation model reference))
            (%cancel-raw-allocation allocator)
            (error condition)))))))

(defun %automatic-success-p (status outcome)
  (and (eq status :complete) (eq outcome :complete)))

(defmethod allocate-object ((context sequential-execution-context)
                            kind bytes alignment descriptor)
  (unless (eq (%context-state context) :bound)
    (%runtime-reject :foreign-context))
  (unless (eq (%plan-state (%context-plan context)) :open)
    (%runtime-reject :collection-busy))
  (let ((validation (%validate-allocation context kind bytes alignment descriptor)))
    (when validation
      (return-from allocate-object (values nil :failed validation))))
  ;; Stage 1: current local allocator.
  (multiple-value-bind (reference success-p)
      (%attempt-object-allocation context kind bytes descriptor)
    (when success-p
      (return-from allocate-object (values reference :allocated nil))))
  ;; Stage 2: one refill attempt.  The reference sequential allocator has no
  ;; hidden refill source, but the protocol call is still made exactly once.
  (let ((request (%context-refill-request context)))
    (setf (aref request 0) bytes
          (aref request 1) alignment
          (aref request 2) kind)
    (when (refill-mutator (%context-allocator context) context request)
      (multiple-value-bind (reference success-p)
        (%attempt-object-allocation context kind bytes descriptor)
        (when success-p
          (return-from allocate-object (values reference :allocated nil))))))
  (let* ((plan (%context-plan context))
         (route (%allocation-route plan (%context-domain context)))
         (route-scope (third route)))
    ;; Stage 3: configured route collection and one retry only after COMPLETE.
    (multiple-value-bind (status outcome)
        (automatic-collect (%context-configuration context) route-scope
                           :allocation-route)
      (when (eq status :retained)
        (return-from allocate-object (values nil :failed outcome)))
      (when (%automatic-success-p status outcome)
        (multiple-value-bind (reference success-p)
            (%attempt-object-allocation context kind bytes descriptor)
          (when success-p
            (return-from allocate-object (values reference :allocated nil)))))
      ;; Rejection does not count as permission to retry, but a distinct full
      ;; scope is still attempted once when construction admits it.
      (unless (eq route-scope :all)
        (multiple-value-bind (full-status full-outcome)
            (automatic-collect (%context-configuration context) :all
                               :allocation-full)
          (when (eq full-status :retained)
            (return-from allocate-object (values nil :failed full-outcome)))
          (when (%automatic-success-p full-status full-outcome)
            (multiple-value-bind (reference success-p)
                (%attempt-object-allocation context kind bytes descriptor)
              (when success-p
                (return-from allocate-object
                  (values reference :allocated nil)))))))
      (values nil :failed :heap-exhausted))))
