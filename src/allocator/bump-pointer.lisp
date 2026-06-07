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
  "Return the fraction of the allocator's total space that is occupied.
Measures against the total number of pages acquired by the space (via
space-page-count), not just the currently committed page range, so that
generations plans correctly detect nursery exhaustion."
  (let* ((cursor (allocator-cursor allocator))
         (space (allocator-space allocator)))
    (if (and space (plusp (space-page-count space)))
        (let* ((start (* (space-start-page space) +page-size-words+))
               (total-capacity (* (space-page-count space) +page-size-words+)))
          (/ (max 0 (float (- cursor start))) (float total-capacity)))
        (if (plusp (allocator-limit allocator))
            (/ (float cursor) (float (allocator-limit allocator)))
            0.0))))
