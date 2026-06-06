(in-package #:clamsara)

;;; --- Side Metadata ---
;;; GC flags are stored in side metadata, separate from the object payload.
;;; Each word in *metadata-words* holds per-word metadata bits.
;;; SIDE METADATA IS THE SOLE AUTHORITATIVE SOURCE for mark, log, pin,
;;; age, generation, and object-start. The object header gc-flags field
;;; contains convenience mirrors (forwarded, pinned, has-young-pointers,
;;; logged) but correctness must not depend on header flags. There is no
;;; header mark flag.
;;;
;;; Per-word bit layout:
;;;   bit 0: object-start
;;;   bit 1: marked (authoritative)
;;;   bit 2: logged
;;;   bit 3: pinned
;;;   bits 4-7: age (4 bits)
;;;   bits 8-15: generation (8 bits, typically 1-2 used)
;;;   bits 16-63: reserved (forwarding status for :separate-region mode)

(defconstant +obj-start-bit-offset+ 0)
(defconstant +marked-bit-offset+ 1)
(defconstant +logged-bit-offset+ 2)
(defconstant +pinned-bit-offset+ 3)
(defconstant +age-shift+ 4)
(defconstant +age-bits+ 4)
(defconstant +generation-shift+ 8)

(defvar *metadata-words* nil
  "Simple-vector of (unsigned-byte 64) holding side metadata. Indexed by
address. One word per heap word. This is the authoritative source for
mark, log, pin, age, generation, and object-start.")

;;; --- Forwarding Placement ---
;;; Forwarding placement is controlled by a metadata specification.
;;; :in-header -- the dead object's first word is overwritten with a tagged
;;;   forwarding address (used by STW collectors). Cost: zero extra memory.
;;; :separate-region -- a forwarding-table simple-vector holds forwarding
;;;   destinations (used by concurrent collectors that need CAS-separated state).

(defclass metadata-spec ()
  ((name :initarg :name :reader metadata-spec-name)
   (placement :initarg :placement :reader metadata-spec-placement
    :type (member :in-header :side :separate-region))
   (bit-offset :initarg :bit-offset :reader metadata-spec-bit-offset)))

(defvar *forwarding-placement* :separate-region
  "Default forwarding placement. :in-header for STW VMs, :separate-region
for concurrent VMs. Override with vm-forwarding-placement generic.")

(defvar *forwarding-pointers* nil
  "Simple-vector of fixnums holding forwarding addresses. Indexed by source
address. Only used when *forwarding-placement* is :separate-region.")

(defun ensure-metadata (word-count)
  "Initialize metadata arrays for a heap of WORD-COUNT words."
  (setf *metadata-words* (make-array word-count
                                     :element-type '(unsigned-byte 64)
                                     :initial-element 0))
  (ensure-forwarding-pointers word-count))

(defun ensure-forwarding-pointers (word-count)
  "Initialize forwarding pointer array (for :separate-region mode)."
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
;;; Forwarding placement is determined by *forwarding-placement*.
;;; :in-header -- overwrites dead object's first word with tagged address.
;;; :separate-region -- uses *forwarding-pointers* side table.
;;; set-object-forwarding sets both the side table (when active) and the
;;; header forwarded flag (as a convenience mirror) so that header-only
;;; forwarding checks work as a fast path.

(defun object-forwarded-p (addr)
  "Check if the object at ADDR has been forwarded."
  (declare (type fixnum addr))
  (ecase *forwarding-placement*
    (:in-header
     (object-flag-set-p addr +flag-forwarded+))
    (:separate-region
     (when (and *forwarding-pointers* (< addr (length *forwarding-pointers*)))
       (not (zerop (aref *forwarding-pointers* addr)))))))

(defun object-forwarding-address (addr)
  "Return the forwarding address, or NIL if not forwarded."
  (declare (type fixnum addr))
  (ecase *forwarding-placement*
     (:in-header
      (when (object-flag-set-p addr +flag-forwarded+)
        (ash (object-header addr) -1)))
    (:separate-region
     (when (and *forwarding-pointers* (< addr (length *forwarding-pointers*)))
       (let ((fwd (aref *forwarding-pointers* addr)))
         (if (zerop fwd) nil fwd))))))

(defun set-object-forwarding (src-addr dst-addr)
  "Set the forwarding pointer from SRC-ADDR to DST-ADDR.
For :in-header mode, stores the forwarding address as a tagged 63-bit value
by shifting the address left 1 bit and setting the low bit as a tag."
  (declare (type fixnum src-addr dst-addr))
  (ecase *forwarding-placement*
    (:in-header
     (setf (object-header src-addr) (logior (ash dst-addr 1) 1))
     (set-object-flag src-addr +flag-forwarded+))
    (:separate-region
     (setf (aref *forwarding-pointers* src-addr) dst-addr)
     (set-object-flag src-addr +flag-forwarded+)))
  dst-addr)

(defun clear-object-forwarding (addr)
  (declare (type fixnum addr))
  (ecase *forwarding-placement*
    (:in-header
     (clear-object-flag addr +flag-forwarded+))
    (:separate-region
     (when *forwarding-pointers*
       (setf (aref *forwarding-pointers* addr) 0)
       (clear-object-flag addr +flag-forwarded+)))))

(defun clear-all-forwarding ()
  (ecase *forwarding-placement*
    (:in-header nil)
    (:separate-region
     (when *forwarding-pointers*
       (fill *forwarding-pointers* 0)))))

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
    (setf (aref *metadata-words* addr) set)
    new-age))
