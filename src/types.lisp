(in-package #:clamsara)

;;; --- Page and Card Constants ---

(defconstant +page-size-words+ 4096
  "Number of words per page (4096 words = 32 KiB).")

(defconstant +card-size-words+ 128
  "Number of words per card (128 words = 1 KiB).")

(defconstant +cards-per-page+ 32
  "Number of cards per page (4096 / 128 = 32).")

;;; --- Address Math ---
;;; An address is a fixnum representing a word index into the heap.
;;; Addresses are plain integers; no struct wrapper is used.

(declaim (inline address-index make-address address= address+ address-))
(deftype address () 'fixnum)

(defun address-index (addr)
  (declare (type address addr))
  addr)

(defun make-address (index)
  (declare (type fixnum index))
  index)

(defun address= (a b)
  (= a b))

(defun address-equal (a b)
  "Spec-name alias for address=."
  (= a b))

(defun address< (a b)
  (< a b))

(defun address<= (a b)
  (<= a b))

(defun address> (a b)
  (> a b))

(defun address>= (a b)
  (>= a b))

(defun address-min (a b)
  (min a b))

(defun address-max (a b)
  (max a b))

(defun address+ (addr offset)
  (declare (type address addr) (type fixnum offset))
  (+ addr offset))

(defun address- (addr offset)
  (declare (type address addr) (type fixnum offset))
  (- addr offset))

;;; --- Object Header Constants ---

(defconstant +header-size-shift+ 0
  "Bit position of the size field in the header word.")

(defconstant +header-size-bits+ 24
  "Width of the size field (24 bits).")

(defconstant +header-type-shift+ 24
  "Bit position of the type-tag field in the header word.")

(defconstant +header-type-bits+ 8
  "Width of the type-tag field (8 bits).")

(defconstant +header-flags-shift+ 32
  "Bit position of the flags field in the header word.")

;;; Object type tags (stored in header, not in address)
(defconstant +type-tag-object+ 0)
(defconstant +type-tag-cons+ 1)
(defconstant +type-tag-array+ 2)
(defconstant +type-tag-function+ 3)
(defconstant +type-tag-hash-table+ 4)
(defconstant +type-tag-struct+ 5)

;;; Header gc-flags (16 bits, bits 32-47 of the header word).
;;; These are convenience mirrors of side metadata. The side metadata
;;; bits are authoritative; header flags may be stale. All correctness
;;; depends on side metadata reads through vm-object-* generics.
;;;   bit 0 (32): forwarded
;;;   bit 1 (33): pinned
;;;   bit 2 (34): has-young-pointers
;;;   bit 3 (35): logged
;;;   bits 4-15 (36-47): spare
;;;
;;; There is no header mark flag. The mark bit lives exclusively in
;;; side metadata (see metadata.lisp).
(defconstant +forwarded-flag-bit+ 0)
(defconstant +flag-forwarded+ #b0001)
(defconstant +flag-pinned+ #b0010)
(defconstant +flag-has-young+ #b0100)
(defconstant +flag-logged+ #b1000)
