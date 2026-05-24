(in-package #:clamsara)

;;; --- Space: A contiguous range of pages within the heap ---

(defclass space ()
  ((name :initarg :name :reader space-name :type keyword)
   (kind :initarg :kind :reader space-kind :type keyword)
   (start-page :initarg :start-page :accessor space-start-page :type fixnum)
   (page-count :initarg :page-count :accessor space-page-count :type fixnum)
   (allocator :initarg :allocator :accessor space-allocator)
   (page-resource :initarg :page-resource :reader space-page-resource :initform nil)
   (constraints :initarg :constraints :reader space-constraints :initform nil))
  (:metaclass space-metaclass)
  (:documentation "A space is a contiguous range of pages within the heap."))

(defclass space-constraints ()
  ((moves-objects :initarg :moves-objects :reader space-moves-objects-p :initform nil)
   (accepts-copies :initarg :accepts-copies :reader space-accepts-copies-p :initform nil)
   (mixed-age :initarg :mixed-age :reader space-mixed-age-p :initform nil)
   (immortal :initarg :immortal :reader space-immortal-p :initform nil))
  (:documentation "Constraints describing properties of a space's memory region."))

(defun make-space (name kind start-page page-count allocator &key metadata page-resource constraints)
  (declare (ignore metadata))
  (make-instance 'space
    :name name :kind kind
    :start-page start-page :page-count page-count
    :allocator allocator :page-resource page-resource
    :constraints constraints))

(defmethod print-object ((space space) stream)
  (print-unreadable-object (space stream :type t :identity t)
    (format stream "~A (~A) pages ~D-~D"
            (space-name space) (space-kind space)
            (space-start-page space)
            (1- (+ (space-start-page space) (space-page-count space))))))

(defun space-address-range (space)
  "Return (VALUES START-ADDRESS END-ADDRESS) for the space."
  (let ((start (* (space-start-page space) +page-size-words+))
        (end (* (+ (space-start-page space) (space-page-count space)) +page-size-words+)))
    (values (make-address start) (make-address end))))

(defgeneric space-contains-p (space addr)
  (:documentation "Return T if ADDR falls within SPACE."))

(defmethod space-contains-p (space addr)
  (multiple-value-bind (start end) (space-address-range space)
    (let ((idx (address-index addr)))
      (and (>= idx (address-index start))
           (< idx (address-index end))))))

(defgeneric space-trace-object (space vm ref tracer &key cycle-kind trace-kind copy-semantics)
  (:documentation "Trace REF within SPACE. Returns the (possibly forwarded) object address."))

(defgeneric space-prepare (space vm &key cycle-kind)
  (:documentation "Pre-GC preparation for SPACE."))

(defgeneric space-release (space vm &key cycle-kind)
  (:documentation "Post-GC release for SPACE."))

(defgeneric space-sweep (space vm)
  (:documentation "Reclaim dead objects in SPACE."))

(defun space-allocate-pages (space n-pages &key (kind :boxed))
  "Allocate N-PAGES for SPACE via its page resource."
  (let ((pr (space-page-resource space)))
    (when pr
      (page-resource-get pr n-pages :space space :kind kind))))
