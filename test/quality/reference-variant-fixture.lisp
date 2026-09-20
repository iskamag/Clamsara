;;;; Independent whole-code-row assertions, adapted from frozen 9dd8629 RED.
;;;; See docs/reference-variant-row-design.md for provenance and scope.
;;;; The original aggregate runner treated CL zero as false; use PLUSP here.

(defpackage #:clamsara.quality.reference-variants
  (:use #:cl #:clamsara #:clamsara.quality.support)
  (:export #:run-row-acceptance #:run-row-generational-acceptance))
(in-package #:clamsara.quality.reference-variants)

;; Standalone observers specialize only test-owned subclasses. They retain all
;; real primary methods and never replace a collector, model or resource effect.
(defclass row-clients (clamsara::simulator-clients) ())
(defclass row-offer (clamsara::host-object-model) ())
(defclass row-address-space (clamsara::simulator-address-space) ())
(defstruct observation construction layout (events nil) (acquisitions 0))
(defvar *observation* nil)
(defvar *case-worlds* nil)
(defvar *preserved-failures* nil)
(defvar *passed* 0)
(defvar *failed* 0)
(defvar *case-name* nil)
(defvar *results* nil)
(defun event (label &rest fields)
  (format t "~&ROW ~S ~S~%" label fields) (finish-output))
(defmethod clamsara::%acquire-construction-resource :after
    ((clients row-clients) construction description placement)
  (declare (ignore clients description placement))
  (when *observation*
    (setf (observation-construction *observation*) construction)
    (incf (observation-acquisitions *observation*))))
(defmethod bind-object-model :before ((offer row-offer) layout bindings)
  (declare (ignore offer bindings))
  (when *observation* (setf (observation-layout *observation*) layout)))
(defmethod clamsara::%release-acquired-construction-resource :before
    ((clients row-clients) (resource clamsara::%simulator-resource))
  (declare (ignore clients))
  (when *observation*
    (push (list :resource (clamsara::%simulator-resource-identity resource))
          (observation-events *observation*))))
(defmethod release-managed-layout :before ((client row-address-space) release)
  (declare (ignore client release))
  (when *observation*
    (push (list :layout :managed-layout) (observation-events *observation*))))

(defstruct (row-world (:include quality-world) (:constructor %make-row-world)
                      (:conc-name row-))
  maps bases granularities offer address-space)
(defun expected-cells (algorithm granularity &optional (reserve-granularity granularity))
  (+ (/ 512 granularity)
     (if (eq algorithm :semispace) (/ 512 reserve-granularity) 0)))
(defun make-row-world (&key (algorithm :semispace) (starts :packed)
                           (granularity 16) (reserve-granularity granularity)
                           (variant-capacity 64) model-capacity)
  (let* ((q 16) (base 4096) (extent 512)
         (cells (expected-cells algorithm granularity reserve-granularity))
         (offer (change-class
                 (make-host-object-model
                  :capacity (or model-capacity cells) :max-object-bytes 128
                  :variant-capacity variant-capacity :kind-capacity 8 :slot-capacity 8
                  :location-capacity 8 :handle-capacity 32 :stage-capacity 2
                  :max-interior-displacement 64 :tag-capacity 4)
                 'row-offer))
         (node (make-object-kind-description offer :quality-node :size-rule 32
                  :alignment-rule 16 :strong-layout '(:id :left :right)))
         (small (make-object-kind-description offer :row-small :size-rule 16 :alignment-rule 16))
         (large (make-object-kind-description offer :row-large :size-rule 64
                  :alignment-rule 16 :strong-layout '(:id :left :right)))
         (cell8 (make-object-kind-description offer :row-cell8 :size-rule 8 :alignment-rule 8))
         (cell16 (make-object-kind-description offer :row-cell16 :size-rule 16 :alignment-rule 16))
         (roots (make-simulator-root-client :provider-capacity 8))
         (provider (make-simulator-root-provider 4))
         (token (register-root-provider roots :row-roots 4 provider))
         (coordinator (make-simulator-coordinator roots :stop-capacity 32 :await-bound 16))
         (arena (change-class
                 (make-simulator-address-space :base base
                  :byte-extent (* extent (if (eq algorithm :semispace) 2 1))
                  :alignment q :page-size 256 :coordinator coordinator)
                 'row-address-space))
         (diagnostics (make-simulator-diagnostics))
         (clients (change-class
                   (make-simulator-clients :model offer :roots roots :coordinator coordinator
                    :address-space arena :atomics (make-host-atomics) :diagnostics diagnostics)
                   'row-clients))
         (registry (make-sequential-finalizer-registry :capacity 4 :root-client roots))
         (domain0 (make-metadata-domain :base base :limit (+ base extent) :granularity granularity))
         (control0 (make-metadata-domain :base base :limit (+ base extent) :granularity q))
         (map0 (ecase starts (:packed (make-object-start-marks :domain domain0))
                            (:scalar (make-scalar-object-start-marks :domain domain0))))
         (first-space
           (if (eq algorithm :semispace)
               (make-semispace-space :name :row-first :object-start-map map0
                 :forwarding (make-side-forwarding :domain control0)
                 :extent extent :packing-quantum q :role :allocation)
               (make-marksweep-space :name :row-first :object-start-map map0
                 :marks (make-side-marks :domain control0) :extent extent
                 :packing-quantum q :descriptor-capacity cells)))
         (map1 nil)
         (second-space
           (when (eq algorithm :semispace)
             (let* ((domain1 (make-metadata-domain :base (+ base extent)
                              :limit (+ base (* 2 extent)) :granularity reserve-granularity))
                    (control1 (make-metadata-domain :base (+ base extent)
                               :limit (+ base (* 2 extent)) :granularity q)))
               (setf map1 (ecase starts (:packed (make-object-start-marks :domain domain1))
                                       (:scalar (make-scalar-object-start-marks :domain domain1))))
               (make-semispace-space :name :row-second :object-start-map map1
                 :forwarding (make-side-forwarding :domain control1)
                 :extent extent :packing-quantum q :role :reserve))))
         (plan (if second-space
                   (make-semispace-plan :from-space first-space :to-space second-space
                     :root-client roots :coordinator coordinator :diagnostics diagnostics
                     :registry registry :trace-capacity 128 :conditional-capacity 32
                     :finalizer-capacity 4 :packing-quantum q)
                   (make-marksweep-plan :space first-space :root-client roots
                     :coordinator coordinator :diagnostics diagnostics :registry registry
                     :trace-capacity 128 :conditional-capacity 32
                     :finalizer-capacity 4 :packing-quantum q)))
         (configuration (construct-plan plan clients))
         (context (bind-mutator configuration :row-mutator :default))
         (world (%make-row-world
                  :algorithm algorithm :object-starts starts :packing-quantum q
                  :configuration configuration :context context :model (configuration-object-model configuration)
                  :roots roots :root-token token :root-provider provider :coordinator coordinator
                  :plan plan :registry registry :space first-space :root-count 4 :node-kind node
                  :maps (if map1 (list map0 map1) (list map0))
                  :bases (if map1 (list base (+ base extent)) (list base))
                  :granularities (if map1 (list granularity reserve-granularity) (list granularity))
                  :offer offer :address-space arena)))
    (declare (ignore small large cell8 cell16))
    (push world *case-worlds*)
    (check (= cells (length (clamsara::host-model-sizes (world-model world))))
           "Fixture C differs from installed descriptor cells")
    (check (>= (clamsara::host-model-capacity (world-model world)) cells)
           "Fixture representation offer does not cover C")
    (check (and (= variant-capacity (clamsara::host-model-variant-capacity (world-model world)))
                (= variant-capacity (length (clamsara::host-model-variants (world-model world)))))
           "Exact offered H was changed")
    world))

(defun assert-builder-released (observation)
  (let* ((construction (observation-construction observation))
         (layout (observation-layout observation)))
    (check (and construction layout (plusp (observation-acquisitions observation)))
           "Expected failure at real binding after resource/layout acquisition")
    (let* ((configuration (clamsara::construction-configuration construction))
           (log (clamsara::%context-transaction-log construction))
           (expected (mapcar (lambda (entry)
                               (list (clamsara::%transaction-entry-kind entry)
                                     (clamsara::%transaction-entry-identity entry))) log)))
      (check (and (eq :released (clamsara::%context-state construction))
                  (eq :failed (clamsara::%configuration-state configuration))
                  (not (clamsara::%configuration-object-model-bound-p configuration)))
             "Rejected binding published/retained construction state")
      (check (equal expected (reverse (observation-events observation)))
             "Release missing, repeated, or not reverse acquisition order")
      (check (every #'clamsara::%transaction-entry-released-p log) "Transaction entry not released")
      (maphash (lambda (identity state)
                 (declare (ignore identity))
                 (check (and (clamsara::%resource-state-released-p state)
                             (clamsara::%simulator-resource-released-p
                              (clamsara::%resource-state-release-capability state)))
                        "Acquired resource/release capability remains live"))
               (clamsara::%context-resources construction))
      (check (and (not (clamsara::%simulator-layout-active-p layout))
                  (null (clamsara::%simulator-active-layout
                         (clamsara::%simulator-layout-client layout))))
             "Rejected binding left real layout installed")
      (event :builder-released :acquired (observation-acquisitions observation)
             :released (length log)))))

;; Read-only existing hosted diagnostics. No code->row directory assumptions.
;; Snapshot the actual arena/word/descriptor planes and every record's scalar
;; fields so changes cannot hide behind EQ identity of mutable Lisp structures.
(defun reference-fields (reference)
  (list (clamsara::host-reference-descriptor reference)
        (clamsara::host-reference-address reference)
        (clamsara::host-reference-kind reference)
        (clamsara::host-reference-tag reference)
        (clamsara::host-reference-displacement reference)))
(defun model-state (model)
  (list (copy-seq (clamsara::host-model-arena model))
        (copy-seq (clamsara::host-model-words model))
        (copy-seq (clamsara::host-model-sizes model))
        (copy-seq (clamsara::host-model-alignments model))
        (copy-seq (clamsara::host-model-descriptor-kinds model))
        (copy-seq (clamsara::host-model-descriptor-generations model))
        (copy-seq (clamsara::host-model-descriptor-counts model))
        (clamsara::host-model-live-count model)
        (clamsara::host-model-variant-count model)
        (map 'list #'reference-fields (clamsara::host-model-base-references model))
        (map 'list #'reference-fields (clamsara::host-model-variants model))))
(defun require-rebuild-rejection (model base code)
  (let ((before (model-state model)) (caught nil) (answer nil))
    ;; Assertions are outside HANDLER-CASE: an assertion is not a valid
    ;; implementation rejection. The returned unwanted value is never rooted.
    (handler-case (setf answer (rebuild-reference model base code))
      (error (condition) (setf caught condition)))
    (check caught "New code ~X was admitted without a whole unused row (returned ~S)" code answer)
    (check (equalp before (model-state model))
           "Rejected new code changed bytes, words, descriptor planes, counts or record fields")
    (event :atomic-code-rejection :code code :condition (princ-to-string caught))))
(defun assert-reference (model reference expected-base canonical-code)
  (check (valid-reference-p model reference) "Returned reference is not admitted")
  (multiple-value-bind (base code) (normalize-reference model reference)
    (check (and (eq base expected-base) (= code canonical-code)
                (reference-encoding-equal-p model reference (rebuild-reference model base code)))
           "Reference lost canonical base/code/exact roundtrip"))
  reference)
(defun graph (world &optional (code 0))
  (let* ((model (world-model world)) (parent (allocate-node world 501))
         (child (allocate-node world 502)))
    (set-node-slot world parent 1 child)
    (clamsara::host-object-payload-write model parent 24 #xA7)
    (clamsara::host-object-payload-write model child 24 #xB3)
    (let ((reference (rebuild-reference model parent code)))
      (assert-reference model reference parent code)
      (set-world-root world 0 reference)
      (values parent child reference))))
(defun verify-graph (world code &optional (root-index 0) child-code)
  (let* ((model (world-model world)) (reference (read-world-root world root-index)))
    (multiple-value-bind (base actual-code) (normalize-reference model reference)
      (check (= code actual-code) "Root lost tag/interior displacement")
      (assert-reference model reference base code)
      (check (and (= 501 (read-node-slot world base 0))
                  (= #xA7 (clamsara::host-object-payload-read model base 24)))
             "Parent ID or raw byte changed")
      (multiple-value-bind (child actual-child-code)
          (normalize-reference model (read-node-slot world base 1))
        (check (and (= 502 (read-node-slot world child 0))
                    (= #xB3 (clamsara::host-object-payload-read model child 24)))
               "Child edge, ID or raw byte changed")
        (when child-code (check (= child-code actual-child-code) "Child form changed")))
      (reference-address model base))))
(defun complete-cycles (world code &optional (count 3))
  (let ((old-base (verify-graph world code)))
    (dotimes (round count)
      (let ((record (collect-world world)))
        (event :cycle :case *case-name* :round round
               :status (cycle-result-status record) :reason (cycle-result-reason record)
               :phase (cycle-result-phase record)
               :moved (cycle-result-count record :objects-moved)
               :discovered (cycle-result-count record :objects-discovered))
        ;; Do not use protected mutator reads when a real collection retained.
        (check (eq :complete (cycle-result-status record)) "Admitted-code collection did not complete")
        (check (= 2 (cycle-result-count record :objects-discovered)) "Collector lost real graph")
        (let ((new-base (verify-graph world code)))
          (check (if (eq :semispace (world-algorithm world)) (/= old-base new-base) (= old-base new-base))
                 "Wrong moving/nonmoving address history")
          (setf old-base new-base))))))
(defun close-successful-world (world)
  (close-quality-world world)
  (check (clamsara.quality.support::world-closed-p world) "Successful world did not close"))
