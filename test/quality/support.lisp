;;;; Shared concrete quality fixture for stateful collector tests.
;;;; Load after ASDF system CLAMSARA.  This file does not install protocol stubs.
(defpackage #:clamsara.quality.support
  (:use #:cl #:clamsara)
  (:export
   #:check
   #:check-equal
   #:signals-runtime-reason
   #:make-quality-world
   #:with-quality-world
   #:close-quality-world
   #:quality-world
   #:world-algorithm
   #:world-object-starts
   #:world-packing-quantum
   #:world-configuration
   #:world-context
   #:world-model
   #:world-roots
   #:world-root-token
   #:world-root-provider
   #:world-coordinator
   #:world-plan
   #:world-registry
   #:world-node-kind
   #:world-space
   #:allocate-node
   #:try-allocate-node
   #:set-node-slot
   #:read-node-slot
   #:set-world-root
   #:read-world-root
   #:collect-world
   #:live-reference-p
   #:stale-reference-p
   #:snapshot-world-graph
   #:run-profile))
(in-package #:clamsara.quality.support)

(defun check (value control &rest arguments)
  (unless value (apply #'error control arguments))
  value)

(defun check-equal (expected actual &optional (label "values"))
  (check (equal expected actual) "~A differ: expected ~S, got ~S"
         label expected actual)
  actual)

(defun signals-runtime-reason (thunk expected)
  "Require THUNK to reject with the exact stable runtime reason EXPECTED."
  (let ((actual
          (handler-case
              (progn (funcall thunk) :no-condition)
            (clamsara::runtime-rejection (condition)
              (clamsara::runtime-rejection-reason condition)))))
    (check (eq expected actual)
           "Expected runtime rejection ~S, got ~S" expected actual)
    actual))

(defstruct (quality-world (:constructor %make-quality-world)
                          (:conc-name world-))
  algorithm
  object-starts
  packing-quantum
  configuration
  context
  model
  roots
  root-token
  root-provider
  coordinator
  plan
  registry
  node-kind
  space
  (root-count 0 :type fixnum)
  (closed-p nil))

(defun %object-start-map (object-starts domain)
  (ecase object-starts
    (:packed (make-object-start-marks :domain domain))
    (:scalar (make-scalar-object-start-marks :domain domain))))

(defun make-quality-world (&key
                             (algorithm :semispace)
                             (object-starts :packed)
                             (base 4096)
                             (extent 2048)
                             (packing-quantum 16)
                             (root-count 8)
                             (trace-capacity 128)
                             (conditional-capacity 128)
                             (finalizer-capacity 16)
                             (finalizer-registration-capacity
                               (max finalizer-capacity 64))
                             (stop-capacity 64)
                             (await-bound 32)
                             await-fail-after
                             (object-capacity 1024))
  "Construct a small real hosted collector world through the public builders.
ALGORITHM is :SEMISPACE or :MARKSWEEP.  OBJECT-STARTS is :PACKED or :SCALAR."
  (check (member algorithm '(:semispace :marksweep) :test #'eq)
         "Unknown quality algorithm ~S" algorithm)
  (check (member object-starts '(:packed :scalar) :test #'eq)
         "Unknown object-start representation ~S" object-starts)
  (let* ((roots (make-simulator-root-client :provider-capacity 16))
         (provider (make-simulator-root-provider root-count))
         (root-token (register-root-provider roots :quality-roots root-count
                                             provider))
         (coordinator
           (let ((value
                   (make-simulator-coordinator
                    roots :stop-capacity stop-capacity
                    :await-bound await-bound)))
             (when await-fail-after
               (setf (clamsara::simulator-await-fail-after value)
                     await-fail-after))
             value))
         (space-count (if (eq algorithm :semispace) 2 1))
         (address-space
           (make-simulator-address-space
            :base base :byte-extent (* space-count extent)
            :alignment packing-quantum :page-size 256
            :coordinator coordinator))
         (model
           (make-host-object-model
            :capacity object-capacity :kind-capacity 16 :slot-capacity 16
            :variant-capacity 256 :location-capacity 32
            :handle-capacity 256 :stage-capacity 16
            :max-object-bytes 256))
         ;; Slot zero is a managed immediate ID.  Slots one and two are the
         ;; actual managed graph edges.  The ID lets the host-side oracle name
         ;; objects without replacing their payload or edges with host data.
         (node-kind
           (make-object-kind-description
            model :quality-node :size-rule 32
            :alignment-rule packing-quantum
            :strong-layout '(:quality-id :left :right)))
         (atomics (make-host-atomics))
         (diagnostics (make-simulator-diagnostics))
         (clients
           (make-simulator-clients
            :model model :roots roots :coordinator coordinator
            :address-space address-space :atomics atomics
            :diagnostics diagnostics))
         (registry
           (make-sequential-finalizer-registry
            :capacity finalizer-capacity :root-client roots
            :registration-capacity finalizer-registration-capacity))
         (domain-0
           (make-metadata-domain
            :base base :limit (+ base extent) :granularity packing-quantum))
         (map-0 (%object-start-map object-starts domain-0))
         (space nil)
         (plan
           (ecase algorithm
             (:semispace
              (let* ((domain-1
                       (make-metadata-domain
                        :base (+ base extent) :limit (+ base (* 2 extent))
                        :granularity packing-quantum))
                     (from
                       (make-semispace-space
                        :name :quality-from :object-start-map map-0
                        :forwarding (make-side-forwarding :domain domain-0)
                        :extent extent :packing-quantum packing-quantum
                        :role :allocation))
                     (to
                       (make-semispace-space
                        :name :quality-to
                        :object-start-map
                        (%object-start-map object-starts domain-1)
                        :forwarding (make-side-forwarding :domain domain-1)
                        :extent extent :packing-quantum packing-quantum
                        :role :reserve)))
                (setf space from)
                (make-semispace-plan
                 :from-space from :to-space to :root-client roots
                 :coordinator coordinator :diagnostics diagnostics
                 :registry registry :trace-capacity trace-capacity
                 :conditional-capacity conditional-capacity
                 :finalizer-capacity finalizer-capacity
                 :packing-quantum packing-quantum)))
             (:marksweep
              (let ((marksweep
                      (make-marksweep-space
                       :name :quality-marksweep :object-start-map map-0
                       :marks (make-side-marks :domain domain-0)
                       :extent extent :packing-quantum packing-quantum
                       :descriptor-capacity object-capacity)))
                (setf space marksweep)
                (make-marksweep-plan
                 :space marksweep :root-client roots
                 :coordinator coordinator :diagnostics diagnostics
                 :registry registry :trace-capacity trace-capacity
                 :conditional-capacity conditional-capacity
                 :finalizer-capacity finalizer-capacity
                 :packing-quantum packing-quantum)))))
         (configuration (construct-plan plan clients))
         (context (bind-mutator configuration :quality-mutator :default)))
    (%make-quality-world
     :algorithm algorithm :object-starts object-starts
     :packing-quantum packing-quantum
     :configuration configuration :context context
     :model (configuration-object-model configuration)
     :roots roots :root-token root-token :root-provider provider
     :coordinator coordinator :plan plan :registry registry
     :node-kind node-kind :space space :root-count root-count)))

(defmacro with-quality-world ((variable &rest options) &body body)
  `(let ((,variable (make-quality-world ,@options)))
     (unwind-protect
          (progn ,@body)
       (unless (world-closed-p ,variable)
         ;; Normal fixtures must prove that their roots can be discharged and
         ;; their configuration can close.  Failure here is a test failure.
         (close-quality-world ,variable)))))

(defun %call-node-location (world object wanted function)
  (let ((index 0) (found nil) (values nil))
    (map-reference-locations
     (world-model world) object
     (lambda (identity location)
       (declare (ignore identity))
       (when (= index wanted)
         (setf found t values (multiple-value-list (funcall function location))))
       (incf index)))
    (check found "Managed node has no slot ~D" wanted)
    (values-list values)))

(defun set-node-slot (world object slot value)
  (%call-node-location
   world object slot
   (lambda (location)
     (multiple-value-bind (effective status)
         (barrier-store (configuration-barrier
                         (world-configuration world))
                        (world-context world) location value)
       (check (eq status :stored) "Barrier store returned ~S" status)
       effective))))

(defun read-node-slot (world object slot)
  (%call-node-location
   world object slot
   (lambda (location)
     (multiple-value-bind (value status)
         (barrier-read (configuration-barrier
                        (world-configuration world))
                       (world-context world) location)
       (check (eq status :complete) "Barrier read returned ~S" status)
       value))))

(defun try-allocate-node (world id)
  "Allocate one real managed node.  Return reference, status and reason."
  (multiple-value-bind (reference status reason)
      (allocate-object (world-context world) :quality-node 32
                       (world-packing-quantum world)
                       (world-node-kind world))
    (when (eq status :allocated)
      (set-node-slot world reference 0 id))
    (values reference status reason)))

(defun allocate-node (world id)
  (multiple-value-bind (reference status reason) (try-allocate-node world id)
    (check (eq status :allocated)
           "Allocation of quality node ~S failed: ~S/~S" id status reason)
    reference))

(defun %root-location (world index)
  (check (and (integerp index)
              (<= 0 index) (< index (world-root-count world)))
         "Invalid quality root index ~S" index)
  (simulator-root-location (world-root-provider world) index))

(defun set-world-root (world index value)
  (multiple-value-bind (effective status)
      (root-provider-store
       (world-roots world) (world-context world)
       (world-root-token world) (%root-location world index) value)
    (check (eq status :stored) "Root store ~D returned ~S" index status)
    effective))

(defun read-world-root (world index)
  (root-provider-load
   (world-roots world) (world-root-token world)
   (%root-location world index)))

(defun collect-world (world &key (scope :all) (cause :explicit) algorithm)
  (let ((record (make-cycle-result-record (world-plan world))))
    (if algorithm
        (collect (world-configuration world) scope cause record
                 :algorithm algorithm)
        (collect (world-configuration world) scope cause record))))

(defun live-reference-p (world reference)
  (handler-case
      (progn (normalize-reference (world-model world) reference) t)
    (error () nil)))

(defun stale-reference-p (world reference)
  (not (live-reference-p world reference)))

(defun snapshot-world-graph (world)
  "Read the graph from real roots/slots.
Return three values: (ROOT-IDS SORTED-NODES), an ID->reference alist, and all
visited references.  Each node row is (ID LEFT-ID RIGHT-ID)."
  (let ((root-ids (make-list (world-root-count world)
                             :initial-element nil))
        (queue '())
        (visited '())
        (id-references '())
        (rows '()))
    (labels ((reference-id (reference)
               (cond ((null reference) nil)
                     ((not (valid-reference-p (world-model world)
                                              reference))
                      (error "Expected a managed reference or NIL, got ~S"
                             reference))
                     (t
                      (normalize-reference (world-model world) reference)
                      (let ((id (read-node-slot world reference 0)))
                        (check (and (integerp id) (not (minusp id)))
                               "Managed node has invalid ID ~S" id)
                         id)))))
      (dotimes (index (world-root-count world))
        (let* ((reference (read-world-root world index))
               (id (reference-id reference)))
          (setf (nth index root-ids) id)
          (when reference (push reference queue))))
      (loop while queue
            for reference = (pop queue)
            for id = (reference-id reference)
            for previous = (assoc id id-references)
            if previous
              do (check (reference-equal (world-model world)
                                         (cdr previous) reference)
                        "Logical ID ~D names two managed objects" id)
            else
              do (let* ((left (read-node-slot world reference 1))
                        (right (read-node-slot world reference 2))
                        (left-id (reference-id left))
                        (right-id (reference-id right)))
                   (push (cons id reference) id-references)
                   (push reference visited)
                   (push (list id left-id right-id) rows)
                   (when left (push left queue))
                   (when right (push right queue))))
      (values (list root-ids (sort rows #'< :key #'first))
              (sort id-references #'< :key #'car)
               (nreverse visited)))))

(defun close-quality-world (world)
  "Discharge a normal fixture and close it.  Retained-stop worlds may reject."
  (unless (world-closed-p world)
    (dotimes (index (world-root-count world))
      (set-world-root world index nil))
    ;; Pending finalizers are roots until drained.
    (drain-pending-finalizers (world-registry world)
                              (world-context world))
    (let ((record (collect-world world)))
      (check (eq :complete (cycle-result-status record))
             "Cleanup collection failed: ~S/~S"
             (cycle-result-status record) (cycle-result-reason record)))
    (check (eq :unbound
               (unbind-mutator (world-configuration world)
                               (world-context world)))
           "Quality mutator did not unbind")
    (multiple-value-bind (status reason)
        (shutdown-configuration (world-configuration world))
      (check (and (eq status :complete) (null reason))
             "Quality configuration did not close: ~S/~S" status reason))
    (setf (world-closed-p world) t))
  t)

(defun run-profile (function &key
                                (algorithms '(:semispace :marksweep))
                                (object-starts '(:packed :scalar)))
  "Call FUNCTION once per bounded algorithm/object-start profile."
  (dolist (algorithm algorithms)
    (dolist (starts object-starts)
      (funcall function algorithm starts)))
  t)
