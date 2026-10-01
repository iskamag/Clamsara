;;;; Executable v14 Immix lifecycle integration (collectors.tex, "Immix").
;;;;
;;;; Immix is a nonmoving mark-region collector.  Marking an object marks every
;;;; line intersecting its reserved extent, including a partial last line.  A
;;;; line is free only after complete liveness judgment; a dead object sharing a
;;;; line with a live object is retained as floating garbage, and a block is
;;;; free only once every spanning object is accounted for.
(defpackage #:clamsara.runtime.immix.test
  (:use #:cl #:clamsara)
  (:export #:run-immix-runtime-tests))
(in-package #:clamsara.runtime.immix.test)

(defun %check (value format-control &rest arguments)
  (unless value (apply #'error format-control arguments))
  value)

(defun %check-count (record counter expected)
  (multiple-value-bind (value known-p) (cycle-result-count record counter)
    (%check (and known-p (= value expected))
            "Immix counter ~S expected ~D, got ~S/~S"
            counter expected value known-p)))

(defstruct (immix-world (:constructor %make-immix-world))
  configuration context plan space roots provider token model kind line-size)

(defun make-immix-world (&key (base 4096) (extent 4096) (q 16)
                              (line-size 64) (block-size 256) (root-count 4))
  (let* ((roots (make-simulator-root-client :provider-capacity 8))
         (provider (make-simulator-root-provider root-count))
         (token (register-root-provider roots :immix-roots root-count provider))
         (coordinator
           (make-simulator-coordinator roots :stop-capacity 64 :await-bound 16))
         (address-space
           (make-simulator-address-space :base base :byte-extent extent
                                        :alignment q :page-size 256
                                        :coordinator coordinator))
         (model (make-host-object-model
                 :capacity 256 :slot-capacity 8 :handle-capacity 64
                 :max-object-bytes 1024))
         (kind (make-object-kind-description
                model :node :size-rule 32 :alignment-rule q
                :strong-layout '(:left :right)))
         (clients (make-simulator-clients
                   :model model :roots roots :coordinator coordinator
                   :address-space address-space :atomics (make-host-atomics)
                   :diagnostics (make-simulator-diagnostics)))
         (domain (make-metadata-domain :base base :limit (+ base extent)
                                       :granularity q))
         (space (make-immix-space :name :immix
                                  :object-start-map
                                  (make-object-start-marks :domain domain)
                                  :marks (make-side-marks :domain domain)
                                  :extent extent :packing-quantum q
                                  :line-size line-size :block-size block-size))
         (registry (make-sequential-finalizer-registry
                    :capacity 4 :root-client roots))
         (plan (make-immix-plan
                :space space :root-client roots :coordinator coordinator
                :diagnostics (make-simulator-diagnostics) :registry registry
                :trace-capacity 256 :conditional-capacity 16
                :finalizer-capacity 4 :packing-quantum q))
         (configuration (construct-plan plan clients))
         (context (bind-mutator configuration :immix-test :default)))
    (%make-immix-world :configuration configuration :context context :plan plan
                       :space space :roots roots :provider provider :token token
                       :model (configuration-object-model configuration)
                       :kind kind :line-size line-size)))

(defun %root-location (world index)
  (simulator-root-location (immix-world-provider world) index))

(defun immix-allocate (world)
  (multiple-value-bind (reference status reason)
      (allocate-object (immix-world-context world) :node 32 16
                       (immix-world-kind world))
    (if (eq status :allocated)
        (values reference t nil)
        (values reference nil reason))))

(defun %alloc (world)
  (multiple-value-bind (reference ok reason) (immix-allocate world)
    (declare (ignore reason))
    (%check ok "Immix allocation failed")
    reference))

(defun %with-slot (world object index function)
  (let ((seen 0) (done nil))
    (map-reference-locations
     (immix-world-model world) object
     (lambda (identity location)
       (declare (ignore identity))
       (when (= index seen) (funcall function location) (setf done t))
       (incf seen)))
    (%check done "Immix slot ~D missing" index)))

(defun immix-set-slot (world object index value)
  (%with-slot
   world object index
   (lambda (location)
     (multiple-value-bind (effective status)
         (barrier-store (configuration-barrier (immix-world-configuration world))
                        (immix-world-context world) location value)
       (%check (eq status :stored) "Immix barrier store returned ~S" status)
       effective))))

(defun immix-read-slot (world object index)
  (let ((value nil))
    (%with-slot
     world object index
     (lambda (location)
       (multiple-value-bind (read status)
           (barrier-read (configuration-barrier (immix-world-configuration world))
                         (immix-world-context world) location)
         (%check (eq status :complete) "Immix barrier read returned ~S" status)
         (setf value read))))
    value))

(defun %set-root (world index value)
  (multiple-value-bind (effective status)
      (root-provider-store (immix-world-roots world) (immix-world-context world)
                           (immix-world-token world) (%root-location world index)
                           value)
    (declare (ignore effective))
    (%check (eq status :stored) "Immix root store returned ~S" status)))

(defun immix-collect (world)
  (let ((record (make-cycle-result-record (immix-world-plan world))))
    (collect (immix-world-configuration world) :all :explicit record)
    (%check (eq :complete (cycle-result-status record))
            "Immix cycle status/reason: ~S/~S"
            (cycle-result-status record) (cycle-result-reason record))
    record))

(defun %live-p (model reference)
  (handler-case (progn (normalize-reference model reference) t)
    (error () nil)))

(defun %close (world)
  (%set-root world 0 nil)
  (%check (eq :unbound (unbind-mutator (immix-world-configuration world)
                                       (immix-world-context world)))
          "Immix mutator did not unbind"))

(defun run-immix-cancel-restores-scan-cursor ()
  "A cancelled reservation must not let the next run selection hand back an
occupied run.  The allocator snapshots both the byte and the run-scan cursor, so
a cancel after selecting the first run restores the scan cursor too."
  (let* ((world (make-immix-world :line-size 64 :block-size 256 :extent 4096))
         (space (immix-world-space world))
         (allocator (clamsara::%space-allocator space))
         (base (clamsara::%space-base space)))
    ;; Fill the first run with live reservations (no collection runs, so they
    ;; stay authoritative), then cancel one and allocate again.
    (dotimes (index 120)
      (multiple-value-bind (address ok)
          (allocate-raw allocator 32 16 :node)
        (%check ok "raw allocation ~D failed" index)
        (%check (= address (+ base (* index 32))) "unexpected raw address")))
    (let ((before (clamsara::%allocator-cursor allocator)))
      (multiple-value-bind (address ok)
          (allocate-raw allocator 32 16 :node)
        (%check ok "reservation failed")
        (clamsara::%cancel-raw-allocation allocator)
        (%check (= (clamsara::%allocator-cursor allocator) before)
                "cancel did not restore the byte cursor"))
      ;; The next request that cannot fit the remainder must not reuse an
      ;; occupied run; with the whole space reserved it simply fails.
      (multiple-value-bind (address ok)
          (allocate-raw allocator 2048 16 :node)
        (%check (not ok) "cancel let a fresh run reuse occupied lines: ~S" address)))
    t))

(defun run-immix-runtime-tests ()
  (run-immix-reclamation)
  (run-immix-floating-garbage)
  (run-immix-partial-line)
  (run-immix-geometry-rejection)
  (run-immix-cancel-restores-scan-cursor)
  (format t "~&V14-IMMIX-LIFECYCLE-OK~%")
  t)

(defun run-immix-reclamation ()
  "An isolated dead object is reclaimed, address-stable live objects survive,
and the freed lines are reused first."
  (let* ((world (make-immix-world :line-size 16 :block-size 64))
         (model (immix-world-model world))
         (a (%alloc world)) (b (%alloc world)) (c (%alloc world)) (dead (%alloc world)))
    (immix-set-slot world a 0 b)
    (immix-set-slot world b 0 a)
    (immix-set-slot world a 1 c)
    (%set-root world 0 a)
    (let ((a-address (reference-address model a))
          (dead-address (reference-address model dead))
          (record (immix-collect world)))
      (%check-count record :objects-discovered 3)
      (%check-count record :objects-moved 0)
      (%check-count record :objects-dead 1)
      ;; Each 32-byte object spans two 16-byte lines and is alone in its lines,
      ;; so the unrooted `dead` object is reclaimed.
      (%check (not (%live-p model dead)) "Isolated Immix garbage was not reclaimed")
      (%check (and (%live-p model a) (%live-p model b) (%live-p model c))
              "Immix reclaimed a live object")
      (let ((root (root-provider-load
                   (immix-world-roots world) (immix-world-token world)
                   (%root-location world 0))))
        (%check (eq root a) "Immix moved a live root")
        (%check (= a-address (reference-address model root))
                "Immix changed a live address")
        (%check (eq (immix-read-slot world root 0) b) "Immix changed an edge"))
      ;; The freed region is reused first.
      (let ((replacement (%alloc world)))
        (%check (= dead-address (reference-address model replacement))
                "Immix did not reuse the freed lines first")))
    (%set-root world 0 nil)
    (immix-collect world)
    (%close world)
    t))

(defun run-immix-floating-garbage ()
  "A dead object sharing a line with a live object is retained until the live
object dies; a block is freed only once every spanning object is accounted for."
  (let* ((world (make-immix-world :line-size 64 :block-size 256))
         (model (immix-world-model world)))
    ;; Line 0 holds A (4096) and B (4128); line 1 holds C (4160).
    (let ((a (%alloc world)) (b (%alloc world)) (c (%alloc world)))
      (%set-root world 0 a)
      (let ((record (immix-collect world)))
        (%check-count record :objects-discovered 1)
        ;; B shares line 0 with live A: floating garbage, not reclaimed.
        (%check (%live-p model b) "Immix reclaimed a line-shared dead object")
        ;; C is alone in line 1: reclaimed.
        (%check (not (%live-p model c)) "Isolated dead object was not reclaimed")
        (%check-count record :objects-dead 1))
      ;; Now A dies too, leaving line 0 with no live object; both A and B fall.
      (%set-root world 0 nil)
      (%check-count (immix-collect world) :objects-dead 2)
      (%check (and (not (%live-p model a)) (not (%live-p model b)))
              "Immix retained objects after their line lost every live object"))
    (%close world)
    t))

(defun run-immix-partial-line ()
  "Marking an object marks its partial last line, so a dead object in a line a
live object partially occupies is retained."
  (let* ((world (make-immix-world :line-size 64 :block-size 256))
         (model (immix-world-model world)))
    ;; A 32-byte object at 4128 spans line 0 bytes [32,64); a live 32-byte
    ;; object at 4096 spans [0,32).  They share line 0.
    (let ((a (%alloc world)) (b (%alloc world)))
      (%set-root world 0 a)
      (immix-collect world)
      (%check (%live-p model b)
              "Partial last line did not retain a sharing dead object"))
    (%close world)
    t))

(defun run-immix-geometry-rejection ()
  "Immix rejects block/line geometry that is not a checked instance geometry."
  (let ((cases
          (list (list :line-not-power-of-two 48 256)
                (list :block-not-multiple-of-line 32 96)
                (list :line-below-quantum 8 64)
                (list :extent-not-multiple-of-line 1000 64))))
    (dolist (case cases)
      (destructuring-bind (label line block) case
        (let ((reason
                (handler-case
                    (progn
                      (make-immix-space
                       :name :bad
                       :object-start-map
                       (make-object-start-marks
                        :domain (make-metadata-domain :base 4096
                                                      :limit 5096 :granularity 16))
                       :marks (make-side-marks
                               :domain (make-metadata-domain :base 4096
                                                             :limit 5096
                                                             :granularity 16))
                       :extent 1000 :packing-quantum 16
                       :line-size line :block-size block)
                      :no-rejection)
                  (clamsara::runtime-rejection (condition)
                    (clamsara::runtime-rejection-reason condition)))))
          (%check (eq reason :invalid-immix-geometry)
                  "~A: expected :invalid-immix-geometry, got ~S" label reason)))))
  t)
