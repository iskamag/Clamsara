;;;; Executable v14 MarkSweep lifecycle integration.
(defpackage #:clamsara.runtime.marksweep.test
  (:use #:cl #:clamsara)
  (:export #:run-marksweep-runtime-tests))
(in-package #:clamsara.runtime.marksweep.test)

(defun %check (value format-control &rest arguments)
  (unless value (apply #'error format-control arguments))
  value)

(defun %stale-reference-p (model reference)
  ;; VALID-REFERENCE-P classifies encodings; it deliberately does not certify
  ;; that the encoded representation is still allocated.
  (handler-case
      (progn (normalize-reference model reference) nil)
    (error () t)))

(defun %check-cycle-counts (record expected)
  (dolist (entry expected)
    (multiple-value-bind (count known-p)
        (cycle-result-count record (car entry))
      (%check (and known-p (= count (cdr entry)))
              "Counter ~S expected ~D, got ~S/~S"
              (car entry) (cdr entry) count known-p)))
  (values))

(defun run-marksweep-runtime-tests ()
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
            :base base :byte-extent extent :alignment q :page-size 256
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
         (domain
           (clamsara::make-metadata-domain
            :base base :limit (+ base extent) :granularity q))
         (space
           (clamsara::make-marksweep-space
            :name :marksweep
            :object-start-map
            (clamsara::make-object-start-marks :domain domain)
            :marks (clamsara::make-side-marks :domain domain)
            :extent extent :packing-quantum q :descriptor-capacity 64))
         (registry (clamsara::make-sequential-finalizer-registry
                    :capacity 8 :root-client roots))
         (plan (clamsara::make-marksweep-plan
                :space space :root-client roots :coordinator coordinator
                :diagnostics diagnostics :registry registry
                :trace-capacity 64 :conditional-capacity 64
                :finalizer-capacity 8 :packing-quantum q))
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
        (let ((a-address (reference-address bound a))
              (dead-address (reference-address bound dead))
              (record (make-cycle-result-record plan)))
          (collect configuration :all :explicit record)
          (%check (eq :complete (cycle-result-status record))
                  "Cycle status/reason: ~S/~S"
                  (cycle-result-status record) (cycle-result-reason record))
          (%check-cycle-counts
           record '((:objects-discovered . 2) (:objects-moved . 0)
                    (:bytes-moved . 0) (:objects-dead . 1)
                    (:weak-corrections . 0) (:finalizers-enqueued . 0)))
          (%check (%stale-reference-p bound dead)
                  "Dead representation was not retired")
          (let* ((new-a
                   (root-provider-load
                    roots application-token
                    (clamsara::simulator-root-location
                     application-roots 0)))
                 (new-b (read-slot new-a 0)))
            (%check (= a-address (reference-address bound new-a))
                    "MarkSweep changed a live object address")
            (%check (reference-equal bound (read-slot new-b 0) new-a)
                    "Two-object cycle did not preserve sharing"))
          (let ((replacement (allocate-node)))
            (%check (= dead-address (reference-address bound replacement))
                    "Reclaimed hole was not reused first")
            (let ((second-record (make-cycle-result-record plan)))
              (collect configuration :all :explicit second-record)
              (%check (eq :complete (cycle-result-status second-record))
                      "Repeat cycle status/reason: ~S/~S"
                      (cycle-result-status second-record)
                      (cycle-result-reason second-record))
              (%check-cycle-counts
               second-record
               '((:objects-discovered . 2) (:objects-moved . 0)
                 (:bytes-moved . 0) (:objects-dead . 1)
                 (:weak-corrections . 0) (:finalizers-enqueued . 0)))
              (%check (%stale-reference-p bound replacement)
                      "Repeat cycle did not retire the replacement")
              (%check (= dead-address
                         (reference-address bound (allocate-node)))
                      "Repeat cycle did not make the same hole reusable"))))))
    (%check (eq :unbound (unbind-mutator configuration context))
            "Mutator did not unbind")
    (format t "~&V14-MARKSWEEP-LIFECYCLE-OK~%")
    t))
