;;;; Independent tests of the optional generational collector.
;;;; Host tables are oracles only; roots, payloads and mutations are managed.
(defpackage #:clamsara.quality.generational
  (:use #:cl #:clamsara #:clamsara.quality.support)
  (:import-from #:clamsara
                #:make-generational-nursery-space
                #:make-generational-mature-space
                #:make-generational-plan)
  (:export #:run-generational-quality-tests #:run-generational-history-tests
           #:run-generational-quality-tests-with-cards
           #:run-minor-capacity-allocation-recovery))
(in-package #:clamsara.quality.generational)

(defstruct (generation-world
             (:include quality-world)
             (:constructor %make-generation-world)
             (:conc-name generation-))
  mature-base mature-limit leaf-kind weak-kind ephemeron-kind card-granularity)

(defun make-generation-world (&key (object-starts :packed)
                                  (nursery-extent 512) (mature-extent 2048)
                                  (root-count 8) card-granularity
                                  movement-participants)
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
                 :variant-capacity 0 :location-capacity 16
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
      (let* ((from (make-generational-nursery-space
                    :name :quality-nursery-from :object-start-map (starts domain-0)
                    :forwarding (make-side-forwarding :domain domain-0)
                    :extent nursery-extent :packing-quantum quantum :role :allocation))
             (to (make-generational-nursery-space
                  :name :quality-nursery-to :object-start-map (starts domain-1)
                  :forwarding (make-side-forwarding :domain domain-1)
                  :extent nursery-extent :packing-quantum quantum :role :reserve))
             (mature (make-generational-mature-space
                      :name :quality-mature :object-start-map (starts domain-m)
                      
                      :extent mature-extent :packing-quantum quantum
                      :descriptor-capacity (1+ capacity)))
             (plan (make-generational-plan
                    :nursery-from from :nursery-to to :mature mature
                    :root-client roots :coordinator coordinator :diagnostics diagnostics
                    :registry registry :trace-capacity capacity :conditional-capacity capacity
                    :finalizer-capacity 8 :packing-quantum quantum
                    :card-granularity card-granularity
                    :movement-participants movement-participants))
             (configuration (construct-plan plan clients))
             (context (bind-mutator configuration :generation-quality :default)))
        (%make-generation-world
         :algorithm :generational :object-starts object-starts :packing-quantum quantum
         :configuration configuration :context context
         :model (configuration-object-model configuration)
         :roots roots :root-token token :root-provider provider :root-count root-count
         :coordinator coordinator :plan plan :registry registry :node-kind node :space from
         :mature-base mature-base :mature-limit (+ base total)
         :leaf-kind leaf :weak-kind weak :ephemeron-kind ephemeron
         :card-granularity card-granularity)))))

(defun allocate-kind (world name descriptor)
  (multiple-value-bind (reference status reason)
      (allocate-object (world-context world) name 32 16 descriptor)
    (check (eq status :allocated) "Allocation failed: ~S/~S" status reason)
    reference))

(defun allocate-leaf (world)
  (allocate-kind world :generation-leaf (generation-leaf-kind world)))

(defun mature-p (world reference)
  (let ((address (reference-address (world-model world) reference)))
    (<= (generation-mature-base world) address
        (1- (generation-mature-limit world)))))

(defun complete-cycle (world scope)
  (let ((record (collect-world world :scope scope)))
    (check (eq :complete (cycle-result-status record))
           "~S cycle failed: ~S/~S/~S" scope (cycle-result-status record)
           (cycle-result-phase record) (cycle-result-reason record))
    record))

(defun count-is (record name expected)
  (multiple-value-bind (value known) (cycle-result-count record name)
    (check (and known (= value expected)) "~S expected ~D, got ~S/~S"
           name expected value known)))

(defun run-capacity-recovery (starts)
  ;; Mature can hold one node. A full major must still reclaim an unrooted
  ;; old node while a young node is live, rather than require old free space
  ;; before it can discover that the old node is dead.
  (let* ((world (make-generation-world :object-starts starts
                                       :nursery-extent 64 :mature-extent 32))
         (old (allocate-leaf world)))
    (set-world-root world 0 old)
    (complete-cycle world :minor)
    (setf old (read-world-root world 0))
    (check (mature-p world old) "Initial leaf was not promoted")
    (let ((young (allocate-leaf world)))
      (set-world-root world 1 young)
      (let ((record (collect-world world :scope :minor)))
        (check (and (eq :retained (cycle-result-status record))
                    (eq :preparing (cycle-result-phase record))
                    (eq :capacity-exhausted (cycle-result-reason record)))
               "Minor capacity rejection changed: ~S/~S/~S"
               (cycle-result-status record) (cycle-result-phase record)
               (cycle-result-reason record)))
      (check (and (live-reference-p world old) (live-reference-p world young))
             "Rejected minor changed existing references")
      (set-world-root world 0 nil)
      (let ((record (complete-cycle world :all)))
        (count-is record :objects-discovered 1)
        (count-is record :objects-moved 1)
        (count-is record :objects-dead 1))
      (check (stale-reference-p world old) "Major did not reclaim dead mature leaf")
      (check (stale-reference-p world young) "Major did not retire nursery source")
      (check (live-reference-p world (read-world-root world 1))
             "Major lost the live young leaf")
      (complete-cycle world :minor)
      (check (mature-p world (read-world-root world 1))
             "Minor did not recover after mature reclamation"))
    (close-quality-world world)))


(defun same-reference (world left right)
  (check (reference-equal (world-model world) left right)
         "Reference identity/sharing changed"))

(defun compare-child (world parent expected new)
  (clamsara.quality.support::%call-node-location
   world parent 1
   (lambda (location)
     (multiple-value-bind (observed changed status)
         (barrier-compare-exchange (configuration-barrier (world-configuration world))
                                   (world-context world) location expected new)
       (check (eq status :complete) "CAS returned ~S" status)
       (values observed changed)))))

(defun run-remembered-edges (starts operation &optional card-granularity)
  (let* ((world (make-generation-world :object-starts starts
                                       :card-granularity card-granularity))
         (parent (allocate-node world 10)))
    (set-world-root world 0 parent)
    (set-world-root world 1 parent)
    (complete-cycle world :minor)
    (check (stale-reference-p world parent) "Promotion did not retire source")
    (setf parent (read-world-root world 0))
    (same-reference world parent (read-world-root world 1))
    (let ((address (reference-address (world-model world) parent))
          (young (allocate-leaf world))
          (unreachable (allocate-leaf world)))
      ;; Leaf initialization performs no stores. Only this tested operation
      ;; can make the mature source remember its new nursery target.
      (ecase operation
        (:store (set-node-slot world parent 1 young))
        (:cas
         (multiple-value-bind (observed changed)
             (compare-child world parent unreachable young)
           (check (and (null observed) (null changed)
                       (null (read-node-slot world parent 1)))
                  "Failed CAS wrote or returned the wrong word"))
         (multiple-value-bind (observed changed)
             (compare-child world parent nil young)
           (check (and (null observed) changed) "Successful CAS failed"))))
      (let ((record (complete-cycle world :minor)))
        (count-is record :objects-moved 1)
        (count-is record :objects-dead 1))
      (check (and (stale-reference-p world young)
                  (stale-reference-p world unreachable))
             "Nursery retirement failed")
      (let ((child (read-node-slot world parent 1)))
        (check (and (live-reference-p world child) (mature-p world child))
               "Old-to-young target was not promoted")
        (check (= address (reference-address (world-model world) parent))
               "Minor moved the mature parent")
        ;; Insert and then delete another young edge. A conservative card must
        ;; not turn the removed value into a strong root of its own.
        (let ((removed (allocate-leaf world)))
          (set-node-slot world parent 1 removed)
          (set-node-slot world parent 1 nil)
          (let ((record (complete-cycle world :minor)))
            (count-is record :objects-moved 0)
            (count-is record :objects-dead 1))
          (check (stale-reference-p world removed) "Deleted young edge retained its target")
          (check (live-reference-p world child) "Minor reclaimed unreachable mature child"))
        ;; A major now leaves a surviving nursery target in nursery to-space.
        ;; The immediately following minor must find it from this old edge,
        ;; without an intervening store that could repair lost remembered state.
        (let ((next (allocate-leaf world)))
          (set-node-slot world parent 1 next)
          (let ((record (complete-cycle world :all)))
            (count-is record :objects-moved 1)
            (count-is record :objects-dead 1))
          (check (stale-reference-p world child) "Major did not reclaim old garbage")
          (check (stale-reference-p world next) "Major did not retire young source")
          (let ((after-major (read-node-slot world parent 1)))
            (check (and (live-reference-p world after-major)
                        (not (mature-p world after-major)))
                   "Major did not retain young survivor in the nursery")
            (count-is (complete-cycle world :minor) :objects-moved 1)
            (check (stale-reference-p world after-major) "Next minor did not retire source")
            (check (mature-p world (read-node-slot world parent 1))
                   "Major lost the remembered edge needed by the next minor")))
        (check (= address (reference-address (world-model world) parent))
               "Major/minor changed the mature address")
        (same-reference world parent (read-world-root world 0))
        (same-reference world parent (read-world-root world 1))))
    (close-quality-world world)))

(defun location-read (world location)
  (multiple-value-bind (value status)
      (barrier-read (configuration-barrier (world-configuration world))
                    (world-context world) location)
    (check (eq status :complete) "Conditional read failed: ~S" status)
    value))

(defun location-write (world location value)
  (multiple-value-bind (effective status)
      (barrier-store (configuration-barrier (world-configuration world))
                     (world-context world) location value)
    (check (eq status :stored) "Conditional write failed: ~S" status)
    effective))

(defun weak-value (world holder)
  (let ((count 0) (answer nil))
    (map-weak-descriptors (world-model world) holder
                         (lambda (identity location cleared)
                           (declare (ignore identity cleared))
                           (incf count) (setf answer (location-read world location))))
    (check (= count 1) "Expected one weak descriptor")
    answer))

(defun set-weak-value (world holder value)
  (let ((count 0))
    (map-weak-descriptors (world-model world) holder
                         (lambda (identity location cleared)
                           (declare (ignore identity cleared))
                           (incf count) (location-write world location value)))
    (check (= count 1) "Expected one weak descriptor")))

(defun ephemeron-values (world holder)
  (let ((count 0) (key nil) (value nil))
    (map-ephemeron-descriptors
     (world-model world) holder
     (lambda (identity key-location value-location clear-key-p cleared-key cleared-value)
       (declare (ignore identity clear-key-p cleared-key cleared-value))
       (incf count)
       (setf key (location-read world key-location)
             value (location-read world value-location))))
    (check (= count 1) "Expected one ephemeron descriptor")
    (values key value)))

(defun set-ephemeron-values (world holder key value)
  (let ((count 0))
    (map-ephemeron-descriptors
     (world-model world) holder
     (lambda (identity key-location value-location clear-key-p cleared-key cleared-value)
       (declare (ignore identity clear-key-p cleared-key cleared-value))
       (incf count)
       (location-write world key-location key)
       (location-write world value-location value)))
    (check (= count 1) "Expected one ephemeron descriptor")))

(defun prepare-aged-values (world descriptions)
  "Each description is (AGE KIND DESCRIPTOR). Return actual corrected handles.
Only requested old objects are allocated before the setup minor."
  (loop for (age name descriptor) in descriptions for index from 0
        when (eq age :old)
          do (set-world-root world index (allocate-kind world name descriptor)))
  (when (find :old descriptions :key #'first)
    (complete-cycle world :minor))
  (loop for (age name descriptor) in descriptions for index from 0
        collect (if (eq age :old)
                    (read-world-root world index)
                    (let ((new (allocate-kind world name descriptor)))
                      (set-world-root world index new)
                      new))))

(defun check-conditional-fate (world original age survives scope corrected)
  (if survives
      (progn
        (check (live-reference-p world corrected) "Conditional survivor is not live")
        (if (eq age :old)
            (same-reference world original corrected)
            (progn
              (check (stale-reference-p world original) "Young source was not retired")
              (check (eq (not (null (mature-p world corrected))) (eq scope :minor))
                     "Conditional survivor landed in the wrong generation"))))
      (check (stale-reference-p world original) "Dead conditional target still normalizes")))

(defun run-weak-case (starts holder-age target-age rooted scope)
  (let* ((world (make-generation-world :object-starts starts))
         (values (prepare-aged-values
                  world (list (list holder-age :generation-weak (generation-weak-kind world))
                              (list target-age :generation-leaf (generation-leaf-kind world)))))
         (holder (first values)) (target (second values))
         (survives (or rooted (and (eq scope :minor) (eq target-age :old)))))
    (unless rooted (set-world-root world 1 nil))
    (set-weak-value world holder target)
    (complete-cycle world scope)
    (setf holder (read-world-root world 0))
    (let ((corrected (weak-value world holder)))
      (if survives
          (progn
            (check-conditional-fate world target target-age t scope corrected)
            (when rooted (same-reference world corrected (read-world-root world 1))))
          (progn
            (check (eq corrected :weak-cleared) "Weak target was not cleared")
            (check-conditional-fate world target target-age nil scope nil))))
    (close-quality-world world)))

(defun run-ephemeron-case (starts holder-age key-age value-age rooted scope)
  (let* ((world (make-generation-world :object-starts starts))
         (values (prepare-aged-values
                  world (list (list holder-age :generation-ephemeron
                                    (generation-ephemeron-kind world))
                              (list key-age :generation-leaf (generation-leaf-kind world))
                              (list value-age :generation-leaf (generation-leaf-kind world)))))
         (holder (first values)) (key (second values)) (value (third values))
         (key-live (or rooted (and (eq scope :minor) (eq key-age :old))))
         (value-live (or key-live (and (eq scope :minor) (eq value-age :old)))))
    (unless rooted (set-world-root world 1 nil))
    (set-world-root world 2 nil)
    (set-ephemeron-values world holder key value)
    (complete-cycle world scope)
    (multiple-value-bind (corrected-key corrected-value)
        (ephemeron-values world (read-world-root world 0))
      (if key-live
          (progn
            (check-conditional-fate world key key-age t scope corrected-key)
            (check-conditional-fate world value value-age t scope corrected-value)
            (when rooted (same-reference world corrected-key (read-world-root world 1))))
          (progn
            (check (and (eq corrected-key :key-cleared)
                        (eq corrected-value :value-cleared))
                   "Dead key did not clear both ephemeron fields")
            (check-conditional-fate world key key-age nil scope nil)
            ;; An unreachable mature value remains allocated in a minor even
            ;; when its ephemeron field clears. That is not a strong fallback.
            (if value-live
                (check (live-reference-p world value) "Minor reclaimed mature value")
                (check-conditional-fate world value value-age nil scope nil)))))
    (close-quality-world world)))

(defun run-conditional-matrix (starts)
  (let ((weak-cases 0) (ephemeron-cases 0))
    (dolist (holder-age '(:young :old))
      (dolist (key-age '(:young :old))
        (dolist (rooted '(nil t))
          (dolist (scope '(:minor :all))
            (run-weak-case starts holder-age key-age rooted scope)
            (incf weak-cases)
            (dolist (value-age '(:young :old))
              (run-ephemeron-case starts holder-age key-age value-age rooted scope)
              (incf ephemeron-cases))))))
    (check (= weak-cases 16) "Weak matrix was not complete")
    (check (= ephemeron-cases 32) "Ephemeron matrix was not complete")
    (format t "~&GENERATIONAL-CONDITIONAL ~S weak=~D ephemeron=~D~%"
            starts weak-cases ephemeron-cases)))

(defun run-reversed-ephemeron-chain (starts)
  (let* ((world (make-generation-world :object-starts starts))
         (holders (prepare-aged-values
                   world (loop repeat 2 collect
                               (list :old :generation-ephemeron
                                     (generation-ephemeron-kind world)))))
         (first (first holders)) (second (second holders))
         (key (allocate-leaf world)) (middle (allocate-leaf world))
         (value (allocate-leaf world)))
    ;; Physical mature enumeration visits FIRST before SECOND. FIRST can only
    ;; activate after SECOND has made MIDDLE live, requiring fixed-point work.
    (check (< (reference-address (world-model world) first)
              (reference-address (world-model world) second))
           "Ephemeron chain is not reverse-ordered")
    (set-ephemeron-values world first middle value)
    (set-ephemeron-values world second key middle)
    (set-world-root world 2 key)
    (count-is (complete-cycle world :minor) :objects-moved 3)
    (check (every (lambda (old) (stale-reference-p world old)) (list key middle value))
           "Fixed-point sources were not retired")
    (multiple-value-bind (new-middle new-value) (ephemeron-values world first)
      (multiple-value-bind (new-key same-middle) (ephemeron-values world second)
        (same-reference world new-key (read-world-root world 2))
        (same-reference world new-middle same-middle)
        (check (every (lambda (reference) (mature-p world reference))
                      (list new-key new-middle new-value))
               "Ephemeron chain did not promote its closure")
        (set-world-root world 2 nil)
        (count-is (complete-cycle world :minor) :objects-dead 0)
        (let ((record (complete-cycle world :all)))
          (count-is record :objects-discovered 2)
          (count-is record :objects-dead 3))
        (check (every (lambda (reference) (stale-reference-p world reference))
                      (list new-key new-middle new-value))
               "Major retained the unrooted ephemeron chain")))
    (dolist (holder holders)
      (multiple-value-bind (key value) (ephemeron-values world holder)
        (check (and (eq key :key-cleared) (eq value :value-cleared))
               "Dead chain fields were not cleared")))
    (close-quality-world world)))

(defun run-generational-quality-tests ()
  (dolist (starts '(:packed :scalar))
    (run-capacity-recovery starts)
    (dolist (operation '(:store :cas)) (run-remembered-edges starts operation))
    (run-conditional-matrix starts)
    (run-reversed-ephemeron-chain starts))
  (format t "~&QUALITY-GENERATIONAL-PASS~%")
  t)

;;; Card-indexed remembered set: the same complete history run with exact card
;;; coverage instead of the conservative whole-mature fallback.  This drives
;;; store/CAS, deletion, major-then-minor, and address stability through the
;;; card rule, so a card bug cannot hide behind the fallback scan.
(defun check-card-mode (starts card-granularity)
  (let ((world (make-generation-world :object-starts starts
                                      :card-granularity card-granularity)))
    (unwind-protect
         (check (clamsara::%gen-card-active-p (world-plan world))
                "Card mode did not activate")
      (close-quality-world world))))

(defun run-card-remembered-edges ()
  (dolist (starts '(:packed :scalar))
    (dolist (operation '(:store :cas))
      ;; Two card widths: one cell per object, and a coarse multi-object card.
      (dolist (card-granularity '(16 64))
        (run-remembered-edges starts operation card-granularity)
        (check-card-mode starts card-granularity))))
  t)
(defun run-minor-capacity-allocation-recovery (starts)
  ;; Mature holds one live object; the nursery holds only garbage.  A minor
  ;; cannot reserve promotion room, but it also has nothing to promote, so a
  ;; clean pre-effect failure must let the allocation ladder escalate to a full
  ;; collection (a major needs no promotion room) instead of deadlocking.
  (let* ((world (make-generation-world :object-starts starts
                                       :nursery-extent 64 :mature-extent 32))
         (old (allocate-leaf world)))
    (set-world-root world 0 old)
    (complete-cycle world :minor)
    (check (mature-p world (read-world-root world 0)) "leaf not promoted")
    ;; Mature is now full.  Drop the mature root but keep it allocated
    ;; unreachable, then fill the nursery with garbage.
    (set-world-root world 0 nil)
    (allocate-leaf world)
    (allocate-leaf world)
    ;; A minor still cannot pre-reserve promotion space for the garbage, and a
    ;; direct collect reports the clean pre-effect failure.
    (let ((record (collect-world world :scope :minor)))
      (check (and (eq :retained (cycle-result-status record))
                  (eq :preparing (cycle-result-phase record))
                  (eq :capacity-exhausted (cycle-result-reason record)))
             "Clean minor failure changed: ~S/~S/~S"
             (cycle-result-status record) (cycle-result-phase record)
             (cycle-result-reason record))
      (check (eq :open (clamsara::%plan-state (world-plan world)))
             "Clean minor failure did not reopen the plan"))
    ;; The allocation ladder must now recover via a full collection.
    (let ((leaf (allocate-leaf world)))
      (check (valid-reference-p (world-model world) leaf)
             "Allocation did not recover after a clean minor failure"))
    (close-quality-world world)))

(defun run-retained-stop-refuses-allocation (starts)
  ;; A genuinely retained stop must refuse ordinary allocation outright: the
  ;; ladder must never escalate through a retained cycle.
  (let* ((world (make-generation-world :object-starts starts
                                       :nursery-extent 64 :mature-extent 32)))
    (set-world-root world 0 (allocate-leaf world))
    (complete-cycle world :minor)
    (setf (clamsara::%plan-state (world-plan world)) :retained)
    (check (handler-case
               (progn (allocate-leaf world) nil)
             (clamsara::runtime-rejection () t))
           "A retained stop admitted ordinary allocation")
    (setf (clamsara::%plan-state (world-plan world)) :open)
    (close-quality-world world)))

(defun run-generational-quality-tests-with-cards ()
  (dolist (starts '(:packed :scalar))
    (run-minor-capacity-allocation-recovery starts)
    (run-retained-stop-refuses-allocation starts))
  (run-card-remembered-edges)
  (run-generational-quality-tests-with-participants)
  (format t "~&QUALITY-GENERATIONAL-CARDS-PASS~%")
  t)

(defun run-generational-quality-tests-with-participants ()
  ;; A source-indexed participant attached to the generational plan must stage
  ;; a move row per promoted source and a tombstone per reclaimed source.
  (dolist (starts '(:packed :scalar))
    (let* ((participant (make-source-directory-participant :capacity 64))
           (world (make-generation-world :object-starts starts
                                         :movement-participants
                                         (list participant))))
      (unwind-protect
           (let ((old (allocate-leaf world)))
             (set-world-root world 0 old)
             (complete-cycle world :minor)   ; promotes old
             (set-world-root world 0 nil)
             (let ((record (complete-cycle world :all)))  ; reclaims mature old
               (count-is record :objects-dead 1))
             (let ((deaths 0))
               (map-participant-directory
                participant (lambda (key value dead)
                  (declare (ignore key value))
                  (when (eq dead 1) (incf deaths))))
               ;; The reclaimed mature source must have a tombstone row.
               (check (plusp deaths) "No tombstone for a reclaimed source")))
        (close-quality-world world)))))
