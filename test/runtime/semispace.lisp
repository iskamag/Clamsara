;;;; Executable v14 SemiSpace lifecycle integration.
(defpackage #:clamsara.runtime.test
  (:use #:cl #:clamsara)
  (:export #:run-v14-runtime-tests))
(in-package #:clamsara.runtime.test)

(defun %check (value format-control &rest arguments)
  (unless value (apply #'error format-control arguments))
  value)

(defun run-v14-runtime-tests ()
  (let* ((q 16) (extent 1024) (base 4096)
         (roots (clamsara::make-simulator-root-client :provider-capacity 8))
         (application-roots (clamsara::make-simulator-root-provider 1))
         (application-token
           (register-root-provider roots :application 1 application-roots))
         (coordinator
           (clamsara::make-simulator-coordinator
            roots :stop-capacity 16 :await-bound 16))
         (address-space
           (clamsara::make-simulator-address-space
            :base base :byte-extent (* 2 extent) :alignment q :page-size 256
            :coordinator coordinator))
         (model (clamsara::make-host-object-model
                 :capacity 256 :slot-capacity 8 :handle-capacity 64
                 :max-object-bytes 128))
         (kind (make-object-kind-description
                model :node :size-rule 32 :alignment-rule q
                :strong-layout '(:left :right)))
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
                :name :from
                :object-start-map
                (clamsara::make-object-start-marks :domain domain-0)
                :forwarding
                (clamsara::make-side-forwarding :domain domain-0)
                :extent extent :packing-quantum q :role :allocation))
         (to (clamsara::make-semispace-space
              :name :to
              :object-start-map
              (clamsara::make-object-start-marks :domain domain-1)
              :forwarding
              (clamsara::make-side-forwarding :domain domain-1)
              :extent extent :packing-quantum q :role :reserve))
         (registry (clamsara::make-sequential-finalizer-registry
                    :capacity 8 :root-client roots))
         (plan (clamsara::make-semispace-plan
                :from-space from :to-space to :root-client roots
                :coordinator coordinator :diagnostics diagnostics
                :registry registry :trace-capacity 64
                :conditional-capacity 64 :finalizer-capacity 8
                :packing-quantum q))
         (configuration (construct-plan plan clients))
         (context (bind-mutator configuration :runtime-test :default))
         (bound (configuration-object-model configuration)))
    (labels ((allocate-node ()
               (multiple-value-bind (reference status reason)
                   (allocate-object context :node 32 q kind)
                 (%check (eq status :allocated)
                         "Allocation failed: ~S" reason)
                 reference))
             (store-slot (object wanted value)
               (let ((index 0) (stored nil))
                 (map-reference-locations
                  bound object
                  (lambda (identity location)
                    (declare (ignore identity))
                    (when (= index wanted)
                      (multiple-value-bind (effective status)
                          (barrier-store (configuration-barrier configuration)
                                         context location value)
                        (%check (eq status :stored)
                                "Barrier store returned ~S" status)
                        (setf stored effective)))
                    (incf index)))
                 stored))
             (read-slot (object wanted)
               (let ((index 0) (result nil) (found nil))
                 (map-reference-locations
                  bound object
                  (lambda (identity location)
                    (declare (ignore identity))
                    (when (= index wanted)
                      (multiple-value-bind (value status)
                          (barrier-read (configuration-barrier configuration)
                                        context location)
                        (%check (eq status :complete)
                                "Barrier read returned ~S" status)
                        (setf result value found t)))
                    (incf index)))
                 (%check found "Missing strong slot ~D" wanted)
                 result)))
      (let ((a (allocate-node)) (b (allocate-node)) (dead (allocate-node)))
        (store-slot a 0 b)
        (store-slot b 0 a)
        (multiple-value-bind (effective status)
            (root-provider-store
             roots context application-token
             (clamsara::simulator-root-location application-roots 0) a)
          (declare (ignore effective))
          (%check (eq status :stored) "Root store returned ~S" status))
        (let ((old-a-address (reference-address bound a))
              (record (make-cycle-result-record plan)))
          (collect configuration :all :explicit record)
          (%check (eq :complete (cycle-result-status record))
                  "Cycle status/reason: ~S/~S"
                  (cycle-result-status record) (cycle-result-reason record))
          (multiple-value-bind (count known-p)
              (cycle-result-count record :objects-moved)
            (%check (and known-p (= count 2))
                    "Expected exactly two moved objects, got ~S/~S"
                    count known-p))
          (multiple-value-bind (count known-p)
              (cycle-result-count record :objects-dead)
            (%check (and known-p (= count 1))
                    "Expected exactly one dead object, got ~S/~S"
                    count known-p))
          (%check (not (valid-reference-p bound dead))
                  "Dead source representation was not retired")
          (let* ((new-a
                   (root-provider-load
                    roots application-token
                    (clamsara::simulator-root-location
                     application-roots 0)))
                 (new-b (read-slot new-a 0)))
            (%check (/= old-a-address (reference-address bound new-a))
                    "Root was not corrected to the other semispace")
            (%check (reference-equal bound (read-slot new-b 0) new-a)
                    "Two-object cycle did not preserve sharing")))))
    (%check (eq :unbound (unbind-mutator configuration context))
            "Mutator did not unbind")
    (format t "~&V14-SEMISPACE-LIFECYCLE-OK~%")
    t))
