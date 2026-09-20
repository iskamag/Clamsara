;;;; src/workload/setup.lisp -- concrete hosted workload construction.
;;;;
;;;; This is the single construction path used by workload smoke/acceptance
;;;; callers.  It does not create a private heap or bypass the configuration
;;;; builder: roots, address-space, object model, semispaces, barrier and
;;;; mutator are all the ordinary CLAMSARA construction services.

(in-package #:clamsara)

(defstruct (workload-runtime
            (:constructor %make-workload-runtime))
  roots root-provider root-token configuration context environment
  model clients plan coordinator address-space from-space to-space)

(defun make-workload-runtime
    (&key (base 4096) (extent (* 32 1024 1024)) (quantum 16)
          (page-size 256) (object-capacity nil)
          (max-object-bytes (* 8 1024 1024))
          (root-capacity 131072) (root-provider-capacity 4)
          (execution :workload) (allocation-domain :default))
  "Construct a real semispace workload environment.

This setup provisions fixed CONS/STRUCT kinds and the host model's opaque
variable-size generic, single-float and integer array kinds. Array sizes use
an extent-dependent rule and indexed layouts, never a slot vector proportional
to element count."
  (unless (and (plusp extent) (plusp quantum) (zerop (mod extent quantum))
               (zerop (mod base quantum)) (> extent (* 2 quantum)))
    (error 'workload-capability-error :operation 'make-workload-runtime
           :reason :invalid-geometry))
  (let* ((required-object-capacity (ceiling (* 2 extent) quantum))
         (effective-object-capacity (or object-capacity
                                        required-object-capacity)))
    (unless (and (integerp effective-object-capacity)
                 (>= effective-object-capacity required-object-capacity))
      (error 'workload-capability-error :operation 'make-workload-runtime
             :reason (list :object-capacity-too-small
                           effective-object-capacity
                           required-object-capacity)))
    (let* ((finalizer-capacity 128)
           (roots (make-simulator-root-client
                   :provider-capacity root-provider-capacity
                   ;; Keep application and framework root bounds distinct.
                   :root-capacity (+ root-capacity (* 2 finalizer-capacity))))
         (root-provider (make-workload-root-provider root-capacity))
         (root-token (register-root-provider roots :workload root-capacity
                                             root-provider))
         (coordinator (make-simulator-coordinator
                       roots :stop-capacity 16384 :await-bound 16384))
         (address-space (make-simulator-address-space
                         :base base :byte-extent (* 2 extent)
                         :alignment quantum :page-size page-size
                         :coordinator coordinator))
         (model (make-host-object-model
                 :capacity effective-object-capacity
                 :max-object-bytes max-object-bytes
                 :location-capacity 32 :handle-capacity 2048
                 :stage-capacity 8 :kind-capacity 16 :slot-capacity 8))
         (cons-kind
           (make-object-kind-description
            model :cons :size-rule 32 :alignment-rule quantum
            :strong-layout '((:identity :car :offset 0)
                             (:identity :cdr :offset 8))))
         ;; Indexed and numeric arrays use private opaque host descriptors.
         ;; The model retains the variable rule and indexed offer; it never
         ;; expands a 500K-element strong-layout vector.
         (array-size-rule (make-host-variable-size-rule
                           :header-bytes 16 :element-bytes 8
                           :element-kind :reference :minimum-elements 0))
         (numeric-array-size-rule
           (make-host-variable-size-rule
            :header-bytes 16 :element-bytes 8
            :element-kind :numeric :minimum-elements 0))
         (array-layout (make-host-indexed-layout
                        :identity-function #'identity
                        :base-offset 16 :element-word-bytes 8
                        :element-strength :strong))
         (array-kind
           (make-object-kind-description
            model :array :size-rule array-size-rule
            :alignment-rule quantum :strong-layout array-layout))
         (single-float-kind
           (make-object-kind-description
            model :array-single-float :size-rule numeric-array-size-rule
            :alignment-rule quantum :strong-layout nil))
         (integer-kind
           (make-object-kind-description
            model :array-integer :size-rule numeric-array-size-rule
            :alignment-rule quantum :strong-layout nil))
         ;; A structure uses one managed type-tag word and up to seven fields.
         (struct-kind
           (make-object-kind-description
            model :struct :size-rule 64 :alignment-rule quantum
            :strong-layout '((:identity :slot0 :offset 0)
                             (:identity :slot1 :offset 8)
                             (:identity :slot2 :offset 16)
                             (:identity :slot3 :offset 24)
                             (:identity :slot4 :offset 32)
                             (:identity :slot5 :offset 40)
                             (:identity :slot6 :offset 48)
                             (:identity :slot7 :offset 56))))
         (atomics (make-host-atomics))
         (diagnostics (make-simulator-diagnostics))
         (clients (make-simulator-clients
                   :model model :roots roots :coordinator coordinator
                   :address-space address-space :atomics atomics
                   :diagnostics diagnostics))
         (domain-0 (make-metadata-domain
                    :base base :limit (+ base extent) :granularity quantum))
         (domain-1 (make-metadata-domain
                    :base (+ base extent) :limit (+ base (* 2 extent))
                    :granularity quantum))
         (from (make-semispace-space
                :name :from
                :object-start-map
                (make-object-start-marks :domain domain-0)
                :forwarding (make-side-forwarding :domain domain-0)
                :extent extent :packing-quantum quantum :role :allocation))
         (to (make-semispace-space
              :name :to
              :object-start-map
              (make-object-start-marks :domain domain-1)
              :forwarding (make-side-forwarding :domain domain-1)
              :extent extent :packing-quantum quantum :role :reserve))
         (registry (make-sequential-finalizer-registry
                    :capacity finalizer-capacity :root-client roots))
         (plan (make-semispace-plan
                :from-space from :to-space to :root-client roots
                :coordinator coordinator :diagnostics diagnostics
                :registry registry :trace-capacity effective-object-capacity
                :conditional-capacity 4096 :finalizer-capacity finalizer-capacity
                :packing-quantum quantum))
         (configuration (construct-plan plan clients))
         (context (bind-mutator configuration execution allocation-domain))
         (kinds (list :cons (make-workload-kind :cons cons-kind 32 quantum)
                      :array (make-workload-kind
                              :array array-kind
                              (lambda (count) (+ 16 (* count 8))) quantum)
                      :array-single-float
                      (make-workload-kind
                       :array-single-float single-float-kind
                       (lambda (count) (+ 16 (* count 8))) quantum
                       :element-type 'single-float)
                      :array-integer
                      (make-workload-kind
                       :array-integer integer-kind
                       (lambda (count) (+ 16 (* count 8))) quantum
                       :element-type 'integer)
                      :struct (make-workload-kind :struct struct-kind 64 quantum)))
         (environment
           (make-workload-environment
            configuration :execution execution
            :allocation-domain allocation-domain :root-client roots
            :root-provider root-provider :root-token root-token
            :root-locations (workload-provider-temporary-locations
                             root-provider)
            :array-header-bytes 16
            :kinds kinds)))
    ;; Maclina setup initializes the fixed VM and retargets the provider before
    ;; any source form or benchmark allocation executes.
    (setup-workload-maclina environment)
    (%make-workload-runtime
     :roots roots :root-provider root-provider :root-token root-token
     :configuration configuration :context context :environment environment
     :model model :clients clients :plan plan :coordinator coordinator
     :address-space address-space :from-space from :to-space to))))

(defun close-workload-runtime (runtime)
  "Collect dead workload payload, then release this runtime's owned services.

Close never discards application roots. A live result, global, or explicit
root rejects close while the environment remains open. The caller must release
that root (for example, consume a completed result with WORKLOAD-EVAL NIL)
and retry. The discharge collection may move live objects on rejection."
  (let ((environment (workload-runtime-environment runtime))
        (configuration (workload-runtime-configuration runtime))
        (context (workload-runtime-context runtime))
        (provider (workload-runtime-root-provider runtime)))
    (unless configuration (return-from close-workload-runtime (values)))
    (let ((vm (workload-provider-vm provider)))
      (when (or (plusp (workload-provider-frame-count provider))
                (and vm (or (plusp (maclina.vm-cross::vm-stack-top vm))
                            (maclina.vm-cross::vm-dynenv-stack vm))))
        (error 'workload-error :operation 'close-workload-runtime
               :reason :active-workload-execution)))
    ;; Do not unbind either owned context until the real root set has been
    ;; traced and all application allocations discharged. A failed collection
    ;; or live-root rejection leaves the environment and registrations intact.
    ;; A prior shutdown already in :CLOSING retries its drain/release only.
    (when (eq :published (%configuration-state configuration))
      (let* ((plan (workload-runtime-plan runtime))
             (record (make-cycle-result-record plan)))
        (collect configuration :all :explicit record)
        (unless (eq :complete (cycle-result-status record))
          (error 'workload-error :operation 'close-workload-runtime
                 :reason (list :discharge-status (cycle-result-status record)
                               (cycle-result-reason record))))
        (multiple-value-bind (live known-p)
            (cycle-result-count record :objects-discovered)
          (unless (and known-p (zerop live)
                       (not (%configuration-has-allocated-objects-p plan)))
            (error 'workload-error :operation 'close-workload-runtime
                   :reason :reachable-objects-not-discharged))))
      (when environment (close-workload-environment environment))
      (when context
        (let ((status (unbind-mutator configuration context)))
          (unless (member status '(:unbound :already-unbound))
            (error 'workload-error :operation 'unbind-mutator :reason status)))))
    (multiple-value-bind (status reason) (shutdown-configuration configuration)
      (unless (eq status :complete)
        (error 'workload-error :operation 'close-workload-runtime
               :reason (list :shutdown-status status reason))))
    (when (workload-runtime-root-token runtime)
      (unregister-root-provider
       (workload-runtime-roots runtime)
       (workload-runtime-root-token runtime)))
    (setf (workload-runtime-environment runtime) nil
          (workload-runtime-context runtime) nil
          (workload-runtime-configuration runtime) nil
          (workload-runtime-root-token runtime) nil)
    (values)))

(defun run-workload-smoke (&key (extent (* 1024 1024)) (stream *standard-output*))
  "Allocate a managed node pair, collect, and report the composed result."
  (let ((runtime (make-workload-runtime :extent extent)))
    (unwind-protect
         (let* ((env (workload-runtime-environment runtime))
                (configuration (workload-runtime-configuration runtime))
                (plan (workload-runtime-plan runtime))
                (root-set
                  (make-workload-root-set
                   env (workload-provider-temporary-locations
                        (workload-runtime-root-provider runtime))))
                (a (workload-eval env `(cons nil nil))))
           ;; Keep both references in registered physical roots across every
           ;; subsequent allocation and barrier slow path.
           (workload-root-place root-set 0 a)
           (let* ((current-a (workload-root-load root-set 0))
                  (b (workload-eval env `(cons ,current-a nil)))
                  (record (make-cycle-result-record plan)))
             (workload-root-place root-set 1 b)
             (collect configuration :all :explicit record)
             ;; The smoke payload has been checked; discharge temporary roots
             ;; before configuration shutdown so reachable-object accounting
             ;; can close cleanly.
             (workload-root-clear root-set 0)
             (workload-root-clear root-set 1)
             ;; VM-CROSS retains the last result list outside BYTECODE-CALL;
             ;; clear it before the discharge cycle as well.
             (let ((vm (workload-provider-vm
                        (workload-runtime-root-provider runtime))))
               (when vm
                 (setf (maclina.vm-cross::vm-values vm) nil
                       (maclina.vm-cross::vm-dynenv-stack vm) nil
                       (maclina.vm-cross::vm-stack-top vm) 0)))
             ;; A second, empty-root cycle reclaims the moved payload.  The
             ;; runtime intentionally rejects shutdown while any object is
             ;; still retained, even if the smoke assertion already passed.
             (let ((discharge (make-cycle-result-record plan)))
               (collect configuration :all :explicit discharge)
               (unless (eq :complete (cycle-result-status discharge))
                 (error 'workload-error :operation 'run-workload-smoke
                        :reason (list :discharge-status
                                      (cycle-result-status discharge)))))
             (multiple-value-bind (moved known-p)
                 (cycle-result-count record :objects-moved)
               (unless (and (eq :complete (cycle-result-status record))
                            known-p (plusp moved))
                 (error 'workload-error :operation 'run-workload-smoke
                        :reason (list :collection-status
                                      (cycle-result-status record)
                                      :objects-moved moved :known-p known-p)))
               (format stream
                       "~&WORKLOAD-SMOKE payload=managed-cons-pair collection=:complete objects-moved=~D~%"
                       moved)
               (list :status :complete :payload :managed-cons-pair
                     :objects-moved moved))))
      (close-workload-runtime runtime))))

(export '(workload-runtime make-workload-runtime close-workload-runtime
          run-workload-smoke))
