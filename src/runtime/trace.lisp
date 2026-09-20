;;;; Shared sequential reference dispatcher, claims, work and discovery replay.
(in-package #:clamsara)

(defgeneric %space-in-cycle-scope-p (space cycle start))
(defmethod %space-in-cycle-scope-p ((space component) cycle start)
  (declare (ignore space start))
  (eq (%cycle-scope cycle) :all))

(defun %reset-trace-context (context scope)
  (let* ((capacity (%trace-capacity context))
         (maximum-generation
           (floor (floor (- most-positive-fixnum 2) 2) capacity)))
    (when (>= (%trace-generation context) maximum-generation)
      (%runtime-reject :generation-exhausted))
    (incf (%trace-generation context)))
  (setf (%trace-scope context) scope
        (%trace-reserved-count context) 0
        (%trace-committed-count context) 0
        (%trace-take-index context) 0
        (%trace-active-index context) nil
        (%trace-failed-reason context) nil)
  (fill (%trace-source-spaces context) nil)
  (fill (%trace-source-starts context) nil)
  (fill (%trace-states context) nil)
  (fill (%trace-work-spaces context) nil)
  (fill (%trace-work-starts context) nil)
  context)

(defmethod begin-trace-context ((cycle sequential-cycle) scope work-capacity)
  (let ((context (%cycle-trace cycle)))
    (unless (and (typep work-capacity '(integer 0 *))
                 (<= work-capacity (%trace-capacity context)))
      (%runtime-reject :capacity-exhausted))
    ;; The required sequential plan always admits discovery.  A zero bound can
    ;; only be used with an empty/noncollecting scope, which this plan does not
    ;; claim.
    (when (zerop work-capacity) (%runtime-reject :capacity-exhausted))
    (%reset-trace-context context scope)))

(defmethod trace-scope-contains-p ((context sequential-trace-context) space start)
  (%space-in-cycle-scope-p space (trace-context-cycle context) start))

(defun %trace-direct-index (context space start)
  (let* ((cycle (trace-context-cycle context))
         (model (configuration-object-model (%cycle-configuration cycle)))
         (address (reference-address model start))
         (offset 0))
    (dolist (candidate (%plan-spaces (%cycle-plan cycle)))
      (let* ((quantum (%space-packing-quantum candidate))
             (cells (ceiling (%space-extent candidate) quantum)))
        (when (eq candidate space)
          (unless (and (<= (%space-base candidate) address)
                       (< address (%space-limit candidate))
                       (zerop (mod (- address (%space-base candidate)) quantum)))
            (return-from %trace-direct-index nil))
          (let ((index (+ offset
                          (floor (- address (%space-base candidate)) quantum))))
            (return-from %trace-direct-index
              (and (< index (%trace-capacity context)) index))))
        ;; Two equal SemiSpace roles are mutually exclusive source domains and
        ;; intentionally share the same direct claim cells across cycles.
        (unless (typep (%cycle-plan cycle) 'semispace-plan)
          (incf offset cells))))
    nil))

(defun %trace-source-index (context space start)
  (let ((index (%trace-direct-index context space start)))
    (when (and index
               (aref (%trace-states context) index)
               (eq space (aref (%trace-source-spaces context) index))
               (eql start (aref (%trace-source-starts context) index))
               (not (eq :abandoned (aref (%trace-states context) index))))
      index)))

(defun %make-trace-capability (context index kind)
  ;; Immutable bounded fixnum: [generation | direct source index | kind].
  (+ (* 2 (+ index (* (%trace-generation context)
                      (%trace-capacity context))))
     kind))

(defun %decode-trace-capability (context token expected-kind)
  (when (typep token '(integer 1 #.most-positive-fixnum))
    (let* ((kind (mod token 2))
           (payload (floor token 2))
           (capacity (%trace-capacity context))
           (index (mod payload capacity))
           (generation (floor payload capacity)))
      (when (and (= kind expected-kind)
                 (= generation (%trace-generation context))
                 (< index capacity)
                 (eq :claimed (aref (%trace-states context) index)))
        index))))

(defmethod trace-claim-object ((context sequential-trace-context) space start)
  (when (%trace-failed-reason context)
    (return-from trace-claim-object (values :failed nil nil)))
  (let ((direct-index (%trace-direct-index context space start)))
    (unless direct-index
      (trace-fail context :fatal-invariant)
      (return-from trace-claim-object (values :failed nil nil)))
    (let ((state (aref (%trace-states context) direct-index)))
      (when state
        (unless (and (eq space (aref (%trace-source-spaces context) direct-index))
                     (eql start (aref (%trace-source-starts context) direct-index)))
          (trace-fail context :fatal-invariant)
          (return-from trace-claim-object (values :failed nil nil)))
        (return-from trace-claim-object
          (case state
            (:committed (values :seen nil nil))
            (:claimed
             (trace-fail context :fatal-invariant)
             (values :failed nil nil))
            (otherwise
             (trace-fail context :fatal-invariant)
             (values :failed nil nil)))))
      (when (>= (%trace-reserved-count context) (%trace-capacity context))
        (trace-fail context :capacity-exhausted)
        (return-from trace-claim-object (values :failed nil nil)))
      (setf (aref (%trace-source-spaces context) direct-index) space
            (aref (%trace-source-starts context) direct-index) start
            (aref (%trace-states context) direct-index) :claimed)
      (incf (%trace-reserved-count context))
      (values :first
              (%make-trace-capability context direct-index 0)
              (%make-trace-capability context direct-index 1)))))

(defmethod trace-await-claim ((context sequential-trace-context) space start)
  (let ((index (%trace-source-index context space start)))
    (cond ((null index) :failed)
          ((eq :committed (aref (%trace-states context) index)) :complete)
          (t :failed))))

(defmethod trace-commit-object ((context sequential-trace-context)
                                claim reservation work-space work-start)
  (let ((claim-index (%decode-trace-capability context claim 0))
        (reservation-index (%decode-trace-capability context reservation 1)))
    (unless (and claim-index reservation-index
                 (= claim-index reservation-index))
      (trace-fail context :fatal-invariant)
      (return-from trace-commit-object :not-owner))
    (when (%trace-failed-reason context)
      (return-from trace-commit-object :failed))
    (let ((work-index (%trace-committed-count context)))
      (when (>= work-index (%trace-capacity context))
        (trace-fail context :capacity-exhausted)
        (return-from trace-commit-object :failed))
      (setf (aref (%trace-work-spaces context) work-index) work-space
            (aref (%trace-work-starts context) work-index) work-start
            (aref (%trace-states context) claim-index) :committed)
      (incf (%trace-committed-count context))
      (%cycle-counter-incf (trace-context-cycle context) :objects-discovered)
      :complete)))

(defmethod trace-abandon-object ((context sequential-trace-context)
                                 claim reservation reason)
  (let ((claim-index (%decode-trace-capability context claim 0))
        (reservation-index (%decode-trace-capability context reservation 1)))
    (if (and claim-index reservation-index (= claim-index reservation-index))
        (setf (aref (%trace-states context) claim-index) :abandoned)
        (setf reason :fatal-invariant)))
  (trace-fail context reason)
  (values))

(defmethod trace-take-work ((context sequential-trace-context) worker)
  (declare (ignore worker))
  (cond
    ((%trace-failed-reason context) (values nil nil :failed))
    ((%trace-active-index context) (values nil nil :wait))
    ((< (%trace-take-index context) (%trace-committed-count context))
     (let ((index (%trace-take-index context)))
       (setf (%trace-active-index context) index)
       (values (aref (%trace-work-spaces context) index)
               (aref (%trace-work-starts context) index)
               :work)))
    ((< (%trace-committed-count context) (%trace-reserved-count context))
     (values nil nil :wait))
    (t (values nil nil :quiescent))))

(defmethod trace-finish-work ((context sequential-trace-context) worker space start)
  (declare (ignore worker))
  (let ((index (%trace-active-index context)))
    (unless (and index
                 (eq space (aref (%trace-work-spaces context) index))
                 (eql start (aref (%trace-work-starts context) index)))
      (trace-fail context :fatal-invariant)
      (return-from trace-finish-work (values)))
    (setf (%trace-active-index context) nil
          (%trace-take-index context) (1+ index))
    (values)))

(defmethod trace-fail ((context sequential-trace-context) reason)
  (unless (%trace-failed-reason context)
    (setf (%trace-failed-reason context) reason))
  (values))

(defmethod finish-trace-context ((context sequential-trace-context))
  (cond ((%trace-failed-reason context)
         (values :failed (%trace-failed-reason context)))
        ((and (= (%trace-take-index context) (%trace-committed-count context))
              (= (%trace-committed-count context)
                 (%trace-reserved-count context))
              (null (%trace-active-index context)))
         (values :complete nil))
        (t (values :failed :fatal-invariant))))

(defmethod map-trace-discoveries ((context sequential-trace-context) function)
  (dotimes (index (%trace-committed-count context))
    (funcall function (aref (%trace-work-spaces context) index)
             (aref (%trace-work-starts context) index)))
  (values))

(defun %metadata-present-p (metadata key)
  (let ((value (metadata-ref metadata key)))
    (and value (not (eql value 0)))))

(defmethod trace-reference ((context sequential-trace-context) reference)
  (let* ((cycle (trace-context-cycle context))
         (configuration (%cycle-configuration cycle))
         (model (configuration-object-model configuration)))
    (unless (valid-reference-p model reference)
      (return-from trace-reference reference))
    (multiple-value-bind (start descriptor) (normalize-reference model reference)
      (let ((space (space-of-reference (configuration-layout configuration) start)))
        (unless space
          (trace-fail context :fatal-invariant)
          (return-from trace-reference reference))
        (unless (%metadata-present-p (%space-object-start-map space)
                                    (reference-address model start))
          (trace-fail context :fatal-invariant)
          (return-from trace-reference reference))
        (unless (trace-scope-contains-p context space start)
          ;; Preserve the exact original encoding outside explicit scope.
          (return-from trace-reference reference))
        (let ((new-start (trace-object space context start)))
          (if (%trace-failed-reason context)
              reference
              (rebuild-reference model new-start descriptor)))))))

(defun %trace-root-location (cycle location)
  (let* ((plan (%cycle-plan cycle))
         (roots (%plan-root-client plan))
         (old (load-root roots location))
         (new (trace-reference (%cycle-trace cycle) old)))
    (unless (%trace-failed-reason (%cycle-trace cycle))
      (store-root roots location new))))

(defun %trace-strong-location (cycle location)
  (let* ((model (configuration-object-model (%cycle-configuration cycle)))
         (old (load-reference model location))
         (new (trace-reference (%cycle-trace cycle) old)))
    (unless (%trace-failed-reason (%cycle-trace cycle))
      (store-reference-raw model location new))))

(defun %drain-strong-work (cycle)
  (let ((context (%cycle-trace cycle))
        (model (configuration-object-model (%cycle-configuration cycle))))
    (loop
      (multiple-value-bind (space start status)
          (trace-take-work context cycle)
        (case status
          (:work
           (handler-case
               (progn
                 (map-reference-locations model start
                                          (%cycle-strong-callback cycle))
                 (trace-finish-work context cycle space start))
             (error ()
               ;; The active item deliberately remains active.  A failed scan
               ;; is not quiescent or reclaimable.
               (trace-fail context :fatal-invariant)
               (return (values :failed :fatal-invariant)))))
          (:quiescent (return (values :complete nil)))
          (:failed (return (values :failed (%trace-failed-reason context))))
          (:wait
           ;; No concurrent producer exists in this profile.  WAIT therefore
           ;; denotes an invariant fault rather than a spin or mutator wait.
           (trace-fail context :fatal-invariant)
           (return (values :failed :fatal-invariant))))))))

(defun %record-cycle-movement (cycle old new)
  (let ((index (%cycle-movement-count cycle)))
    (when (>= index (length (%cycle-movement-old cycle)))
      (trace-fail (%cycle-trace cycle) :capacity-exhausted)
      (return-from %record-cycle-movement nil))
    (setf (aref (%cycle-movement-old cycle) index) old
          (aref (%cycle-movement-new cycle) index) new)
    (incf (%cycle-movement-count cycle))
    (%cycle-counter-incf cycle :objects-moved)
    t))

(defun %record-cycle-death (cycle space start)
  (let ((index (%cycle-death-count cycle)))
    (when (>= index (length (%cycle-death-starts cycle)))
      (return-from %record-cycle-death nil))
    (setf (aref (%cycle-death-spaces cycle) index) space
          (aref (%cycle-death-starts cycle) index) start)
    (incf (%cycle-death-count cycle))
    (%cycle-counter-incf cycle :objects-dead)
    t))

(defmethod map-cycle-movements ((cycle sequential-cycle) function)
  (dotimes (index (%cycle-movement-count cycle))
    (funcall function (aref (%cycle-movement-old cycle) index)
             (aref (%cycle-movement-new cycle) index)))
  (values))

(defmethod map-cycle-deaths ((cycle sequential-cycle) function)
  (dotimes (index (%cycle-death-count cycle))
    (funcall function (aref (%cycle-death-spaces cycle) index)
             (aref (%cycle-death-starts cycle) index)))
  (values))
