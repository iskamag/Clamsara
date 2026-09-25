;;;; Native lifecycle/capacity checks for the optional generational profile.
(defpackage #:clamsara.runtime.generational.test
  (:use #:cl #:clamsara)
  (:export #:run-generational-runtime-tests))
(in-package #:clamsara.runtime.generational.test)

(defun check (value control &rest arguments)
  (unless value (apply #'error control arguments)) value)

(defun stale-p (model reference)
  (handler-case (progn (normalize-reference model reference) nil)
    (error () t)))

(defun check-counts (record expected)
  (dolist (entry expected)
    (multiple-value-bind (count known-p)
        (cycle-result-count record (car entry))
      (check (and known-p (= count (cdr entry)))
             "Counter ~S expected ~D, got ~S/~S"
             (car entry) (cdr entry) count known-p))))

(defun run-generational-runtime-tests ()
  (let* ((q 16) (nursery-extent 1024) (mature-extent 4096) (base 4096)
         (roots (clamsara::make-simulator-root-client :provider-capacity 8))
         (app-roots (clamsara::make-simulator-root-provider 2))
         (app-token (register-root-provider roots :generational-app 2 app-roots))
         (coordinator (clamsara::make-simulator-coordinator
                       roots :stop-capacity 32 :await-bound 16))
         (address-space
           (clamsara::make-simulator-address-space
            :base base :byte-extent (+ (* 2 nursery-extent) mature-extent)
            :alignment q :page-size 256 :coordinator coordinator))
         (model (clamsara::make-host-object-model
                 :capacity 512 :kind-capacity 8 :slot-capacity 8
                 :variant-capacity 0 :location-capacity 8
                 :handle-capacity 128 :stage-capacity 4
                 :max-object-bytes 128))
         (node-kind (make-object-kind-description
                     model :node :size-rule 16 :alignment-rule q
                     :strong-layout '((:identity :child :offset 0))))
         (weak-description
           (make-weak-location-description
            model '(:identity :weak-edge :offset 0) :leaf :weak-cleared))
         (ephemeron-description
           (make-ephemeron-description
            model :generational-ephemeron t :key-cleared :value-cleared))
         (leaf-kind (make-object-kind-description
                     model :leaf :size-rule 16 :alignment-rule q))
         (weak-kind (make-object-kind-description
                     model :weak-holder :size-rule 16 :alignment-rule q
                     :weak-descriptions (list weak-description)))
         (ephemeron-kind (make-object-kind-description
                           model :ephemeron-holder :size-rule 16
                           :alignment-rule q
                           :ephemeron-descriptions
                           (list ephemeron-description)))
         (atomics (clamsara::make-host-atomics))
         (diagnostics (clamsara::make-simulator-diagnostics))
         (clients (clamsara::make-simulator-clients
                   :model model :roots roots :coordinator coordinator
                   :address-space address-space :atomics atomics
                   :diagnostics diagnostics))
         (domain-0 (clamsara::make-metadata-domain
                    :base base :limit (+ base nursery-extent) :granularity q))
         (domain-1 (clamsara::make-metadata-domain
                    :base (+ base nursery-extent)
                    :limit (+ base (* 2 nursery-extent)) :granularity q))
         (mature-base (+ base (* 2 nursery-extent)))
         (domain-m (clamsara::make-metadata-domain
                    :base mature-base :limit (+ mature-base mature-extent)
                    :granularity q))
         (nursery-0
           (clamsara::make-generational-nursery-space
            :name :nursery-0
            :object-start-map (clamsara::make-object-start-marks :domain domain-0)
            :forwarding (clamsara::make-side-forwarding :domain domain-0)
            :extent nursery-extent :packing-quantum q :role :allocation))
         (nursery-1
           (clamsara::make-generational-nursery-space
            :name :nursery-1
            :object-start-map (clamsara::make-object-start-marks :domain domain-1)
            :forwarding (clamsara::make-side-forwarding :domain domain-1)
            :extent nursery-extent :packing-quantum q :role :reserve))
         (mature
           (clamsara::make-generational-mature-space
            :name :mature
            :object-start-map (clamsara::make-object-start-marks :domain domain-m)
            
            :extent mature-extent :packing-quantum q :descriptor-capacity 128))
         (registry (clamsara::make-sequential-finalizer-registry
                    :capacity 8 :root-client roots))
         (plan (clamsara::make-generational-plan
                :nursery-from nursery-0 :nursery-to nursery-1 :mature mature
                :root-client roots :coordinator coordinator
                :diagnostics diagnostics :registry registry
                :trace-capacity 384 :conditional-capacity 384
                :finalizer-capacity 8 :packing-quantum q))
         (configuration (construct-plan plan clients))
         (context (bind-mutator configuration :generational-test :default))
         (bound (configuration-object-model configuration))
         (barrier (configuration-barrier configuration)))
    (labels ((root-location (index)
               (clamsara::simulator-root-location app-roots index))
             (root (index) (root-provider-load roots app-token (root-location index)))
             (set-root (index value)
               (multiple-value-bind (effective status)
                   (root-provider-store roots context app-token
                                        (root-location index) value)
                 (check (eq status :stored) "Root store returned ~S" status)
                 effective))
             (allocate-kind (name descriptor)
               (multiple-value-bind (reference status reason)
                   (allocate-object context name 16 q descriptor)
                 (check (eq status :allocated) "Allocation failed: ~S" reason)
                 reference))
             (allocate-node () (allocate-kind :node node-kind))
             (write-through-barrier (location value)
               (multiple-value-bind (effective status)
                   (barrier-store barrier context location value)
                 (declare (ignore effective))
                 (check (eq status :stored) "Barrier store returned ~S" status)))
             (read-through-barrier (location)
               (multiple-value-bind (value status)
                   (barrier-read barrier context location)
                 (check (eq status :complete) "Barrier read returned ~S" status)
                 value))
             (set-weak (holder value)
               (let ((seen 0))
                 (map-weak-descriptors
                  bound holder
                  (lambda (identity location cleared)
                    (declare (ignore identity cleared))
                    (incf seen) (write-through-barrier location value)))
                 (check (= seen 1) "Expected one weak location")))
             (read-weak (holder)
               (let ((seen 0) (answer nil))
                 (map-weak-descriptors
                  bound holder
                  (lambda (identity location cleared)
                    (declare (ignore identity cleared))
                    (incf seen) (setf answer (read-through-barrier location))))
                 (check (= seen 1) "Expected one weak location") answer))
             (set-ephemeron (holder key value)
               (let ((seen 0))
                 (map-ephemeron-descriptors
                  bound holder
                  (lambda (identity key-location value-location clear-key-p
                           cleared-key cleared-value)
                    (declare (ignore identity clear-key-p cleared-key cleared-value))
                    (incf seen)
                    (write-through-barrier key-location key)
                    (write-through-barrier value-location value)))
                 (check (= seen 1) "Expected one ephemeron descriptor")))
             (read-ephemeron (holder)
               (let ((seen 0) (key nil) (value nil))
                 (map-ephemeron-descriptors
                  bound holder
                  (lambda (identity key-location value-location clear-key-p
                           cleared-key cleared-value)
                    (declare (ignore identity clear-key-p cleared-key cleared-value))
                    (incf seen)
                    (setf value (read-through-barrier value-location)
                          key (read-through-barrier key-location))))
                 (check (= seen 1) "Expected one ephemeron descriptor")
                 (values key value)))
             (set-child (parent child)
               (let ((seen 0))
                 (map-reference-locations
                  bound parent
                  (lambda (identity location)
                    (declare (ignore identity))
                    (incf seen)
                    (multiple-value-bind (effective status)
                        (barrier-store barrier context location child)
                      (declare (ignore effective))
                      (check (eq status :stored) "Child store returned ~S" status))))
                 (check (= seen 1) "Expected one child slot")))
             (child (parent)
               (let ((seen 0) (answer nil))
                 (map-reference-locations
                  bound parent
                  (lambda (identity location)
                    (declare (ignore identity))
                    (incf seen)
                    (multiple-value-bind (value status)
                        (barrier-read barrier context location)
                      (check (eq status :complete) "Child read returned ~S" status)
                      (setf answer value))))
                 (check (= seen 1) "Expected one child slot") answer))
             (cycle (scope expected)
               (let ((record (make-cycle-result-record plan)))
                 (collect configuration scope :explicit record)
                 (check (eq :complete (cycle-result-status record))
                        "~S cycle failed: ~S/~S" scope
                        (cycle-result-phase record) (cycle-result-reason record))
                 (check-counts record expected)
                 record)))
      ;; Threshold-one promotion: a rooted nursery parent moves into mature.
      (let ((nursery-parent (allocate-node)))
        (set-root 0 nursery-parent)
        (cycle :minor '((:objects-discovered . 1) (:objects-moved . 1)
                        (:bytes-moved . 16) (:objects-dead . 0)
                        (:weak-corrections . 0) (:finalizers-enqueued . 0)))
        (check (stale-p bound nursery-parent) "Nursery source was not retired")
        (let* ((old-parent (root 0))
               (old-address (reference-address bound old-parent))
               (young-child (allocate-node)))
          (check (and (>= old-address mature-base)
                      (< old-address (+ mature-base mature-extent)))
                 "Parent was not promoted into mature")
          ;; Only this old edge retains the child.  The plan-authored barrier
          ;; must dirty the conservative mature card.
          (set-child old-parent young-child)
          (check (if (clamsara::%gen-card-active-p plan)
                     (find 1 (clamsara::%gen-card-marks plan))
                     (clamsara::%gen-remembered-dirty-p plan))
                 "Old-to-young store did not dirty remembered state")
          (cycle :minor '((:objects-discovered . 1) (:objects-moved . 1)
                          (:bytes-moved . 16) (:objects-dead . 0)
                          (:weak-corrections . 0) (:finalizers-enqueued . 0)))
          (check (stale-p bound young-child) "Young child source was not retired")
          (let ((parent-after (root 0)))
            (check (= old-address (reference-address bound parent-after))
                   "Minor moved an old object")
            (let ((promoted-child (child parent-after)))
              (check (and (valid-reference-p bound promoted-child)
                          (>= (reference-address bound promoted-child) mature-base))
                     "Remembered edge did not preserve/promote young child")))
          (check (if (clamsara::%gen-card-active-p plan)
                     (not (find 1 (clamsara::%gen-card-marks plan)))
                     (not (clamsara::%gen-remembered-dirty-p plan)))
                 "Remembered card did not clear after complete correction")
          ;; An empty repeat minor leaves old objects stable and reports zero.
          (cycle :minor '((:objects-discovered . 0) (:objects-moved . 0)
                          (:bytes-moved . 0) (:objects-dead . 0)
                          (:weak-corrections . 0) (:finalizers-enqueued . 0)))
          (check (= old-address (reference-address bound (root 0)))
                 "Repeat minor changed old address")
          ;; Promote a second object, then make it unreachable and prove that
          ;; a true major (not a minor label) reclaims mature storage.
          (let ((doomed-young (allocate-node)))
            (set-root 1 doomed-young)
            (cycle :minor '((:objects-discovered . 1) (:objects-moved . 1)
                            (:bytes-moved . 16) (:objects-dead . 0)
                            (:weak-corrections . 0) (:finalizers-enqueued . 0)))
            (let ((doomed-old (root 1)))
              (set-root 1 nil)
              (cycle :all '((:objects-discovered . 2) (:objects-moved . 0)
                            (:bytes-moved . 0) (:objects-dead . 1)
                            (:weak-corrections . 0) (:finalizers-enqueued . 0)))
              (check (stale-p bound doomed-old)
                     "Major did not reclaim unreachable mature object")
              (check (= old-address (reference-address bound (root 0)))
                     "Major moved rooted mature parent")))
          ;; Complete mature conditional-source enumeration is independent of
          ;; strong remembered-card dirtiness.  Live weak young references are
          ;; corrected; dead ones are cleared.
          (let ((weak-young (allocate-kind :weak-holder weak-kind)))
            (set-root 1 weak-young)
            (cycle :minor '((:objects-discovered . 1) (:objects-moved . 1)
                            (:bytes-moved . 16) (:objects-dead . 0)
                            (:weak-corrections . 1) (:finalizers-enqueued . 0)))
            (let* ((weak-old (root 1))
                   (live-target (allocate-kind :leaf leaf-kind)))
              (set-weak weak-old live-target)
              (set-root 0 live-target)
              (cycle :minor '((:objects-discovered . 1) (:objects-moved . 1)
                              (:bytes-moved . 16) (:objects-dead . 0)
                              (:weak-corrections . 1) (:finalizers-enqueued . 0)))
              (check (valid-reference-p bound (read-weak weak-old))
                     "Live mature weak edge was not corrected")
              (set-root 0 nil)
              (let ((dead-target (allocate-kind :leaf leaf-kind)))
                (set-weak weak-old dead-target)
                (cycle :minor '((:objects-discovered . 0) (:objects-moved . 0)
                                (:bytes-moved . 0) (:objects-dead . 1)
                                (:weak-corrections . 1)
                                (:finalizers-enqueued . 0)))
                (check (eq :weak-cleared (read-weak weak-old))
                       "Dead mature weak edge was not cleared")))
            ;; A mature ephemeron with a rooted young key retains and promotes
            ;; its young value during minor fixed-point closure.
            (let ((ephemeron-young
                    (allocate-kind :ephemeron-holder ephemeron-kind)))
              (set-root 1 ephemeron-young)
              (cycle :minor '((:objects-discovered . 1) (:objects-moved . 1)
                              (:bytes-moved . 16) (:objects-dead . 0)
                              (:weak-corrections . 2)
                              (:finalizers-enqueued . 0)))
              (let* ((ephemeron-old (root 1))
                     (young-key (allocate-kind :leaf leaf-kind))
                     (young-value (allocate-kind :leaf leaf-kind)))
                (set-ephemeron ephemeron-old young-key young-value)
                (set-root 0 young-key)
                (cycle :minor '((:objects-discovered . 2)
                                (:objects-moved . 2) (:bytes-moved . 32)
                                (:objects-dead . 0) (:weak-corrections . 2)
                                (:finalizers-enqueued . 0)))
                (multiple-value-bind (key value)
                    (read-ephemeron ephemeron-old)
                  (check (and (valid-reference-p bound key)
                              (valid-reference-p bound value)
                              (stale-p bound young-key)
                              (stale-p bound young-value))
                         "Mature ephemeron did not close over young value"))))
            ;; Adversarially erase remembered state after a strong old-to-young
            ;; store.  The young referent must not be rescued by a hidden scan.
            (set-root 0 old-parent)
            (set-root 1 nil)
            (let ((unremembered (allocate-kind :leaf leaf-kind)))
              (set-child old-parent unremembered)
              (if (clamsara::%gen-card-active-p plan)
                  (fill (clamsara::%gen-card-marks plan) 0)
                  (setf (clamsara::%gen-remembered-dirty-p plan) nil))
              (cycle :minor '((:objects-discovered . 0) (:objects-moved . 0)
                              (:bytes-moved . 0) (:objects-dead . 1)
                              (:weak-corrections . 2)
                              (:finalizers-enqueued . 0)))
              (check (stale-p bound unremembered)
                     "Missing-dirty adversary was silently rescued")
              (set-child old-parent nil))))))
    (check (eq :unbound (unbind-mutator configuration context))
           "Generational mutator did not unbind")
    (run-generational-capacity-test)
    (format t "~&V14-GENERATIONAL-LIFECYCLE-OK~%")
    t))


