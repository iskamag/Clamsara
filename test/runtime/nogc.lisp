;;;; Executable v14 NoGC lifecycle integration (collectors.tex, "NoGC").
;;;; NoGC publishes no reclamation: a cycle traces roots but moves and kills
;;;; nothing, addresses and edges are stable, and exhaustion is an ordinary
;;;; allocation failure that never mangles a live object.
(defpackage #:clamsara.runtime.nogc.test
  (:use #:cl #:clamsara)
  (:export #:run-nogc-runtime-tests))
(in-package #:clamsara.runtime.nogc.test)

(defun %check (value format-control &rest arguments)
  (unless value (apply #'error format-control arguments))
  value)

(defun %check-count (record counter expected)
  (multiple-value-bind (value known-p) (cycle-result-count record counter)
    (%check (and known-p (= value expected))
            "NoGC counter ~S expected ~D, got ~S/~S"
            counter expected value known-p)))

(defstruct (nogc-world (:constructor %make-nogc-world))
  configuration context plan space roots provider token model kind)

(defun make-nogc-world (&key (base 4096) (extent 512) (q 16) (root-count 3))
  (let* ((roots (make-simulator-root-client :provider-capacity 8))
         (provider (make-simulator-root-provider root-count))
         (token (register-root-provider roots :nogc-roots root-count provider))
         (coordinator
           (make-simulator-coordinator roots :stop-capacity 32 :await-bound 16))
         (address-space
           (make-simulator-address-space :base base :byte-extent extent
                                        :alignment q :page-size 256
                                        :coordinator coordinator))
         (model (make-host-object-model
                 :capacity 64 :slot-capacity 8 :handle-capacity 64
                 :max-object-bytes 128))
         (kind (make-object-kind-description
                model :node :size-rule 32 :alignment-rule q
                :strong-layout '(:left :right)))
         (clients (make-simulator-clients
                   :model model :roots roots :coordinator coordinator
                   :address-space address-space :atomics (make-host-atomics)
                   :diagnostics (make-simulator-diagnostics)))
         (domain (make-metadata-domain :base base :limit (+ base extent)
                                       :granularity q))
         (space (make-nogc-space :name :nogc
                                 :object-start-map
                                 (make-object-start-marks :domain domain)
                                 :extent extent :packing-quantum q))
         (registry (make-sequential-finalizer-registry
                    :capacity 4 :root-client roots))
         (plan (make-nogc-plan
                :space space :root-client roots :coordinator coordinator
                :diagnostics (make-simulator-diagnostics) :registry registry
                :trace-capacity 8 :conditional-capacity 8 :finalizer-capacity 4
                :packing-quantum q))
         (configuration (construct-plan plan clients))
         (context (bind-mutator configuration :nogc-test :default)))
    (%make-nogc-world :configuration configuration :context context :plan plan
                      :space space :roots roots :provider provider :token token
                      :model (configuration-object-model configuration)
                      :kind kind)))

(defun %root-location (world index)
  (simulator-root-location (nogc-world-provider world) index))

(defun nogc-allocate (world)
  (multiple-value-bind (reference status reason)
      (allocate-object (nogc-world-context world) :node 32 16
                       (nogc-world-kind world))
    (if (eq status :allocated)
        (values reference t nil)
        (values reference nil reason))))

(defun nogc-set-slot (world object index value)
  (let ((seen 0) (stored nil))
    (map-reference-locations
     (nogc-world-model world) object
     (lambda (identity location)
       (declare (ignore identity))
       (when (= index seen)
         (multiple-value-bind (effective status)
             (barrier-store (configuration-barrier (nogc-world-configuration world))
                            (nogc-world-context world) location value)
           (%check (eq status :stored) "NoGC barrier store returned ~S" status)
           (setf stored effective)))
       (incf seen)))
    (%check stored "NoGC slot ~D was not found" index)))

(defun nogc-read-slot (world object index)
  (let ((seen 0) (value nil) (found nil))
    (map-reference-locations
     (nogc-world-model world) object
     (lambda (identity location)
       (declare (ignore identity))
       (when (= index seen)
         (multiple-value-bind (read status)
             (barrier-read (configuration-barrier (nogc-world-configuration world))
                           (nogc-world-context world) location)
           (%check (eq status :complete) "NoGC barrier read returned ~S" status)
           (setf value read found t)))
       (incf seen)))
    (%check found "NoGC slot ~D was not found" index)
    value))

(defun nogc-collect (world)
  (let ((record (make-cycle-result-record (nogc-world-plan world))))
    (collect (nogc-world-configuration world) :all :explicit record)
    (%check (eq :complete (cycle-result-status record))
            "NoGC cycle status/reason: ~S/~S"
            (cycle-result-status record) (cycle-result-reason record))
    record))

(defun %set-root (world index value)
  (multiple-value-bind (effective status)
      (root-provider-store (nogc-world-roots world) (nogc-world-context world)
                           (nogc-world-token world) (%root-location world index) value)
    (declare (ignore effective))
    (%check (eq status :stored) "root store returned ~S" status)))

(defun %read-root (world index)
  (root-provider-load (nogc-world-roots world) (nogc-world-token world)
                      (%root-location world index)))

(defun %live-p (model reference)
  (handler-case (progn (normalize-reference model reference) t)
    (error () nil)))

(defun %close (world)
  (%set-root world 0 nil)
  (%check (eq :unbound
              (unbind-mutator (nogc-world-configuration world)
                              (nogc-world-context world)))
          "NoGC mutator did not unbind"))

(defun run-nogc-runtime-tests ()
  (run-nogc-stability)
  (run-nogc-exhaustion)
  (run-nogc-finalizer-closure)
  (format t "~&V14-NOGC-LIFECYCLE-OK~%")
  t)

(defun run-nogc-stability ()
  "A cycle changes no address, no edge and no liveness: NoGC never moves."
  (let* ((world (make-nogc-world))
         (model (nogc-world-model world)))
    (let ((a nil) (b nil) (c nil))
      (multiple-value-bind (reference ok) (nogc-allocate world)
        (%check ok "NoGC allocation failed") (setf a reference))
      (multiple-value-bind (reference ok) (nogc-allocate world)
        (%check ok "NoGC allocation failed") (setf b reference))
      (multiple-value-bind (reference ok) (nogc-allocate world)
        (%check ok "NoGC allocation failed") (setf c reference))
      (nogc-set-slot world a 0 b)
      (nogc-set-slot world a 1 c)
      (nogc-set-slot world c 0 a)
      (%set-root world 0 a)
      (let ((a-address (reference-address model a))
            (b-address (reference-address model b))
            (c-address (reference-address model c))
            (record (nogc-collect world)))
        (%check-count record :objects-discovered 0)
        (%check-count record :objects-moved 0)
        (%check-count record :bytes-moved 0)
        (%check-count record :objects-dead 0)
        (let ((root (%read-root world 0)))
          (%check (eq root a) "NoGC changed a live root")
          (%check (= a-address (reference-address model root))
                  "NoGC changed an object address")
          (%check (eq (nogc-read-slot world root 0) b) "NoGC changed an edge")
          (%check (eq (nogc-read-slot world root 1) c) "NoGC changed an edge")
          (%check (= b-address (reference-address model b)) "edge address changed")
          (%check (= c-address (reference-address model c)) "edge address changed")
          (%check (eq (nogc-read-slot world c 0) root) "NoGC changed the cycle edge"))
        ;; A second cycle is equally inert and still complete.
        (%check-count (nogc-collect world) :objects-dead 0)))
    (%close world)
    t))

(defun run-nogc-exhaustion ()
  "Exhaustion is an ordinary :heap-exhausted failure; a collection does not
reopen the space, and a live root is never mangled."
  (let* ((world (make-nogc-world :extent 256))
         (model (nogc-world-model world)))
    (multiple-value-bind (a ok) (nogc-allocate world)
      (%check ok "NoGC allocation failed")
      (%set-root world 0 a)
      (let ((exhausted nil) (reasons nil))
        (dotimes (i 32)
          (multiple-value-bind (reference ok reason) (nogc-allocate world)
            (declare (ignore reference))
            (unless ok (setf exhausted t) (pushnew reason reasons))))
        (%check exhausted "NoGC never reached exhaustion")
        (%check (equal reasons '(:heap-exhausted))
                "NoGC exhaustion reasons: ~S" reasons))
      ;; An explicit collection reclaims nothing, so allocation stays exhausted.
      (let ((record (nogc-collect world)))
        (%check-count record :objects-dead 0)
        (%check-count record :objects-moved 0))
      (multiple-value-bind (reference ok reason) (nogc-allocate world)
        (declare (ignore reference))
        (%check (and (not ok) (eq reason :heap-exhausted))
                "NoGC reallocated after a reclaiming-looking cycle"))
      ;; The live root and its representation survive exhaustion intact.
      (let ((root (%read-root world 0)))
        (%check (eq root a) "exhaustion mangled a live root")
        (%check (%live-p model root) "live root representation became stale"))
      ;; The plan state stays open: exhaustion is not a fatal or retained stop.
      (%check (eq :open (clamsara::%plan-state (nogc-world-plan world)))
              "NoGC plan left :open after exhaustion"))
    (%close world)
    t))

(defun run-nogc-finalizer-closure ()
  "The common conditional/finalizer closure runs against NoGC's true-everything
object-live-p without inventing reclamation."
  (let* ((world (make-nogc-world))
         (registry (clamsara::%plan-registry (nogc-world-plan world)))
         (context (nogc-world-context world)))
    (multiple-value-bind (a ok) (nogc-allocate world)
      (%check ok "NoGC allocation failed")
      (register-finalizer registry context a
                          (lambda (value) (declare (ignore value))))
      (let ((record (nogc-collect world)))
        (%check-count record :objects-dead 0)
        (%check-count record :objects-moved 0)
        ;; The referent is still live (NoGC proves nothing dead), so it must not
        ;; be frozen as a pending finalizer candidate.
        (%check-count record :finalizers-enqueued 0)))
    (%close world)
    t))
