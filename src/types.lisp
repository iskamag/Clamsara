;;;; types.lisp -- fundamental constants, granularities, reference encoding.
;;;;
;;;; The simulator heap is a one-dimensional (unsigned-byte 64) array indexed
;;;; by WORD INDEX. A "reference" / "address" is a fixnum word index; 0 is the
;;;; null reference and is never allocated.

(in-package #:clamsara)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defconstant +word-bits+ 64)
  (defconstant +word-bytes+ 8)
  (defconstant +log-word-bytes+ 3)

  ;; Page = 4 KiB = 512 words. The SFT maps page-index -> space.
  (defconstant +page-words+ 512)
  (defconstant +log-page-words+ 9)
  (defconstant +log-page-bytes+ 12)

  ;; Address-space granularities (words per cell), powers of two.
  ;; Illustrative; VM-defined per the spec. Used as stratum granularity.
  (defconstant +g-word+ 1)
  (defconstant +g-line+ 16)            ; 128 B  (Immix line)
  (defconstant +g-card+ 128)           ; 1 KiB  (card / generational remset)
  (defconstant +g-block+ 512)          ; 4 KiB  (Immix block == 1 page)
  (defconstant +g-metablock+ 131072)   ; 1 MiB  (Claimore metablock = 256 blocks)
  (defconstant +g-superblock+ 33554432)) ; 256 MiB (Claimore superblock = 256 metablocks)

;; Granularity accessors (functions, because strata may use custom values).
(declaim (inline g-word g-line g-card g-block g-metablock g-superblock))
(defun g-word       () +g-word+)
(defun g-line       () +g-line+)
(defun g-card       () +g-card+)
(defun g-block      () +g-block+)
(defun g-metablock  () +g-metablock+)
(defun g-superblock () +g-superblock+)

;; ---- references -----------------------------------------------------------

(deftype word-address () '(integer 0 #.most-positive-fixnum))
(declaim (inline word-address-p null-ref null-ref-p))
(defun word-address-p (x) (and (typep x 'fixnum) (not (minusp x))))
(defun null-ref () 0)
(defun null-ref-p (x) (eql x 0))

;; Object type tags (memory.tex).
(defconstant +tag-object+     0)
(defconstant +tag-cons+       1)
(defconstant +tag-array+      2)
(defconstant +tag-function+   3)
(defconstant +tag-hash-table+ 4)
(defconstant +tag-struct+     5)

;; ---- coloured pointers (Axis 2: in-pointer metadata) ---------------------
;; Two colour bits live at positions 62-63 of a reference word. The low 62
;; bits are the bare address. Colour 0 = remapped ("good"); a freshly minted
;; plain address is therefore already good, which is convenient.
(defconstant +colour-bits+ 2)
(defconstant +colour-pos+ 62)
(defconstant +colour-mask+ #.(ash 3 62))  ; bits 62..63 set (the colour field)

(defconstant +colour-remapped+    0) ; good / not-relocating
(defconstant +colour-marked0+     1)
(defconstant +colour-marked1+     2)
(defconstant +colour-finalizable+ 3)

(declaim (inline colour-good colour-remapped colour-marked0 colour-marked1
                 colour-finalizable))
(defun colour-good       () +colour-remapped+)
(defun colour-remapped   () +colour-remapped+)
(defun colour-marked0    () +colour-marked0+)
(defun colour-marked1    () +colour-marked1+)
(defun colour-finalizable() +colour-finalizable+)

;; ---- in-header STW forwarding tag (Axis 2: in-header) ---------------------
;; Bit 63 of the header word marks a dead, forwarded object; the low 48 bits
;; hold the destination address. Live headers keep bit 63 clear.
(defconstant +fwd-tag-bit+ 63)
(defconstant +fwd-addr-bits+ 48)

(declaim (inline header-forwarded-p make-forwarding-header forwarding-address))
(defun header-forwarded-p (header) (logbitp +fwd-tag-bit+ header))
(defun make-forwarding-header (dst) (logior (ash 1 +fwd-tag-bit+)
                                            (ldb (byte +fwd-addr-bits+ 0) dst)))
(defun forwarding-address (header) (ldb (byte +fwd-addr-bits+ 0) header))

;; ---- page/address arithmetic --------------------------------------------

(declaim (inline page-start-address address-page page-start-p))
(defun page-start-address (page-index) (ash page-index +log-page-words+))
(defun address-page (addr) (ash addr (- +log-page-words+)))
(defun page-start-p (addr) (zerop (logand addr (1- +page-words+))))

(declaim (inline align-up log2-int power-of-two-p))
(defun power-of-two-p (n) (and (integerp n) (plusp n) (zerop (logand n (1- n)))))
(defun log2-int (n)
  (declare (optimize (speed 3) (safety 0)))
  (1- (integer-length n)))
(defun align-up (n alignment)          ; alignment a power of two
  (logandc2 (1- (+ n alignment)) (1- alignment)))

;; ---- type-tag keywords ---------------------------------------------------

(defun type-tag (tag)
  (svref #(:object :cons :array :function :hash-table :struct) tag))
(defun tag-for (keyword)
  (position keyword #(:object :cons :array :function :hash-table :struct)))
