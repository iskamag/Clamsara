;;;; test/barrier/barrier.lisp
;;;; Native adversarial tests for the composed v14 barrier driver.
;;;; Fixtures author contribution behavior; they do not replace the runtime
;;;; barrier or provide fallback operations.

(defpackage #:clamsara.barrier.test
  (:use #:cl #:clamsara)
  (:export #:run-v14-barrier-contracts))

(in-package #:clamsara.barrier.test)

(defun %assert (condition format-control &rest args)
  (unless condition (error "v14 barrier contract failure: ~?" format-control args))
  t)

(defclass test-barrier-model ()
  ((value :initarg :value :accessor test-model-value)
   (loads :initform 0 :accessor test-model-loads)
   (stores :initform 0 :accessor test-model-stores)
   (store-values :initform nil :accessor test-model-store-values)))

(defmethod load-reference ((model test-barrier-model) location &optional order)
  (declare (ignore location order))
  (incf (test-model-loads model))
  (test-model-value model))
(defmethod store-reference-raw
    ((model test-barrier-model) location value &optional order)
  (declare (ignore location order))
  (incf (test-model-stores model))
  (push value (test-model-store-values model))
  (setf (test-model-value model) value))
(defmethod reference-encoding-equal-p
    ((model test-barrier-model) left right)
  (declare (ignore model))
  (eql left right))

(defstruct (test-reservation (:constructor %make-test-reservation
                              (contribution operation)))
  contribution operation)

(defvar *barrier-global-events* nil)

(defclass test-contribution ()
  ((name :initarg :name :reader test-contribution-name)
   (reserve-status :initarg :reserve-status :initform :ready
                   :accessor test-reserve-status)
   (admit-status :initarg :admit-status :initform :complete
                 :accessor test-admit-status)
   (transform-status :initarg :transform-status :initform :complete
                     :accessor test-transform-status)
   (transformer :initarg :transformer :initform nil
                :accessor test-transformer)
   (log :initform nil :accessor test-contribution-log)
   ;; A well-behaved contribution never retains a borrowed location.
   (retained-location :initform nil
                      :accessor test-retained-location)))

(defun %event (contribution kind &rest data)
  (let ((event (cons kind (cons (test-contribution-name contribution) data))))
    (push event (test-contribution-log contribution))
    (push event *barrier-global-events*)))
(defun %events (contribution)
  (nreverse (copy-list (test-contribution-log contribution))))
(defun %make-contribution (name &key (reserve-status :ready)
                                      (admit-status :complete)
                                      (transform-status :complete)
                                      transformer)
  (make-instance 'test-contribution :name name
                 :reserve-status reserve-status :admit-status admit-status
                 :transform-status transform-status :transformer transformer))

(defmethod barrier-contribution-reserve
    ((contribution test-contribution) context operation location)
  (declare (ignore context location))
  (%event contribution :reserve operation)
  (if (eq :ready (test-reserve-status contribution))
      (values (%make-test-reservation contribution operation) :ready)
      (values nil (test-reserve-status contribution))))
(defmethod barrier-contribution-admit
    ((contribution test-contribution) reservation context operation location)
  (declare (ignore reservation context location))
  (%event contribution :admit operation)
  (values (test-admit-status contribution)))
(defmethod barrier-contribution-transform
    ((contribution test-contribution) reservation context operation location old candidate)
  (declare (ignore reservation context location))
  (%event contribution :transform operation old candidate)
  (if (eq :complete (test-transform-status contribution))
      (values (if (test-transformer contribution)
                  (funcall (test-transformer contribution) old candidate)
                  candidate)
              :complete)
      (values nil (test-transform-status contribution))))
(defmethod barrier-contribution-before-exposure
    ((contribution test-contribution) reservation context operation location old final)
  (declare (ignore reservation context))
  (%event contribution :before operation old final)
  ;; Deliberately no assignment to RETAINED-LOCATION: LOCATION is borrowed.
  (values))
(defmethod barrier-contribution-after-exposure
    ((contribution test-contribution) reservation context operation location old final)
  (declare (ignore reservation context))
  (%event contribution :after operation old final)
  (values))
(defmethod barrier-contribution-cancel
    ((contribution test-contribution) reservation)
  (%event contribution :cancel
          (test-reservation-operation reservation))
  (values))

(defun %facts (events policy)
  (list :events events :needs-old-p t :needs-new-p t
        :replacement-policy policy))

(defun %barrier (model contributions facts)
  (clamsara::make-composed-barrier
   (coerce contributions 'vector) (coerce facts 'vector) model))
(defun %context (count)
  (make-instance 'clamsara::sequential-execution-context
                 :configuration nil :plan nil :execution :test
                 :allocation-domain :test :allocator nil :generation 1
                 :barrier-reservations (make-array count :initial-element nil)
                 :barrier-reserved-p (make-array count :initial-element nil)))
(defun %kinds (events contributions)
  (mapcar (lambda (contribution)
            (%facts events
                    (or (getf (getf contribution :options) :policy)
                        :observe)))
          contributions))
(defun %all-events (contribution kind)
  (remove-if-not (lambda (event) (eq kind (car event)))
                 (%events contribution)))
(defun %count-events (contribution kind)
  (length (%all-events contribution kind)))

(defun test-store-order-and-observe-final ()
  (let* ((model (make-instance 'test-barrier-model :value 0))
         (first (%make-contribution :first
                                    :transformer (lambda (old candidate)
                                                   (declare (ignore old))
                                                   (1+ candidate))))
         (second (%make-contribution :second
                                     :transformer (lambda (old candidate)
                                                    (declare (ignore old))
                                                    (* 2 candidate))))
         (observer (%make-contribution :observer))
         (barrier (%barrier
                   model (list first second observer)
                   (list (%facts '(:store) :transform)
                         (%facts '(:store) :transform)
                         (%facts '(:store) :observe-final))))
         (context (%context 3)))
    (multiple-value-bind (effective status)
        (barrier-store barrier context :location 3)
      (%assert (and (= effective 8) (eq status :stored))
               "transform chain returned ~S/~S" effective status))
    (%assert (= 1 (test-model-loads model)) "store loaded raw value more than once")
    (%assert (= 1 (test-model-stores model)) "store exposed more than one raw write")
    (%assert (= 8 (test-model-value model)) "store did not publish final value")
    (dolist (contribution (list first second observer))
      (%assert (= 1 (%count-events contribution :reserve))
               "~S reserve count wrong" (test-contribution-name contribution))
      (%assert (= 1 (%count-events contribution :admit))
               "~S admit count wrong" (test-contribution-name contribution))
      (%assert (= 1 (%count-events contribution :before))
               "~S before exposure count wrong" (test-contribution-name contribution))
      (%assert (= 1 (%count-events contribution :after))
               "~S after exposure count wrong" (test-contribution-name contribution))
      (%assert (null (test-retained-location contribution))
               "~S retained a borrowed location" (test-contribution-name contribution)))
    ;; Transformer order is contribution order.  The observer sees the final
    ;; transformed candidate but is not itself called as a transformer.
    (%assert (= 1 (%count-events first :transform)) "first transformer did not run")
    (%assert (= 1 (%count-events second :transform)) "second transformer did not run")
    (%assert (zerop (%count-events observer :transform))
             "observe-final contribution transformed")
    (%assert (= 8 (fifth (first (%all-events observer :before))))
             "observer did not see final candidate")
    (%assert (every #'null (coerce (slot-value context
                                               'clamsara::barrier-reserved-p)
                                   'list))
             "reservation ownership remained after success")
    t))

(defun test-store-retry-and-reverse-cancellation ()
  ;; Reservation failure: only the prior successful reservation is cancelled.
  (let* ((model (make-instance 'test-barrier-model :value :old))
         (first (%make-contribution :first))
         (second (%make-contribution :second :reserve-status :retry))
         (barrier (%barrier model (list first second)
                            (list (%facts '(:store) :observe)
                                  (%facts '(:store) :observe))))
         (context (%context 2)))
    (setf *barrier-global-events* nil)
    (multiple-value-bind (effective status)
        (barrier-store barrier context :location :reserve-retry)
      (%assert (and (null effective) (eq status :retry)) "reserve retry failed"))
    (%assert (= 1 (%count-events first :cancel)) "prior reservation not cancelled")
    (%assert (zerop (%count-events second :cancel)) "unowned reservation cancelled")
    (%assert (zerop (test-model-stores model)) "reserve retry wrote raw storage"))
  ;; Admission failure cancels all admitted reservations in reverse order.
  (let* ((model (make-instance 'test-barrier-model :value :old))
         (first (%make-contribution :first))
         (second (%make-contribution :second :admit-status :retry))
         (barrier (%barrier model (list first second)
                            (list (%facts '(:store) :observe)
                                  (%facts '(:store) :observe))))
         (context (%context 2)))
    (setf *barrier-global-events* nil)
    (multiple-value-bind (effective status)
        (barrier-store barrier context :location :admit-retry)
      (%assert (and (null effective) (eq status :retry)) "admit retry failed"))
    (%assert (= 1 (%count-events first :cancel)) "first admission not cancelled")
    (%assert (= 1 (%count-events second :cancel)) "second admission not cancelled")
    (let ((cancels (remove-if-not (lambda (event) (eq :cancel (car event)))
                                  (nreverse (copy-list *barrier-global-events*)))))
      (%assert (equal (mapcar #'second cancels) '(:second :first))
               "admission cancellation was not reverse order: ~S"
               (mapcar #'second cancels)))
    (%assert (zerop (test-model-stores model)) "admit retry wrote raw storage"))
  ;; Transformer failure occurs after one raw read, but before exposure/store.
  (let* ((model (make-instance 'test-barrier-model :value :old))
         (first (%make-contribution :first))
         (second (%make-contribution :second :transform-status :retry))
         (barrier (%barrier model (list first second)
                            (list (%facts '(:store) :transform)
                                  (%facts '(:store) :transform))))
         (context (%context 2)))
    (setf *barrier-global-events* nil)
    (multiple-value-bind (effective status)
        (barrier-store barrier context :location :transform-retry)
      (%assert (and (null effective) (eq status :retry)) "transform retry failed"))
    (%assert (= 1 (test-model-loads model)) "transform retry did not read once")
    (%assert (zerop (test-model-stores model)) "transform retry wrote storage")
    (%assert (= 1 (%count-events first :cancel)) "transform first not cancelled")
    (%assert (= 1 (%count-events second :cancel)) "transform second not cancelled"))
  ;; Busy admission cancels all reservations and performs no load/store.
  (let* ((model (make-instance 'test-barrier-model :value :old))
         (first (%make-contribution :first))
         (second (%make-contribution :second))
         (barrier (%barrier model (list first second)
                            (list (%facts '(:store) :observe)
                                  (%facts '(:store) :observe))))
         (context (%context 2)))
    (setf *barrier-global-events* nil
          (slot-value barrier 'clamsara::busy-p) t)
    (multiple-value-bind (effective status)
        (barrier-store barrier context :location :busy)
      (%assert (and (null effective) (eq status :retry)) "busy path did not retry"))
    (setf (slot-value barrier 'clamsara::busy-p) nil)
    (%assert (zerop (test-model-loads model)) "busy retry loaded raw value")
    (%assert (zerop (test-model-stores model)) "busy retry wrote raw value")
    (%assert (= 1 (%count-events first :cancel)) "busy first not cancelled")
    (%assert (= 1 (%count-events second :cancel)) "busy second not cancelled")
    (let ((cancels (remove-if-not (lambda (event) (eq :cancel (car event)))
                                  (nreverse (copy-list *barrier-global-events*)))))
      (%assert (equal (mapcar #'second cancels) '(:second :first))
               "busy cancellation was not reverse order")))
  t)

(defun test-cas-mismatch-and-success ()
  ;; A mismatch commits only the read path and cancels the write reservation.
  (let* ((model (make-instance 'test-barrier-model :value :actual))
         (read (%make-contribution :read))
         (write (%make-contribution :write))
         (barrier (%barrier model (list read write)
                            (list (%facts '(:read) :observe)
                                  (%facts '(:cas) :observe))))
         (context (%context 2)))
    (multiple-value-bind (observed success status)
        (barrier-compare-exchange barrier context :location :expected :new)
      (%assert (and (eq observed :actual) (null success) (eq status :complete))
               "CAS mismatch returned ~S/~S/~S" observed success status))
    (%assert (eq :actual (test-model-value model)) "CAS mismatch changed value")
    (%assert (zerop (test-model-stores model)) "CAS mismatch wrote storage")
    (%assert (= 1 (%count-events read :before)) "CAS mismatch skipped read before")
    (%assert (= 1 (%count-events read :after)) "CAS mismatch skipped read after")
    (%assert (zerop (%count-events write :before)) "CAS mismatch exposed write")
    (%assert (= 1 (%count-events write :cancel)) "CAS mismatch did not cancel write")
    (%assert (null (test-retained-location read)) "read callback retained location")
    (%assert (null (test-retained-location write)) "write callback retained location"))
  ;; A matched CAS invokes read and write exposure once and stores once.
  (let* ((model (make-instance 'test-barrier-model :value :actual))
         (read (%make-contribution :read))
         (write (%make-contribution :write))
         (barrier (%barrier model (list read write)
                            (list (%facts '(:read) :observe)
                                  (%facts '(:cas) :observe))))
         (context (%context 2)))
    (multiple-value-bind (observed success status)
        (barrier-compare-exchange barrier context :location :actual :new)
      (%assert (and (eq observed :actual) success (eq status :complete))
               "CAS success returned ~S/~S/~S" observed success status))
    (%assert (eq :new (test-model-value model)) "CAS success did not store")
    (%assert (= 1 (test-model-stores model)) "CAS success stored more than once")
    (%assert (= 1 (%count-events read :before)) "CAS success read before count")
    (%assert (= 1 (%count-events read :after)) "CAS success read after count")
    (%assert (= 1 (%count-events write :before)) "CAS success write before count")
    (%assert (= 1 (%count-events write :after)) "CAS success write after count"))
  t)

(defun test-root-store-primitive-route ()
  (let* ((model (make-instance 'test-barrier-model :value :unused))
         (root (make-instance 'clamsara::simulator-root-location))
         (contribution (%make-contribution :root
                                           :transformer
                                           (lambda (old candidate)
                                             (declare (ignore old))
                                             (list :effective candidate))))
         (barrier (%barrier model (list contribution)
                            (list (%facts '(:root-store) :transform))))
         (context (%context 1)))
    (setf (clamsara::host-root-value root) :old-root)
    (multiple-value-bind (effective status)
        ;; ROOT-PROVIDER-STORE reaches this exact internal primitive with
        ;; operation :ROOT-STORE after runtime admission.  Calling it directly
        ;; isolates the route without fabricating provider/runtime state.
        (clamsara::%barrier-store-operation
         barrier context root :new-root :root-store)
      (%assert (and (equal effective '(:effective :new-root))
                    (eq status :stored))
               "root-store primitive returned ~S/~S" effective status))
    (%assert (equal (clamsara::host-root-value root)
                    '(:effective :new-root))
             "root-store primitive bypassed host location")
    (%assert (= 1 (%count-events contribution :before))
             "root-store omitted before exposure")
    (%assert (= 1 (%count-events contribution :after))
             "root-store omitted after exposure")
    (%assert (null (test-retained-location contribution))
             "root-store callback retained location")
    t))


(defun test-root-provider-store-admitted-runtime-context ()
  ;; Build a minimal but real admitted runtime context through BIND-MUTATOR,
  ;; then use the public ROOT-PROVIDER-STORE entry on an ordinary simulator
  ;; provider location.  No direct raw host write is used here.
  (let* ((root-client (clamsara::make-simulator-root-client
                       :provider-capacity 1))
         (provider (clamsara::make-simulator-root-provider 1))
         (provider-token nil)
         (location (clamsara::simulator-root-location provider 0))
         (model (make-instance 'test-barrier-model :value :unused))
         (contribution (%make-contribution :public-root))
         (barrier (%barrier model (list contribution)
                            (list (%facts '(:root-store) :observe))))
         ;; BIND-MUTATOR only needs the admitted route's runtime space and its
         ;; prebound allocator slot.  No allocation is performed by this test.
         (space (make-instance 'clamsara::runtime-space
                               :name :root-store-test :object-start-map nil
                               :extent 128 :packing-quantum 8))
         (plan (make-instance 'clamsara::sequential-runtime-plan
                              :root-client root-client :coordinator nil
                              :diagnostics nil :registry nil :spaces (list space)
                              :trace-capacity 1 :conditional-capacity 0
                              :finalizer-capacity 0 :packing-quantum 8
                              :allocation-routes (list (list :test space :all))
                              :default-algorithm :test :algorithms '(:test)
                              :causes nil :reasons nil :counters nil))
         (configuration (make-instance 'clamsara::%configuration
                                       :plan plan :clients nil :graph nil
                                       :component-order nil))
         (context nil))
    (setf (clamsara::%plan-configuration plan) configuration
          (clamsara::%plan-state plan) :open
          (clamsara::%configuration-barrier configuration) barrier
          (clamsara::%configuration-barrier-bound-p configuration) t)
    (setf provider-token
          (register-root-provider root-client :ordinary-runtime 1 provider))
    (unwind-protect
         (progn
           (setf context (bind-mutator configuration :execution :test))
           (setf (clamsara::host-root-value location) :old-root)
           (multiple-value-bind (effective status)
               (root-provider-store root-client context provider-token location
                                    :new-root)
             (%assert (and (eq effective :new-root) (eq status :stored))
                      "ordinary root-provider-store returned ~S/~S"
                      effective status))
           (%assert (eq :new-root
                        (root-provider-load root-client provider-token location))
                    "ordinary root-provider-store did not publish root")
           (%assert (= 1 (%count-events contribution :before))
                    "ordinary root-store skipped before exposure")
           (%assert (= 1 (%count-events contribution :after))
                    "ordinary root-store skipped after exposure")
           (%assert (null (test-retained-location contribution))
                    "ordinary root-store callback retained location"))
      (when context (unbind-mutator configuration context))
      (when provider-token
        (unregister-root-provider root-client provider-token)))
    t))

(defun run-v14-barrier-contracts ()
  (test-store-order-and-observe-final)
  (test-store-retry-and-reverse-cancellation)
  (test-cas-mismatch-and-success)
  (test-root-store-primitive-route)
  (test-root-provider-store-admitted-runtime-context)
  (values t :complete))
