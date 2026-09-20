;;;; Explicit hosted resource provisioning and construction-only manifests.
(in-package #:clamsara)

(defclass simulator-clients ()
  ((model :initarg :model :reader construction-object-model)
   (roots :initarg :roots :reader construction-root-client)
   (coordinator :initarg :coordinator :reader construction-stop-coordinator)
   (address-space :initarg :address-space :reader construction-address-space-client)
   (atomics :initarg :atomics :reader construction-atomics-client)
   (diagnostics :initarg :diagnostics :reader construction-diagnostics-client)
   (profile :initarg :profile :reader construction-client-profile)))
(defun make-simulator-clients (&key model roots coordinator address-space atomics diagnostics
                                   (profile :sequential-host))
  (unless (and model roots coordinator address-space atomics diagnostics
               (eq profile :sequential-host))
    (error 'construction-rejected :reason :unsupported-host-clients))
  (make-instance 'simulator-clients :model model :roots roots :coordinator coordinator
                 :address-space address-space :atomics atomics
                 :diagnostics diagnostics :profile profile))

(defstruct (%simulator-resource (:constructor %make-simulator-resource))
  clients construction identity handle physical-padding auxiliary-reserve
  manifest manifest-seen (closed-p nil) (released-p nil))

(defun %host-object-storage (object)
  ;; Construction-only explicit primitive ownership, not arbitrary graph walk.
  #+sbcl
  (cond
    ((or (null object) (typep object 'fixnum) (characterp object)) 0)
    ((typep object 'standard-object)
     (+ (sb-ext:primitive-object-size object)
        (sb-ext:primitive-object-size (sb-pcl::std-instance-slots object))))
    ((hash-table-p object)
     (+ (sb-ext:primitive-object-size object)
        (sb-ext:primitive-object-size (sb-impl::hash-table-pairs object))
        (sb-ext:primitive-object-size (sb-impl::hash-table-index-vector object))
        (sb-ext:primitive-object-size (sb-impl::hash-table-next-vector object))
        (let ((hashes (sb-impl::hash-table-hash-vector object)))
          (if hashes (sb-ext:primitive-object-size hashes) 0))))
    (t (sb-ext:primitive-object-size object)))
  #-sbcl
  (progn (declare (ignore object))
         (error 'construction-rejected :reason :unsupported-host-accounting)))
(defun %host-checked-size (n)
  (unless (typep n '(integer 0 #.most-positive-fixnum))
    (error 'construction-rejected :reason :host-capacity-overflow))
  n)

(defmethod %acquire-construction-resource
    ((clients simulator-clients) construction description placement)
  (unless (and (eq :sequential-host (construction-client-profile clients))
               (null placement)
               (member (%resource-description-allocation-context description)
                       '(:construction :construction-only))
               (member (%resource-description-exhaustion-action description)
                       '(:reject :reject-before-publication)))
    (error 'construction-rejected :reason :unsupported-resource-policy))
  (let* ((entries (%host-checked-size (%resource-description-logical-entry-bound description)))
         (minimum (%host-checked-size (%resource-description-minimum-physical-bytes description)))
         (auxiliary (%host-checked-size (%resource-description-auxiliary-bytes description)))
         (representation (%resource-description-representation description))
         (element-type (case representation
                         (:packed-bit-vector 'bit)
                         ((:scalar-bit-vector :forwarding-vector
                           :runtime-object-vector :runtime-index-vector) t)
                         (otherwise
                          (error 'construction-rejected
                                 :reason :unsupported-resource-representation))))
         (initial (case representation
                    ((:forwarding-vector :runtime-object-vector) nil)
                    (otherwise 0))))
    (%host-checked-size (+ minimum auxiliary (* entries (if (eq element-type 'bit) 1 8))))
    ;; All allocation is still private. Signaling retains no installed state.
    (let* ((handle (make-array entries :element-type element-type :initial-element initial))
           (handle-bytes (%host-object-storage handle))
           (padding (when (> minimum handle-bytes)
                      (make-array (- minimum handle-bytes)
                                  :element-type '(unsigned-byte 8) :initial-element 0)))
           (reserve (make-array auxiliary :element-type '(unsigned-byte 8) :initial-element 0))
           (capability (%make-simulator-resource
                        :clients clients :construction construction
                        :identity (%resource-description-identity description)
                        :handle handle :physical-padding padding
                        :auxiliary-reserve reserve
                        :manifest-seen (make-hash-table :test #'eq))))
      (values handle (+ handle-bytes (if padding (%host-object-storage padding) 0))
              entries (+ (%host-object-storage reserve) (%host-object-storage capability))
              capability))))

(defun %register-resource-auxiliary (construction identity object)
  (let* ((state (gethash identity (%context-resources construction)))
         (resource (and state (%resource-state-release-capability state))))
    (unless (and (eq :building (%context-state construction))
                 (%simulator-resource-p resource)
                 (not (%simulator-resource-closed-p resource))
                 (not (%simulator-resource-released-p resource)))
      (error 'construction-rejected :reason :auxiliary-registration-closed))
    (unless (or (eq object (%simulator-resource-handle resource))
                (gethash object (%simulator-resource-manifest-seen resource)))
      (setf (gethash object (%simulator-resource-manifest-seen resource)) t)
      (push object (%simulator-resource-manifest resource)))
    object))

(defun %close-resource-manifests (construction)
  ;; Called after all initialization, before validation and immutable account.
  ;; Lists used while constructing the manifest are replaced with its fixed
  ;; representation. Entries do not traverse or grow this manifest at runtime.
  (let ((owners (make-hash-table :test #'eq)))
    (maphash
     (lambda (identity state)
       (let ((resource (%resource-state-release-capability state)))
         (when (%simulator-resource-p resource)
           (dolist (object (list (%simulator-resource-handle resource)
                                 (%simulator-resource-physical-padding resource)
                                 (%simulator-resource-auxiliary-reserve resource)
                                 resource))
             (when object
               (multiple-value-bind (owner present-p) (gethash object owners)
                 (when (and present-p (not (eql identity owner)))
                   (error 'construction-rejected :reason :duplicate-resource-storage))
                 (setf (gethash object owners) identity)))))))
     (%context-resources construction))
    (maphash
     (lambda (identity state)
       (let ((resource (%resource-state-release-capability state)))
         (when (%simulator-resource-p resource)
           (unless (%simulator-resource-closed-p resource)
             (let* ((manifest (coerce (nreverse (%simulator-resource-manifest resource))
                                      'simple-vector))
                    (auxiliary (+ (%host-object-storage resource)
                                  (%host-object-storage manifest)
                                  (%host-object-storage
                                   (%simulator-resource-auxiliary-reserve resource)))))
               (dotimes (i (length manifest))
                 (let ((object (aref manifest i)))
                   (multiple-value-bind (owner present-p) (gethash object owners)
                     (when (and present-p (not (eql identity owner)))
                       (error 'construction-rejected :reason :duplicate-resource-storage))
                     (unless present-p
                       (setf (gethash object owners) identity)
                       (incf auxiliary (%host-object-storage object))))))
               (%host-checked-size auxiliary)
               (setf (%simulator-resource-manifest resource) manifest
                     ;; Dedup scratch is construction-only and no longer retained.
                     (%simulator-resource-manifest-seen resource) nil
                     (%simulator-resource-closed-p resource) t
                     (%resource-state-auxiliary-bytes state) auxiliary))))))
     (%context-resources construction)))
  (values))

(defmethod %release-acquired-construction-resource
    ((clients simulator-clients) (resource %simulator-resource))
  (unless (eq clients (%simulator-resource-clients resource))
    (error 'construction-rejected :reason :foreign-resource-release))
  (unless (%simulator-resource-released-p resource)
    (setf (%simulator-resource-released-p resource) t
          (%simulator-resource-handle resource) nil
          (%simulator-resource-manifest resource) nil
          (%simulator-resource-manifest-seen resource) nil
          (%simulator-resource-physical-padding resource) nil
          (%simulator-resource-auxiliary-reserve resource) nil))
  (values))
