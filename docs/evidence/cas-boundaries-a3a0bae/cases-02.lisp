(defpackage #:clamsara.cascade-probe
  (:use #:cl #:clamsara #:clamsara.quality.support))
(in-package #:clamsara.cascade-probe)
(defvar *rules* nil)
(defvar *trace* nil)
(defvar *trace-count* 0)
(defvar *expected-fatal-worlds* nil)
(defvar *failed-worlds* nil)
(defvar *failures* 0)
(defvar *cases* 0)
(define-condition injected-fault (error) ())
(defclass rule ()
  ((name :initarg :name :reader rule-name)
   (events :initarg :events :reader rule-events)
   (before :initarg :before :initform nil :reader rule-before)
   (active :initform nil :accessor rule-active)
   (action :initform nil :accessor rule-action)
   (acted :initform nil :accessor rule-acted)
   (action-result :initform nil :accessor rule-action-result)
   (condition :initform (make-condition 'injected-fault) :reader rule-condition)))
(defclass broad-rule (rule) ())
(defclass read-event-rule (rule) ())
(defun event (rule phase operation)
  ;; Fixed hosted observer storage. It holds only symbols, never a location
  ;; or managed reference, and does not allocate during the protected call.
  (when (> (+ *trace-count* 3) (length *trace*))
    (error (rule-condition rule)))
  (setf (aref *trace* *trace-count*) phase
        (aref *trace* (+ *trace-count* 1)) (rule-name rule)
        (aref *trace* (+ *trace-count* 2)) operation)
  (incf *trace-count* 3))
(defun trace-rows ()
  ;; Formatting/conversion occurs outside the completed/escaped barrier entry.
  (loop for i from 0 below *trace-count* by 3
        collect (list (aref *trace* i) (aref *trace* (+ i 1))
                      (aref *trace* (+ i 2)))))
(defmethod describe-barrier-contribution ((r rule))
  (values (rule-name r) (copy-list (rule-events r)) nil nil nil
          (copy-list (rule-before r)) nil :observe :retry-before-exposure/fatal-after))
(defun reserve (r op)
  (event r :reserve op)
  (if (rule-active r) (values nil :retry)
      (progn (setf (rule-active r) t) (values r :ready))))
(defun admit (r ctx op loc)
  (event r :admit op)
  (unless (rule-acted r)
    (case (rule-action r)
      (:reenter
       (setf (rule-acted r) t
             (rule-action-result r)
             (nth-value 1
               (barrier-read (configuration-barrier (clamsara::%context-configuration ctx))
                             ctx loc))))
      (:unbind
       (setf (rule-acted r) t
             (rule-action-result r)
             (unbind-mutator (clamsara::%context-configuration ctx) ctx)))))
  :complete)
(defmethod barrier-contribution-reserve ((r broad-rule) ctx op loc)
  (declare (ignore ctx loc)) (reserve r op))
(defmethod barrier-contribution-admit ((r broad-rule) reservation ctx op loc)
  (declare (ignore reservation)) (admit r ctx op loc))
(defmethod barrier-contribution-reserve ((r read-event-rule) ctx (op (eql :read)) loc)
  (declare (ignore ctx loc)) (reserve r op))
(defmethod barrier-contribution-admit ((r read-event-rule) reservation ctx (op (eql :read)) loc)
  (declare (ignore reservation)) (admit r ctx op loc))
(defmethod barrier-contribution-before-exposure ((r rule) reservation ctx op loc old final)
  (declare (ignore reservation ctx loc old final))
  (event r :before op)
  (case (rule-action r)
    (:error (error (rule-condition r)))
    (:throw (throw 'cas-probe-exit :escaped)))
  (values))
(defmethod barrier-contribution-after-exposure ((r rule) reservation ctx op loc old final)
  (declare (ignore reservation ctx loc old final))
  (event r :after op) (setf (rule-active r) nil) (values))
(defmethod barrier-contribution-cancel ((r rule) reservation)
  (declare (ignore reservation))
  (event r :cancel nil) (setf (rule-active r) nil) (values))
(defclass cas-plan (clamsara::semispace-plan)
  ((rules :initarg :rules :reader plan-rules)))
(defmethod component-barrier-contributions ((p cas-plan)) (copy-list (plan-rules p)))
(defmethod clamsara::map-construction-auxiliary-storage ((p cas-plan) f)
  (call-next-method)
  (clamsara::%map-construction-cons-storage (plan-rules p) f)
  (dolist (r (plan-rules p))
    (funcall f r) (funcall f (rule-condition r))
    (clamsara::%map-construction-cons-storage (rule-events r) f)
    (clamsara::%map-construction-cons-storage (rule-before r) f))
  (values))
(defun make-cas-plan (&rest args)
  (change-class (apply #'make-semispace-plan args) 'cas-plan :rules *rules*))
(defun make-cas-world (&key
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
                (make-cas-plan
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
                (make-marksweep-plan
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


(defun rule (name events &optional before exact-read-p)
  (make-instance (if exact-read-p 'read-event-rule 'broad-rule)
                 :name name :events events :before before))
(defun names-at (phase)
  (loop for event in (trace-rows) when (eq (first event) phase)
        collect (second event)))
(defun invoke (w object operation expected new)
  (clamsara.quality.support::%call-node-location w object 1
    (lambda (location)
      (let ((barrier (configuration-barrier (world-configuration w))))
        (ecase operation
          (:read (multiple-value-list (barrier-read barrier (world-context w) location)))
          (:cas (multiple-value-list
                  (barrier-compare-exchange barrier (world-context w) location expected new))))))))
(defun attempt (fn)
  (handler-case (list :returned (catch 'cas-probe-exit (funcall fn)))
    (error (c) (list :signaled (type-of c)))))
(defun one (label rules body)
  (incf *cases*)
  (let ((*rules* rules) (*trace* (make-array 384 :initial-element nil))
        (*trace-count* 0) (w nil))
    (handler-case
        (progn
          (setf w (make-cas-world))
          (let ((source (allocate-node w 301))
                (old (allocate-node w 302))
                (new (allocate-node w 303)))
            (set-world-root w 0 source)
            (set-world-root w 1 old)
            (set-world-root w 2 new)
            (set-node-slot w source 1 old)
            (fill *trace* nil) (setf *trace-count* 0)
            (funcall body w source old new))
          (if (member label '(:mismatch-before-error-sticky
                              :matched-before-throw-sticky
                              :post-fault-allocation-closed))
              (progn
                (check (not (eq (clamsara::%plan-state (world-plan w)) :open))
                       "Expected fatal world is still open")
                (push (list label w) *expected-fatal-worlds*))
              (close-quality-world w))
          (format t "~&CAS-PASS ~S~%" label))
      (error (c)
        (incf *failures*) (push (list label w c (trace-rows)) *failed-worlds*)
        (format t "~&CAS-FAIL ~S ~A~%TRACE ~S~%" label c (trace-rows))))))

(one :global-before-order
     (list (rule :w1 '(:cas) '(:r)) (rule :r '(:read) '(:w2)) (rule :w2 '(:cas)))
     (lambda (w source old new)
       (let ((result (invoke w source :cas old new)))
         (check (and (eq (first result) old) (second result) (eq (third result) :complete))
                "CAS match result changed")
         (check (equal (names-at :before) '(:w1 :r :w2)) "BEFORE order is event-major"))))
(one :reverse-write-only-cancellation
     (list (rule :w1 '(:cas) '(:r)) (rule :r '(:read) '(:w2)) (rule :w2 '(:cas)))
     (lambda (w source old new)
       (declare (ignore old))
       (let ((result (invoke w source :cas nil new)))
         (check (and (null (second result)) (eq (third result) :complete)) "Mismatch result changed")
         (check (equal (names-at :cancel) '(:w2 :w1)) "Mismatch cancellation is not reverse"))))
(one :mismatch-before-error-sticky
     (list (rule :r '(:read)))
     (lambda (w source old new)
       (declare (ignore old))
       (setf (rule-action (first *rules*)) :error)
       (format t "~&MISMATCH-FAULT ~S~%" (attempt (lambda () (invoke w source :cas nil new))))
       (check (clamsara::%barrier-failed-p (configuration-barrier (world-configuration w)))
              "Mismatch exposure fault did not poison barrier")))
(one :matched-before-throw-sticky
     (list (rule :r '(:read)))
     (lambda (w source old new)
       (setf (rule-action (first *rules*)) :throw)
       (format t "~&MATCHED-NLX ~S~%" (attempt (lambda () (invoke w source :cas old new))))
       (check (clamsara::%barrier-failed-p (configuration-barrier (world-configuration w)))
              "Non-error exposure exit did not poison barrier")))
(one :same-context-admit-reentry
     (list (rule :r '(:read)))
     (lambda (w source old new)
       (declare (ignore new))
       (let ((r (first *rules*)))
         (setf (rule-action r) :reenter)
         (let ((result (invoke w source :read nil nil)))
           (check (and (eq (first result) old) (eq (second result) :complete)) "Outer read failed")
           (check (eq (rule-action-result r) :retry) "Nested operation did not retry")
           (check (and (equal (names-at :after) '(:r)) (not (rule-active r)))
                  "Nested entry erased outer scratch/ownership")))))
(one :active-context-unbind
     (list (rule :r '(:read)))
     (lambda (w source old new)
       (declare (ignore old new))
       (let ((r (first *rules*)))
         (setf (rule-action r) :unbind)
         (format t "~&UNBIND-ENTRY ~S~%" (attempt (lambda () (invoke w source :read nil nil))))
         (check (eq (rule-action-result r) :retry) "Active callback context was unbound"))))
(one :post-fault-allocation-closed
     (list (rule :r '(:read)))
     (lambda (w source old new)
       (declare (ignore old))
       (setf (rule-action (first *rules*)) :error)
       (attempt (lambda () (invoke w source :cas nil new)))
       (let ((result (attempt
                      (lambda ()
                        (multiple-value-list
                          (allocate-object (world-context w) :quality-node 32 16
                            (object-kind-descriptor (world-model w) :quality-node)))))))
         (format t "~&POST-FAULT-ALLOCATION ~S~%" (if (eq (first result) :returned)
                                                        (cons :returned (cdr (second result))) result))
         (check (eq (first result) :signaled) "Managed allocation still succeeds after exposure fault"))))
(one :admitted-eql-read-dispatch
     (list (rule :r '(:read) nil t))
     (lambda (w source old new)
       (let ((result (invoke w source :cas old new)))
         (check (and (eq (first result) old) (second result) (eq (third result) :complete))
                "Admitted EQL READ method was not called consistently"))))
(format t "~&CAS-BOUNDARY-SUMMARY cases=~D failures=~D retained=~D~%"
        *cases* *failures* (length *failed-worlds*))
(check (zerop *failures*) "CAS boundary requirements failed")
