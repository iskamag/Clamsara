;;;; Additional independently authored fixed-repair histories.
;;;; Load the unchanged acceptance-03.lisp first. No production protocol is stubbed.
(in-package #:clamsara.cas-independent)
(defvar *hook-source* nil)
(defvar *registration-reference* nil)
(defvar *mode* nil)
(defvar *hook-phase* nil)
(defvar *hook-rule* nil)
(defvar *hook-context* nil)
(defvar *hook-fired* nil)
(defvar *nested-fault* nil)
(defvar *caught-nested-fatal* nil)
(defvar *allocator* nil)
(defvar *ordinary-result* nil)
(defvar *finalizer-token* nil)
(defvar *finalizer-ran* 0)
(defvar *compare-count* 0)
(defvar *extra-algorithm* :semispace)
(defun finalizer-callback (reference) (declare (ignore reference)) (incf *finalizer-ran*))
(defun trigger-nested-fatal (location)
  (let ((*nested-fault* t))
    (setf *caught-nested-fatal*
          (catch 'clamsara::simulator-fatal
            (barrier-read (configuration-barrier (world-configuration *world*))
                          *second-context* location)
            :unexpected-return))))
(defun ordinary-action ()
  (setf *ordinary-result*
        (handler-case
            (case *mode*
              (:raw (allocate-raw *allocator* 32 16 :quality-node) :allowed)
              (:refill (refill-mutator *allocator* (world-context *world*)
                                      (clamsara::%context-refill-request (world-context *world*)))
                       :allowed)
              (:register
               (register-finalizer (world-registry *world*) (world-context *world*)
                                   *registration-reference* #'finalizer-callback)
               :allowed)
              (:cancel-finalizer
               (cancel-finalizer (world-registry *world*) (world-context *world*) *finalizer-token*)
               :allowed)
              (:drain
               (drain-pending-finalizers (world-registry *world*) (world-context *world*))
               :allowed))
          (clamsara::runtime-rejection (condition)
            (clamsara::runtime-rejection-reason condition))))
  (values))
(defun phase-hook (r phase context location)
  (when (and *capture* (eq r *hook-rule*) (eq phase *hook-phase*)
             (eq context *hook-context*) (not *hook-fired*))
    (setf *hook-fired* t)
    (case *mode*
      (:error (error (rule-fault r)))
      (:throw (throw 'review-nonlocal-exit :rule-nonlocal-exit))
      (:nested (trigger-nested-fatal location))
      ((:raw :refill :register :cancel-finalizer :drain) (ordinary-action))))
  (values))
(defmethod barrier-contribution-reserve :around ((r rule) context operation location)
  (multiple-value-bind (reservation status) (call-next-method)
    (when (and *nested-fault* (eq context *second-context*) (eq (rule-name r) :b))
      (note r :nested-reserve-fault operation reservation)
      (error (rule-fault r)))
    (phase-hook r :reserve context location)
    (values reservation (if (and *capture* (eq *mode* :invalid) (eq r *hook-rule*)
                                 (eq context *hook-context*) (eq *hook-phase* :reserve))
                            :invalid-status status))))
(defmethod barrier-contribution-admit :around ((r rule) reservation context operation location)
  (declare (ignore reservation operation))
  (let ((status (call-next-method)))
    (phase-hook r :admit context location)
    (if (and *capture* (eq *mode* :invalid) (eq r *hook-rule*)
             (eq context *hook-context*) (eq *hook-phase* :admit))
        :invalid-status status)))
(defmethod barrier-contribution-transform :around
    ((r rule) reservation context operation location old candidate)
  (declare (ignore reservation operation old candidate))
  (multiple-value-bind (value status) (call-next-method)
    (phase-hook r :transform context location)
    (values value (if (and *capture* (eq *mode* :invalid) (eq r *hook-rule*)
                           (eq context *hook-context*) (eq *hook-phase* :transform))
                      :invalid-status status))))
(defmethod barrier-contribution-before-exposure :around
    ((r rule) reservation context operation location old final)
  (declare (ignore reservation operation old final))
  (call-next-method)
  (phase-hook r :before context location))
(defmethod barrier-contribution-after-exposure :around
    ((r rule) reservation context operation location old final)
  (declare (ignore reservation operation old final))
  (call-next-method)
  (phase-hook r :after context location))
(defmethod barrier-contribution-cancel :around ((r rule) reservation)
  (when (and *capture* (eq r *hook-rule*) (eq *hook-phase* :cancel) (not *hook-fired*))
    (when (member *mode* '(:error :throw))
      (setf *hook-fired* t)
      (note r :cancel-fault nil reservation)
      (if (eq *mode* :error) (error (rule-fault r))
          (throw 'review-nonlocal-exit :rule-nonlocal-exit))))
  (call-next-method)
  ;; A cancel has no location. Use a newly mapped location only inside its
  ;; callback when testing a caught fatal, never save an outer location.
  (when (and *capture* (eq r *hook-rule*) (eq *hook-phase* :cancel)
             (eq *mode* :nested) (not *hook-fired*))
    (setf *hook-fired* t)
    (map-reference-locations
     (world-model *world*) *hook-source*
     (lambda (identity location)
       (when (eq identity :left) (trigger-nested-fatal location)))))
  (values))
;; Preserve the previous load/store observer while adding source-boundary hooks.
(defmethod load-reference :around ((model clamsara::host-bound-object-model)
                                  location &optional order)
  (declare (ignore order))
  (when *capture* (incf *raw-loads*))
  (let ((value (call-next-method)))
    (when (and *capture* (eq *mode* :nested) (eq *hook-phase* :raw-load) (not *hook-fired*))
      (setf *hook-fired* t) (trigger-nested-fatal location))
    value))
(defmethod reference-encoding-equal-p :around
    ((model clamsara::host-bound-object-model) left right)
  (declare (ignore left right))
  (when *capture* (incf *compare-count*))
  (let ((result (call-next-method)))
    (when (and *capture* (eq *mode* :nested) (eq *hook-phase* :comparison) (not *hook-fired*))
      (setf *hook-fired* t)
      (map-reference-locations
       model *hook-source*
       (lambda (identity location)
         (when (eq identity :left) (trigger-nested-fatal location)))))
    result))
(defmethod store-reference-raw :around ((model clamsara::host-bound-object-model)
                                       location value &optional order)
  (declare (ignore value order))
  (when *capture* (incf *raw-stores*))
  (multiple-value-prog1 (call-next-method)
    (when (and *capture* (eq *mode* :nested) (eq *hook-phase* :raw-store) (not *hook-fired*))
      (setf *hook-fired* t) (trigger-nested-fatal location))))
(defun allocator-snapshot (allocator)
  (if (typep allocator 'clamsara::bump-runtime-allocator)
      (list (clamsara::%allocator-cursor allocator) (clamsara::%allocator-limit allocator)
            (clamsara::%allocator-last-cursor allocator) (clamsara::%allocator-last-valid-p allocator))
      (list (coerce (clamsara::%free-starts allocator) 'list)
            (coerce (clamsara::%free-limits allocator) 'list)
            (clamsara::%free-count allocator) (clamsara::%free-last-index allocator)
            (clamsara::%free-last-start allocator) (clamsara::%allocator-last-valid-p allocator))))
(defun registry-snapshot (registry)
  (list (clamsara::%registry-next-token registry)
        (clamsara::%registry-pending-head registry)
        (clamsara::%registry-pending-count registry)
        (coerce (clamsara::%registry-states registry) 'list)
        (coerce (clamsara::%registry-pending registry) 'list)))
(defun check-fatal-state (w &optional (pins 1))
  (let ((plan (world-plan w)) (context (world-context w)))
    (check (eq (clamsara::%plan-state plan) :fatal) "Poisoned plan not sticky fatal")
    (check (eq (clamsara::%context-barrier-state context) :failed) "Failed context scratch recycled")
    (check (= (clamsara::%plan-barrier-pin-count plan) pins) "Fatal pin ownership lost")
    (check (null (clamsara::%plan-retained-cycle plan)) "Barrier fabricated retained GC cycle")
    (check (null (clamsara::%cycle-stop-token (clamsara::%plan-cycle plan))) "Barrier fabricated GC stop")
    (check (eq (unbind-mutator (world-configuration w) context) :retry) "Failed context unbound")))
(defun check-fatal-extra-entries (w)
  (let* ((*allocator* (clamsara::%context-allocator (world-context w)))
         (before (allocator-snapshot *allocator*))
         (registry (world-registry w)) (*registration-reference* (read-world-root w 1)) (registry-before (registry-snapshot registry)))
    (dolist (mode '(:raw :refill :register :cancel-finalizer :drain))
      (let ((*mode* mode) (*ordinary-result* nil) (*capture* nil))
        (ordinary-action)
        (check (eq *ordinary-result* :fatal-invariant) "Fatal ordinary bypass ~S/~S" mode *ordinary-result*)))
    (check (equal before (allocator-snapshot *allocator*)) "Fatal raw/refill altered cursor or history")
    (check (equal registry-before (registry-snapshot registry)) "Fatal finalizer entry altered registry")))
(defun configure-hook (mode phase rule w)
  (setf *mode* mode *hook-phase* phase *hook-rule* rule *hook-context* (world-context w)
        *hook-fired* nil *caught-nested-fatal* nil *compare-count* 0))
(defun extra-one (label rules body &key fatal)
  (let ((*hook-source* nil) (*registration-reference* nil)
        (*mode* nil) (*hook-phase* nil) (*hook-rule* nil) (*hook-context* nil)
        (*hook-fired* nil) (*nested-fault* nil) (*caught-nested-fatal* nil)
        (*ordinary-result* nil) (*finalizer-token* nil) (*finalizer-ran* 0)
        (*allocator* nil) (*compare-count* 0))
    (one label rules body :fatal fatal)))

;; Copy only the prior real world constructor for a MarkSweep-specific test plan.
(defclass extra-marksweep-plan (clamsara::marksweep-plan)
  ((rules :initarg :rules :reader plan-rules)))
(defmethod component-barrier-contributions ((p extra-marksweep-plan)) (copy-list (plan-rules p)))
(defmethod clamsara::map-construction-auxiliary-storage ((p extra-marksweep-plan) f)
  (call-next-method)
  (clamsara::%map-construction-cons-storage (plan-rules p) f)
  (dolist (r (plan-rules p))
    (funcall f r) (funcall f (rule-fault r))
    (clamsara::%map-construction-cons-storage (rule-events r) f)
    (clamsara::%map-construction-cons-storage (rule-before r) f)
    (funcall f (rule-tokens r)) (map nil f (rule-tokens r)))
  (values))
(defun make-extra-marksweep-plan (&rest args)
  (change-class (apply #'make-marksweep-plan args) 'extra-marksweep-plan :rules *rules*))

(defun make-extra-world (&key
                             (algorithm :semispace)
                             (object-starts :packed)
                             (base 4096)
                             (extent 2048)
                             (packing-quantum 16)
                             (map-granularity packing-quantum)
                             (root-count 8)
                             (trace-capacity 128)
                             (conditional-capacity 128)
                             (finalizer-capacity 16)
                             (finalizer-registration-capacity
                               (max finalizer-capacity 64))
                             (stop-capacity 64)
                             (await-bound 32)
                             await-fail-after
                             configure-model
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
            :variant-capacity 0 :location-capacity 32
            :handle-capacity 256 :stage-capacity 16
            :max-object-bytes 256))
         ;; Slot zero is a managed immediate ID.  Slots one and two are the
         ;; actual managed graph edges.  The ID lets the host-side oracle name
         ;; objects without replacing their payload or edges with host data.
         (node-kind
           (prog1
               (make-object-kind-description
                model :quality-node :size-rule 32
                :alignment-rule packing-quantum
                :strong-layout '(:quality-id :left :right))
             ;; Test-only extension seam; all descriptions still precede binding
             ;; and immutable construction ownership/account closure.
             (when configure-model (funcall configure-model model))))
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
            :base base :limit (+ base extent) :granularity map-granularity))
         (control-domain-0
           (if (= map-granularity packing-quantum) domain-0
               (make-metadata-domain :base base :limit (+ base extent)
                                     :granularity packing-quantum)))
         (map-0 (clamsara.quality.support::%object-start-map object-starts domain-0))
         (space nil)
         (plan
           (ecase algorithm
             (:semispace
              (let* ((domain-1
                       (make-metadata-domain
                        :base (+ base extent) :limit (+ base (* 2 extent))
                        :granularity map-granularity))
                     (control-domain-1
                       (if (= map-granularity packing-quantum) domain-1
                           (make-metadata-domain
                            :base (+ base extent) :limit (+ base (* 2 extent))
                            :granularity packing-quantum)))
                     (from
                       (make-semispace-space
                        :name :quality-from :object-start-map map-0
                        :forwarding (make-side-forwarding :domain control-domain-0)
                        :extent extent :packing-quantum packing-quantum
                        :role :allocation))
                     (to
                       (make-semispace-space
                        :name :quality-to
                        :object-start-map
                        (clamsara.quality.support::%object-start-map object-starts domain-1)
                        :forwarding (make-side-forwarding :domain control-domain-1)
                        :extent extent :packing-quantum packing-quantum
                        :role :reserve)))
                (setf space from)
                (make-review-plan
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
                       :marks (make-side-marks :domain control-domain-0)
                       :extent extent :packing-quantum packing-quantum
                       :descriptor-capacity object-capacity)))
                (setf space marksweep)
                (make-extra-marksweep-plan
                 :space marksweep :root-client roots
                 :coordinator coordinator :diagnostics diagnostics
                 :registry registry :trace-capacity trace-capacity
                 :conditional-capacity conditional-capacity
                 :finalizer-capacity finalizer-capacity
                 :packing-quantum packing-quantum)))))
         (configuration (construct-plan plan clients))
         (context (bind-mutator configuration :quality-mutator :default)))
    (clamsara.quality.support::%make-quality-world
     :algorithm algorithm :object-starts object-starts
     :packing-quantum packing-quantum
     :configuration configuration :context context
     :model (configuration-object-model configuration)
     :roots roots :root-token root-token :root-provider provider
     :coordinator coordinator :plan plan :registry registry
     :node-kind node-kind :space space :root-count root-count)))
(defvar *original-world-constructor* #'make-review-world)
(defun make-review-world (&rest args)
  (apply #'make-extra-world :algorithm *extra-algorithm* args))

(defun test-illegal-phase (phase mode)
  (let ((rules (three-rules :read)))
    (extra-one (list :illegal-phase phase mode) rules
      (lambda (w source old new)
        (configure-hook mode phase (second rules) w)
        (let ((outcome (attempt-invoke w source :read old new)))
          (check (eq outcome :fatal-invariant) "Pre-effect violation did not use invariant-fatal")
          (check-fatal-state w)
          (check (null (names-at :cancel)) "Unknown fault guessed ordinary cancellation")
          (check (null (names-at :before)) "Unknown fault reached exposure")
          (check (= *raw-loads* (if (eq phase :transform) 1 0)) "Wrong pre-effect raw-load boundary")
          (check (zerop *raw-stores*) "Pre-effect violation stored")
          (check-fatal-extra-entries w)
          (closure-probes w))) :fatal t)))
(defun test-cancel-fault (mode position)
  (let ((rules (three-rules :read)))
    (extra-one (list :cancel-fault mode position) rules
      (lambda (w source old new)
        (setf (rule-action (second rules)) :retry (rule-phase (second rules)) :admit)
        (configure-hook mode :cancel (nth position rules) w)
        (check (eq (attempt-invoke w source :read old new) :fatal-invariant) "Cancel fault escaped as retry/error")
        (check-fatal-state w)
        (check (zerop *raw-loads*) "Cancel fault unexpectedly loaded")
        (check (equal (names-at :cancel) (if (= position 2) nil '(:c))) "Cancel prefix not settled once")
        (loop for r in rules for i from 0
              do (check (eq (aref (clamsara::%context-barrier-reserved-p (world-context w)) i)
                             (<= i position)) "Cancel ownership prefix lost/recreated")
                 (check (= (token-total r #'token-cancels) (if (> i position) 1 0))
                        "Cancel was repeated or skipped prior to fault"))
        (check-fatal-extra-entries w)
        (closure-probes w)) :fatal t)))
(defun test-caught-nested-fatal (phase)
  (let ((rules (three-rules :read)))
    (extra-one (list :caught-other-context-fatal phase) rules
      (lambda (w source old new)
        (setf *second-context* (bind-mutator (world-configuration w) :nested-fatal :default))
        (configure-hook :nested phase (second rules) w)
        (setf *hook-source* source)
        (when (eq phase :cancel)
          (setf (rule-action (second rules)) :retry (rule-phase (second rules)) :admit))
        (let ((outcome (attempt-invoke w source
                                       (if (member phase '(:comparison :raw-store)) :match :read)
                                       old new)))
          (check (eq *caught-nested-fatal* :fatal-invariant) "Callback did not catch the nested fatal")
          (check (eq outcome :fatal-invariant) "Outer call continued after caught nested fatal")
          (check-fatal-state w 2)
          (check (eq (clamsara::%context-barrier-state *second-context*) :failed)
                 "Nested failed frame was recycled")
          (check (aref (clamsara::%context-barrier-reserved-p *second-context*) 0)
                 "Nested successful reservation was forgotten")
          (check (not (aref (clamsara::%context-barrier-reserved-p *second-context*) 1))
                 "Driver invented ownership for unreturned nested reservation")
          (let ((owned (clamsara::%context-barrier-reserved-p (world-context w))))
            (check (aref owned 1) "Current outer token cleared after caught fatal")
            (check (eq (aref owned 0) (not (eq phase :after))) "Earlier outer token ownership wrong")
            (check (eq (aref owned 2) (not (member phase '(:reserve :cancel))))
                   "Later outer token ownership wrong"))
          (when (member phase '(:reserve :admit :transform :raw-load :comparison :cancel))
            (check (null (names-at :before)) "Outer exposed after known closed state"))
          (when (member phase '(:raw-load :comparison))
            (check (null (names-at :transform)) "Sticky check came after transforms"))
          (when (eq phase :raw-load) (check (zerop *compare-count*) "Comparison preceded post-load sticky check"))
          (when (eq phase :raw-store) (check (null (names-at :after)) "After callbacks ran after closed raw store"))
          (when (eq phase :after)
            (check (equal (names-at :after) '(:a :b)) "After-exposure ran later contribution"))
          (when (eq phase :cancel)
            (check (equal (names-at :cancel) '(:c :b)) "Cancel continued after fatal"))
          (check-fatal-extra-entries w)
          (closure-probes w))) :fatal t)))
(defun prepare-finalizer-action (w mode)
  (case mode
    (:register nil)
    (:cancel-finalizer
     (setf *finalizer-token*
           (register-finalizer (world-registry w) (world-context w)
                               (read-world-root w 1) #'finalizer-callback)))
    (:drain
     (let ((victim (allocate-node w 504)))
       (setf *finalizer-token*
             (register-finalizer (world-registry w) (world-context w) victim #'finalizer-callback)))
     (check (eq (cycle-result-status (collect-world w)) :complete) "Pending finalizer collection failed")
     (check (= (clamsara::%registry-pending-count (world-registry w)) 1) "No real pending finalizer")
     (check (zerop *finalizer-ran*) "Collection ran callback"))))
(defun test-ordinary-pin (algorithm phase mode)
  (let ((rules (three-rules :read)) (*extra-algorithm* algorithm))
    (extra-one (list :ordinary-pin algorithm phase mode) rules
      (lambda (w source old new)
        (declare (ignore source old new))
        (prepare-finalizer-action w mode)
        (let* ((source (read-world-root w 0)) (old (read-world-root w 1))
               (new (read-world-root w 2))
               (allocator (clamsara::%context-allocator (world-context w)))
               (allocator-before (allocator-snapshot allocator))
               (registry-before (registry-snapshot (world-registry w)))
               (ctx-cursor (clamsara::%context-cursor (world-context w)))
               (ctx-limit (clamsara::%context-limit (world-context w))))
          (setf *allocator* allocator *registration-reference* old)
          (reset-observer)
          (configure-hook mode phase (second rules) w)
          (check-completion w source :read old new)
          (check *hook-fired* "Ordinary negative control did not run")
          (check (eq *ordinary-result* :barrier-busy) "Live pin did not reject before ordinary effect")
          (check (equal allocator-before (allocator-snapshot allocator)) "Blocked raw/refill changed allocator")
          (check (and (= ctx-cursor (clamsara::%context-cursor (world-context w)))
                      (= ctx-limit (clamsara::%context-limit (world-context w))))
                 "Blocked raw/refill changed context cursor")
          (check (equal registry-before (registry-snapshot (world-registry w))) "Blocked finalizer mutated registry")
          (check (zerop *finalizer-ran*) "Pending callback ran under protected barrier")
          (check (zerop (clamsara::%plan-barrier-pin-count (world-plan w))) "Successful entry leaked pin")
          (check (eq (clamsara::%context-barrier-state (world-context w)) :idle) "Successful context not idle")
          ;; Later-positive controls use the same real allocator/registry.
          (setf *mode* nil)
          (case mode
            (:raw
             (multiple-value-bind (address ready) (allocate-raw allocator 32 16 :quality-node)
               (check (and ready (integerp address)) "Post-pin raw reservation refused")
               ;; This is legitimate cancellation of a private raw allocation,
               ;; not forced fatal cleanup or a manual object publication.
               (clamsara::%cancel-raw-allocation allocator))
             (set-world-root w 4 (allocate-node w 505)))
            (:refill
             (check (null (refill-mutator allocator (world-context w)
                                          (clamsara::%context-refill-request (world-context w))))
                    "Concrete post-pin refill contract changed")
             (check (equal allocator-before (allocator-snapshot allocator)) "No-refill path changed allocator"))
            (:register
             (let ((token (register-finalizer (world-registry w) (world-context w) old #'finalizer-callback)))
               (check token "Post-pin registration refused")
               (check (eq (cancel-finalizer (world-registry w) (world-context w) token) :canceled)
                      "Post-pin cancellation refused")))
            (:cancel-finalizer
             (check (eq (cancel-finalizer (world-registry w) (world-context w) *finalizer-token*) :canceled)
                    "Blocked cancellation consumed token")
             (check (eq (cancel-finalizer (world-registry w) (world-context w) *finalizer-token*) :already-finalized)
                    "Post-pin cancellation not once-only"))
            (:drain
             (check (= (drain-pending-finalizers (world-registry w) (world-context w)) 1)
                    "Post-pin real pending callback not run")
             (check (= *finalizer-ran* 1) "Pending callback was lost/duplicated")
             (check (zerop (drain-pending-finalizers (world-registry w) (world-context w)))
                    "Finalizer drain repeated callback"))))))))

;; Opaque NIL reservation ownership is independent of the token value.
(defclass nil-token-rule (rule) ())
(defmethod barrier-contribution-reserve ((r nil-token-rule) context operation location)
  (multiple-value-bind (token status) (do-reserve r context operation location)
    (declare (ignore token)) (values nil status)))
(defmethod barrier-contribution-admit ((r nil-token-rule) reservation context operation location)
  (check (null reservation) "NIL token was wrapped/replaced")
  (do-admit r (aref (rule-tokens r) 0) context operation location))
(defmethod barrier-contribution-transform ((r nil-token-rule) reservation context operation location old candidate)
  (declare (ignore context location old))
  (check (null reservation) "NIL transform token replaced")
  (note r :transform operation (aref (rule-tokens r) 0))
  (values candidate :complete))
(defmethod barrier-contribution-before-exposure ((r nil-token-rule) reservation context operation location old final)
  (declare (ignore context location old final))
  (check (null reservation) "NIL before token replaced")
  (note r :before operation (aref (rule-tokens r) 0)))
(defmethod barrier-contribution-after-exposure ((r nil-token-rule) reservation context operation location old final)
  (declare (ignore context location old final))
  (check (null reservation) "NIL after token replaced")
  (let ((token (aref (rule-tokens r) 0)))
    (check (token-active token) "NIL token consumed twice")
    (note r :after operation token)
    (setf (token-active token) nil) (incf (token-consumes token))))
(defmethod barrier-contribution-cancel ((r nil-token-rule) reservation)
  (check (null reservation) "NIL cancel token replaced")
  (let ((token (aref (rule-tokens r) 0)))
    (check (token-active token) "NIL token canceled twice")
    (note r :cancel nil token)
    (setf (token-active token) nil) (incf (token-cancels token))))
(defun test-nil-token (event operation)
  (let ((rules (list (make-instance 'nil-token-rule :name :nil-token :events (list event)))))
    (extra-one (list :nil-opaque-token event operation) rules
      (lambda (w source old new)
        (check-completion w source operation old new)
        (check (= (token-total (first rules) #'token-acquires) 1) "NIL token acquisition")
        (check (= (token-total (first rules) (if (eq event :cas) #'token-cancels #'token-consumes)) 1)
               "NIL token terminal path skipped")))))

(defun measure-workspace (w)
  (let* ((context (world-context w)) (plan (world-plan w))
         (barrier (configuration-barrier (world-configuration w)))
         (construction (configuration-construction-context (world-configuration w)))
         (state (gethash :configuration-auxiliary (clamsara::%context-resources construction)))
         (resource (clamsara::%resource-state-release-capability state))
         (manifest (clamsara::%simulator-resource-manifest resource))
         (n (length (clamsara::%barrier-contributions barrier))))
    (check (find plan manifest :test #'eq) "Plan object missing from construction storage manifest")
    (check (find barrier manifest :test #'eq) "Barrier object missing from construction storage manifest")
    (check (not (find context manifest :test #'eq)) "Unexpected post-bind context in immutable construction manifest")
    (check (= n (length (clamsara::%context-barrier-reservations context))) "Reservation scratch is not N")
    (check (= n (length (clamsara::%context-barrier-reserved-p context))) "Ownership scratch is not N")
    (format t "~&WORKSPACE N=~D plan-measured=~D barrier-measured=~D context-measured=~D tokens-vector-measured=~D owned-vector-measured=~D construction-auxiliary-account=~D~%"
            n (clamsara::%host-object-storage plan) (clamsara::%host-object-storage barrier)
            (clamsara::%host-object-storage context)
            (clamsara::%host-object-storage (clamsara::%context-barrier-reservations context))
            (clamsara::%host-object-storage (clamsara::%context-barrier-reserved-p context))
            (clamsara::%resource-state-auxiliary-bytes state))
    ;; Exact identity/count checks, not a guessed byte formula or a claim that
    ;; the post-bind context belongs to the frozen construction account.
    (values)))

(defvar *before-extra-cases* *cases*)
(defvar *before-extra-failures* *failures*)
(dolist (phase '(:reserve :admit :transform))
  (dolist (mode '(:invalid :error :throw)) (test-illegal-phase phase mode)))
(dolist (mode '(:error :throw))
  (dolist (position '(2 1)) (test-cancel-fault mode position)))
(dolist (phase '(:reserve :admit :transform :before :after :cancel :raw-load :comparison :raw-store))
  (test-caught-nested-fatal phase))
(dolist (algorithm '(:semispace :marksweep))
  (dolist (phase '(:reserve :admit :transform :before :after))
    (dolist (mode '(:raw :refill)) (test-ordinary-pin algorithm phase mode))))
(dolist (phase '(:reserve :admit :transform :before :after))
  (dolist (mode '(:register :cancel-finalizer :drain)) (test-ordinary-pin :semispace phase mode)))
(test-nil-token :read :match)
(test-nil-token :cas :mismatch)
(extra-one :fixed-workspace-account (three-rules :read)
  (lambda (w source old new)
    (let ((reservations (clamsara::%context-barrier-reservations (world-context w)))
          (owned (clamsara::%context-barrier-reserved-p (world-context w))))
      (measure-workspace w)
      (check-completion w source :read old new)
      (check (and (eq reservations (clamsara::%context-barrier-reservations (world-context w)))
                  (eq owned (clamsara::%context-barrier-reserved-p (world-context w))))
             "Invocation replaced fixed workspace")
      (check (zerop (clamsara::%plan-barrier-pin-count (world-plan w))) "Workspace control leaked plan pin"))))

(extra-one :fatal-shutdown-reject-not-retained (three-rules :read)
  (lambda (w source old new)
    (setf (rule-action (first *rules*)) :error (rule-phase (first *rules*)) :before)
    (check (eq (attempt-invoke w source :read old new) :post-publication-failure) "Missing fatal diagnostic")
    (let* ((configuration (world-configuration w))
           (construction (configuration-construction-context configuration))
           (config-state (clamsara::%configuration-state configuration))
           (construction-state (clamsara::%context-state construction))
           (release-index (clamsara::%configuration-shutdown-release-index configuration))
           (unbound (unbind-mutator configuration (world-context w)))
           (reason nil)
           (outcome
             (handler-case
                 (multiple-value-bind (status why) (shutdown-configuration configuration)
                   (declare (ignore why)) status)
               (clamsara::runtime-rejection (condition)
                 (setf reason (clamsara::runtime-rejection-reason condition)) :rejected))))
      (format t "~&FATAL-SHUTDOWN-EXACT outcome=~S reason=~S unbind=~S config=~S->~S construction=~S->~S release=~D->~D~%"
              outcome reason unbound config-state (clamsara::%configuration-state configuration)
              construction-state (clamsara::%context-state construction)
              release-index (clamsara::%configuration-shutdown-release-index configuration))
      (check (and (eq outcome :rejected) (eq reason :fatal-invariant))
             "Irrecoverable fatal shutdown must reject, not return a recoverable retained result")
      (check (eq config-state (clamsara::%configuration-state configuration)) "Rejected shutdown changed configuration state")
      (check (eq construction-state (clamsara::%context-state construction)) "Rejected shutdown changed construction state")
      (check (= release-index (clamsara::%configuration-shutdown-release-index configuration)) "Fatal rejection released resources")
      (check (clamsara::simulator-provider-token-active-p (world-root-token w)) "Fatal rejection retired roots")
      (check-fatal-state w))) :fatal t)

(format t "~&EXTRA-SUMMARY cases=~D failures=~D total-cases=~D total-failures=~D retained-fatal=~D~%"
        (- *cases* *before-extra-cases*) (- *failures* *before-extra-failures*)
        *cases* *failures* (length *expected-fatal-worlds*))
(check (zerop *failures*) "Fixed-repair independent acceptance failed")
