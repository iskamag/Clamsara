(in-package #:whole-code-row-acceptance)
(defstruct (generation-world
             (:include quality-world)
             (:constructor %make-generation-world)
             (:conc-name generation-))
  mature-base mature-limit leaf-kind weak-kind ephemeron-kind)

(defun make-row-generation-world (&key (object-starts :packed)
                                  (nursery-extent 512) (mature-extent 2048)
                                  (root-count 8))
  (let* ((base 4096) (quantum 16)
         (total (+ (* 2 nursery-extent) mature-extent))
         (capacity (/ total quantum))
         (roots (make-simulator-root-client :provider-capacity 8))
         (provider (make-simulator-root-provider root-count))
         (token (register-root-provider roots :generation-quality root-count provider))
         (coordinator (make-simulator-coordinator roots :stop-capacity 128 :await-bound 16))
         (address-space (make-simulator-address-space
                         :base base :byte-extent total :alignment quantum
                         :page-size 16 :coordinator coordinator))
         (model (make-host-object-model
                 :capacity capacity :kind-capacity 8 :slot-capacity 16
                 :variant-capacity capacity :location-capacity 16
                 :handle-capacity 128 :stage-capacity 4 :max-object-bytes 32))
         (node (make-object-kind-description
                model :quality-node :size-rule 32 :alignment-rule quantum
                :strong-layout '(:quality-id :left :right)))
         ;; No post-allocation store: allocating a leaf cannot accidentally
         ;; dirty a remembered card and mask a missing old-to-young barrier.
         (leaf (make-object-kind-description model :generation-leaf
                :size-rule 32 :alignment-rule quantum))
         (weak (make-object-kind-description
                model :generation-weak :size-rule 32 :alignment-rule quantum
                :weak-descriptions
                (list (make-weak-location-description
                       model '(:identity :weak :offset 0) :generation-leaf :weak-cleared))))
         (ephemeron (make-object-kind-description
                     model :generation-ephemeron :size-rule 32 :alignment-rule quantum
                     :ephemeron-descriptions
                     (list (make-ephemeron-description model :ephemeron t
                                                       :key-cleared :value-cleared))))
         (diagnostics (make-simulator-diagnostics))
         (clients (make-simulator-clients
                   :model model :roots roots :coordinator coordinator
                   :address-space address-space :atomics (make-host-atomics)
                   :diagnostics diagnostics))
         (registry (make-sequential-finalizer-registry :capacity 8 :root-client roots))
         (mature-base (+ base (* 2 nursery-extent)))
         (domain-0 (make-metadata-domain :base base :limit (+ base nursery-extent)
                                        :granularity quantum))
         (domain-1 (make-metadata-domain :base (+ base nursery-extent)
                                        :limit mature-base :granularity quantum))
         (domain-m (make-metadata-domain :base mature-base :limit (+ base total)
                                        :granularity quantum)))
    (flet ((starts (domain)
             (ecase object-starts
               (:packed (make-object-start-marks :domain domain))
               (:scalar (make-scalar-object-start-marks :domain domain)))))
      (let* ((from (clamsara::make-generational-nursery-space
                    :name :quality-nursery-from :object-start-map (starts domain-0)
                    :forwarding (make-side-forwarding :domain domain-0)
                    :extent nursery-extent :packing-quantum quantum :role :allocation))
             (to (clamsara::make-generational-nursery-space
                  :name :quality-nursery-to :object-start-map (starts domain-1)
                  :forwarding (make-side-forwarding :domain domain-1)
                  :extent nursery-extent :packing-quantum quantum :role :reserve))
             (mature (clamsara::make-generational-mature-space
                      :name :quality-mature :object-start-map (starts domain-m)
                      :marks (make-side-marks :domain domain-m)
                      :extent mature-extent :packing-quantum quantum
                      :descriptor-capacity (1+ capacity)))
             (plan (clamsara::make-generational-plan
                    :nursery-from from :nursery-to to :mature mature
                    :root-client roots :coordinator coordinator :diagnostics diagnostics
                    :registry registry :trace-capacity capacity :conditional-capacity capacity
                    :finalizer-capacity 8 :packing-quantum quantum))
             (configuration (construct-plan plan clients))
             (context (bind-mutator configuration :generation-quality :default)))
        (%make-generation-world
         :algorithm :generational :object-starts object-starts :packing-quantum quantum
         :configuration configuration :context context
         :model (configuration-object-model configuration)
         :roots roots :root-token token :root-provider provider :root-count root-count
         :coordinator coordinator :plan plan :registry registry :node-kind node :space from
         :mature-base mature-base :mature-limit (+ base total)
         :leaf-kind leaf :weak-kind weak :ephemeron-kind ephemeron)))))


(defun generation-case (starts code)
  (let* ((world (make-row-generation-world :object-starts starts))
         (model (world-model world)))
    (push world *case-worlds*)
    (check (= (clamsara::host-model-variant-capacity model)
              (length (clamsara::host-model-sizes model))) "Promotion fixture did not offer exactly C")
    (multiple-value-bind (parent child original) (graph world code)
      (declare (ignore original))
      (set-node-slot world parent 1 (rebuild-reference model child code)))
    (loop for scope in '(:minor :minor :all)
          for expected-moved in '(2 0 0) do
      (let ((record (collect-world world :scope scope)))
        (event :promotion :scope scope :status (cycle-result-status record)
               :reason (cycle-result-reason record) :moved (cycle-result-count record :objects-moved)
               :discovered (cycle-result-count record :objects-discovered))
        (check (eq :complete (cycle-result-status record)) "Admitted form failed promotion/major")
        (check (= expected-moved (cycle-result-count record :objects-moved))
               "Wrong nursery-promotion/mature address history")
        ;; A minor does not rediscover every old object. Verify the actual
        ;; rooted graph below, rather than pretending its scoped count is 2.
        (let ((address (verify-graph world code 0 code)))
          (check (<= (generation-mature-base world) address
                     (1- (generation-mature-limit world)))
                 "Root did not move into the mature domain"))))
    (close-successful-world world)))
