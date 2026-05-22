(in-package #:clamsara)

;;; --- Side Metadata ---
;;; GC flags are stored in side metadata, separate from the object payload.
;;; Each word in *metadata-words* holds per-word metadata bits.
;;;
;;; Bit layout per metadata word:
;;;   bit 0: word-is-object-start
;;;   bit 1: word-is-marked
;;;   bit 2: word-is-logged (has young pointers / nursery object)
;;;   bit 3: word-is-pinned
;;;   bits 4-7: age (4 bits)
;;;   bits 8-31: generation (24 bits, typically 1-2 used)
;;;   bits 32-63: reserved / forwarding

(defconstant +obj-start-bit-offset+ 0)
(defconstant +marked-bit-offset+ 1)
(defconstant +logged-bit-offset+ 2)
(defconstant +pinned-bit-offset+ 3)
(defconstant +age-shift+ 4)
(defconstant +age-bits+ 4)
(defconstant +generation-shift+ 8)

(defvar *metadata-words* nil
  "Simple-vector of (unsigned-byte 64) for side metadata. Indexed by address.")

(defvar *forwarding-pointers* nil
  "Simple-vector of fixnums holding forwarding addresses. Indexed by source address.
Forwarding status is determined by checking whether vm-object-is-forwarded-p returns T.")

(defun ensure-metadata (word-count)
  "Initialize metadata arrays for a heap of WORD-COUNT words."
  (setf *metadata-words* (make-array word-count
                                     :element-type '(unsigned-byte 64)
                                     :initial-element 0))
  (ensure-forwarding-pointers word-count))

(defun ensure-forwarding-pointers (word-count)
  "Initialize forwarding pointer array."
  (setf *forwarding-pointers* (make-array word-count
                                          :element-type 'fixnum
                                          :initial-element 0)))

;;; --- Object-Start Bits ---

(declaim (inline object-start-p mark-object-start unmark-object-start))

(defun object-start-p (addr)
  (declare (type fixnum addr))
  (logbitp +obj-start-bit-offset+ (aref *metadata-words* addr)))

(defun mark-object-start (addr)
  (declare (type fixnum addr))
  (setf (aref *metadata-words* addr)
        (logior (aref *metadata-words* addr) (ash 1 +obj-start-bit-offset+))))

(defun unmark-object-start (addr)
  (declare (type fixnum addr))
  (setf (aref *metadata-words* addr)
        (logandc2 (aref *metadata-words* addr) (ash 1 +obj-start-bit-offset+))))

;;; --- Mark Bits ---

(declaim (inline object-marked-p mark-object unmark-object clear-all-mark-bits))

(defun object-marked-p (addr)
  (declare (type fixnum addr))
  (logbitp +marked-bit-offset+ (aref *metadata-words* addr)))

(defun mark-object (addr)
  (declare (type fixnum addr))
  (setf (aref *metadata-words* addr)
        (logior (aref *metadata-words* addr) (ash 1 +marked-bit-offset+))))

(defun unmark-object (addr)
  (declare (type fixnum addr))
  (setf (aref *metadata-words* addr)
        (logandc2 (aref *metadata-words* addr) (ash 1 +marked-bit-offset+))))

(defun clear-all-mark-bits ()
  (loop for i from 0 below (length *metadata-words*)
        do (setf (aref *metadata-words* i)
                 (logandc2 (aref *metadata-words* i) (ash 1 +marked-bit-offset+)))))

;;; --- Log Bits ---

(declaim (inline object-logged-p log-object unlog-object clear-all-log-bits))

(defun object-logged-p (addr)
  (declare (type fixnum addr))
  (logbitp +logged-bit-offset+ (aref *metadata-words* addr)))

(defun log-object (addr)
  (declare (type fixnum addr))
  (setf (aref *metadata-words* addr)
        (logior (aref *metadata-words* addr) (ash 1 +logged-bit-offset+))))

(defun unlog-object (addr)
  (declare (type fixnum addr))
  (setf (aref *metadata-words* addr)
        (logandc2 (aref *metadata-words* addr) (ash 1 +logged-bit-offset+))))

(defun clear-all-log-bits ()
  (loop for i from 0 below (length *metadata-words*)
        do (setf (aref *metadata-words* i)
                 (logandc2 (aref *metadata-words* i) (ash 1 +logged-bit-offset+)))))

;;; --- Pin Bits ---

(declaim (inline object-pinned-p pin-object unpin-object))

(defun object-pinned-p (addr)
  (declare (type fixnum addr))
  (logbitp +pinned-bit-offset+ (aref *metadata-words* addr)))

(defun pin-object (addr)
  (declare (type fixnum addr))
  (setf (aref *metadata-words* addr)
        (logior (aref *metadata-words* addr) (ash 1 +pinned-bit-offset+))))

(defun unpin-object (addr)
  (declare (type fixnum addr))
  (setf (aref *metadata-words* addr)
        (logandc2 (aref *metadata-words* addr) (ash 1 +pinned-bit-offset+))))

;;; --- Forwarding ---
;;; For stop-the-world collectors, forwarding pointers are stored in-object:
;;; the dead object's first word is overwritten with a forwarding pointer.
;;; We use a side table for thread-safe forwarding since some plans need it.

(defun object-forwarded-p (addr)
  "Check if the object at ADDR has been forwarded (uses in-object header flag)."
  (declare (type fixnum addr))
  (when (and *forwarding-pointers* (< addr (length *forwarding-pointers*)))
    (not (zerop (aref *forwarding-pointers* addr)))))

(defun object-forwarding-address (addr)
  "Return the forwarding address, or NIL if not forwarded."
  (declare (type fixnum addr))
  (when (and *forwarding-pointers* (< addr (length *forwarding-pointers*)))
    (let ((fwd (aref *forwarding-pointers* addr)))
      (if (zerop fwd) nil fwd))))

(defun set-object-forwarding (src-addr dst-addr)
  "Set the forwarding pointer from SRC-ADDR to DST-ADDR."
  (declare (type fixnum src-addr dst-addr))
  (setf (aref *forwarding-pointers* src-addr) dst-addr)
  ;; Also set the forwarded flag in the object header
  (set-object-flag src-addr +flag-forwarded+)
  dst-addr)

(defun clear-object-forwarding (addr)
  (declare (type fixnum addr))
  (setf (aref *forwarding-pointers* addr) 0)
  (clear-object-flag addr +flag-forwarded+))

(defun clear-all-forwarding ()
  (when *forwarding-pointers*
    (fill *forwarding-pointers* 0)))

;;; --- Age (generation survivor count) ---

(defun object-age (addr)
  (declare (type fixnum addr))
  (ldb (byte +age-bits+ +age-shift+) (aref *metadata-words* addr)))

(defun (setf object-age) (new-age addr)
  (declare (type fixnum addr) (type (integer 0 15) new-age))
  (let* ((word (aref *metadata-words* addr))
         (mask (ash (1- (ash 1 +age-bits+)) +age-shift+))
         (cleared (logandc2 word mask))
         (set (logior cleared (ash new-age +age-shift+))))
    (setf (aref *metadata-words* addr) set)))
