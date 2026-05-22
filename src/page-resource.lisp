(in-package #:clamsara)

;;; --- Page Resources ---

(defclass page-resource ()
  ((total-pages :initarg :total-pages :reader pr-total-pages)
   (page-table :initarg :page-table :reader pr-page-table)
   (bitmap :initarg :bitmap :accessor pr-bitmap
    :documentation "Bitmap simple-vector: bit=1 means allocated."))
  (:documentation "Manages page allocation from the heap."))

(defgeneric page-resource-get (pr n-pages &key space kind)
  (:documentation "Allocate N-PAGES contiguous pages. Returns start-page index or NIL."))

(defgeneric page-resource-release (pr start-page n-pages)
  (:documentation "Release N-PAGES starting at START-PAGE."))

(defun make-page-resource (total-pages)
  (let* ((bitmap-words (ceiling total-pages 64))
         (bitmap (make-array bitmap-words :element-type '(unsigned-byte 64) :initial-element 0)))
    (make-instance 'page-resource
      :total-pages total-pages
      :page-table (make-array total-pages :element-type 'page)
      :bitmap bitmap)))

(defun initialize-page-resource (word-count)
  "Create and initialize a page resource for a heap of WORD-COUNT words."
  (let* ((n-pages (ceiling word-count +page-size-words+))
         (pr (make-page-resource n-pages)))
    (dotimes (i n-pages)
      (setf (aref (pr-page-table pr) i) (%make-page)))
    ;; Reserve page 0 (address 0 is the null sentinel)
    (when (> n-pages 0)
      (mark-page-allocated pr 0))
    pr))

(defmethod page-resource-get ((pr page-resource) n-pages &key space kind)
  (declare (ignore space kind))
  (let ((start (find-contiguous-free-pages pr n-pages)))
    (when start
      (dotimes (i n-pages)
        (mark-page-allocated pr (+ start i)))
      start)))

(defun find-contiguous-free-pages (pr n-pages)
  (let ((total (pr-total-pages pr)))
    (loop with run = 0
          for i from 0 below total
          do (if (page-is-free-p pr i)
                 (progn (incf run)
                        (when (>= run n-pages)
                          (return-from find-contiguous-free-pages (1+ (- i n-pages)))))
                 (setf run 0)))))

(defun page-is-free-p (pr page-index)
  (let ((word-idx (floor page-index 64))
        (bit-idx (mod page-index 64)))
    (not (logbitp bit-idx (aref (pr-bitmap pr) word-idx)))))

(defun mark-page-allocated (pr page-index)
  (let ((word-idx (floor page-index 64))
        (bit-idx (mod page-index 64)))
    (setf (aref (pr-bitmap pr) word-idx)
          (logior (aref (pr-bitmap pr) word-idx) (ash 1 bit-idx)))))

(defun mark-page-free (pr page-index)
  (let ((word-idx (floor page-index 64))
        (bit-idx (mod page-index 64)))
    (setf (aref (pr-bitmap pr) word-idx)
          (logandc2 (aref (pr-bitmap pr) word-idx) (ash 1 bit-idx)))))

(defmethod page-resource-release ((pr page-resource) start-page n-pages)
  (dotimes (i n-pages)
    (mark-page-free pr (+ start-page i))))

;;; --- Monotone Page Resource ---

(defclass monotone-pr (page-resource)
  ((cursor :initform 0 :accessor mpr-cursor :type fixnum))
  (:documentation "Bump-pointer page allocation. No release."))

(defmethod page-resource-get ((pr monotone-pr) n-pages &key space kind)
  (declare (ignore space kind))
  (let* ((cursor (mpr-cursor pr))
         (result cursor))
    (when (> (+ cursor n-pages) (pr-total-pages pr))
      (return-from page-resource-get nil))
    (dotimes (i n-pages)
      (mark-page-allocated pr (+ cursor i)))
    (setf (mpr-cursor pr) (+ cursor n-pages))
    result))

;;; --- Free-List Page Resource ---

(defclass free-list-pr (page-resource)
  ((free-list :initform nil :accessor flpr-free-list :type list))
  (:documentation "Releasable page allocation with free-list coalescing."))

(defmethod page-resource-release ((pr free-list-pr) start-page n-pages)
  (dotimes (i n-pages)
    (mark-page-free pr (+ start-page i)))
  (push (cons start-page n-pages) (flpr-free-list pr)))
