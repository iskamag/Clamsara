(in-package #:clamsara)

;;; --- Free-List Allocator ---
;;; Power-of-2 segregated free lists with best-fit allocation.
;;; 64 bins: bin N holds free chunks of size 2^N words.

(defconstant +free-list-bins+ 64
  "Number of power-of-2 size classes.")

(defclass free-list-allocator ()
  ((bins :initform (make-array +free-list-bins+ :initial-element nil)
    :accessor allocator-bins :type simple-vector)
   (page-resource :initarg :page-resource :reader allocator-page-resource)
   (space :initarg :space :reader allocator-space)
   (total-allocated :initform 0 :accessor free-list-total-allocated :type fixnum))
  (:documentation "Power-of-2 segregated free-list allocator."))

(defun make-free-list-allocator (space page-resource)
  (make-instance 'free-list-allocator :space space :page-resource page-resource))

;;; --- Free Chunk Representation ---
;;; A free chunk is stored as a cons cell: (start-address . size-in-words)

(defun chunk-start (chunk) (car chunk))
(defun chunk-size (chunk) (cdr chunk))
(defun chunk-end (chunk) (+ (chunk-start chunk) (chunk-size chunk)))

(defun bin-index-for-size (size)
  (min (1- +free-list-bins+)
       (integer-length (1- (max 1 size)))))

;;; --- Allocation ---

(defmethod alloc ((a free-list-allocator) size &key)
  (let ((bin-idx (bin-index-for-size size)))
    (loop for bin from bin-idx below +free-list-bins+
          for candidates = (aref (allocator-bins a) bin)
          when candidates do
            (let ((found (find-chunk-in-bin candidates size)))
              (when found
                (let ((addr (chunk-start found))
                      (chunk-words (chunk-size found)))
                  (remove-chunk-from-bin a bin found)
                  (let ((excess (- chunk-words size)))
                    (when (>= excess 4)
                      (let ((remainder (cons (+ addr size) excess)))
                        (add-chunk-to-bin a remainder))))
                  (incf (free-list-total-allocated a) size)
                  (return-from alloc (make-address addr))))))
    ;; No free chunk found: try to acquire a new page
    (let* ((space (allocator-space a))
           (page-idx (if space
                         (space-allocate-pages space 1 :kind :boxed)
                         (let ((pr (allocator-page-resource a)))
                           (when pr
                             (page-resource-get pr 1 :kind :boxed))))))
      (when page-idx
        (let ((chunk (cons (* page-idx +page-size-words+) +page-size-words+)))
          (add-chunk-to-bin a chunk)
          (alloc a size))))))

;;; --- Free ---

(defgeneric free (allocator addr size &key &allow-other-keys)
  (:documentation "Free SIZE words at ADDRESS."))

(defmethod free ((a free-list-allocator) addr size &key)
  (let* ((start (address-index addr))
         (chunk (cons start size)))
    ;; Coalesce with preceding chunk
    (when (> start 0)
      (let ((prev (find-chunk-ending-at a start)))
        (when prev
          (remove-chunk-from-bin a (bin-index-for-size (chunk-size prev)) prev)
          (setf chunk (cons (chunk-start prev) (+ (chunk-size prev) size)))
          (setf start (chunk-start prev)))))
    ;; Coalesce with following chunk
    (let ((following-start (+ start (cdr chunk))))
      (let ((following (find-chunk-by-address a following-start)))
        (when following
          (remove-chunk-from-bin a (bin-index-for-size (chunk-size following)) following)
          (setf chunk (cons (car chunk) (+ (cdr chunk) (chunk-size following)))))))
    (add-chunk-to-bin a chunk)
    (decf (free-list-total-allocated a) size)
    addr))

;;; --- Bin Operations ---

(defun add-chunk-to-bin (allocator chunk)
  (let* ((bin (bin-index-for-size (chunk-size chunk)))
         (bin-list (aref (allocator-bins allocator) bin)))
    (setf (aref (allocator-bins allocator) bin)
          (merge 'list (list chunk) bin-list
                 (lambda (a b) (< (chunk-start a) (chunk-start b)))))))

(defun remove-chunk-from-bin (allocator bin chunk)
  (setf (aref (allocator-bins allocator) bin)
        (remove chunk (aref (allocator-bins allocator) bin) :test #'eq)))

(defun find-chunk-in-bin (candidates size)
  (loop for chunk in candidates
        when (>= (chunk-size chunk) size)
          return chunk))

(defun find-chunk-by-address (allocator addr)
  (loop for bin below +free-list-bins+
        for candidates = (aref (allocator-bins allocator) bin)
        do (loop for chunk in candidates
                 when (= (chunk-start chunk) addr)
                   return (return-from find-chunk-by-address chunk))))

(defun find-chunk-ending-at (allocator end-addr)
  (loop for bin below +free-list-bins+
        for candidates = (aref (allocator-bins allocator) bin)
        do (loop for chunk in candidates
                 when (= (chunk-end chunk) end-addr)
                   return (return-from find-chunk-ending-at chunk))))

;;; --- Free-List Initialization ---

(defun free-list-allocator-add-page (allocator page-index)
  (let ((chunk (cons (* page-index +page-size-words+) +page-size-words+)))
    (add-chunk-to-bin allocator chunk)))

(defun free-list-allocator-clear (allocator)
  (loop for bin below +free-list-bins+
        do (setf (aref (allocator-bins allocator) bin) nil))
  (setf (free-list-total-allocated allocator) 0))
