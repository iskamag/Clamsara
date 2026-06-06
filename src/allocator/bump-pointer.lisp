(in-package #:clamsara)

;;; --- Bump-Pointer Allocator ---

(defclass bump-allocator ()
  ((cursor :initform 0 :accessor allocator-cursor :type fixnum)
   (limit :initform 0 :accessor allocator-limit :type fixnum)
   (space :initarg :space :reader allocator-space)
   (page-resource :initarg :page-resource :reader allocator-page-resource)
   (alignment :initarg :alignment :initform 1
    :accessor allocator-alignment :type fixnum))
  (:documentation "Bump-pointer allocator. Advances a cursor through a contiguous region."))

(defun make-bump-allocator (space page-resource &key (alignment 1))
  (make-instance 'bump-allocator
    :space space :page-resource page-resource :alignment alignment))

(defgeneric alloc (allocator size &key &allow-other-keys)
  (:documentation "Allocate SIZE words. Returns an address or NIL if exhausted."))

(defgeneric coalesce (allocator)
  (:documentation "Coalesce adjacent free chunks. Required for free-list-allocator subclasses."))

(defgeneric mark-line (allocator addr mark-state)
  (:documentation "Mark the line containing ADDR with MARK-STATE. Required for immix-allocator."))

(defgeneric block-is-recyclable-p (allocator block)
  (:documentation "Return T if BLOCK can be recycled (no live lines). Required for immix-allocator."))

(defmethod alloc ((a bump-allocator) size &key)
  (let* ((align (allocator-alignment a))
         (cursor (allocator-cursor a))
         (aligned-cursor (if (= align 1) cursor
                             (* (ceiling cursor align) align)))
         (new-cursor (+ aligned-cursor size)))
    (when (or (zerop (allocator-limit a))
              (> new-cursor (allocator-limit a)))
      (unless (bump-allocator-acquire-page a size)
        (return-from alloc nil))
      (setf cursor (allocator-cursor a)
            aligned-cursor cursor
            new-cursor (+ cursor size)))
    (setf (allocator-cursor a) new-cursor)
    (make-address aligned-cursor)))

(defun bump-allocator-acquire-page (allocator min-size)
  (when (> min-size +page-size-words+)
    (return-from bump-allocator-acquire-page nil))
  (let* ((space (allocator-space allocator))
         (page-idx (if space
                       (space-allocate-pages space 1 :kind :boxed)
                       (let ((pr (allocator-page-resource allocator)))
                         (when pr
                           (page-resource-get pr 1 :kind :boxed))))))
    (when page-idx
      (let ((page-start (* page-idx +page-size-words+)))
        (setf (allocator-cursor allocator) page-start
              (allocator-limit allocator) (+ page-start +page-size-words+))
        (when space (incf (space-page-count space)))
        t))))

(defun bump-allocator-reset (allocator &key (cursor 0) (limit 0))
  (setf (allocator-cursor allocator) cursor
        (allocator-limit allocator) limit))

(defun bump-allocator-occupancy (allocator)
  "Return the fraction of the allocator region used, or 0 if the region
is not bounded."
  (let ((cursor (allocator-cursor allocator))
        (limit (allocator-limit allocator))
        (space (allocator-space allocator)))
    (if (and space (plusp limit))
        (let ((start (* (space-start-page space) +page-size-words+)))
          (if (>= limit start)
              (/ (- cursor start) (max 1 (- limit start)))
              0))
        (if (plusp limit)
            (/ cursor limit)
            0))))
