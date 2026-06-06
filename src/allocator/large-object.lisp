(in-package #:clamsara)

;;; --- Large-Object Allocator ---

(defclass large-object-allocator ()
  ((entries :initform (make-array 256 :element-type 'fixnum :initial-element 0)
    :accessor los-entries :type (simple-array fixnum (*))
    :documentation "Pre-allocated simple-vector of (addr size addr size ...) pairs.")
   (entry-count :initform 0 :accessor los-entry-count :type fixnum)
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
      (let ((addr (make-address (* start-page +page-size-words+)))
            (vec (los-entries a))
            (cnt (los-entry-count a)))
        ;; Grow vector if needed
        (when (>= (+ cnt 2) (length vec))
          (let ((new-vec (make-array (* (length vec) 2)
                                     :element-type 'fixnum
                                     :initial-element 0)))
            (replace new-vec vec)
            (setf (los-entries a) new-vec
                  vec new-vec)))
        (setf (aref vec cnt) addr
              (aref vec (1+ cnt)) size)
        (setf (los-entry-count a) (+ cnt 2))
        addr))))

(defmethod free ((a large-object-allocator) addr size &key)
  (declare (ignore size))
  (let* ((vec (los-entries a))
         (cnt (los-entry-count a))
         (n-pages 0)
         (keep-vec (make-array cnt :element-type 'fixnum :initial-element 0))
         (keep-cnt 0))
    (loop for i from 0 below cnt by 2
          for entry-addr = (aref vec i)
          for entry-size = (aref vec (1+ i))
          if (= entry-addr addr)
             do (setf n-pages (ceiling entry-size +page-size-words+))
          else
             do (setf (aref keep-vec keep-cnt) entry-addr
                      (aref keep-vec (1+ keep-cnt)) entry-size)
                (incf keep-cnt 2))
    (setf (los-entries a) keep-vec
          (los-entry-count a) keep-cnt)
    (when (and (> n-pages 0) (allocator-page-resource a))
      (let ((start-page (floor addr +page-size-words+)))
        (page-resource-release (allocator-page-resource a) start-page n-pages))))
  addr)

(defun large-object-allocator-clear (allocator)
  (let* ((vec (los-entries allocator))
         (cnt (los-entry-count allocator)))
    (loop for i from 0 below cnt by 2
          for entry-addr = (aref vec i)
          for entry-size = (aref vec (1+ i))
          do (let ((start-page (floor entry-addr +page-size-words+))
                   (n-pages (ceiling entry-size +page-size-words+)))
               (when (allocator-page-resource allocator)
                 (page-resource-release (allocator-page-resource allocator) start-page n-pages)))))
  (setf (los-entry-count allocator) 0))

(defun large-object-allocations (allocator)
  (let* ((vec (los-entries allocator))
         (cnt (los-entry-count allocator))
         (result nil))
    (loop for i from 0 below cnt by 2
          do (push (cons (aref vec i) (aref vec (1+ i))) result))
    (nreverse result)))
