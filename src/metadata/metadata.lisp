;;;; Metadata role and physical-storage protocols.
;;;; This file depends only on the construction protocols and
;;;; the client metadata protocol.  It intentionally does not use the
;;;; legacy src/core/metadata implementation.

(in-package #:clamsara)

;;; -------------------------------------------------------------------------
;;; Conditions and immutable domain geometry.

(define-condition metadata-error (error)
  ((metadata :initarg :metadata :initform nil :reader metadata-error-metadata)
   (key :initarg :key :initform nil :reader metadata-error-key)
   (fact :initarg :fact :initform nil :reader metadata-error-fact)))

(define-condition metadata-invalid (metadata-error) ())
(define-condition metadata-key-error (metadata-error) ())
(define-condition metadata-capacity-error (metadata-error) ())
(define-condition metadata-operation-error (metadata-error) ())
(define-condition metadata-alias-error (metadata-error) ())

(defclass metadata-domain ()
  ((base :initarg :base :reader metadata-domain-base)
   (limit :initarg :limit :reader metadata-domain-limit)
   (granularity :initarg :granularity :reader metadata-domain-granularity)
   (addressed-p :initarg :addressed-p :initform t
                 :reader metadata-domain-addressed-p)
   (placement-identity :initarg :placement-identity :initform nil
                       :reader metadata-domain-placement-identity)
   (key-function :initarg :key-function :initform nil
                 :reader metadata-domain-key-function)))

(defun make-metadata-domain (&key base limit granularity (addressed-p t)
                                  placement-identity key-function)
  "Make immutable finite metadata geometry.

BASE and LIMIT are the byte-address extent for an addressed domain.  For an
ordinal domain they are still nonnegative integer cell ordinals; no object
address is guessed by this class.  KEY-FUNCTION, when supplied, maps a cell
index to the provider's canonical key and is used only for traversal."
  (unless (and (integerp granularity) (> granularity 0)
               (if placement-identity (or (null base) (and (integerp base) (>= base 0))) (integerp base))
               (if placement-identity (or (null limit) (and (integerp limit) (>= limit 0)))
                   (and (integerp limit) (<= 0 base limit))))
    (error 'metadata-invalid :fact (list :bad-domain base limit granularity placement-identity)))
  (unless (or (null key-function) (functionp key-function))
    (error 'metadata-invalid :fact (list :bad-key-function key-function)))
  (unless (or placement-identity (and (integerp base) (integerp limit)))
    (error 'metadata-invalid :fact :unresolved-domain-needs-placement-identity))
  (make-instance 'metadata-domain :base base :limit limit
                 :granularity granularity :addressed-p addressed-p
                 :placement-identity placement-identity :key-function key-function))

(defun %domain-cell-count (domain)
  (let ((base (metadata-domain-base domain))
        (limit (metadata-domain-limit domain))
        (g (metadata-domain-granularity domain)))
    (ceiling (- limit base) g)))

(defun %domain-key (domain index)
  (let ((f (metadata-domain-key-function domain)))
    (if f (funcall f index)
        (+ (metadata-domain-base domain)
           (* index (metadata-domain-granularity domain))))))

(defun %valid-domain-p (domain)
  (and (typep domain 'metadata-domain)
       (integerp (metadata-domain-base domain))
       (integerp (metadata-domain-limit domain))
       (integerp (metadata-domain-granularity domain))
       (<= 0 (metadata-domain-base domain)
           (metadata-domain-limit domain))
       (> (metadata-domain-granularity domain) 0)))

;;; -------------------------------------------------------------------------
;;; Logical role protocols.  Role classes are behavioral protocols, not
;;; constructor flags.  Storage classes below supply all physical methods.

(defclass metadata (component)
  ((domain :initarg :domain :reader metadata-domain)
   (initialized-p :initform nil :accessor metadata-initialized-p)
   (generation :initform 0 :accessor metadata-generation)
   (traversal-active-p :initform nil :accessor metadata-traversal-active-p)
   (resource-handle :initform nil :accessor metadata-resource-handle)))

(defclass bit-metadata (metadata) ())
(defclass range-metadata (metadata) ())
(defclass transferable-metadata (metadata) ())
(defclass atomic-metadata (metadata) ())

(defgeneric metadata-bounds (metadata))
(defgeneric metadata-default-value (metadata key))
(defgeneric metadata-value-valid-p (metadata key value))
(defgeneric metadata-value-equal-p (metadata key left right))
(defgeneric metadata-ref (metadata key))
(defgeneric metadata-set (metadata key value))
(defgeneric metadata-cas (metadata key old new))
(defgeneric metadata-reset (metadata key))
(defgeneric metadata-set-bit (metadata key))
(defgeneric metadata-clear-bit (metadata key))
(defgeneric metadata-reset-range (metadata range))
(defgeneric metadata-fold (metadata range function initial-value))
(defgeneric metadata-map-present (metadata range function))
(defgeneric metadata-project (source destination reducer))
(defgeneric metadata-transfer
    (source source-key destination destination-key)
  (:argument-precedence-order destination destination-key source source-key))

;;; Abstract methods signal rather than pretending a protocol is implemented.
(defmethod metadata-bounds ((m metadata))
  (declare (ignore m))
  (error 'metadata-operation-error :fact :metadata-bounds))
(defmethod metadata-default-value ((m metadata) key)
  (error 'metadata-operation-error :metadata m :key key
         :fact :metadata-default-value))
(defmethod metadata-value-valid-p ((m metadata) key value)
  (declare (ignore value))
  (error 'metadata-operation-error :metadata m :key key
         :fact :metadata-value-valid-p))
(defmethod metadata-value-equal-p ((m metadata) key left right)
  (declare (ignore left right))
  (error 'metadata-operation-error :metadata m :key key
         :fact :metadata-value-equal-p))
(defmethod metadata-ref ((m metadata) key)
  (error 'metadata-operation-error :metadata m :key key :fact :metadata-ref))
(defmethod metadata-set ((m metadata) key value)
  (declare (ignore value))
  (error 'metadata-operation-error :metadata m :key key :fact :metadata-set))
(defmethod metadata-cas ((m metadata) key old new)
  (declare (ignore old new))
  (error 'metadata-operation-error :metadata m :key key :fact :metadata-cas))
(defmethod metadata-reset ((m metadata) key)
  (error 'metadata-operation-error :metadata m :key key :fact :metadata-reset))
(defmethod metadata-set-bit ((m bit-metadata) key)
  (let ((old (metadata-ref m key))) (metadata-set m key 1) old))
(defmethod metadata-clear-bit ((m bit-metadata) key)
  (let ((old (metadata-ref m key))) (metadata-set m key 0) old))
(defmethod metadata-reset-range ((m range-metadata) range)
  (declare (ignore range))
  (error 'metadata-operation-error :metadata m :fact :metadata-reset-range))
(defmethod metadata-fold ((m range-metadata) range function initial-value)
  (declare (ignore range function initial-value))
  (error 'metadata-operation-error :metadata m :fact :metadata-fold))
(defmethod metadata-map-present ((m range-metadata) range function)
  (declare (ignore range function))
  (error 'metadata-operation-error :metadata m :fact :metadata-map-present))
(defmethod metadata-project ((source range-metadata) destination reducer)
  (declare (ignore destination reducer))
  (error 'metadata-operation-error :metadata source :fact :metadata-project))
(defmethod metadata-transfer
    ((source transferable-metadata) source-key
     (destination transferable-metadata) destination-key)
  (declare (ignore source source-key destination destination-key))
  (error 'metadata-operation-error :fact :metadata-transfer))

;;; Mark role: the logical meaning lives here and is independent of storage.
(defclass mark-map (bit-metadata transferable-metadata) ())
(defmethod metadata-default-value ((marks mark-map) key)
  (declare (ignore marks key)) 0)
(defmethod metadata-value-valid-p ((marks mark-map) key value)
  (declare (ignore marks key))
  (or (eql value 0) (eql value 1)))
(defmethod metadata-value-equal-p ((marks mark-map) key left right)
  (declare (ignore marks key))
  (eql left right))
(defmethod metadata-reset ((marks mark-map) key)
  (metadata-set marks key 0))
(defmethod metadata-transfer
    ((source mark-map) source-key (destination mark-map) destination-key)
  (metadata-set destination destination-key
                (metadata-ref source source-key))
  destination)

;;; Additional logical roles used by moving spaces.
(defclass object-start-map (mark-map) ())
(defclass forwarding-metadata (range-metadata transferable-metadata) ())
(defmethod metadata-default-value ((m forwarding-metadata) key) (declare (ignore m key)) nil)
(defmethod metadata-value-valid-p ((m forwarding-metadata) key value) (declare (ignore m key value)) t)
(defmethod metadata-value-equal-p ((m forwarding-metadata) key left right) (declare (ignore m key)) (eql left right))
(defmethod metadata-reset ((m forwarding-metadata) key) (metadata-set m key nil))
(defmethod metadata-transfer ((source forwarding-metadata) source-key (destination forwarding-metadata) destination-key)
  (metadata-set destination destination-key (metadata-ref source source-key)) destination)

;;; -------------------------------------------------------------------------
;;; Storage support.

(defclass metadata-storage (metadata)
  ((base :initarg :base :initform nil :reader storage-base)
   (limit :initarg :limit :initform nil :reader storage-limit)
   (granularity :initarg :granularity :initform nil :reader storage-granularity)
   (storage-vector :initarg :vector :initform nil :accessor storage-vector)
   (capacity :initform 0 :accessor storage-capacity)
   (storage-token :initform nil :accessor storage-token)
   (enumerator :initarg :enumerator :initform nil :reader storage-enumerator)
   (keys :initarg :keys :initform nil :reader storage-keys)
   (model :initarg :model :initform nil :reader storage-model)
   (field :initarg :field :initform nil :reader storage-field)
   (atomics :initarg :atomics :initform nil :reader storage-atomics)
   (places :initarg :places :initform nil :reader storage-places)
   (field-description :initform nil :accessor storage-field-description)))

(defclass packed-bit-storage (metadata-storage range-metadata) ())
(defclass scalar-bit-storage (metadata-storage range-metadata) ())
(defclass offered-bit-storage (metadata-storage) ())
(defclass enumerated-offered-bit-storage (offered-bit-storage range-metadata) ())
(defclass side-marks (mark-map packed-bit-storage) ())
(defclass scalar-side-marks (mark-map scalar-bit-storage) ())
(defclass inline-marks (mark-map enumerated-offered-bit-storage) ())
(defclass scalar-inline-marks (mark-map offered-bit-storage) ())
(defclass side-forwarding (forwarding-metadata metadata-storage) ())
(defclass side-forwarding-storage (side-forwarding) ())
(defclass object-start-marks (object-start-map packed-bit-storage) ())
(defclass scalar-object-start-marks (object-start-map scalar-bit-storage) ())

(defun make-side-marks (&rest initargs)
  (apply #'make-instance 'side-marks initargs))
(defun make-scalar-side-marks (&rest initargs)
  (apply #'make-instance 'scalar-side-marks initargs))
(defun make-inline-marks (&rest initargs)
  (apply #'make-instance 'inline-marks initargs))
(defun make-scalar-inline-marks (&rest initargs)
  (apply #'make-instance 'scalar-inline-marks initargs))
(defun make-side-forwarding (&rest initargs) (apply #'make-instance 'side-forwarding initargs))
(defun make-object-start-marks (&rest initargs) (apply #'make-instance 'object-start-marks initargs))
(defun make-scalar-object-start-marks (&rest initargs)
  (apply #'make-instance 'scalar-object-start-marks initargs))

(defun %geometry-from-domain (domain)
  (cond
    ((typep domain 'metadata-domain)
     (values (metadata-domain-base domain) (metadata-domain-limit domain)
             (metadata-domain-granularity domain)))
    ;; A metadata domain is intentionally the only public geometry object;
    ;; accepting a three-element list is useful for construction fixtures and
    ;; does not infer an address interval from a host object.
    ((and (consp domain) (keywordp (car domain)))
     (values (getf domain :base) (getf domain :limit)
             (getf domain :granularity)))
    (t (values nil nil nil))))

(defun %install-geometry (storage)
  (multiple-value-bind (db dl dg) (%geometry-from-domain (metadata-domain storage))
    (let ((b (or (storage-base storage) db))
          (l (or (storage-limit storage) dl))
          (g (or (storage-granularity storage) dg)))
      (when (or (null b) (null l)) (return-from %install-geometry nil))
      (unless (and (integerp b) (integerp l) (integerp g)
                   (<= 0 b l) (> g 0))
        (error 'metadata-invalid :metadata storage
               :fact (list :finite-domain-required b l g)))
      (when (and (storage-base storage) (/= (storage-base storage) b))
        (error 'metadata-invalid :metadata storage :fact :domain-base-mismatch))
      (when (and (storage-limit storage) (/= (storage-limit storage) l))
        (error 'metadata-invalid :metadata storage :fact :domain-limit-mismatch))
      (when (and (storage-granularity storage)
                 (/= (storage-granularity storage) g))
        (error 'metadata-invalid :metadata storage
               :fact :domain-granularity-mismatch))
      (setf (slot-value storage 'base) b
            (slot-value storage 'limit) l
            (slot-value storage 'granularity) g
            (slot-value storage 'domain)
            (or (metadata-domain storage)
                (make-metadata-domain :base b :limit l :granularity g)))
      (values b l g))))

(defun %storage-cell-count (storage)
  (ceiling (- (storage-limit storage) (storage-base storage))
           (storage-granularity storage)))

(defun %provision-storage (storage &key (allocate-p nil))
  (unless (%install-geometry storage) (setf (storage-capacity storage) 0) (return-from %provision-storage storage))
  (let ((n (%storage-cell-count storage)))
    (setf (storage-capacity storage) n)
    (when (and allocate-p (null (storage-vector storage)) (not (typep storage 'offered-bit-storage)))
      (setf (storage-vector storage)
            (cond ((typep storage 'forwarding-metadata) (make-array n :initial-element nil))
                  ((typep storage 'scalar-bit-storage) (make-array n :initial-element 0))
                  (t (make-array n :element-type 'bit :initial-element 0)))))
    (when (and (not (typep storage 'offered-bit-storage)) (storage-vector storage)
               (or (not (arrayp (storage-vector storage))) (< (array-total-size (storage-vector storage)) n)))
      (error 'metadata-capacity-error :metadata storage :fact :insufficient-resource-handle))
    (unless (storage-token storage) (setf (storage-token storage) (or (storage-vector storage) storage)))
    storage))

(defmethod initialize-instance :after ((storage metadata-storage) &key)
  ;; Provisioning is construction-time and all capacity is fixed.  Logical
  ;; defaults are not considered established until INITIALIZE-COMPONENT.
  (%provision-storage storage))

(defmethod metadata-bounds ((storage metadata-storage))
  (values (storage-base storage) (storage-limit storage)
          (storage-granularity storage)))

(defvar *metadata-internal-write* nil)
(defun %ensure-initialized (m)
  (unless (metadata-initialized-p m) (error 'metadata-operation-error :metadata m :fact :not-initialized)) m)
(defun %ensure-writable (m)
  (when (and (metadata-traversal-active-p m) (not *metadata-internal-write*))
    (error 'metadata-operation-error :metadata m :fact :callback-mutation-forbidden)) m)
(defun %begin-traversal (objects)
  (dolist (m objects) (when (metadata-traversal-active-p m) (error 'metadata-operation-error :metadata m :fact :nested-traversal)))
  (dolist (m objects) (setf (metadata-traversal-active-p m) t)))
(defun %end-traversal (objects) (dolist (m objects) (setf (metadata-traversal-active-p m) nil)))

(defun %address-index (storage key)
  (unless (and (integerp key)
               (<= (storage-base storage) key)
               (< key (storage-limit storage)))
    (error 'metadata-key-error :metadata storage :key key
           :fact (list :outside-bounds (storage-base storage)
                       (storage-limit storage))))
  (floor (- key (storage-base storage)) (storage-granularity storage)))

(defun %canonical-key (storage index)
  (+ (storage-base storage) (* index (storage-granularity storage))))

(defun %check-range (storage range)
  (unless (and (consp range) (integerp (car range))
               (integerp (cdr range)))
    (error 'metadata-key-error :metadata storage :key range
           :fact :invalid-range))
  (let ((start (car range)) (end (cdr range))
        (base (storage-base storage)) (limit (storage-limit storage))
        (g (storage-granularity storage)))
    (unless (and (<= base start end limit)
                 (or (= start limit) (= (mod (- start base) g) 0))
                 (or (= end limit) (= (mod (- end base) g) 0)))
      (error 'metadata-key-error :metadata storage :key range
             :fact (list :range-boundary base limit g)))
    (values start end (if (= start end) 0
                          (ceiling (- end start) g)))))

(defun %range-indices (storage range)
  (multiple-value-bind (start end count) (%check-range storage range)
    (declare (ignore end))
    (if (zerop count) nil
        (loop for i from (%address-index storage start)
                below (+ (%address-index storage start) count) collect i))))

(defun %ensure-logical-value (m key value)
  (unless (metadata-value-valid-p m key value)
    (error 'metadata-key-error :metadata m :key key
           :fact (list :invalid-value value)))
  value)

(defun %bump-generation (m)
  (incf (metadata-generation m)))

;;; Physical vector methods.  A packed bit vector is accessed cell-wise, so a
;;; write cannot alter neighboring bits.  Concurrent users are not admitted
;;; because these classes do not promise ATOMIC-METADATA.
(defmethod metadata-ref ((storage packed-bit-storage) key)
  (%ensure-initialized storage)
  (sbit (storage-vector storage) (%address-index storage key)))
(defmethod metadata-set ((storage packed-bit-storage) key value)
  (%ensure-initialized storage) (%ensure-writable storage)
  (%ensure-logical-value storage key value)
  (let ((i (%address-index storage key)))
    (setf (sbit (storage-vector storage) i) value)
    (%bump-generation storage)
    value))
(defmethod metadata-cas ((storage packed-bit-storage) key old new)
  (%ensure-initialized storage) (%ensure-writable storage)
  (%ensure-logical-value storage key new)
  (let* ((i (%address-index storage key))
         (observed (sbit (storage-vector storage) i)))
    (if (metadata-value-equal-p storage key observed old)
        (progn (setf (sbit (storage-vector storage) i) new)
               (%bump-generation storage)
               (values observed t))
        (values observed nil))))

(defmethod metadata-ref ((storage scalar-bit-storage) key) (%ensure-initialized storage) (aref (storage-vector storage) (%address-index storage key)))
(defmethod metadata-set ((storage scalar-bit-storage) key value) (%ensure-initialized storage) (%ensure-writable storage) (%ensure-logical-value storage key value) (setf (aref (storage-vector storage) (%address-index storage key)) value) (%bump-generation storage) value)
(defmethod metadata-cas ((storage scalar-bit-storage) key old new) (%ensure-initialized storage) (%ensure-writable storage) (%ensure-logical-value storage key new) (let* ((i (%address-index storage key)) (observed (aref (storage-vector storage) i))) (if (metadata-value-equal-p storage key observed old) (progn (setf (aref (storage-vector storage) i) new) (%bump-generation storage) (values observed t)) (values observed nil))))
(defmethod metadata-ref ((storage side-forwarding) key) (%ensure-initialized storage) (aref (storage-vector storage) (%address-index storage key)))
(defmethod metadata-set ((storage side-forwarding) key value) (%ensure-initialized storage) (%ensure-writable storage) (%ensure-logical-value storage key value) (setf (aref (storage-vector storage) (%address-index storage key)) value) (%bump-generation storage) value)
(defmethod metadata-cas ((storage side-forwarding) key old new) (%ensure-initialized storage) (%ensure-writable storage) (%ensure-logical-value storage key new) (let* ((i (%address-index storage key)) (observed (aref (storage-vector storage) i))) (if (metadata-value-equal-p storage key observed old) (progn (setf (aref (storage-vector storage) i) new) (%bump-generation storage) (values observed t)) (values observed nil))))

;;; Offered fields use client metadata generics.
(defun %field-read (storage key) (field-read (storage-model storage) (storage-field storage) key))
(defun %field-write (storage key value) (field-write (storage-model storage) (storage-field storage) key value))
(defun %field-cas (storage key old new) (field-cas (storage-model storage) (storage-field storage) key old new))
(defun %offered-key (storage key) (%canonical-key storage (%address-index storage key)))

(defun %valid-offered-value-p (storage value)
  (declare (ignore storage))
  (or (eql value 0) (eql value 1)))

(defmethod metadata-ref ((storage offered-bit-storage) key)
  (%ensure-initialized storage)
  (let ((value (%field-read storage (%offered-key storage key))))
    (unless (%valid-offered-value-p storage value)
      (error 'metadata-operation-error :metadata storage :key key
             :fact (list :offered-value-not-bit value)))
    value))
(defmethod metadata-set ((storage offered-bit-storage) key value)
  (%ensure-initialized storage) (%ensure-writable storage)
  (%ensure-logical-value storage key value)
  (let ((result (%field-write storage (%offered-key storage key) value)))
    (unless (eql result value)
      (error 'metadata-operation-error :metadata storage :key key
             :fact (list :field-write-result result value)))
    (%bump-generation storage)
    value))
(defmethod metadata-cas ((storage offered-bit-storage) key old new)
  (%ensure-initialized storage) (%ensure-writable storage)
  (%ensure-logical-value storage key new)
  (multiple-value-bind (observed success)
      (%field-cas storage (%offered-key storage key) old new)
    (unless (%valid-offered-value-p storage observed)
      (error 'metadata-operation-error :metadata storage :key key
             :fact (list :offered-cas-value-not-bit observed)))
    (when success (%bump-generation storage))
    (values observed (and success t))))

;;; Enumerated offered storage supplies range semantics only when it has an
;;; explicit bounded enumerator.  Dense address geometry is the built-in
;;; enumerator; a custom function receives (start end) and returns canonical
;;; keys in ascending order.
(defun %offered-keys (storage)
  (let ((keys (storage-keys storage))
        (enum (storage-enumerator storage)))
    (cond
      (keys (copy-list keys))
      (enum (let ((result (funcall enum (storage-base storage)
                                   (storage-limit storage))))
              (unless (listp result)
                (error 'metadata-invalid :metadata storage
                       :fact :enumerator-not-proper-list))
              (copy-list result)))
      (t (loop for i below (storage-capacity storage)
               collect (%canonical-key storage i))))))

(defun %validate-enumerated-keys (storage)
  (unless (or (storage-enumerator storage) (storage-keys storage))
    (error 'metadata-invalid :metadata storage :fact :enumerator-required-for-range))
  (let ((keys (%offered-keys storage)) (seen (make-hash-table :test #'eql)) (previous nil))
    (dolist (key keys)
      (let ((index (%address-index storage key)))
        (unless (= key (%canonical-key storage index)) (error 'metadata-invalid :metadata storage :fact :noncanonical-enumerator-key))
        (when (and previous (<= key previous)) (error 'metadata-invalid :metadata storage :fact :enumerator-not-ascending))
        (setf previous key))
      (when (gethash key seen)
        (error 'metadata-invalid :metadata storage
               :fact (list :duplicate-enumerator-key key)))
      (setf (gethash key seen) t))
    (unless (= (length keys) (storage-capacity storage))
      (error 'metadata-invalid :metadata storage
             :fact (list :enumerator-coverage (length keys)
                         (storage-capacity storage))))
    keys))

;;; -------------------------------------------------------------------------
;;; Range implementation and callback guards.

(defun %assert-unchanged (m generation)
  (unless (= generation (metadata-generation m))
    (error 'metadata-operation-error :metadata m
           :fact :callback-mutated-metadata)))

(defun %reset-cell (m key)
  (metadata-reset m key))

(defmethod metadata-reset-range ((m range-metadata) range)
  (%ensure-initialized m)
  ;; Validate the complete range, role reset semantics, and all keys before
  ;; the first mutation.  Runtime reset is deliberately not a rollback.
  (let ((keys (mapcar (lambda (i) (%canonical-key m i))
                      (%range-indices m range))))
    (dolist (key keys) (metadata-default-value m key))
    (dolist (key keys) (%reset-cell m key)))
  m)

(defmethod metadata-fold ((m range-metadata) range function initial-value)
  (%ensure-initialized m)
  (unless (functionp function) (error 'metadata-invalid :metadata m :fact :fold-function))
  (let ((keys (mapcar (lambda (i) (%canonical-key m i)) (%range-indices m range))) (generation (metadata-generation m)) (accumulator initial-value))
    (%begin-traversal (list m))
    (unwind-protect (dolist (key keys accumulator) (setf accumulator (funcall function (metadata-ref m key) accumulator)) (%assert-unchanged m generation))
      (%end-traversal (list m)))))

(defmethod metadata-map-present ((m range-metadata) range function)
  (%ensure-initialized m)
  (unless (functionp function) (error 'metadata-invalid :metadata m :fact :map-function))
  (let ((keys (mapcar (lambda (i) (%canonical-key m i)) (%range-indices m range))) (generation (metadata-generation m)))
    (%begin-traversal (list m))
    (unwind-protect (dolist (key keys m) (let ((value (metadata-ref m key))) (unless (metadata-value-equal-p m key value (metadata-default-value m key)) (funcall function key value) (%assert-unchanged m generation))))
      (%end-traversal (list m)))))

(defun %full-range (m)
  (cons (storage-base m) (storage-limit m)))

(defun %dense-domain-compatible-p (source destination)
  (multiple-value-bind (sb sl sg) (metadata-bounds source)
    (multiple-value-bind (db dl dg) (metadata-bounds destination)
      (and (= sb db) (= sl dl) (plusp sg) (plusp dg)
           (zerop (mod dg sg))))))

(defun %storage-alias-p (left right)
  (or (eq (storage-token left) (storage-token right))
      (and (typep left 'offered-bit-storage) (typep right 'offered-bit-storage)
           (eq (storage-model left) (storage-model right)) (eq (storage-field left) (storage-field right)))))

(defmethod metadata-project ((source range-metadata)
                             (destination range-metadata) reducer)
  (%ensure-initialized source)
  (%ensure-initialized destination)
  (unless (functionp reducer)
    (error 'metadata-invalid :metadata source :fact :projection-reducer))
  (when (%storage-alias-p source destination)
    (error 'metadata-alias-error :metadata source :fact :projection-alias))
  (unless (%dense-domain-compatible-p source destination)
    (error 'metadata-key-error :metadata source :fact :incompatible-projection-domain))
  (let ((sgen (metadata-generation source))
        (dgen (metadata-generation destination))
        (base (storage-base source))
        (limit (storage-limit source))
        (sg (storage-granularity source))
        (dg (storage-granularity destination)))
    (%begin-traversal (list source destination))
    (unwind-protect
         (loop for address from base below limit by sg
               for destination-key = (+ (storage-base destination) (* (floor (- address (storage-base destination)) dg) dg))
               for sv = (metadata-ref source address) for dv = (metadata-ref destination destination-key)
               for nv = (funcall reducer sv dv)
               do (%assert-unchanged source sgen) (%assert-unchanged destination dgen)
                  (%ensure-logical-value destination destination-key nv)
                  (let ((*metadata-internal-write* t)) (metadata-set destination destination-key nv))
                  (setf dgen (metadata-generation destination)))
      (%end-traversal (list source destination)))
    destination))

;;; -------------------------------------------------------------------------
;;; Transfer preflight and role-specific primary methods.

(defun %transfer-key-check (m key)
  (%ensure-initialized m)
  (%address-index m key)
  key)

(defmethod metadata-transfer :around
    ((source transferable-metadata) source-key
     (destination transferable-metadata) destination-key)
  (%transfer-key-check source source-key)
  (%transfer-key-check destination destination-key)
  (unless (or (and (typep source 'mark-map) (typep destination 'mark-map))
              (and (typep source 'forwarding-metadata) (typep destination 'forwarding-metadata)))
    (error 'metadata-operation-error :metadata source :fact :incompatible-transfer-role))
  (when (and (%storage-alias-p source destination)
             (= (%address-index source source-key)
                (%address-index destination destination-key)))
    (error 'metadata-alias-error :metadata source :fact :same-transfer-cell))
  ;; A transfer is a bounded pair operation.  The primary method may only
  ;; mutate the destination; source retention/retirement belongs to its owner.
  (call-next-method))

;;; -------------------------------------------------------------------------
;;; Construction lifecycle and capacity declarations.

(defmethod component-dependencies ((storage metadata-storage))
  (append (call-next-method) (if (and (metadata-domain storage)
                                      (typep (metadata-domain storage)
                                             'component))
                                 (list (metadata-domain storage))
                                 nil)))

(defun %storage-bytes (storage)
  (cond ((typep storage 'packed-bit-storage) (ceiling (storage-capacity storage) 8))
        ((typep storage 'scalar-bit-storage) (* (storage-capacity storage) 8))
        ((typep storage 'side-forwarding) (* (storage-capacity storage) 8)) (t 0)))
(defun %make-resource-contribution* (storage)
  (make-resource-contribution storage storage
   (cond ((typep storage 'packed-bit-storage) :packed-bit-vector)
         ((typep storage 'scalar-bit-storage) :scalar-bit-vector)
         ((typep storage 'side-forwarding) :forwarding-vector) (t :offered-bit))
   :placement-identity nil :minimum-physical-bytes (+ (%storage-bytes storage) 16)
   :logical-entry-bound (storage-capacity storage) :auxiliary-bytes 16
   :allocation-context :construction :exhaustion-action :reject))
(defmethod component-resources ((storage metadata-storage))
  (if (typep storage 'offered-bit-storage) (call-next-method)
      (append (call-next-method) (list (%make-resource-contribution* storage)))))
(defun %resolve-placement-domain (storage context)
  (let* ((domain (metadata-domain storage)) (identity (and (typep domain 'metadata-domain) (metadata-domain-placement-identity domain))))
    (when identity (multiple-value-bind (base limit present-p) (construction-placement context identity)
      (unless (and present-p (integerp base) (integerp limit) (<= 0 base limit)) (error 'metadata-capacity-error :metadata storage :fact :placement-not-present))
      (setf (slot-value storage 'domain) (make-metadata-domain :base base :limit limit :granularity (metadata-domain-granularity domain) :addressed-p (metadata-domain-addressed-p domain) :key-function (metadata-domain-key-function domain)))))) storage)
(defun %bind-construction-storage (storage context)
  (multiple-value-bind (handle present-p physical-bytes entry-capacity auxiliary-bytes) (construction-resource context storage)
    (unless (and present-p (or (and (typep storage 'packed-bit-storage) (typep handle 'simple-bit-vector)) (and (typep storage 'scalar-bit-storage) (typep handle 'simple-vector)) (and (typep storage 'side-forwarding) (typep handle 'simple-vector)))) (error 'metadata-capacity-error :metadata storage :fact :invalid-resource-handle))
    (unless (and (integerp entry-capacity) (>= entry-capacity (storage-capacity storage)) (integerp physical-bytes) (>= physical-bytes (+ (%storage-bytes storage) 16)) (integerp auxiliary-bytes) (>= auxiliary-bytes 16)) (error 'metadata-capacity-error :metadata storage :fact :insufficient-resource-capacity))
    (setf (metadata-resource-handle storage) handle (storage-vector storage) handle) (%provision-storage storage)))
(defmethod initialize-component ((storage metadata-storage) context)
  (call-next-method)
  (unless context (error 'metadata-capacity-error :metadata storage :fact :construction-resource-context-required))
  (%resolve-placement-domain storage context)
  (if (typep storage 'offered-bit-storage) (%provision-storage storage) (%bind-construction-storage storage context))
  (cond ((typep storage 'side-forwarding) (fill (storage-vector storage) nil))
        ((or (typep storage 'packed-bit-storage) (typep storage 'scalar-bit-storage)) (fill (storage-vector storage) 0))
        ((typep storage 'enumerated-offered-bit-storage) (dolist (key (%offered-keys storage)) (%field-write storage key 0)))
        ((typep storage 'offered-bit-storage) (dotimes (i (storage-capacity storage)) (%field-write storage (%canonical-key storage i) 0))))
  (setf (metadata-generation storage) 0 (metadata-initialized-p storage) t) nil)

(defun %validate-field-description (storage)
  (when (and (storage-model storage) (storage-field storage) (null (storage-field-description storage)))
    (multiple-value-bind (identity width legal operations orders object-kinds overlaps copy-behavior checkpoint)
        (describe-metadata-field-offer (storage-model storage) (storage-field storage))
      (unless (and identity (= width 1) (listp legal) (member 0 legal :test #'eql) (member 1 legal :test #'eql) (listp operations) (member :read operations) (member :write operations) (member :cas operations) (listp orders) (intersection orders '(:relaxed :acquire :release :acq-rel :sequential)) copy-behavior checkpoint)
        (error 'metadata-invalid :metadata storage :fact :invalid-offered-field))
      (setf (storage-field-description storage) (list identity width legal operations orders object-kinds overlaps copy-behavior checkpoint))))
  storage)

(defun %validate-logical-role (storage)
  (when (and (metadata-initialized-p storage)
             (plusp (storage-capacity storage)))
    (let ((key (%canonical-key storage 0)))
      (handler-case
          (let ((default (metadata-default-value storage key)))
            (unless (metadata-value-valid-p storage key default)
              (error 'metadata-invalid :metadata storage
                     :fact :default-value-rejected))
            (metadata-value-equal-p storage key default default))
        (metadata-operation-error (condition)
          (error 'metadata-invalid :metadata storage
                 :fact (list :abstract-logical-role condition))))))
  storage)

(declaim (ftype (function (t) t) %validate-field-description))

(defmethod validate-component :after ((storage metadata-storage) configuration)
  (declare (ignore configuration))
  (%provision-storage storage)
  (multiple-value-bind (base limit granularity) (metadata-bounds storage)
    (unless (and (integerp base) (integerp limit) (integerp granularity)
                 (<= 0 base limit) (> granularity 0))
      (error 'metadata-invalid :metadata storage :fact :unresolved-bounds)))
  (when (typep storage 'enumerated-offered-bit-storage)
    (%validate-enumerated-keys storage))
  (when (typep storage 'offered-bit-storage)
    (%validate-field-description storage)
    (unless (and (storage-model storage) (storage-field storage))
      (error 'metadata-invalid :metadata storage
             :fact :offered-field-requires-model-and-field)))
  (when (typep storage 'atomic-metadata)
    ;; These concrete classes do not provide atomic packed updates.  An
    ;; admitted concurrent composition must use a different storage class
    ;; with actual atomic methods rather than inheriting this implementation.
    (error 'metadata-invalid :metadata storage
           :fact :exclusive-storage-cannot-promise-atomicity))
  t)

(defmethod validate-component :after ((m metadata) configuration)
  (declare (ignore configuration))
  ;; Protocol validators reject abstract-only components.  Storage classes
  ;; above establish concrete whole-domain coverage; this role check catches
  ;; an accidental bare role instance before publication.
  (when (and (not (typep m 'metadata-storage))
             (or (typep m 'bit-metadata)
                 (typep m 'range-metadata)
                 (typep m 'transferable-metadata)
                 (typep m 'atomic-metadata)))
    (error 'metadata-invalid :metadata m :fact :role-without-storage))
  t)
