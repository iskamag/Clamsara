(in-package #:clamsara)

;;; --- Heap: The Core Simple-Vector ---

(defvar *heap* nil
  "The simulated heap: a simple-vector of (unsigned-byte 64).
Each element is one machine word. An address is an index into this vector.")

(defvar *heap-size* 0
  "Total size of *HEAP* in words.")

(defun ensure-heap (word-count)
  "Initialize or resize the heap to WORD-COUNT words."
  (unless (and *heap* (>= (length *heap*) word-count))
    (setf *heap* (make-array word-count
                             :element-type '(unsigned-byte 64)
                             :initial-element 0)
          *heap-size* word-count)))

(defun heap-ref (addr)
  "Read the word at ADDRESS in the heap."
  (declare (type fixnum addr))
  (aref *heap* (the fixnum addr)))

(defun (setf heap-ref) (value addr)
  "Write VALUE to ADDRESS in the heap."
  (declare (type fixnum addr))
  (setf (aref *heap* (the fixnum addr)) value))

;;; --- Page Structure ---

(defstruct (page (:constructor %make-page))
  "Metadata for one page in the heap."
  (space nil :type (or null symbol))
  (generation 0 :type (integer 0 7))
  (kind :free :type keyword)
  (used-words 0 :type fixnum)
  (flags 0 :type fixnum))

(defun page-free-p (page)
  (eq (page-kind page) :free))

(defun page-allocate (page space-name kind)
  (setf (page-space page) space-name
        (page-kind page) kind
        (page-used-words page) 0))

(defun page-reset (page)
  (setf (page-space page) nil
        (page-kind page) :free
        (page-used-words page) 0
        (page-flags page) 0))

;;; --- Page Table ---

(defvar *page-table* nil
  "Vector of PAGE structs, one per page in the heap.")

(defun ensure-page-table (word-count)
  "Initialize the page table for a heap of WORD-COUNT words."
  (let ((n-pages (ceiling word-count +page-size-words+)))
    (setf *page-table* (make-array n-pages :element-type 'page))
    (dotimes (i n-pages)
      (setf (aref *page-table* i) (%make-page)))))

(defun page-for-address (addr)
  "Return the PAGE struct for the given ADDRESS."
  (let ((index (floor (address-index addr) +page-size-words+)))
    (aref *page-table* index)))

;;; --- Card Table ---

(defstruct (card-table (:constructor make-card-table (&key (cards (make-array 0 :element-type '(unsigned-byte 8) :initial-element 0)))))
  "Card table for write barrier / remembered set tracking."
  (cards cards :type (simple-array (unsigned-byte 8) (*))))

(defun ensure-card-table (word-count)
  "Initialize the card table for a heap of WORD-COUNT words."
  (let* ((page-count (ceiling word-count +page-size-words+))
         (card-count (* page-count +cards-per-page+)))
    (make-card-table :cards (make-array card-count
                                        :element-type '(unsigned-byte 8)
                                        :initial-element 0))))

(defun card-index (addr)
  "Return the card index for ADDRESS."
  (floor (address-index addr) +card-size-words+))

(defun card-dirty-p (card-table addr)
  "Return T if the card containing ADDRESS is dirty."
  (let ((idx (card-index addr)))
    (> (aref (card-table-cards card-table) idx) 0)))

(defun mark-card-dirty (card-table addr)
  "Mark the card containing ADDRESS as dirty."
  (let ((idx (card-index addr)))
    (setf (aref (card-table-cards card-table) idx) 1)))

(defun clear-card-dirty (card-table addr)
  "Mark the card containing ADDRESS as clean."
  (let ((idx (card-index addr)))
    (setf (aref (card-table-cards card-table) idx) 0)))

(defun clear-all-cards (card-table)
  "Reset all cards to clean."
  (fill (card-table-cards card-table) 0))
