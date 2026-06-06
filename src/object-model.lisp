(in-package #:clamsara)

;;; --- Object Model ---
;;; Objects in the heap are contiguous ranges of words.
;;; Layout:
;;;   Word 0: HEADER -- [size(24) | type-tag(8) | gc-flags(16) | spare(16)]
;;;   Word 1: SLOT 0
;;;   Word 2: SLOT 1
;;;   ...
;;;   Word N: SLOT N-1
;;;
;;; The header encodes:
;;;   - SIZE: number of reference slots (for tracing)
;;;   - TYPE-TAG: object type for scanning
;;;   - GC-FLAGS: forwarded, pinned, has-young-pointers, logged (16 bits)
;;;   - SPARE: VM-use (16 bits)
;;;
;;; GC-FLAGS are convenience mirrors of side metadata. The side metadata
;;; bits are authoritative. There is no header mark flag; the mark bit
;;; lives exclusively in side metadata (see metadata.lisp).

;;; --- Header Encoding ---

(declaim (inline %make-object-header %header-size %header-type-tag %header-flags %header-flag-set-p))

(defun %make-object-header (size &key (type-tag +type-tag-object+) (flags 0))
  "Construct an object header word with SIZE slots, TYPE-TAG, and FLAGS."
  (logior (ash size +header-size-shift+)
          (ash type-tag +header-type-shift+)
          (ash flags +header-flags-shift+)))

(defun %header-size (header)
  (ldb (byte +header-size-bits+ +header-size-shift+) header))

(defun %header-type-tag (header)
  (ldb (byte +header-type-bits+ +header-type-shift+) header))

(defun %header-flags (header)
  (ldb (byte 16 +header-flags-shift+) header))

(defun %header-flag-set-p (header flag)
  (logtest (ldb (byte 16 +header-flags-shift+) header) flag))

;;; --- Object Access (direct, no VM) ---

(declaim (inline %object-header (setf %object-header) %object-size
                 %object-type-tag %object-flags %object-reference
                 (setf %object-reference)))

(defun %object-header (addr)
  (heap-ref addr))

(defun (setf %object-header) (header addr)
  (setf (heap-ref addr) header))

(defun %object-size (addr)
  (%header-size (%object-header addr)))

(defun %object-type-tag (addr)
  (%header-type-tag (%object-header addr)))

(defun %object-flags (addr)
  (%header-flags (%object-header addr)))

(defun %object-total-words (addr)
  (1+ (%object-size addr)))

(defun %object-reference (addr slot-index)
  (heap-ref (+ (address-index addr) 1 slot-index)))

(defun (setf %object-reference) (value addr slot-index)
  (setf (heap-ref (+ (address-index addr) 1 slot-index)) value))

(defun %object-flag-set-p (addr flag)
  (%header-flag-set-p (%object-header addr) flag))

(defun %set-object-flag (addr flag)
  (let ((header (%object-header addr)))
    (setf (%object-header addr) (logior header (ash flag +header-flags-shift+)))))

(defun %clear-object-flag (addr flag)
  (let ((header (%object-header addr)))
    (setf (%object-header addr) (logandc2 header (ash flag +header-flags-shift+)))))

(defun %write-object-header (addr size type-tag &optional flags)
  (setf (%object-header addr) (%make-object-header size :type-tag type-tag :flags (or flags 0)))
  (when *metadata-words*
    (mark-object-start addr))
  addr)

;;; --- Public Convenience Functions ---

(declaim (inline make-object-header object-header (setf object-header)
                 header-size header-type-tag header-flags header-flag-set-p
                 object-size object-type-tag object-flags object-reference
                 (setf object-reference) object-reference-count object-total-words
                 object-flag-set-p set-object-flag clear-object-flag))

(defun make-object-header (size &key (type-tag +type-tag-object+) (flags 0))
  (%make-object-header size :type-tag type-tag :flags flags))

(defun object-header (addr)
  (%object-header addr))

(defun (setf object-header) (header addr)
  (setf (%object-header addr) header))

(defun header-size (header)
  (%header-size header))

(defun header-type-tag (header)
  (%header-type-tag header))

(defun header-flags (header)
  (%header-flags header))

(defun header-flag-set-p (header flag)
  (%header-flag-set-p header flag))

(defun object-size (addr)
  (%object-size addr))

(defun object-type-tag (addr)
  (%object-type-tag addr))

(defun object-flags (addr)
  (%object-flags addr))

(defun object-reference (addr slot-index)
  (%object-reference addr slot-index))

(defun (setf object-reference) (value addr slot-index)
  (setf (%object-reference addr slot-index) value))

(defun object-reference-count (addr)
  (%object-size addr))

(defun object-total-words (addr)
  (%object-total-words addr))

(defun object-flag-set-p (addr flag)
  (%object-flag-set-p addr flag))

(defun set-object-flag (addr flag)
  (%set-object-flag addr flag))

(defun clear-object-flag (addr flag)
  (%clear-object-flag addr flag))

(defun write-object-header (addr size type-tag &optional flags)
  (%write-object-header addr size type-tag flags))
