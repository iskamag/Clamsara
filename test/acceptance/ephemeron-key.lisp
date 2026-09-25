;;;; Independent acceptance regression: a live ephemeron key that moves must be
;;;; corrected even when the descriptor's key-clear boolean is NIL.  The
;;;; conditional commit previously stored a corrected key only when clearing was
;;;; enabled, leaving a live non-clearable key pointing at its retired source.
;;;;
;;;; Uses the real hosted object model, metadata, roots, coordinator,
;;;; construction, SemiSpace collector and finalizer registry. No stubs.

(defpackage #:clamsara.acceptance.ephemeron-key
  (:use #:cl #:clamsara)
  (:export #:run-ephemeron-key-acceptance))
(in-package #:clamsara.acceptance.ephemeron-key)

(defun check (value control &rest arguments)
  (unless value (apply #'error control arguments))
  value)

(defun make-ephemeron-world (clear-key-p)
  "One SemiSpace configuration whose ephemeron kind has CLEAR-KEY-P."
  (let* ((q 16) (extent 4096) (base 4096)
         (roots (clamsara::make-simulator-root-client :provider-capacity 8))
         (provider (clamsara::make-simulator-root-provider 8))
         (token (register-root-provider roots :ephemeron-key 8 provider))
         (coordinator
           (clamsara::make-simulator-coordinator
            roots :stop-capacity 64 :await-bound 16))
         (address-space
           (clamsara::make-simulator-address-space
            :base base :byte-extent (* 2 extent) :alignment q :page-size 256
            :coordinator coordinator))
         (model
           (clamsara::make-host-object-model
            :capacity 512 :kind-capacity 8 :slot-capacity 16
            :variant-capacity 0 :location-capacity 16
            :handle-capacity 128 :stage-capacity 8 :max-object-bytes 64))
         (leaf (make-object-kind-description
                model :leaf :size-rule 16 :alignment-rule q))
         (ephemeron
           (make-object-kind-description
            model :ephemeron :size-rule 16 :alignment-rule q
            :ephemeron-descriptions
            (list (make-ephemeron-description
                   model :edge clear-key-p :key-cleared :value-cleared))))
         (clients
           (clamsara::make-simulator-clients
            :model model :roots roots :coordinator coordinator
            :address-space address-space :atomics (clamsara::make-host-atomics)
            :diagnostics (clamsara::make-simulator-diagnostics)))
         (registry
           (clamsara::make-sequential-finalizer-registry
            :capacity 8 :root-client roots))
         (domain-0
           (clamsara::make-metadata-domain
            :base base :limit (+ base extent) :granularity q))
         (domain-1
           (clamsara::make-metadata-domain
            :base (+ base extent) :limit (+ base (* 2 extent)) :granularity q))
         (from
           (clamsara::make-semispace-space
            :name :ek-from :object-start-map
            (clamsara::make-object-start-marks :domain domain-0)
            :forwarding (clamsara::make-side-forwarding :domain domain-0)
            :extent extent :packing-quantum q :role :allocation))
         (to
           (clamsara::make-semispace-space
            :name :ek-to :object-start-map
            (clamsara::make-object-start-marks :domain domain-1)
            :forwarding (clamsara::make-side-forwarding :domain domain-1)
            :extent extent :packing-quantum q :role :reserve))
         (plan
           (clamsara::make-semispace-plan
            :from-space from :to-space to :root-client roots
            :coordinator coordinator
            :diagnostics (clamsara::make-simulator-diagnostics)
            :registry registry :trace-capacity 256 :conditional-capacity 128
            :finalizer-capacity 8 :packing-quantum q)))
    (let ((configuration (construct-plan plan clients)))
      (values configuration (bind-mutator configuration :ephemeron-key :default)
              plan provider roots token leaf ephemeron))))

(defun run-one-ephemeron-key-case (clear-key-p)
  (multiple-value-bind (configuration context plan provider roots token
                        leaf-kind ephemeron-kind)
      (make-ephemeron-world clear-key-p)
    (let ((model (configuration-object-model configuration))
          (barrier (configuration-barrier configuration)))
      (labels
          ((allocate (kind descriptor)
             (multiple-value-bind (reference status reason)
                 (allocate-object context kind 16 16 descriptor)
               (check (eq status :allocated)
                      "Allocation of ~S failed: ~S/~S" kind status reason)
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
           (set-root (index value)
             (multiple-value-bind (effective status)
                 (root-provider-store roots context token
                                      (clamsara::simulator-root-location
                                       provider index)
                                      value)
               (check (eq status :stored) "Root store ~D returned ~S" index status)
               effective))
           (root-value (index)
             (root-provider-load roots token
                                 (clamsara::simulator-root-location
                                  provider index)))
           (write-pair (holder key value)
             (let ((count 0))
               (map-ephemeron-descriptors
                model holder
                (lambda (identity key-location value-location
                         clear-key-p cleared-key cleared-value)
                  (declare (ignore identity clear-key-p cleared-key cleared-value))
                  (incf count)
                  (write-location key-location key)
                  (write-location value-location value)))
               (check (= count 1) "Expected one ephemeron descriptor, saw ~D" count)))
           (read-pair (holder)
             (let ((count 0) (key nil) (value nil))
               (map-ephemeron-descriptors
                model holder
                (lambda (identity key-location value-location
                         clear-key-p cleared-key cleared-value)
                  (declare (ignore identity clear-key-p cleared-key cleared-value))
                  (incf count)
                  (setf value (read-location value-location)
                        key (read-location key-location))))
               (check (= count 1) "Expected one ephemeron descriptor, saw ~D" count)
               (values key value))))
        (let ((key (allocate :leaf leaf-kind))
              (value (allocate :leaf leaf-kind))
              (holder (allocate :ephemeron ephemeron-kind)))
          (write-pair holder key value)
          ;; The holder and key are rooted; the key is therefore live.  The
          ;; value is reachable only through the ephemeron, so the pair is
          ;; active and the value must be retained.
          (set-root 0 holder)
          (set-root 1 key)
          (let ((record (make-cycle-result-record plan)))
            (collect configuration :all :explicit record)
            (check (eq :complete (cycle-result-status record))
                   "Cycle failed: ~S/~S" (cycle-result-status record)
                   (cycle-result-reason record)))
          (let ((current-key (root-value 1)))
            (multiple-value-bind (slot-key slot-value) (read-pair (root-value 0))
              ;; The live key moved to the destination space.  The stored key
              ;; slot must be corrected to the same object as the rooted key,
              ;; whether or not key clearing is enabled.
              (check (handler-case
                         (progn (normalize-reference model slot-key) t)
                       (error () nil))
                     "Live ephemeron key slot did not normalize to a live object")
              (check (reference-equal model slot-key current-key)
                     "Live ephemeron key slot was not corrected to the moved key")
              ;; The value is retained only through the ephemeron and also
              ;; moved, so its slot must likewise resolve to live storage.
              (check (handler-case
                         (progn (normalize-reference model slot-value) t)
                       (error () nil))
                     "Live ephemeron value slot did not normalize to a live object"))
            (set-root 0 nil)
            (set-root 1 nil)
            (let ((record (make-cycle-result-record plan)))
              (collect configuration :all :explicit record)
              (check (eq :complete (cycle-result-status record))
                     "Discharge cycle failed: ~S/~S"
                     (cycle-result-status record) (cycle-result-reason record)))))
        (check (eq :unbound (unbind-mutator configuration context))
               "Mutator did not unbind")
        (multiple-value-bind (status reason) (shutdown-configuration configuration)
          (check (and (eq status :complete) (null reason))
                 "Clean configuration did not shut down: ~S/~S" status reason))))))

(defun run-ephemeron-key-acceptance ()
  (run-one-ephemeron-key-case nil)
  (run-one-ephemeron-key-case t)
  (format t "~&EPHEMERON-KEY-ACCEPTANCE-PASS~%")
  t)
