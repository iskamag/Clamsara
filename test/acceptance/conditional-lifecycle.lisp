;;;; Full required sequential weak/ephemeron/finalizer lifecycle acceptance.
;;;;
;;;; This uses the real hosted object model, metadata, roots, coordinator,
;;;; construction, SemiSpace collector and finalizer registry.  It installs no
;;;; protocol stubs or overrides.

(defpackage #:clamsara.acceptance.conditional-lifecycle
  (:use #:cl #:clamsara)
  (:export #:run-conditional-lifecycle-acceptance))
(in-package #:clamsara.acceptance.conditional-lifecycle)

(defun check (value control &rest arguments)
  (unless value (apply #'error control arguments))
  value)

(defun run-conditional-lifecycle-acceptance ()
  (let* ((q 16)
         (extent 4096)
         (base 4096)
         (roots (clamsara::make-simulator-root-client :provider-capacity 8))
         (application-roots (clamsara::make-simulator-root-provider 8))
         (application-token
           (register-root-provider roots :conditional-application 8
                                   application-roots))
         (coordinator
           (clamsara::make-simulator-coordinator
            roots :stop-capacity 64 :await-bound 16))
         (address-space
           (clamsara::make-simulator-address-space
            :base base :byte-extent (* 2 extent) :alignment q :page-size 256
            :coordinator coordinator))
         (model
           (clamsara::make-host-object-model
            :capacity 512 :kind-capacity 16 :slot-capacity 16
            :variant-capacity 256 :location-capacity 16
            :handle-capacity 128 :stage-capacity 8
            :max-object-bytes 128))
         (weak-description
           (make-weak-location-description
            model '(:identity :weak-edge :offset 0) :leaf :weak-cleared))
         (ephemeron-description
           (make-ephemeron-description
            model :chain-ephemeron t :key-cleared :value-cleared))
         (leaf-kind
           (make-object-kind-description
            model :leaf :size-rule 16 :alignment-rule q))
         (weak-kind
           (make-object-kind-description
            model :weak-holder :size-rule 16 :alignment-rule q
            :weak-descriptions (list weak-description)))
         (ephemeron-kind
           (make-object-kind-description
            model :ephemeron-holder :size-rule 16 :alignment-rule q
            :ephemeron-descriptions (list ephemeron-description)))
         (finalizable-kind
           (make-object-kind-description
            model :finalizable-parent :size-rule 16 :alignment-rule q
            :strong-layout '((:identity :child :offset 0))))
         (atomics (clamsara::make-host-atomics))
         (diagnostics (clamsara::make-simulator-diagnostics))
         (clients
           (clamsara::make-simulator-clients
            :model model :roots roots :coordinator coordinator
            :address-space address-space :atomics atomics
            :diagnostics diagnostics))
         (domain-0
           (clamsara::make-metadata-domain
            :base base :limit (+ base extent) :granularity q))
         (domain-1
           (clamsara::make-metadata-domain
            :base (+ base extent) :limit (+ base (* 2 extent))
            :granularity q))
         (from
           (clamsara::make-semispace-space
            :name :conditional-from
            :object-start-map
            (clamsara::make-object-start-marks :domain domain-0)
            :forwarding (clamsara::make-side-forwarding :domain domain-0)
            :extent extent :packing-quantum q :role :allocation))
         (to
           (clamsara::make-semispace-space
            :name :conditional-to
            :object-start-map
            (clamsara::make-object-start-marks :domain domain-1)
            :forwarding (clamsara::make-side-forwarding :domain domain-1)
            :extent extent :packing-quantum q :role :reserve))
         (registry
           (clamsara::make-sequential-finalizer-registry
            :capacity 8 :root-client roots))
         (plan
           (clamsara::make-semispace-plan
            :from-space from :to-space to :root-client roots
            :coordinator coordinator :diagnostics diagnostics
            :registry registry :trace-capacity 256
            :conditional-capacity 128 :finalizer-capacity 8
            :packing-quantum q))
         (configuration (construct-plan plan clients))
         (context (bind-mutator configuration :conditional-test :default))
         (bound (configuration-object-model configuration))
         (barrier (configuration-barrier configuration))
         (finalizer-callback-count 0)
         (failing-callback-count 0)
         (callback-child nil)
         (resurrected nil)
         (resurrection-location
           (clamsara::simulator-root-location application-roots 7)))
    (labels
        ((root-location (index)
           (clamsara::simulator-root-location application-roots index))
         (root-value (index)
           (root-provider-load roots application-token (root-location index)))
         (set-root (index value)
           (multiple-value-bind (effective status)
               (root-provider-store roots context application-token
                                    (root-location index) value)
             (check (eq status :stored) "Root store ~D returned ~S" index status)
             effective))
         (allocate (name bytes descriptor)
           (multiple-value-bind (reference status reason)
               (allocate-object context name bytes q descriptor)
             (check (eq status :allocated)
                    "Allocation of ~S failed: ~S/~S" name status reason)
             reference))
         (write-location (location value)
           (multiple-value-bind (effective status)
               (barrier-store barrier context location value)
             (check (eq status :stored) "Conditional store returned ~S" status)
             effective))
         (read-location (location)
           (multiple-value-bind (value status)
               (barrier-read barrier context location)
             (check (eq status :complete) "Conditional read returned ~S" status)
             value))
         (set-weak (holder value)
           (let ((count 0))
             (map-weak-descriptors
              bound holder
              (lambda (identity location cleared)
                (declare (ignore identity cleared))
                (incf count)
                (write-location location value)))
             (check (= count 1) "Expected one weak descriptor, saw ~D" count)))
         (read-weak (holder)
           (let ((count 0) (answer nil))
             (map-weak-descriptors
              bound holder
              (lambda (identity location cleared)
                (declare (ignore identity cleared))
                (incf count)
                (setf answer (read-location location))))
             (check (= count 1) "Expected one weak descriptor, saw ~D" count)
             answer))
         (set-ephemeron (holder key value)
           (let ((count 0))
             (map-ephemeron-descriptors
              bound holder
              (lambda (identity key-location value-location clear-key-p
                       cleared-key cleared-value)
                (declare (ignore identity clear-key-p cleared-key cleared-value))
                (incf count)
                (write-location key-location key)
                (write-location value-location value)))
             (check (= count 1) "Expected one ephemeron descriptor, saw ~D" count)))
         (read-ephemeron (holder)
           (let ((count 0) (key nil) (value nil))
             (map-ephemeron-descriptors
              bound holder
              (lambda (identity key-location value-location clear-key-p
                       cleared-key cleared-value)
                (declare (ignore identity clear-key-p cleared-key cleared-value))
                (incf count)
                ;; The normative decision order loads value before key.
                (setf value (read-location value-location)
                      key (read-location key-location))))
             (check (= count 1) "Expected one ephemeron descriptor, saw ~D" count)
             (values key value)))
         (set-strong-child (parent child)
           (let ((count 0))
             (map-reference-locations
              bound parent
              (lambda (identity location)
                (declare (ignore identity))
                (incf count)
                (write-location location child)))
             (check (= count 1) "Expected one strong child, saw ~D" count)))
         (read-strong-child (parent)
           (let ((count 0) (child nil))
             (map-reference-locations
              bound parent
              (lambda (identity location)
                (declare (ignore identity))
                (incf count)
                (setf child (read-location location))))
             (check (= count 1) "Expected one strong child, saw ~D" count)
             child))
         (live-reference-p (reference)
           ;; VALID-REFERENCE-P recognizes this model's admitted encoding; it
           ;; does not claim the descriptor still denotes a live object.
           (handler-case
               (progn (normalize-reference bound reference) t)
             (error () nil)))
         (stale-reference-p (reference)
           (handler-case
               (progn (normalize-reference bound reference) nil)
             (error () t)))
         (run-cycle ()
           (let ((record (make-cycle-result-record plan)))
             (collect configuration :all :explicit record)
             (check (eq :complete (cycle-result-status record))
                    "Cycle failed in ~S: ~S"
                    (cycle-result-phase record) (cycle-result-reason record))
             record)))

      ;; Weak fields do not create liveness.  A live weak target is corrected;
      ;; an otherwise-dead target is replaced with its exact cleared immediate.
      (let* ((weak-dead-holder (allocate :weak-holder 16 weak-kind))
             (weak-dead-target (allocate :leaf 16 leaf-kind))
             (weak-live-holder (allocate :weak-holder 16 weak-kind))
             (weak-live-target (allocate :leaf 16 leaf-kind))
             ;; Root order deliberately presents the second ephemeron before
             ;; the first.  Its value can become live only after replay.
             (chain-second (allocate :ephemeron-holder 16 ephemeron-kind))
             (chain-first (allocate :ephemeron-holder 16 ephemeron-kind))
             (chain-key (allocate :leaf 16 leaf-kind))
             (chain-middle (allocate :leaf 16 leaf-kind))
             (chain-value (allocate :leaf 16 leaf-kind))
             (dead-holder (allocate :ephemeron-holder 16 ephemeron-kind))
             (dead-key (allocate :leaf 16 leaf-kind))
             (dead-value (allocate :leaf 16 leaf-kind)))
        (set-weak weak-dead-holder weak-dead-target)
        (set-weak weak-live-holder weak-live-target)
        (set-ephemeron chain-first chain-key chain-middle)
        (set-ephemeron chain-second chain-middle chain-value)
        (set-ephemeron dead-holder dead-key dead-value)
        (set-root 0 weak-dead-holder)
        (set-root 1 weak-live-holder)
        (set-root 2 weak-live-target)
        (set-root 3 chain-second)
        (set-root 4 chain-first)
        (set-root 5 chain-key)
        (set-root 6 dead-holder)
        (run-cycle)

        (check (eq :weak-cleared (read-weak (root-value 0)))
               "Dead weak referent was not cleared")
        (check (reference-equal bound (read-weak (root-value 1)) (root-value 2))
               "Live weak referent was not corrected")
        (multiple-value-bind (first-key first-value)
            (read-ephemeron (root-value 4))
          (check (reference-equal bound first-key (root-value 5))
                 "First ephemeron key was not corrected")
          (multiple-value-bind (second-key second-value)
              (read-ephemeron (root-value 3))
            (check (reference-equal bound first-value second-key)
                   "Ephemeron replay did not retain/correct the middle key")
            (check (live-reference-p second-value)
                   "Least-fixed-point replay did not retain the terminal value")))
        (multiple-value-bind (key value) (read-ephemeron (root-value 6))
          (check (eq key :key-cleared) "Dead ephemeron key was not cleared")
          (check (eq value :value-cleared)
                 "Dead ephemeron value was not cleared"))

        ;; Discharge the conditional graph before the finalizer lifecycle.
        (dotimes (index 7) (set-root index nil))
        (run-cycle))

      ;; A selected finalizer referent and its strong child must remain alive
      ;; through pending publication.  One callback resurrects the parent;
      ;; another exits nonlocally.  Drain claims each at most once and continues.
      (let* ((child (allocate :leaf 16 leaf-kind))
             (parent (allocate :finalizable-parent 16 finalizable-kind))
             (failing (allocate :leaf 16 leaf-kind)))
        (set-strong-child parent child)
        (let ((resurrection-token
                (register-finalizer
                 registry context parent
                 (lambda (corrected-parent)
                   (incf finalizer-callback-count)
                   (setf callback-child (read-strong-child corrected-parent))
                   (multiple-value-bind (effective status)
                       (root-provider-store roots context application-token
                                            resurrection-location
                                            corrected-parent)
                     (check (eq status :stored)
                            "Resurrection root store returned ~S" status)
                     (setf resurrected effective)))))
              (failing-token
                (register-finalizer
                 registry context failing
                 (lambda (corrected)
                   (declare (ignore corrected))
                   (incf failing-callback-count)
                   (error "intentional finalizer callback failure")))))
          (run-cycle)

          ;; Pending records are roots.  Shutdown must not revoke their manager.
          (check (eq :unbound (unbind-mutator configuration context))
                 "Mutator did not unbind before shutdown preflight")
          (let ((reason
                  (handler-case
                      (progn (shutdown-configuration configuration) nil)
                    (clamsara::runtime-rejection (condition)
                      (clamsara::runtime-rejection-reason condition)))))
            (check (eq reason :reachable-objects-not-discharged)
                   "Pending finalizers did not retain usable management: ~S"
                   reason)
            (check (eq :published (clamsara::%configuration-state configuration))
                   "Rejected shutdown closed the configuration"))
          (setf context (bind-mutator configuration :finalizer-drain :default))

          ;; Paper v14 exposes synchronous acquire-claim/drain, not a separate
          ;; public lease/ack API.  State changes before callback invocation are
          ;; tested by the failing callback and a repeated drain.
          (check (= 2 (drain-pending-finalizers registry context))
                 "Pending finalizer drain did not run both callbacks")
          (check (and (= finalizer-callback-count 1)
                      (= failing-callback-count 1))
                 "A finalizer callback did not run exactly once")
          (check (= 0 (drain-pending-finalizers registry context))
                 "Repeated drain invoked a callback twice")
          (check (and (eq :already-finalized
                          (cancel-finalizer registry context resurrection-token))
                      (eq :already-finalized
                          (cancel-finalizer registry context failing-token)))
                 "Completed finalizer token was reusable")
          (check (and resurrected (live-reference-p resurrected))
                 "Resurrection callback did not publish a corrected referent")
          (check (and callback-child (live-reference-p callback-child))
                 "Finalizer support closure did not retain the child")

          ;; Resurrection survives the following cycle and its child is still
          ;; reachable.  Removing that root lets both die in the next cycle.
          (run-cycle)
          (let ((live-parent (root-value 7)))
            (check (live-reference-p live-parent)
                   "Resurrected parent did not survive the next cycle")
            (let ((live-child (read-strong-child live-parent)))
              (check (live-reference-p live-child)
                     "Resurrected parent's child did not survive the next cycle")
              ;; Keep the current encoding so the following cycle tests fate,
              ;; rather than merely observing that the prior encoding moved.
              (setf callback-child live-child))
            (setf resurrected live-parent))
          (set-root 7 nil)
          (run-cycle)
          (check (stale-reference-p resurrected)
                 "Unrooted resurrected referent survived a later cycle")
          (check (stale-reference-p callback-child)
                 "Finalizer child survived after resurrection root removal")))

      (check (eq :unbound (unbind-mutator configuration context))
             "Final mutator did not unbind")
      (multiple-value-bind (status reason) (shutdown-configuration configuration)
        (check (and (eq status :complete) (null reason))
               "Clean conditional configuration did not shut down: ~S/~S"
               status reason))
      (format t "~&CONDITIONAL-LIFECYCLE-ACCEPTANCE-PASS~%")
      t)))