(defun run-generational-capacity-test ()
  (let* ((q 16) (nursery-extent 64) (mature-extent 32) (base 16384)
         (roots (clamsara::make-simulator-root-client :provider-capacity 4))
         (provider (clamsara::make-simulator-root-provider 3))
         (token (register-root-provider roots :capacity-roots 3 provider))
         (coordinator (clamsara::make-simulator-coordinator
                       roots :stop-capacity 8 :await-bound 8))
         (address-space
           (clamsara::make-simulator-address-space
            :base base :byte-extent (+ (* 2 nursery-extent) mature-extent)
            :alignment q :page-size 16 :coordinator coordinator))
         (model (clamsara::make-host-object-model
                 :capacity 64 :kind-capacity 2 :slot-capacity 2
                 :variant-capacity 16 :location-capacity 4
                 :handle-capacity 16 :stage-capacity 2
                 :max-object-bytes 32))
         (kind (make-object-kind-description
                model :capacity-atom :size-rule 16 :alignment-rule q))
         (diagnostics (clamsara::make-simulator-diagnostics))
         (clients (clamsara::make-simulator-clients
                   :model model :roots roots :coordinator coordinator
                   :address-space address-space
                   :atomics (clamsara::make-host-atomics)
                   :diagnostics diagnostics))
         (domain-0 (clamsara::make-metadata-domain
                    :base base :limit (+ base nursery-extent) :granularity q))
         (domain-1 (clamsara::make-metadata-domain
                    :base (+ base nursery-extent)
                    :limit (+ base (* 2 nursery-extent)) :granularity q))
         (mature-base (+ base (* 2 nursery-extent)))
         (domain-m (clamsara::make-metadata-domain
                    :base mature-base :limit (+ mature-base mature-extent)
                    :granularity q))
         (from (clamsara::make-generational-nursery-space
                :name :capacity-from
                :object-start-map (clamsara::make-object-start-marks
                                   :domain domain-0)
                :forwarding (clamsara::make-side-forwarding :domain domain-0)
                :extent nursery-extent :packing-quantum q :role :allocation))
         (to (clamsara::make-generational-nursery-space
              :name :capacity-to
              :object-start-map (clamsara::make-object-start-marks
                                 :domain domain-1)
              :forwarding (clamsara::make-side-forwarding :domain domain-1)
              :extent nursery-extent :packing-quantum q :role :reserve))
         (mature (clamsara::make-generational-mature-space
                  :name :capacity-mature
                  :object-start-map (clamsara::make-object-start-marks
                                     :domain domain-m)
                  
                  :extent mature-extent :packing-quantum q
                  :descriptor-capacity 8))
         (registry (clamsara::make-sequential-finalizer-registry
                    :capacity 2 :root-client roots))
         (plan (clamsara::make-generational-plan
                :nursery-from from :nursery-to to :mature mature
                :root-client roots :coordinator coordinator
                :diagnostics diagnostics :registry registry
                :trace-capacity 10 :conditional-capacity 10
                :finalizer-capacity 2 :packing-quantum q))
         (configuration (construct-plan plan clients))
         (context (bind-mutator configuration :capacity-test :default))
         (bound (configuration-object-model configuration))
         (references (make-array 3 :initial-element nil)))
    (dotimes (index 3)
      (multiple-value-bind (reference status reason)
          (allocate-object context :capacity-atom 16 q kind)
        (check (eq status :allocated) "Capacity setup allocation failed: ~S" reason)
        (setf (aref references index) reference)
        (multiple-value-bind (effective root-status)
            (root-provider-store
             roots context token
             (clamsara::simulator-root-location provider index) reference)
          (declare (ignore effective))
          (check (eq root-status :stored) "Capacity root store failed"))))
    (let ((record (make-cycle-result-record plan)))
      (collect configuration :minor :explicit record)
      (check (and (eq :retained (cycle-result-status record))
                  (eq :preparing (cycle-result-phase record))
                  (eq :capacity-exhausted (cycle-result-reason record)))
             "Promotion capacity failure was not exact: ~S/~S/~S"
             (cycle-result-status record) (cycle-result-phase record)
             (cycle-result-reason record)))
    ;; Reservation failed before forwarding or source retirement.  The stop is
    ;; released and every original nursery representation remains usable.
    (dotimes (index 3)
      (check (valid-reference-p bound (aref references index))
             "Pre-effect capacity failure invalidated nursery reference ~D" index)
      (check (not (stale-p bound (aref references index)))
             "Pre-effect capacity failure retired nursery reference ~D" index))
    (check (and (eq :open (clamsara::%plan-state plan))
                (eq :released (clamsara::simulator-stop-state coordinator))
                (null (clamsara::%cycle-stop-token (clamsara::%plan-cycle plan))))
           "Pre-effect capacity failure retained the plan or stop: ~S/~S/~S"
           (clamsara::%plan-state plan)
           (clamsara::simulator-stop-state coordinator)
           (clamsara::simulator-current-stop coordinator))
    (check (eq :unbound (unbind-mutator configuration context))
           "Capacity-test mutator did not unbind")
    t))
