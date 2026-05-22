(in-package #:clamsara)

;;; --- Large-Object Allocator ---

(defclass large-object-allocator ()
  ((entries :initform nil :accessor los-entries :type list)
   (page-resource :initarg :page-resource :reader allocator-page-resource)
   (space :initarg :space :reader allocator-space))
  (:documentation "Large-object allocator. Allocates multi-page objects."))

(defun make-large-object-allocator (space page-resource)
  (make-instance 'large-object-allocator :space space :page-resource page-resource))

(defmethod alloc ((a large-object-allocator) size &key)
  (let* ((n-pages (ceiling size +page-size-words+))
         (pr (allocator-page-resource a))
         (start-page (page-resource-get pr n-pages :kind :boxed)))
    (when start-page
      (let ((addr (make-address (* start-page +page-size-words+))))
        (push (cons addr size) (los-entries a))
        addr))))

(defmethod free ((a large-object-allocator) addr size &key)
  (declare (ignore size))
  (setf (los-entries a)
        (remove-if (lambda (e) (= (car e) addr)) (los-entries a)))
  addr)

(defun large-object-allocator-clear (allocator)
  (setf (los-entries allocator) nil))

(defun large-object-allocations (allocator)
  (los-entries allocator))
