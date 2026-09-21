;;;; Unexecuted source-only admission baseline, frozen committed 1099.
;;;; Load CLAMSARA/QUALITY/SUPPORT first. Never load CLAMSARA/WORKLOAD.
;;;; No load-time run, production replacement, root erasure, cancel/drain or close.
(defpackage #:clamsara.finalizer.admission.baseline.v1
  (:use #:cl #:clamsara #:clamsara.quality.support)
  (:export #:run-native-callback-admission #:*admission-owners*
           #:fna-owner-world #:fna-owner-status #:fna-owner-phase
           #:fna-owner-condition #:fna-owner-observed-condition
           #:fna-owner-observation-error #:fna-owner-returned-values
           #:fna-owner-before #:fna-owner-at-signal #:fna-owner-after
           #:fna-owner-effects #:fna-owner-callback-calls
           #:fna-state-same-p #:fna-summary))
(in-package #:clamsara.finalizer.admission.baseline.v1)

(defstruct fna-owner world (status :retained) (phase :adopted)
  condition observed-condition observation-error returned-values
  before at-signal after (effects (make-array 8 :initial-element 0))
  (callback-calls 0))
(defstruct fna-state identities values tables)
(defvar *admission-owners* nil)
(defvar *active-admission-owner* nil)
(define-condition fna-failure (error)
  ((reason :initarg :reason :reader fna-failure-reason))
  (:report (lambda (c stream)
             (format stream "Finalizer admission baseline: ~S"
                     (fna-failure-reason c)))))
(defun fna-demand (test reason)
  (unless test (error 'fna-failure :reason reason))
  test)
(defun fna-effect (index)
  (when *active-admission-owner*
    (incf (aref (fna-owner-effects *active-admission-owner*) index))))
(defun fna-native-callback (referent)
  ;; Deliberately not a managed value; no captured guest reference or user work.
  (declare (ignore referent))
  (when *active-admission-owner*
    (incf (fna-owner-callback-calls *active-admission-owner*)))
  nil)

(defun fna-with-unique-method (name qualifiers classes definition thunk)
  (let* ((generic (fdefinition name))
         (specializers (mapcar #'find-class classes)))
    (fna-demand (null (find-method generic qualifiers specializers nil))
                :observer-method-already-present)
    (let ((method (eval definition)))
      ;; Only our observer method is removed. No world cleanup occurs here.
      (unwind-protect (funcall thunk) (remove-method generic method)))))
(defun fna-with-observers (thunk)
  (labels ((install (specs)
             (if (null specs) (funcall thunk)
                 (destructuring-bind (name qualifiers classes definition) (car specs)
                   (fna-with-unique-method name qualifiers classes definition
                     (lambda () (install (cdr specs))))))))
    (install
     '((root-provider-store (:before) (clamsara::simulator-root-client t t t t)
        (defmethod root-provider-store :before
            ((client clamsara::simulator-root-client) context token location value)
          (declare (ignore client context token location value))
          (fna-effect 0)))
       (clamsara::store-provider-root (:before)
        (t clamsara::sequential-execution-context t t t)
        (defmethod clamsara::store-provider-root :before
            (client (context clamsara::sequential-execution-context) token location value)
          (declare (ignore client context token location value))
          (fna-effect 1)))
       (barrier-store (:before) (clamsara::composed-barrier clamsara::sequential-execution-context t t)
        (defmethod barrier-store :before
            ((barrier clamsara::composed-barrier)
             (context clamsara::sequential-execution-context) location value)
          (declare (ignore barrier context location value))
          (fna-effect 2)))
       ((setf clamsara::host-root-value) (:before) (t clamsara::finalizer-root-location)
        (defmethod (setf clamsara::host-root-value) :before
            (value (location clamsara::finalizer-root-location))
          (declare (ignore value location))
          (fna-effect 3)))
       (allocate-object (:before) (clamsara::sequential-execution-context t t t t)
        (defmethod allocate-object :before
            ((context clamsara::sequential-execution-context) kind bytes alignment descriptor)
          (declare (ignore context kind bytes alignment descriptor))
          (fna-effect 4)))
       (collect (:before) (t t t t)
        (defmethod collect :before (configuration scope cause result-record &key algorithm)
          (declare (ignore configuration scope cause result-record algorithm))
          (fna-effect 5)))
       (automatic-collect (:before) (t t t)
        (defmethod automatic-collect :before (configuration scope cause)
          (declare (ignore configuration scope cause))
          (fna-effect 5)))
       (request-safepoint (:before) (clamsara::simulator-coordinator t t)
        (defmethod request-safepoint :before
            ((coordinator clamsara::simulator-coordinator) scope reason)
          (declare (ignore coordinator scope reason))
          (fna-effect 6)))))))

(defun fna-snapshot (world)
  "Read explicit physical state; copied guest encodings are never GC owners.
No snapshot/collector operation is invoked. Compare only across admission."
  (let* ((registry (world-registry world)) (roots (world-roots world))
         (context (world-context world)) (plan (world-plan world))
         (configuration (world-configuration world))
         (barrier (configuration-barrier configuration))
         (identities nil) (values nil) (tables nil))
    (labels ((identity! (value) (push value identities))
             (value! (value) (push value values))
             (vector! (vector)
               (identity! vector)
               (value! (length vector))
               (dotimes (i (length vector)) (value! (aref vector i))))
             (table! (table)
               (identity! table)
               (push (loop for key being each hash-key of table
                           using (hash-value value) collect (cons key value)) tables)))
      (dolist (object (list world configuration context plan (world-model world)
                            roots (world-root-provider world) (world-root-token world)
                            registry (world-coordinator world) barrier
                            (clamsara::%registry-token-owner registry)
                            (clamsara::%registry-provider-token registry)))
        (identity! object))
      ;; Actual registry vectors and every physical/token payload, not their
      ;; mutable vector identities alone. EQL below keeps nonnumeric identity.
      (dolist (vector (list (clamsara::%registry-registrations registry)
                           (clamsara::%registry-referents registry)
                           (clamsara::%registry-supports registry)
                           (clamsara::%registry-callbacks registry)
                           (clamsara::%registry-states registry)
                           (clamsara::%registry-tokens registry)
                           (clamsara::%registry-pending registry)
                           (clamsara::%registry-token-reserve registry)
                           (clamsara::%registry-locations registry)
                           (clamsara::%context-barrier-reservations context)
                           (clamsara::%context-barrier-reserved-p context)
                           (clamsara::%context-refill-request context)
                           (clamsara::simulator-provider-locations
                            (world-root-provider world))
                           (clamsara::simulator-root-providers roots)
                           (clamsara::simulator-root-token-reserve roots)
                           (clamsara::simulator-root-entry-reserve roots)
                           (clamsara::simulator-root-registration-scratch roots)))
        (vector! vector))
      (loop for token across (clamsara::%registry-token-reserve registry) do
        (value! (clamsara::sequential-finalizer-token-owner token))
        (value! (clamsara::sequential-finalizer-token-generation token))
        (value! (clamsara::sequential-finalizer-token-index token)))
      (loop for token across (clamsara::simulator-root-token-reserve roots) do
        (dolist (value (list (clamsara::simulator-provider-token-owner token)
                            (clamsara::simulator-provider-token-identity token)
                            (clamsara::simulator-provider-token-generation token)
                            (clamsara::simulator-provider-token-provider token)
                            (clamsara::simulator-provider-token-active-p token)
                            (clamsara::simulator-provider-token-position token)
                            (clamsara::simulator-provider-token-entry-head token)
                            (clamsara::simulator-provider-token-entry-count token)))
          (value! value)))
      (loop for entry across (clamsara::simulator-root-entry-reserve roots) do
        (dolist (value (list (clamsara::simulator-root-entry-token entry)
                            (clamsara::simulator-root-entry-location entry)
                            (clamsara::simulator-root-entry-next entry)
                            (clamsara::simulator-root-entry-seen entry)
                            (clamsara::simulator-root-entry-active-p entry)))
          (value! value)))
      (table! (clamsara::simulator-root-directory roots))
      (table! (clamsara::simulator-root-registration-seen roots))
      ;; Host physical getters only; LOAD-ROOT is snapshot-only and is NOT used.
      (loop for location across (clamsara::simulator-provider-locations
                                  (world-root-provider world))
            do (value! (clamsara::host-root-value location)))
      (loop for location across (clamsara::%registry-locations registry)
            do (value! (clamsara::host-root-value location)))
      (dolist (value
               (list (clamsara::%configuration-state configuration)
                     (clamsara::%context-state context)
                     (clamsara::%context-generation context)
                     (clamsara::%context-barrier-state context)
                     (clamsara::%context-finalizer-depth context)
                     (clamsara::%plan-state plan)
                     (clamsara::%plan-active-context-count plan)
                     (clamsara::%plan-next-context-generation plan)
                     (clamsara::%plan-barrier-pin-count plan)
                     (clamsara::%barrier-busy-p barrier)
                     (clamsara::%barrier-failed-p barrier)
                     (clamsara::%registry-capacity registry)
                     (clamsara::%registry-registration-capacity registry)
                     (clamsara::%registry-next-token registry)
                     (clamsara::%registry-pending-count registry)
                     (clamsara::%registry-pending-head registry)
                     (clamsara::%registry-callback-failure-count registry)
                     (clamsara::simulator-root-next-token roots)
                     (clamsara::simulator-root-free-entry-head roots)
                     (clamsara::simulator-root-free-entry-count roots)
                     (clamsara::simulator-root-generation roots)
                     (clamsara::simulator-root-admission-closed-p roots)
                     (clamsara::simulator-root-registration-active-p roots)
                     (clamsara::simulator-root-pass roots)
                     (clamsara::simulator-root-snapshot-active-p
                      (clamsara::simulator-client-snapshot roots))))
        (value! value))
      (make-fna-state :identities (nreverse identities)
                      :values (nreverse values) :tables (nreverse tables)))))

(defun fna-eql-list-p (a b)
  (and (= (length a) (length b)) (every #'eql a b)))
(defun fna-table-same-p (a b)
  ;; Do not assume hash iteration order is a protocol guarantee.
  (and (= (length a) (length b))
       (every (lambda (entry)
                (let ((other (assoc (car entry) b :test #'eq)))
                  (and other (eq (cdr entry) (cdr other))))) a)))
(defun fna-state-same-p (a b)
  (and a b
       (= (length (fna-state-identities a)) (length (fna-state-identities b)))
       (every #'eq (fna-state-identities a) (fna-state-identities b))
       (fna-eql-list-p (fna-state-values a) (fna-state-values b))
       (= (length (fna-state-tables a)) (length (fna-state-tables b)))
       (every #'fna-table-same-p (fna-state-tables a) (fna-state-tables b))))
(defun fna-capture-signal-state (owner condition)
  (setf (fna-owner-observed-condition owner) condition)
  ;; An observer failure cannot replace the real registration condition.
  (handler-case
      (setf (fna-owner-at-signal owner) (fna-snapshot (fna-owner-world owner)))
    (error (secondary) (setf (fna-owner-observation-error owner) secondary))))

(defun run-native-callback-admission
    (world &key (expected-reason :invalid-finalizer-registration))
  "One caller-owned fresh world. Native non-model callback must reject.
No cleanup is performed, even on the positive rejection path. Inspect owners.
EXPECTED-REASON pins an implementation diagnostic, not a new public policy."
  (let ((owner (make-fna-owner :world world)))
    (push owner *admission-owners*)
    (handler-bind
        ((error (lambda (condition)
                  (setf (fna-owner-condition owner) condition)
                  (unless (eq :red-accepted (fna-owner-status owner))
                    (setf (fna-owner-status owner) :failed-retained)))))
      (setf (fna-owner-phase owner) :setup)
      (let* ((registry (world-registry world)) (context (world-context world))
             (configuration (world-configuration world))
             (callback #'fna-native-callback))
        (fna-demand (eq :published (clamsara::%configuration-state configuration))
                    :configuration-not-published)
        (fna-demand (eq :open (clamsara::%plan-state (world-plan world))) :plan-not-open)
        (fna-demand (eq :bound (clamsara::%context-state context)) :context-not-bound)
        (fna-demand (eq configuration (clamsara::%registry-configuration registry))
                    :foreign-registry)
        (fna-demand (eq configuration (clamsara::%context-configuration context))
                    :foreign-context)
        (fna-demand (every #'null (clamsara::%registry-registrations registry))
                    :registry-not-fresh)
        (fna-demand (every (lambda (state) (eq state :free))
                           (clamsara::%registry-states registry)) :registry-not-free)
        (fna-demand (zerop (clamsara::%registry-next-token registry)) :token-history-not-fresh)
        (dotimes (i (clamsara.quality.support::world-root-count world))
          (fna-demand (null (read-world-root world i)) :application-root-not-empty))
        ;; Root the valid referent immediately; no callback or collection occurs
        ;; between allocation return and this case-owned physical root handoff.
        (set-world-root world 0 (allocate-node world 7101))
        (fna-demand (functionp callback) :native-callback-not-functionp)
        (fna-demand (not (valid-reference-p (world-model world) callback))
                    :callback-is-unexpectedly-managed)
        (fna-demand (clamsara::%registry-local-referent-p
                     registry (read-world-root world 0)) :referent-not-allocated-local)
        (fna-demand (= 7101 (read-node-slot world (read-world-root world 0) 0))
                    :referent-setup-payload)
        (fna-with-observers
         (lambda ()
           ;; Reuse the shared raw STORE observer, do not overwrite its methods.
           (fna-demand (null clamsara.quality.support::*reference-operation-observer*)
                       :raw-observer-already-active)
           (let ((*active-admission-owner* owner)
                 (clamsara.quality.support::*reference-operation-observer*
                   (lambda (operation) (when (eq operation :store) (fna-effect 7)))))
             (setf (fna-owner-phase owner) :admission
                   (fna-owner-before owner) (fna-snapshot world))
             (let ((rejected nil))
               (handler-case
                   (handler-bind ((error (lambda (c) (fna-capture-signal-state owner c))))
                     (setf (fna-owner-returned-values owner)
                           (multiple-value-list
                            (register-finalizer registry context
                                                (read-world-root world 0) callback))))
                 (clamsara::runtime-rejection (condition)
                   (setf rejected condition)))
               (setf (fna-owner-after owner) (fna-snapshot world))
               (unless rejected
                 ;; Frozen1099 is expected by source inspection to reach RED here.
                 ;; Keep returned token, callback, rooted referent and world as-is.
                 (setf (fna-owner-status owner) :red-accepted
                       (fna-owner-phase owner) :unexpected-native-admission)
                 (error 'fna-failure :reason :native-callback-was-accepted))
               (setf (fna-owner-phase owner) :verify-rejection)
               (fna-demand (eq expected-reason
                              (clamsara::runtime-rejection-reason rejected))
                           :wrong-rejection-reason)
               (fna-demand (null (fna-owner-observation-error owner)) :observer-failed)
               (fna-demand (fna-state-same-p (fna-owner-before owner)
                                            (fna-owner-at-signal owner))
                           :effects-before-rejection)
               (fna-demand (fna-state-same-p (fna-owner-before owner)
                                            (fna-owner-after owner))
                           :effects-during-unwind)
               (fna-demand (every #'zerop (fna-owner-effects owner)) :effect-call-attempted)
               (fna-demand (zerop (fna-owner-callback-calls owner)) :callback-was-invoked)
               (fna-demand (null (fna-owner-returned-values owner)) :token-was-returned)
               (fna-demand (= 7101 (read-node-slot world (read-world-root world 0) 0))
                           :rooted-referent-changed)
               (setf (fna-owner-status owner) :rejected-retained
                     (fna-owner-phase owner) :admission-only-proved))))))
      owner)))

(defun fna-summary (owner)
  "Scalar summary only; do not print/traverse captured guest graphs on failure."
  (let* ((world (fna-owner-world owner))
         (registry (world-registry world)))
    (list :status (fna-owner-status owner) :phase (fna-owner-phase owner)
          :world-retained (not (null world))
          :configuration-state (clamsara::%configuration-state (world-configuration world))
          :plan-state (clamsara::%plan-state (world-plan world))
          :application-root-token-active
          (clamsara::simulator-provider-token-active-p (world-root-token world))
          :registry-root-token-active
          (clamsara::simulator-provider-token-active-p
           (clamsara::%registry-provider-token registry))
          :next-token (clamsara::%registry-next-token registry)
          :registry-states (coerce (clamsara::%registry-states registry) 'list)
          :returned-values-count (length (fna-owner-returned-values owner))
          :effects (coerce (fna-owner-effects owner) 'list)
          :callback-calls (fna-owner-callback-calls owner)
          :condition-type (and (fna-owner-condition owner)
                               (type-of (fna-owner-condition owner)))
          :observed-condition-type (and (fna-owner-observed-condition owner)
                                        (type-of (fna-owner-observed-condition owner))))))

;;;; No captured-reference consequence run or positive publication case is here.
;;;; Those require separate authorization/domain review. No fake managed callable.
