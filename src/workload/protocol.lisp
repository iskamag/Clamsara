;;;; src/workload/protocol.lisp -- Maclina/client workload boundary.
;;;;
;;;; This file owns the workload adapter, not the v14 protocol.  It never
;;;; supplies a method for an unbound client operation and it never treats an
;;;; SBCL object as a managed reference.  A concrete hosted client supplies
;;;; the configuration, root client/provider, and opaque object-kind
;;;; descriptions at setup time.

(in-package #:clamsara)

(define-condition workload-error (error)
  ((operation :initarg :operation :reader workload-error-operation)
   (reason :initarg :reason :reader workload-error-reason))
  (:report (lambda (condition stream)
             (format stream "workload ~A failed: ~A"
                     (workload-error-operation condition)
                     (workload-error-reason condition)))))

(define-condition workload-capability-error (workload-error) ())
(define-condition workload-allocation-error (workload-error) ())

(defstruct (workload-kind
            (:constructor %make-workload-kind
                (name description bytes alignment &optional element-type)))
  "One construction-time kind offer used by the workload adapter.

DESCRIPTION is opaque to this adapter.  BYTES and ALIGNMENT are either
positive integers or setup-time functions accepting a slot/element count.
The adapter asks OBJECT-KIND-DESCRIPTOR for the corresponding allocation
descriptor immediately before an allocation; it never infers layout from a
host class or scans payload words."
  (name nil :type symbol)
  description
  bytes
  alignment
  (element-type nil))

(defun make-workload-kind (name description bytes alignment &key element-type)
  "Create a workload kind from an already admitted opaque description.
This constructor performs no binding and is intended for setup only."
  (unless (and (symbolp name) description)
    (error 'workload-capability-error :operation 'make-workload-kind
           :reason (list :invalid-kind name)))
  (labels ((positive (value what)
             (unless (or (and (integerp value) (plusp value))
                         (functionp value))
               (error 'workload-capability-error :operation 'make-workload-kind
                      :reason (list what value)))
             value))
    (%make-workload-kind name description
                         (positive bytes :bytes)
                         (positive alignment :alignment)
                         element-type)))

(defclass workload-environment ()
  ((configuration :initarg :configuration :reader workload-configuration)
   (model :initarg :model :reader workload-model)
   (barrier :initarg :barrier :reader workload-barrier)
   (root-client :initarg :root-client :reader workload-root-client)
   (root-provider :initarg :root-provider :reader workload-root-provider)
   (root-token :initarg :root-token :reader workload-root-token)
   ;; Physical location tokens are supplied by the registered provider.  They
   ;; are never created while source code executes.
   (root-locations :initarg :root-locations :reader workload-root-locations)
   (execution :initarg :execution :reader workload-execution)
   (allocation-domain :initarg :allocation-domain
                      :reader workload-allocation-domain)
   (context :initarg :context :reader workload-context)
   (kinds :initarg :kinds :reader workload-kinds)
   (word-bytes :initarg :word-bytes :initform 8 :reader workload-word-bytes)
   (array-header-bytes :initarg :array-header-bytes :initform 0
                       :reader workload-array-header-bytes)
   (stack-size :initarg :stack-size :initform 65536 :reader workload-stack-size)
   ;; The Maclina objects are deliberately opaque to this API.  The concrete
   ;; interpreter file fills these slots after installing its environment.
   (maclina-client :initform nil :accessor workload-maclina-client)
   (maclina-environment :initform nil :accessor workload-maclina-environment)
   (closed-p :initform nil :accessor workload-closed-p)))

(defun %workload-kind (environment name)
  (or (getf (workload-kinds environment) name)
      (error 'workload-capability-error :operation 'workload-kind
             :reason (list :missing-kind name))))

(defun %positive-size (value count)
  (let ((answer (if (functionp value) (funcall value count) value)))
    (unless (and (integerp answer) (plusp answer))
      (error 'workload-capability-error :operation 'allocation
             :reason (list :invalid-size answer count)))
    answer))

(defun %workload-kind-allocation (environment name count)
  (let* ((kind (%workload-kind environment name))
         (model (workload-model environment))
         (description (workload-kind-description kind))
         (descriptor (object-kind-descriptor model description))
         (bytes (%positive-size (workload-kind-bytes kind) count))
         (alignment (%positive-size (workload-kind-alignment kind) count)))
    (values description bytes alignment descriptor)))

(defun %require-open (environment operation)
  (when (workload-closed-p environment)
    (error 'workload-error :operation operation :reason :closed))
  environment)

(defun %configuration-slot (configuration generic operation)
  (handler-case
      (funcall generic configuration)
    (undefined-function ()
      (error 'workload-capability-error :operation operation
             :reason :missing-configuration-method))))

(defun make-workload-environment
    (configuration &key execution allocation-domain root-client root-provider
                            root-token root-locations (root-capacity 4096) kinds
                            (word-bytes 8) (array-header-bytes 0)
                            (stack-size 65536))
  "Bind one Maclina workload context to an admitted v14 configuration.

The root provider/token are required physical root coverage.  This function
never creates a hidden root vector.  If ROOT-TOKEN is NIL, ROOT-PROVIDER must
be a provider already accepted by ROOT-CLIENT and this function signals rather
than guessing how registration works.  KINDS is a property list mapping
:CONS, :ARRAY, :STRUCT, :SYMBOL and any extension names to WORKLOAD-KIND
objects.  EXECUTION and ALLOCATION-DOMAIN are the caller's prebound records.
No benchmark source is read or compiled here."
  (declare (ignore root-capacity))
  (unless (and configuration execution allocation-domain root-client
               root-provider root-token root-locations)
    (error 'workload-capability-error :operation 'make-workload-environment
           :reason :missing-bound-client-or-root-provider))
  (unless (and (listp kinds) (evenp (length kinds)))
    (error 'workload-capability-error :operation 'make-workload-environment
           :reason :invalid-kinds))
  (let* ((model (%configuration-slot
                 configuration #'configuration-object-model
                 'configuration-object-model))
         (barrier (%configuration-slot
                   configuration #'configuration-barrier
                   'configuration-barrier))
         ;; BIND-MUTATOR is the only operation that turns the caller's
         ;; execution/allocation records into a runtime context.
         (context (bind-mutator configuration execution allocation-domain)))
    (unless context
      (error 'workload-capability-error :operation 'bind-mutator
             :reason :rejected))
    (make-instance 'workload-environment
                   :configuration configuration :model model
                   :barrier barrier :root-client root-client
                   :root-provider root-provider :root-token root-token
                   :root-locations root-locations :execution execution :allocation-domain allocation-domain
                   :context context :kinds kinds :word-bytes word-bytes
                   :array-header-bytes array-header-bytes :stack-size stack-size)))

(defun close-workload-environment (environment)
  "Unbind ENVIRONMENT once.  A stop-owned context reports RETRY explicitly."
  (unless (workload-closed-p environment)
    (let ((status (unbind-mutator (workload-configuration environment)
                                  (workload-context environment))))
      (case status
        ((:unbound :already-unbound)
         (setf (workload-closed-p environment) t)
         status)
        (:retry
         (error 'workload-error :operation 'unbind-mutator :reason :retry))
        (otherwise
         (error 'workload-error :operation 'unbind-mutator :reason status))))))

(defun %with-slot-location (environment object key function)
  "Borrow one declared slot through the model's indexed host-language seam.

The public mapper remains the collector's complete strong scanner.  A source
AREF/CAR operation must not scan a 500k-element array to find one slot, and it
must not derive an offset from an address.  The simulator model therefore
provides this private, construction-bound resolver:

  (%call-with-simulator-reference-location
     model start :strong identity function)

It validates generation/kind/identity and invokes FUNCTION only while the
location is borrowed.  A missing resolver is a capability error, never a
fallback to guessed indexing."
  (let* ((package (find-package '#:clamsara))
         (name (and package
                     (find-symbol "%CALL-WITH-SIMULATOR-REFERENCE-LOCATION"
                                  package)))
         (resolver (and name (fboundp name) (symbol-function name))))
    (unless resolver
      (error 'workload-capability-error
             :operation 'indexed-reference-location
             :reason :missing-model-resolver))
    (multiple-value-bind (result status reason)
        (funcall resolver (workload-model environment) object :strong key function)
      (case status
        ((:present :complete) result)
        (:stale (error 'workload-error :operation 'indexed-reference-location
                       :reason :stale))
        (:retry (error 'workload-error :operation 'indexed-reference-location
                       :reason :retry))
        (otherwise
         (if (null status)
             result
             (error 'workload-capability-error
                    :operation 'indexed-reference-location
                    :reason (or reason status))))))))

(defun workload-temporary-root-clear (environment index)
  (root-provider-store
   (workload-root-client environment)
   (workload-context environment)
   (workload-root-token environment)
   (aref (workload-root-locations environment) index)
   nil)
  nil)

(defun workload-temporary-root-load (environment index)
  (root-provider-load
   (workload-root-client environment)
   (workload-root-token environment)
   (aref (workload-root-locations environment) index)))

(defun workload-read-slot (environment object key)
  "Read one managed slot through the complete configured read path."
  (%require-open environment 'workload-read-slot)
  (%with-slot-location
   environment object key
   (lambda (location)
     (barrier-read (workload-barrier environment) (workload-context environment)
                   location))))

(defun workload-write-slot (environment object key value)
  "Write one managed slot through the complete configured barrier path."
  (%require-open environment 'workload-write-slot)
  ;; The new value remains in a registered physical root while the indexed
  ;; location is borrowed and the composed barrier runs its slow path.
  (let ((effective nil))
    (multiple-value-prog1
        (progn
          (multiple-value-bind (root-value root-status)
              (root-provider-store
               (workload-root-client environment)
               (workload-context environment)
               (workload-root-token environment)
               (aref (workload-root-locations environment) 0)
               value)
            (unless (eq root-status :stored)
              (error 'workload-error :operation 'root-provider-store
                     :reason root-status))
            (setf effective
                  (%with-slot-location
                   environment object key
                   (lambda (location)
                     (multiple-value-bind (new status)
                         (barrier-store (workload-barrier environment)
                                        (workload-context environment)
                                        location root-value)
                       (case status
                         (:stored new)
                         (:retry
                          (error 'workload-error :operation 'barrier-store
                                 :reason :retry))
                         (otherwise
                          (error 'workload-error :operation 'barrier-store
                                 :reason status))))))))
          effective)
      (root-provider-store
       (workload-root-client environment)
       (workload-context environment)
       (workload-root-token environment)
       (aref (workload-root-locations environment) 0)
       nil))))

(defun workload-reference-p (environment value)
  "Ask the bound model whether VALUE is an admitted reference encoding."
  (valid-reference-p (workload-model environment) value))

(defun workload-allocate (environment kind-name count initial-values)
  "Allocate and initialize a managed object through the v14 route.

INITIAL-VALUES is a proper list of (SLOT-KEY VALUE) entries.  Each key
must be admitted by the installed kind description and each value is written
through WORKLOAD-WRITE-SLOT.  The caller must root every reference in the
list before this function is entered; this function also keeps copies in
registered temporary roots while allocation and barrier writes can move the
object."
  (%require-open environment 'workload-allocate)
  (unless (listp initial-values)
    (error 'workload-capability-error :operation 'workload-allocate
           :reason (list :initial-values-not-list initial-values)))
  (dolist (entry initial-values)
    (unless (and (consp entry) (consp (cdr entry)) (null (cddr entry)))
      (error 'workload-capability-error :operation 'workload-allocate
             :reason (list :invalid-initial-value-entry entry))))
  (unless (<= (+ 2 (length initial-values))
             (length (workload-root-locations environment)))
    (error 'workload-capability-error :operation 'workload-allocate
           :reason (list :root-capacity (length initial-values))))
  (multiple-value-bind (kind bytes alignment descriptor)
      (%workload-kind-allocation environment kind-name count)
    ;; Root initial values before allocation.  Allocation may collect and
    ;; refresh these slots, while the host INITIAL-VALUES list cannot move.
    (unwind-protect
         (progn
           (loop for (key value) in initial-values
                 for index from 2
                 do (%store-temporary-root environment index value))
           (multiple-value-bind (reference status reason)
               (allocate-object (workload-context environment)
                                kind bytes alignment descriptor)
             (unless (eq status :allocated)
               (error 'workload-allocation-error :operation 'allocate-object
                      :reason (or reason status)))
             ;; Slot zero is owned by WORKLOAD-WRITE-SLOT.  Slot one keeps the
             ;; new object alive, and slots two onward retain initialization.
             (%store-temporary-root environment 1 reference)
             (unwind-protect
                  (progn
                    (loop for (key value) in initial-values
                          for index from 2
                          do (workload-write-slot
                              environment
                              (workload-temporary-root-load environment 1)
                              key
                              (workload-temporary-root-load environment index)))
                    (workload-temporary-root-load environment 1))
               (workload-temporary-root-clear environment 1))))
      (loop for index from 2 below (+ 2 (length initial-values))
            do (workload-temporary-root-clear environment index)))))

(defun workload-ensure-reference (environment value)
  (unless (workload-reference-p environment value)
    (error 'workload-capability-error :operation 'workload-ensure-reference
           :reason (list :not-managed-reference value)))
  value)

(export '(workload-error workload-capability-error workload-allocation-error
          workload-kind make-workload-kind workload-environment
          make-workload-environment close-workload-environment
          workload-configuration workload-model workload-barrier
          workload-root-client workload-root-provider workload-root-token
          workload-kind-element-type
          workload-root-locations workload-execution workload-allocation-domain workload-context
          workload-kinds workload-word-bytes workload-array-header-bytes
          workload-stack-size workload-maclina-client workload-maclina-environment
          workload-read-slot workload-write-slot workload-temporary-root-load
          workload-temporary-root-clear workload-reference-p workload-allocate))
