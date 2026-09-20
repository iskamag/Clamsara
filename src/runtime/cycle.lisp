;;;; Full stopped sequential collection lifecycle, including conditionals.
(in-package #:clamsara)

(defun %reset-cycle (cycle configuration scope cause algorithm)
  (setf (%cycle-configuration cycle) configuration
        (%cycle-scope cycle) scope
        (%cycle-cause cycle) cause
        (%cycle-algorithm cycle) algorithm
        (%cycle-phase cycle) :preparing
        (%cycle-stop-token cycle) nil
        (%cycle-coverage cycle) nil
        (%cycle-forwarding-published-p cycle) nil
        (%cycle-commit-started-p cycle) nil
        (%cycle-retained-p cycle) nil
        (%cycle-retained-reason cycle) nil
        (%cycle-movement-count cycle) 0
        (%cycle-death-count cycle) 0
        (%cycle-retirement-count cycle) 0
        (%cycle-current-retirement-space cycle) nil
        (%conditional-count cycle) 0
        (%finalizer-count cycle) 0
        (%cycle-current-start cycle) nil
        (%cycle-current-conditional-index cycle) 0
        (%cycle-conditional-mode cycle) nil
        (%cycle-conditional-match-p cycle) nil)
  (fill (%cycle-counts cycle) 0)
  (fill (%cycle-retirement-starts cycle) nil)
  (fill (%conditional-source cycle) nil)
  (fill (%conditional-kind cycle) nil)
  (fill (%conditional-id cycle) nil)
  (fill (%conditional-original-key cycle) nil)
  (fill (%conditional-original-value cycle) nil)
  (fill (%conditional-new-key cycle) nil)
  (fill (%conditional-new-value cycle) nil)
  (fill (%conditional-clear-key-p cycle) nil)
  (fill (%finalizer-token cycle) nil)
  (fill (%finalizer-original cycle) nil)
  (fill (%finalizer-corrected cycle) nil)
  (fill (%finalizer-candidate-p cycle) nil)
  (fill (%finalizer-seen-p cycle) nil)
  cycle)

(defgeneric %plan-scope-supported-p (plan scope))
(defmethod %plan-scope-supported-p ((plan sequential-runtime-plan) scope)
  (declare (ignore plan))
  (eq scope :all))

(defun %scope-supported-p (plan scope)
  (%plan-scope-supported-p plan scope))

;;; Plan phase hooks keep the required full-heap plans unchanged while an
;;; admitted composition can select its participating spaces and source sets.
(defgeneric %plan-stop-scope (plan cycle))
(defmethod %plan-stop-scope ((plan sequential-runtime-plan) cycle)
  (declare (ignore plan))
  (%cycle-scope cycle))

(defgeneric %prepare-cycle-spaces (plan cycle))
(defmethod %prepare-cycle-spaces ((plan sequential-runtime-plan) cycle)
  (dolist (space (%plan-spaces plan))
    (prepare-space space cycle))
  (values :complete nil))

(defgeneric %trace-plan-additional-roots (plan cycle))
(defmethod %trace-plan-additional-roots
    ((plan sequential-runtime-plan) cycle)
  (declare (ignore plan cycle))
  (values :complete nil))

(defgeneric %map-plan-conditional-sources (plan cycle function))
(defmethod %map-plan-conditional-sources
    ((plan sequential-runtime-plan) cycle function)
  (declare (ignore plan))
  (map-trace-discoveries (%cycle-trace cycle) function))

(defgeneric %prepare-plan-reclamation (plan cycle))
(defgeneric %finish-plan-reclamation (plan cycle))

(defun %reference-status (cycle reference)
  "Return :IMMEDIATE, :OUT-OF-SCOPE or :IN-SCOPE and current live judgment."
  (let* ((configuration (%cycle-configuration cycle))
         (model (configuration-object-model configuration))
         (trace (%cycle-trace cycle)))
    (unless (valid-reference-p model reference)
      (return-from %reference-status (values :immediate nil nil nil)))
    (multiple-value-bind (start descriptor) (normalize-reference model reference)
      (declare (ignore descriptor))
      (let ((space (space-of-reference (configuration-layout configuration) start)))
        (unless space
          (trace-fail trace :fatal-invariant)
          (return-from %reference-status (values :in-scope nil nil start)))
        (if (not (trace-scope-contains-p trace space start))
            (values :out-of-scope t space start)
            (values :in-scope (object-live-p space cycle start) space start))))))

(defun %ephemeron-key-live-p (cycle key clear-key-p cleared-key)
  (let ((model (configuration-object-model (%cycle-configuration cycle))))
    (multiple-value-bind (status live-p space start)
        (%reference-status cycle key)
      (declare (ignore space start))
      (case status
        (:immediate
         (not (and clear-key-p
                   (reference-encoding-equal-p model key cleared-key))))
        (:out-of-scope t)
        (:in-scope (and live-p t))))))

(defun %inspect-discovery-ephemerons (cycle start)
  (setf (%cycle-current-start cycle) start)
  (map-ephemeron-descriptors
   (configuration-object-model (%cycle-configuration cycle)) start
   (%cycle-ephemeron-callback cycle))
  (values))

(defun %inspect-ephemeron (cycle identity key-location value-location
                           clear-key-p cleared-key cleared-value)
  (declare (ignore identity))
  (let* ((model (configuration-object-model (%cycle-configuration cycle)))
         ;; Required order: value first, then key only for an active pair.
         (value (load-reference model value-location)))
    (unless (reference-encoding-equal-p model value cleared-value)
      (let ((key (load-reference model key-location)))
        (when (%ephemeron-key-live-p cycle key clear-key-p cleared-key)
          (trace-reference (%cycle-trace cycle) value)))))
  (values))

(defun %ephemeron-closure (cycle)
  (loop
    (let ((before (trace-discovery-count (%cycle-trace cycle))))
      (%map-plan-conditional-sources
       (%cycle-plan cycle) cycle (%cycle-discovery-callback cycle))
      (multiple-value-bind (status reason) (%drain-strong-work cycle)
        (unless (eq status :complete)
          (return (values status reason))))
      (when (= before (trace-discovery-count (%cycle-trace cycle)))
        (return (values :complete nil))))))

(defun %stage-finalizer-registration (cycle token referent)
  (let ((index (%finalizer-count cycle)))
    (when (>= index (length (%finalizer-token cycle)))
      (trace-fail (%cycle-trace cycle) :weak-storage-exhausted)
      (return-from %stage-finalizer-registration (values)))
    (multiple-value-bind (status live-p space start)
        (%reference-status cycle referent)
      (declare (ignore space start))
      (setf (aref (%finalizer-token cycle) index) token
            (aref (%finalizer-original cycle) index) referent
            (aref (%finalizer-candidate-p cycle) index)
            (and (eq status :in-scope) (not live-p))
            (aref (%finalizer-corrected cycle) index)
            (if (and (eq status :in-scope) live-p)
                (trace-reference (%cycle-trace cycle) referent)
                referent)
            (aref (%finalizer-seen-p cycle) index) nil)
      (incf (%finalizer-count cycle))))
  (values))

(defun %stage-finalizers-and-retain (cycle)
  ;; Enumeration fills the entire bounded vector before any dead candidate is
  ;; traced.  Thus exhaustion cannot select a partial finalizer batch.
  (setf (%finalizer-count cycle) 0)
  (map-finalizer-registrations (%plan-registry (%cycle-plan cycle))
                               (%cycle-finalizer-callback cycle))
  (when (%trace-failed-reason (%cycle-trace cycle))
    (return-from %stage-finalizers-and-retain
      (values :failed (%trace-failed-reason (%cycle-trace cycle)))))
  (dotimes (index (%finalizer-count cycle))
    (when (aref (%finalizer-candidate-p cycle) index)
      (setf (aref (%finalizer-corrected cycle) index)
            (trace-reference (%cycle-trace cycle)
                             (aref (%finalizer-original cycle) index)))))
  (multiple-value-bind (status reason) (%drain-strong-work cycle)
    (unless (eq status :complete)
      (return-from %stage-finalizers-and-retain (values status reason))))
  (%ephemeron-closure cycle))

(defun %find-staged-finalizer (cycle token)
  (dotimes (index (%finalizer-count cycle) nil)
    (when (eql token (aref (%finalizer-token cycle) index))
      (return index))))

(defun %revalidate-finalizer-registration (cycle token referent)
  (let ((index (%find-staged-finalizer cycle token))
        (model (configuration-object-model (%cycle-configuration cycle))))
    (unless (and index
                 (reference-encoding-equal-p
                  model referent (aref (%finalizer-original cycle) index)))
      (trace-fail (%cycle-trace cycle) :weak-storage-exhausted)
      (return-from %revalidate-finalizer-registration (values)))
    (setf (aref (%finalizer-seen-p cycle) index) t))
  (values))

(defun %revalidate-finalizers (cycle)
  (fill (%finalizer-seen-p cycle) nil)
  (let ((registry (%plan-registry (%cycle-plan cycle))))
    (map-finalizer-registrations
     registry (%cycle-revalidate-finalizer-callback cycle))
    (dotimes (index (%finalizer-count cycle))
      (unless (aref (%finalizer-seen-p cycle) index)
        (trace-fail (%cycle-trace cycle) :weak-storage-exhausted)))
    (let ((candidates 0))
      (dotimes (index (%finalizer-count cycle))
        (when (aref (%finalizer-candidate-p cycle) index)
          (incf candidates)))
      (when (> (+ (%registry-pending-count registry) candidates)
               (%registry-capacity registry))
        (trace-fail (%cycle-trace cycle) :weak-storage-exhausted))))
  (if (%trace-failed-reason (%cycle-trace cycle))
      (values :failed (%trace-failed-reason (%cycle-trace cycle)))
      (values :complete nil)))

(defun %conditional-corrected-reference (cycle original cleared-value)
  (multiple-value-bind (status live-p space start)
      (%reference-status cycle original)
    (declare (ignore space start))
    (case status
      ((:immediate :out-of-scope) original)
      (:in-scope (if live-p
                     (trace-reference (%cycle-trace cycle) original)
                     cleared-value)))))

(defun %stage-conditional (cycle kind identity source original-key original-value
                           new-key new-value clear-key-p)
  (let ((index (%conditional-count cycle)))
    (when (>= index (length (%conditional-source cycle)))
      (trace-fail (%cycle-trace cycle) :weak-storage-exhausted)
      (return-from %stage-conditional nil))
    (setf (aref (%conditional-source cycle) index) source
          (aref (%conditional-kind cycle) index) kind
          (aref (%conditional-id cycle) index) identity
          (aref (%conditional-original-key cycle) index) original-key
          (aref (%conditional-original-value cycle) index) original-value
          (aref (%conditional-new-key cycle) index) new-key
          (aref (%conditional-new-value cycle) index) new-value
          (aref (%conditional-clear-key-p cycle) index) clear-key-p)
    (incf (%conditional-count cycle))
    t))

(defun %stage-weak-descriptor (cycle identity location cleared-value)
  (let* ((model (configuration-object-model (%cycle-configuration cycle)))
         (original (load-reference model location))
         (corrected (%conditional-corrected-reference
                     cycle original cleared-value)))
    (%stage-conditional cycle :weak identity (%cycle-current-start cycle)
                        nil original nil corrected nil))
  (values))

(defun %stage-ephemeron-descriptor (cycle identity key-location value-location
                                    clear-key-p cleared-key cleared-value)
  (let* ((model (configuration-object-model (%cycle-configuration cycle)))
         ;; Value-first preserves the inactive cleared-value rule.
         (original-value (load-reference model value-location))
         (original-key (load-reference model key-location))
         (inactive-p
           (reference-encoding-equal-p model original-value cleared-value))
         (key-live-p
           (and (not inactive-p)
                (%ephemeron-key-live-p cycle original-key
                                       clear-key-p cleared-key)))
         (new-key
           (cond ((not key-live-p) (if clear-key-p cleared-key original-key))
                 (t (%conditional-corrected-reference
                     cycle original-key original-key))))
         (new-value
           (cond (inactive-p original-value)
                 (key-live-p
                  (%conditional-corrected-reference
                   cycle original-value cleared-value))
                 (t cleared-value))))
    (%stage-conditional cycle :ephemeron identity (%cycle-current-start cycle)
                        original-key original-value new-key new-value clear-key-p))
  (values))

(defun %stage-discovery-conditionals (cycle space start)
  (declare (ignore space))
  (setf (%cycle-current-start cycle) start)
  (let ((model (configuration-object-model (%cycle-configuration cycle))))
    (map-weak-descriptors model start (%cycle-weak-callback cycle))
    (map-ephemeron-descriptors
     model start (%cycle-conditional-ephemeron-callback cycle)))
  (values))

(defun %stage-all-conditionals (cycle)
  (setf (%conditional-count cycle) 0)
  (let ((initial (trace-discovery-count (%cycle-trace cycle))))
    (%map-plan-conditional-sources
     (%cycle-plan cycle) cycle (%cycle-stage-discovery-callback cycle))
    (cond ((%trace-failed-reason (%cycle-trace cycle))
         (values :failed (%trace-failed-reason (%cycle-trace cycle))))
        ;; Closure was final.  Staging may correct a seen reference but must not
        ;; add liveness now.
        ((/= (trace-discovery-count (%cycle-trace cycle)) initial)
         (values :failed :fatal-invariant))
        (t (values :complete nil)))))

(defun %conditional-check-or-commit-weak (cycle identity location cleared-value)
  (declare (ignore cleared-value))
  (let* ((index (%cycle-current-conditional-index cycle))
         (model (configuration-object-model (%cycle-configuration cycle))))
    (when (eql identity (aref (%conditional-id cycle) index))
      (let ((observed (load-reference model location)))
        (unless (reference-encoding-equal-p
                 model observed (aref (%conditional-original-value cycle) index))
          (return-from %conditional-check-or-commit-weak (values)))
        (when (eq (%cycle-conditional-mode cycle) :commit)
          (store-reference-raw
           model location (aref (%conditional-new-value cycle) index)))
        (setf (%cycle-conditional-match-p cycle) t))))
  (values))

(defun %conditional-check-or-commit-ephemeron
    (cycle identity key-location value-location clear-key-p
     cleared-key cleared-value)
  (declare (ignore cleared-key cleared-value))
  (let* ((index (%cycle-current-conditional-index cycle))
         (model (configuration-object-model (%cycle-configuration cycle))))
    (when (and (eql identity (aref (%conditional-id cycle) index))
               (eql (and clear-key-p t)
                    (and (aref (%conditional-clear-key-p cycle) index) t)))
      ;; Value first, as in every other ephemeron pass.
      (let ((value (load-reference model value-location))
            (key (load-reference model key-location)))
        (unless (and
                 (reference-encoding-equal-p
                  model value (aref (%conditional-original-value cycle) index))
                 (reference-encoding-equal-p
                  model key (aref (%conditional-original-key cycle) index)))
          (return-from %conditional-check-or-commit-ephemeron (values)))
        (when (eq (%cycle-conditional-mode cycle) :commit)
          (store-reference-raw
           model value-location (aref (%conditional-new-value cycle) index))
          (when clear-key-p
            (store-reference-raw
             model key-location (aref (%conditional-new-key cycle) index))))
        (setf (%cycle-conditional-match-p cycle) t))))
  (values))

(defun %check-or-commit-conditionals (cycle mode)
  (let ((model (configuration-object-model (%cycle-configuration cycle))))
    (dotimes (index (%conditional-count cycle) (values :complete nil))
      (setf (%cycle-current-conditional-index cycle) index
            (%cycle-conditional-mode cycle) mode
            (%cycle-conditional-match-p cycle) nil)
      (let ((source (aref (%conditional-source cycle) index)))
        (ecase (aref (%conditional-kind cycle) index)
          (:weak
           (map-weak-descriptors
            model source (%cycle-conditional-weak-check-callback cycle)))
          (:ephemeron
           (map-ephemeron-descriptors
            model source
            (%cycle-conditional-ephemeron-check-callback cycle)))))
      (unless (%cycle-conditional-match-p cycle)
        (return (values :failed
                        (if (eq mode :commit)
                            :post-publication-failure
                            :weak-storage-exhausted)))))))

(defun %cancel-ready (plan cycle ready-space-count ready-participant-count)
  (dotimes (index ready-participant-count)
    (cancel-movement-participant
     (nth index (%plan-movement-participants plan)) cycle))
  (dotimes (index ready-space-count)
    (cancel-reclaim-space (nth index (%plan-spaces plan)) cycle))
  (values))

(defmethod %prepare-plan-reclamation
    ((plan sequential-runtime-plan) cycle)
  (let ((ready-spaces 0)
        (ready-participants 0))
    (dolist (space (%plan-spaces plan))
      (multiple-value-bind (status reason) (reclaim-space space cycle)
        (unless (eq status :ready)
          (%cancel-ready plan cycle ready-spaces ready-participants)
          (return-from %prepare-plan-reclamation
            (values :failed (or reason :preflight-failed))))
        (incf ready-spaces)))
    (dolist (participant (%plan-movement-participants plan))
      (multiple-value-bind (status reason)
          (prepare-movement-participant participant cycle)
        (unless (eq status :ready)
          (%cancel-ready plan cycle ready-spaces ready-participants)
          (return-from %prepare-plan-reclamation
            (values :failed (or reason :preflight-failed))))
        (incf ready-participants)))
    (values :complete nil)))

(defmethod %finish-plan-reclamation
    ((plan sequential-runtime-plan) cycle)
  (dolist (participant (%plan-movement-participants plan))
    (finish-movement-participant participant cycle))
  (dolist (space (%plan-spaces plan))
    (finish-space space cycle))
  (values :complete nil))

(defun %commit-cycle (cycle)
  (let* ((plan (%cycle-plan cycle))
         (registry (%plan-registry plan)))
    (setf (%cycle-phase cycle) :reclaim/correct
          (%cycle-commit-started-p cycle) t)
    ;; Live registry correction and candidate freeze are already exact-token
    ;; revalidated, so this closed path is bounded and non-failing.
    (dotimes (index (%finalizer-count cycle))
      (let ((token (aref (%finalizer-token cycle) index))
            (original (aref (%finalizer-original cycle) index))
            (corrected (aref (%finalizer-corrected cycle) index)))
        (if (aref (%finalizer-candidate-p cycle) index)
            (freeze-finalizer-candidate registry token original corrected)
            (unless (eq :corrected
                        (correct-finalizer-referent
                         registry token original corrected))
              (return-from %commit-cycle
                (values :failed :post-publication-failure))))))
    (multiple-value-bind (status reason)
        (%check-or-commit-conditionals cycle :commit)
      (unless (eq status :complete)
        (return-from %commit-cycle (values status reason))))
    (%cycle-counter-incf cycle :weak-corrections (%conditional-count cycle))
    (multiple-value-bind (finish-status finish-reason)
        (%finish-plan-reclamation plan cycle)
      (unless (eq finish-status :complete)
        (return-from %commit-cycle
          (values finish-status (or finish-reason
                                    :post-publication-failure)))))
    (publish-pending-finalizers registry)
    (let ((candidates 0))
      (dotimes (index (%finalizer-count cycle))
        (when (aref (%finalizer-candidate-p cycle) index) (incf candidates)))
      (%cycle-counter-incf cycle :finalizers-enqueued candidates))
    (values :complete nil)))

(defun %release-cycle-stop (cycle expected)
  (let ((result (release-safepoint (%plan-coordinator (%cycle-plan cycle))
                                   (%cycle-stop-token cycle))))
    (unless (eq result expected)
      (setf (%cycle-retained-p cycle) t
            (%cycle-retained-reason cycle) :fatal-invariant)
      (return-from %release-cycle-stop nil))
    (setf (%cycle-stop-token cycle) nil
          (%cycle-coverage cycle) nil)
    t))

(defun %cycle-failure (cycle reason)
  (let ((plan (%cycle-plan cycle)))
    (setf (%cycle-retained-reason cycle) reason)
    (if (or (%cycle-forwarding-published-p cycle)
            (%cycle-commit-started-p cycle))
        (progn
          ;; Source/destination or commit state is externally visible.  Keep
          ;; the covering stop and reject every later entry.
          (setf (%cycle-retained-p cycle) t
                (%plan-retained-cycle plan) cycle
                (%plan-state plan) :retained)
          (values :retained reason))
        (progn
          (when (%cycle-stop-token cycle)
            (unless (%release-cycle-stop cycle :released)
              (setf (%plan-retained-cycle plan) cycle
                    (%plan-state plan) :retained)
              (return-from %cycle-failure
                (values :retained :fatal-invariant))))
          (setf (%plan-state plan) :open)
          (values :retained reason)))))

(defun %execute-cycle (cycle)
  (let* ((plan (%cycle-plan cycle))
         (coordinator (%plan-coordinator plan)))
    (multiple-value-bind (token rejection)
        (request-safepoint coordinator (%plan-stop-scope plan cycle)
                           :collection)
      (when rejection
        (setf (%plan-state plan) :open)
        (%runtime-reject
         (case rejection
           (:busy :collection-busy)
           (otherwise :preflight-failed))))
      (setf (%cycle-stop-token cycle) token)
      (multiple-value-bind (same-token coverage await-failure)
          (await-safepoint coordinator token)
        (unless (eq same-token token)
          (setf (%cycle-retained-p cycle) t
                (%cycle-retained-reason cycle) :fatal-invariant
                (%plan-state plan) :retained)
          (return-from %execute-cycle (values :retained :fatal-invariant)))
        (when await-failure
          (unless (%release-cycle-stop cycle :cancelled)
            (setf (%plan-state plan) :retained)
            (return-from %execute-cycle (values :retained :fatal-invariant)))
          (setf (%plan-state plan) :open)
          (return-from %execute-cycle (values :retained :coverage-failed)))
        (setf (%cycle-coverage cycle) coverage)))
    ;; All fallible phases below run with complete coverage.
    (handler-case
        (progn
          (multiple-value-bind (status reason)
              (%prepare-cycle-spaces plan cycle)
            (unless (eq status :complete)
              (return-from %execute-cycle (%cycle-failure cycle reason))))
          (begin-trace-context cycle (%cycle-scope cycle)
                               (%plan-trace-capacity plan))
          (setf (%cycle-phase cycle) :roots)
          (with-root-snapshot (%plan-root-client plan) (%cycle-coverage cycle)
                              (%cycle-snapshot-callback cycle))
          (multiple-value-bind (status reason)
              (%trace-plan-additional-roots plan cycle)
            (unless (eq status :complete)
              (return-from %execute-cycle (%cycle-failure cycle reason))))
          (multiple-value-bind (status reason) (%drain-strong-work cycle)
            (unless (eq status :complete)
              (return-from %execute-cycle (%cycle-failure cycle reason))))
          (setf (%cycle-phase cycle) :weak-closure)
          (multiple-value-bind (status reason) (%ephemeron-closure cycle)
            (unless (eq status :complete)
              (return-from %execute-cycle (%cycle-failure cycle reason))))
          (setf (%cycle-phase cycle) :finalizer-retention)
          (multiple-value-bind (status reason) (%stage-finalizers-and-retain cycle)
            (unless (eq status :complete)
              (return-from %execute-cycle (%cycle-failure cycle reason))))
          (multiple-value-bind (status reason) (%revalidate-finalizers cycle)
            (unless (eq status :complete)
              (return-from %execute-cycle (%cycle-failure cycle reason))))
          (multiple-value-bind (status reason) (%stage-all-conditionals cycle)
            (unless (eq status :complete)
              (return-from %execute-cycle (%cycle-failure cycle reason))))
          ;; Exact encodings are re-enumerated before reclamation preflight.
          (multiple-value-bind (status reason)
              (%check-or-commit-conditionals cycle :validate)
            (unless (eq status :complete)
              (return-from %execute-cycle (%cycle-failure cycle reason))))
          (multiple-value-bind (status reason) (%prepare-plan-reclamation plan cycle)
            (unless (eq status :complete)
              (return-from %execute-cycle (%cycle-failure cycle reason))))
          (multiple-value-bind (status reason) (%commit-cycle cycle)
            (unless (eq status :complete)
              (return-from %execute-cycle (%cycle-failure cycle reason))))
          (setf (%cycle-phase cycle) :release)
          (unless (%release-cycle-stop cycle :released)
            (setf (%plan-state plan) :retained
                  (%plan-retained-cycle plan) cycle)
            (return-from %execute-cycle (values :retained :fatal-invariant)))
          (setf (%plan-state plan) :open)
          (values :complete :complete))
      (error ()
        ;; Once coverage exists an unexpected callback/host fault is not an
        ;; ordinary unwind-release.  Keep the stop; diagnostics can inspect the
        ;; stable retained reason without resuming a possibly corrected heap.
        (setf (%cycle-retained-p cycle) t
              (%cycle-retained-reason cycle)
              (if (or (%cycle-forwarding-published-p cycle)
                      (%cycle-commit-started-p cycle))
                  :post-publication-failure :fatal-invariant)
              (%plan-retained-cycle plan) cycle
              (%plan-state plan) :retained)
        (values :retained (%cycle-retained-reason cycle))))))

(defun %validate-collection-entry (configuration scope cause record algorithm)
  (let* ((plan (%configuration-runtime-plan configuration))
         (selected (or algorithm (%plan-default-algorithm plan))))
    (unless (eq (cycle-result-owner record) plan)
      (%runtime-reject :foreign-result-record))
    (unless (%scope-supported-p plan scope)
      (%runtime-reject :unsupported-scope))
    (unless (member selected (%plan-algorithms plan) :test #'eq)
      (%runtime-reject :unsupported-algorithm))
    (unless (cycle-cause-known-p plan cause)
      (%runtime-reject :unsupported-cause))
    (unless (eq (%plan-state plan) :open)
      (%runtime-reject :collection-busy))
    (values plan selected)))

(defmethod collect (configuration scope cause result-record &key algorithm)
  (declare (ignore configuration scope cause result-record algorithm))
  (%runtime-reject :foreign-result-record))

(defmethod collect (configuration scope cause
                    (record sequential-cycle-result) &key algorithm)
  (multiple-value-bind (plan selected)
      (%validate-collection-entry configuration scope cause record algorithm)
    ;; Admission changes private owner state only after every public rejection
    ;; above.  The caller record remains untouched until a terminal boundary.
    (setf (%plan-state plan) :collecting)
    (let ((cycle (%reset-cycle (%plan-cycle plan) configuration scope cause selected)))
      (multiple-value-bind (status reason) (%execute-cycle cycle)
        (%fill-result record cycle status reason)))))

(defmethod automatic-collect (configuration scope cause)
  (let ((plan (%configuration-runtime-plan configuration)))
    (handler-case
        (let* ((record (%plan-automatic-result plan))
               (result (collect configuration scope cause record)))
          (values (cycle-result-status result) (cycle-result-reason result)))
      (runtime-rejection (condition)
        (values :rejected (runtime-rejection-reason condition))))))


(defun %configuration-has-allocated-objects-p (plan)
  (block present
    (dolist (space (%plan-spaces plan) nil)
      (metadata-map-present
       (%space-object-start-map space) (%space-range space)
       (lambda (key value)
         (declare (ignore key value))
         (return-from present t))))))

(defun %close-configuration-runtime (configuration)
  "Preflight and atomically close the fixed sequential entry routes."
  (let ((plan (%configuration-runtime-plan configuration)))
    (unless (member (%plan-state plan) '(:open :retained) :test #'eq)
      (%runtime-reject :collection-busy))
    (when (plusp (%plan-active-context-count plan))
      (%runtime-reject :active-mutator-contexts))
    (when (and (eq (%plan-state plan) :open)
               (%configuration-has-allocated-objects-p plan))
      (%runtime-reject :reachable-objects-not-discharged))
    (unless (eq (%plan-state plan) :retained)
      (setf (%plan-state plan) :closing))
    (values)))

(defun %drain-configuration-runtime (configuration)
  (let ((plan (%configuration-runtime-plan configuration)))
    (cond ((eq (%plan-state plan) :retained)
           (values :retained
                   (or (%cycle-retained-reason (%plan-retained-cycle plan))
                       :fatal-invariant)))
          ((plusp (%plan-active-context-count plan))
           (values :retained :active-mutator-contexts))
          (t
           (setf (%plan-state plan) :closed)
           (values :complete nil)))))
