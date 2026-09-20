;;;; Post-forwarding failure must retain the stop and reject resumption.
(defpackage #:clamsara.runtime.retained-failure.test
  (:use #:cl #:clamsara)
  (:export #:run-retained-failure-test))
(in-package #:clamsara.runtime.retained-failure.test)

(defun check (value control &rest arguments)
  (unless value (apply #'error control arguments))
  value)

(defun rejection-reason (thunk)
  (handler-case (progn (funcall thunk) nil)
    (clamsara::runtime-rejection (condition)
      (clamsara::runtime-rejection-reason condition))))

(defun signals-error-p (thunk)
  (handler-case (progn (funcall thunk) nil)
    (error () t)))

(defun run-retained-failure-test ()
  (let* ((q 16) (extent 1024) (base 4096)
         (roots (clamsara::make-simulator-root-client :provider-capacity 8))
         (application-roots (clamsara::make-simulator-root-provider 1))
         (application-token
           (register-root-provider roots :retained-application 1
                                   application-roots))
         (coordinator
           (clamsara::make-simulator-coordinator
            roots :stop-capacity 16 :await-bound 16))
         (address-space
           (clamsara::make-simulator-address-space
            :base base :byte-extent (* 2 extent) :alignment q :page-size 256
            :coordinator coordinator))
         (model (clamsara::make-host-object-model
                 :capacity 256 :kind-capacity 8 :slot-capacity 8
                 :variant-capacity 0 :location-capacity 8
                 :handle-capacity 64 :stage-capacity 4
                 :max-object-bytes 128))
         (weak-description
           (make-weak-location-description
            model '(:identity :weak-edge :offset 0) :leaf :cleared))
         (weak-kind
           (make-object-kind-description
            model :weak-holder :size-rule 16 :alignment-rule q
            :weak-descriptions (list weak-description)))
         (atomics (clamsara::make-host-atomics))
         (diagnostics (clamsara::make-simulator-diagnostics))
         (clients (clamsara::make-simulator-clients
                   :model model :roots roots :coordinator coordinator
                   :address-space address-space :atomics atomics
                   :diagnostics diagnostics))
         (domain-0 (clamsara::make-metadata-domain
                    :base base :limit (+ base extent) :granularity q))
         (domain-1 (clamsara::make-metadata-domain
                    :base (+ base extent) :limit (+ base (* 2 extent))
                    :granularity q))
         (from (clamsara::make-semispace-space
                :name :retained-from
                :object-start-map
                (clamsara::make-object-start-marks :domain domain-0)
                :forwarding (clamsara::make-side-forwarding :domain domain-0)
                :extent extent :packing-quantum q :role :allocation))
         (to (clamsara::make-semispace-space
              :name :retained-to
              :object-start-map
              (clamsara::make-object-start-marks :domain domain-1)
              :forwarding (clamsara::make-side-forwarding :domain domain-1)
              :extent extent :packing-quantum q :role :reserve))
         (registry (clamsara::make-sequential-finalizer-registry
                    :capacity 4 :root-client roots))
         ;; Zero conditional capacity is admitted construction state.  The
         ;; rooted weak holder is copied first, then exact conditional staging
         ;; fails after forwarding publication.
         (plan (clamsara::make-semispace-plan
                :from-space from :to-space to :root-client roots
                :coordinator coordinator :diagnostics diagnostics
                :registry registry :trace-capacity 64
                :conditional-capacity 0 :finalizer-capacity 4
                :packing-quantum q))
         (configuration (construct-plan plan clients))
         (context (bind-mutator configuration :retained-test :default))
         (holder
           (multiple-value-bind (reference status reason)
               (allocate-object context :weak-holder 16 q weak-kind)
             (check (eq status :allocated) "Allocation failed: ~S" reason)
             reference))
         (location (clamsara::simulator-root-location application-roots 0)))
    (multiple-value-bind (effective status)
        (root-provider-store roots context application-token location holder)
      (declare (ignore effective))
      (check (eq status :stored) "Root store returned ~S" status))
    (let ((record (make-cycle-result-record plan)))
      (collect configuration :all :explicit record)
      (check (and (eq :retained (cycle-result-status record))
                  (eq :weak-storage-exhausted (cycle-result-reason record)))
             "Expected retained weak exhaustion, got ~S/~S"
             (cycle-result-status record) (cycle-result-reason record))
      (dolist (entry '((:objects-discovered . 1) (:objects-moved . 1)
                       (:bytes-moved . 16) (:objects-dead . 0)
                       (:weak-corrections . 0) (:finalizers-enqueued . 0)))
        (multiple-value-bind (count known-p)
            (cycle-result-count record (car entry))
          (check (and known-p (= count (cdr entry)))
                 "Counter ~S expected ~D, got ~S/~S"
                 (car entry) (cdr entry) count known-p))))
    (check (and (eq :retained (clamsara::%plan-state plan))
                (eq :covered (clamsara::simulator-stop-state coordinator)))
           "Post-forwarding failure resumed the heap")
    (let ((fresh (make-cycle-result-record plan)))
      (check (eq :collection-busy
                 (rejection-reason
                  (lambda () (collect configuration :all :explicit fresh))))
             "A second collection entered retained state")
      (check (eq :uninitialized (cycle-result-status fresh))
             "Rejected collection mutated its result record"))
    (check (eq :collection-busy
               (rejection-reason
                (lambda ()
                  (allocate-object context :weak-holder 16 q weak-kind))))
           "Allocation entered retained state")
    ;; The retained stop closes host root admission before the composed route,
    ;; so the host may reject this as :ROOT-ACCESS-STOPPED rather than exposing
    ;; the runtime's :COLLECTION-BUSY reason.  Either path must preclude a store.
    (check (signals-error-p
            (lambda ()
              (root-provider-store roots context application-token
                                   location nil)))
           "Root store entered retained state")
    (check (eq :collection-busy
               (rejection-reason
                (lambda ()
                  (register-finalizer registry context holder
                                      (lambda (reference)
                                        (declare (ignore reference)))))))
           "Finalizer registration entered retained state")
    (check (eq :retry (unbind-mutator configuration context))
           "Retained stop allowed context unbind")
    (multiple-value-bind (status reason)
        (clamsara::%drain-configuration-runtime configuration)
      (check (and (eq status :retained)
                  (eq reason :weak-storage-exhausted))
             "Runtime drain lost retained reason: ~S/~S" status reason))
    (check (eq :active-mutator-contexts
               (rejection-reason
                (lambda () (shutdown-configuration configuration))))
           "Shutdown entered an active retained configuration")
    (check (and (eq :published
                    (clamsara::%configuration-state configuration))
                (eq :covered (clamsara::simulator-stop-state coordinator)))
           "Rejected shutdown resumed or closed retained state")
    (format t "~&V14-RETAINED-FAILURE-OK~%")
    t))
