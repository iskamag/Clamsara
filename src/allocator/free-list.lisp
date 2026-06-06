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
;;; A free chunk is a dedicated struct to avoid host allocations during GC.

(defstruct free-list-chunk
  "A contiguous range of free words."
  (start 0 :type fixnum)
  (size 0 :type fixnum))

(defun chunk-start (chunk) (free-list-chunk-start chunk))
(defun chunk-size (chunk) (free-list-chunk-size chunk))
(defun chunk-end (chunk) (+ (free-list-chunk-start chunk) (free-list-chunk-size chunk)))

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
                       (let ((remainder (make-free-list-chunk :start (+ addr size) :size excess)))
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
         (let ((chunk (make-free-list-chunk :start (* page-idx +page-size-words+) :size +page-size-words+)))
           (add-chunk-to-bin a chunk)
           (alloc a size))))))

;;; --- Free ---

(defgeneric free (allocator addr size &key &allow-other-keys)
  (:documentation "Free SIZE words at ADDRESS."))

(defmethod free ((a free-list-allocator) addr size &key)
  (let* ((start (address-index addr))
         (chunk (make-free-list-chunk :start start :size size)))
    ;; Coalesce with preceding chunk
    (when (> start 0)
      (let ((prev (find-chunk-ending-at a start)))
        (when prev
          (remove-chunk-from-bin a (bin-index-for-size (chunk-size prev)) prev)
          (setf (free-list-chunk-start chunk) (chunk-start prev)
                (free-list-chunk-size chunk) (+ (chunk-size prev) size)
                start (chunk-start prev)))))
    ;; Coalesce with following chunk
    (let ((following-start (+ start (free-list-chunk-size chunk))))
      (let ((following (find-chunk-by-address a following-start)))
        (when following
          (remove-chunk-from-bin a (bin-index-for-size (chunk-size following)) following)
          (setf (free-list-chunk-size chunk)
                (+ (free-list-chunk-size chunk) (chunk-size following))))))
    (add-chunk-to-bin a chunk)
    (decf (free-list-total-allocated a) size)
    addr))

(defmethod coalesce ((a free-list-allocator))
  "Perform a full coalescing pass over all bins, merging adjacent free chunks."
  (let ((all-chunks nil))
    (loop for bin from 0 below +free-list-bins+
          do (loop for chunk in (aref (allocator-bins a) bin)
                   do (push chunk all-chunks)))
    (setf all-chunks (sort all-chunks #'< :key #'chunk-start))
    ;; Clear all bins
    (loop for bin from 0 below +free-list-bins+
          do (setf (aref (allocator-bins a) bin) nil))
    ;; Re-insert coalesced chunks
    (let ((merged nil)
          (current (first all-chunks)))
      (when current
        (loop for next in (rest all-chunks)
              do (if (= (chunk-end current) (chunk-start next))
                     (setf (free-list-chunk-size current)
                           (+ (free-list-chunk-size current) (chunk-size next)))
                     (progn (push current merged)
                            (setf current next))))
        (push current merged)
        (dolist (chunk (nreverse merged))
          (add-chunk-to-bin a chunk))))))

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
  (let ((chunk (make-free-list-chunk :start (* page-index +page-size-words+) :size +page-size-words+)))
    (add-chunk-to-bin allocator chunk)))

(defun free-list-allocator-clear (allocator)
  (loop for bin below +free-list-bins+
        do (setf (aref (allocator-bins allocator) bin) nil))
  (setf (free-list-total-allocated allocator) 0))

(defun free-list-allocator-occupancy (allocator)
  "Return the estimated occupancy of the free-list allocator as a float."
  (let ((total-allocated (free-list-total-allocated allocator))
        (total-capacity 0))
    (loop for bin below +free-list-bins+
          do (dolist (chunk (aref (allocator-bins allocator) bin))
               (incf total-capacity (chunk-size chunk))))
    (let ((total (+ total-allocated total-capacity)))
      (if (zerop total)
          0.0
          (/ (float total-allocated) (float total))))))
