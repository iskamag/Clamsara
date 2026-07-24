;;;; strata.lisp -- the unifying side-metadata primitive (paper-v8 ch. strata).
;;;;
;;;; A stratum is a dense, typed metadata layer over the heap address space:
;;;;   stratum := (name, granularity, cell-type, default, storage)
;;;; cell-index(addr) = floor(addr / granularity).  Granularity is a power of
;;;; two in WORDS.  Storage policy is invisible to consumers: s-get/s-set
;;;; dispatch on it. The simulator uses host bit-vectors. Besides matching
;;;; paper-v8 chapter 6, this avoids boxing a host bignum whenever bit 63 of an
;;;; (unsigned-byte 64) packed word is set.

(in-package #:clamsara)

(declaim (inline %log2-gran %cell-index %cell-count))
(defun %log2-gran (s) (stratum-log-gran s))
(defun %cell-index (s addr) (ash addr (- (%log2-gran s))))
(defun %cell-count (s) (ceiling (stratum-heap-words s) (stratum-granularity s)))

(defclass stratum ()
  ((name        :initarg :name        :reader stratum-name)
   (granularity :initarg :granularity :reader stratum-granularity)
   (cell-type   :initarg :cell-type   :reader stratum-cell-type)
   (default     :initarg :default     :initform 0 :reader stratum-default)
   (storage     :initarg :storage     :initform :contiguous :reader stratum-storage)
   (heap-words  :initarg :heap-words  :reader stratum-heap-words)
   (log-gran    :reader stratum-log-gran)
   (cells       :accessor stratum-cells)    ; backing store (type-specific)
   (active      :accessor stratum-active :initform nil) ; active-set vector
   (concurrent-p :initarg :concurrent :initform nil :reader stratum-concurrent-p)
   ;; two-level directory:
   (dir         :accessor stratum-dir :initform nil)
   (chunk-cells :accessor stratum-chunk-cells :initform 65536))
  (:default-initargs :cell-type :bit :granularity 1))

(defmethod shared-initialize :after ((s stratum) slot-names &key)
  (declare (ignore slot-names))
  (unless (slot-boundp s 'log-gran)
    (let ((g (stratum-granularity s)))
      (unless (power-of-two-p g)
        (error 'clamsara-error :message
               (format nil "stratum ~a granularity ~a not a power of two"
                       (stratum-name s) g)))
      (setf (slot-value s 'log-gran) (log2-int g))))
  (unless (slot-boundp s 'cells)
    (%stratum-allocate s)))

(declaim (inline %bits-per-cell %default-byte))
(defun %bits-per-cell (cell-type)
  (ecase cell-type (:bit 1) (:u4 4) (:u8 8) (:u16 16) (:ref 64)))
(defun %default-byte (s cell-type)
  (let ((d (stratum-default s)))
    (ecase cell-type
      (:u4 (logior (ldb (byte 4 0) d) (ash (ldb (byte 4 0) d) 4)))
      ((:bit :u8 :u16 :ref) d))))

(defun %stratum-allocate (s)
  (let* ((ct (stratum-cell-type s))
         (cells (%cell-count s))
         (storage (stratum-storage s)))
    (case storage
      ((:contiguous :contiguous-with-active-set)
       (setf (stratum-cells s) (%make-flat ct cells)
             (stratum-active s)
             (if (eq storage :contiguous-with-active-set)
                 (make-array cells :element-type 'fixnum
                             :initial-element 0 :fill-pointer 0)
                 nil)))
      (:two-level
       ;; A target faults chunks in from immortal pages. The host simulator has
       ;; no immortal array allocator, so allocate its chunks at boot rather
       ;; than lazily calling MAKE-ARRAY during collection.
       (let* ((chunks (ceiling cells (stratum-chunk-cells s)))
              (dir (make-array chunks :initial-element nil)))
         (dotimes (chunk chunks)
           (setf (aref dir chunk)
                 (%make-flat ct (stratum-chunk-cells s))))
         (setf (stratum-dir s) dir)))
      (t (error 'clamsara-error
                :message (format nil "unknown storage ~a" storage))))
    s))

(defun %make-flat (cell-type cells)
  (ecase cell-type
    (:bit  (make-array cells :element-type 'bit :initial-element 0))
    (:u4   (make-array (ceiling cells 2) :element-type '(unsigned-byte 8)
                       :initial-element 0))
    (:u8   (make-array cells :element-type '(unsigned-byte 8) :initial-element 0))
    (:u16  (make-array cells :element-type '(unsigned-byte 16) :initial-element 0))
    (:ref  (make-array cells :element-type '(unsigned-byte 64) :initial-element 0))))

(defun make-stratum (name granularity cell-type heap-words
                     &key (default 0) (storage :contiguous) concurrent)
  "Construct and allocate a stratum.  GRANULARITY is words/cell (power of two)."
  (make-instance 'stratum
                 :name name :granularity granularity :cell-type cell-type
                 :default default :storage storage :heap-words heap-words
                 :concurrent concurrent))

(defun stratum-p (x) (typep x 'stratum))

;; ---- per-storage access helpers ------------------------------------------

(declaim (inline %flat-get %flat-set))
(defun %flat-get (s idx)
  (ecase (stratum-cell-type s)
    (:bit  (sbit (stratum-cells s) idx))
    (:u4   (let ((by (ash idx -1)) (ni (logand idx 1)))
             (ldb (byte 4 (* ni 4)) (aref (stratum-cells s) by))))
    (:u8   (aref (stratum-cells s) idx))
    (:u16  (aref (stratum-cells s) idx))
    (:ref  (aref (stratum-cells s) idx))))
(defun %flat-set (s idx v)
  (ecase (stratum-cell-type s)
    (:bit  (setf (sbit (stratum-cells s) idx) (if (oddp v) 1 0)))
    (:u4   (let ((by (ash idx -1)) (ni (logand idx 1)) (vec (stratum-cells s)))
             (setf (aref vec by)
                   (dpb (ldb (byte 4 0) v) (byte 4 (* ni 4)) (aref vec by)))))
    (:u8   (setf (aref (stratum-cells s) idx) (ldb (byte 8 0) v)))
    (:u16  (setf (aref (stratum-cells s) idx) (ldb (byte 16 0) v)))
    (:ref  (setf (aref (stratum-cells s) idx) v))))

(declaim (inline %chunk-get %chunk-ensure))
(defun %chunk-ensure (s chunk)
  (or (aref (stratum-dir s) chunk)
      (error 'clamsara-error
             :message "unallocated two-level stratum chunk")))
(defun %chunk-get (s idx)
  (let* ((cs (stratum-chunk-cells s))
         (chunk (floor idx cs))
         (off (logand idx (1- cs)))
         (arr (aref (stratum-dir s) chunk)))
    (if arr
        (ecase (stratum-cell-type s)
          (:bit  (sbit arr off))
          (:u4   (ldb (byte 4 (* (logand off 1) 4)) (aref arr (ash off -1))))
          (:u8   (aref arr off))
          (:u16  (aref arr off))
          (:ref  (aref arr off)))
        (stratum-default s))))

;; ---- scalar operations ---------------------------------------------------

(declaim (inline s-get s-set s-test-bit s-set-bit s-clear-bit))
(defun s-get (s addr)
  (let ((idx (%cell-index s addr)))
    (ecase (stratum-storage s)
      (:contiguous-with-active-set (%flat-get s idx))
      (:contiguous (%flat-get s idx))
      (:two-level (%chunk-get s idx)))))

(defun s-set (s addr v)
  (let ((idx (%cell-index s addr)))
    (ecase (stratum-storage s)
      ((:contiguous :contiguous-with-active-set)
       (let ((prev (%flat-get s idx)))
         (%flat-set s idx v)
         (when (and (stratum-active s) (eql prev (stratum-default s))
                    (not (eql v (stratum-default s))))
           ;; The active set is only a hint. If duplicate clear/set traffic
           ;; fills it, disable the hint and use the dense backing.
           (unless (vector-push idx (stratum-active s))
             (setf (stratum-active s) nil)))))
      (:two-level
       (let* ((cs (stratum-chunk-cells s))
              (chunk (floor idx cs)) (off (logand idx (1- cs)))
              (arr (%chunk-ensure s chunk)))
         (ecase (stratum-cell-type s)
           (:bit  (setf (sbit arr off) (if (oddp v) 1 0)))
           (:u4   (setf (aref arr (ash off -1))
                        (dpb (ldb (byte 4 0) v) (byte 4 (* (logand off 1) 4))
                             (aref arr (ash off -1)))))
           (:u8   (setf (aref arr off) (ldb (byte 8 0) v)))
           (:u16  (setf (aref arr off) (ldb (byte 16 0) v)))
           (:ref  (setf (aref arr off) v))))))))

(defun s-test-bit (s addr)
  (declare (optimize (speed 3) (safety 0)))
  (not (eql (s-get s addr) (stratum-default s))))

(defun s-set-bit (s addr) (s-set s addr 1))
(defun s-clear-bit (s addr) (s-set s addr 0))

(defun s-cas (s addr old new)
  "Compare-and-swap a cell.  Single-threaded simulator: a plain compare-set."
  (let ((cur (s-get s addr)))
    (cond ((eql cur old) (s-set s addr new) t)
          (t nil))))

;; ---- bulk operations -----------------------------------------------------

(defun %range-bounds (s range)
  "Return (values start-idx end-idx) in CELL space for RANGE (word cons) or whole."
  (if range
      (values (%cell-index s (car range)) (%cell-index s (cdr range)))
      (values 0 (%cell-count s))))

(defun s-clear-range (s start-addr end-addr)
  "Reset cells covering [START-ADDR, END-ADDR) without allocating a range cons."
  (let ((def (stratum-default s)))
    (loop for idx from (%cell-index s start-addr)
          below (%cell-index s end-addr)
          do (s-set s (ash idx (%log2-gran s)) def)))
  s)

(defun s-clear (s &optional range)
  (let ((def (stratum-default s)))
    (cond
      ((and (null range) (member (stratum-storage s) '(:contiguous :contiguous-with-active-set)))
       (ecase (stratum-cell-type s)
         (:bit  (fill (stratum-cells s) 0))
         (:u4   (fill (stratum-cells s) (%default-byte s :u4)))
         (:u8   (fill (stratum-cells s) (ldb (byte 8 0) def)))
         (:u16  (fill (stratum-cells s) (ldb (byte 16 0) def)))
         (:ref  (fill (stratum-cells s) def)))
       (when (stratum-active s)
         (setf (fill-pointer (stratum-active s)) 0)))
      (t
       (if range
           (s-clear-range s (car range) (cdr range))
           (s-clear-range s 0 (stratum-heap-words s)))
       (when (stratum-active s)
         (setf (fill-pointer (stratum-active s)) 0))))))

(defun s-fold (s range fn acc)
  "Reduce FN over cells in RANGE; FN takes (value acc) -> new acc."
  (multiple-value-bind (start end) (%range-bounds s range)
    (let ((shift (%log2-gran s)))
      (loop for idx from start below end
            for addr = (ash idx shift)
            do (setf acc (funcall fn (s-get s addr) acc)))
      acc)))

(defun s-popcount (s &optional range)
  "Number of non-default cells in RANGE. Fast path for a host bit-vector;
  a bounded RANGE counts only the cells in [start,end)."
  (cond
    ((and (eq (stratum-cell-type s) :bit)
          (member (stratum-storage s) '(:contiguous :contiguous-with-active-set)))
     (let ((vec (stratum-cells s)) (sum 0))
       (declare (fixnum sum))
       (if (null range)
           (setf sum (count 1 vec))
           (multiple-value-bind (start end) (%range-bounds s range)
             (loop for c from start below end
                   when (eql 1 (sbit vec c))
                   do (incf sum))))
       sum))
    (t
     (s-fold s range (lambda (v n) (if (eql v (stratum-default s)) n (1+ n))) 0))))

(defun s-for-set-cells (s range fn)
  "Call FN on each address whose cell is non-default (set), in RANGE.
  The simulator scans its host bit-vector; raw-memory backends splice a
  word-at-a-time bit scan at boot."
  (multiple-value-bind (start end) (%range-bounds s range)
    (let ((shift (%log2-gran s)))
      (cond
        ((and (eq (stratum-cell-type s) :bit)
              (member (stratum-storage s) '(:contiguous :contiguous-with-active-set)))
         (let ((vec (stratum-cells s)))
           (loop for idx from start below end
                 when (eql 1 (sbit vec idx))
                 do (funcall fn (ash idx shift)))))
        ((stratum-active s)
         (loop for idx across (stratum-active s)
               when (and (>= idx start) (< idx end)
                         (not (eql (s-get s (ash idx shift)) (stratum-default s))))
               do (funcall fn (ash idx shift))))
        (t
         (loop for idx from start below end
               for addr = (ash idx shift)
               unless (eql (s-get s addr) (stratum-default s))
               do (funcall fn addr)))))))

(defun s-project (src dst reduce)
  "Coarsen: dst[j] <- REDUCE over src cells covered by dst cell j.
  REDUCE is :any, :all, or :sum.  dst granularity must be >= src granularity."
  (let* ((sg (stratum-granularity src)) (dg (stratum-granularity dst))
         (factor (truncate dg sg)))
    (assert (>= dg sg) ()
            "s-project: dst granularity ~a < src ~a" dg sg)
    (assert (= (* factor sg) dg) () "s-project: granularities must nest")
      (let ((dst-count (ceiling (stratum-heap-words dst) dg))
            (sg-log (log2-int sg)) (dg-log (log2-int dg)))
        (loop for j below dst-count
              for any-p = nil
              for all-p = t
              for sum = 0
              do (loop for k below factor
                       for v = (s-get src (ash (+ (* j factor) k) sg-log))
                       do (setf any-p (or any-p (not (eql v (stratum-default src)))))
                          (setf all-p (and all-p (not (eql v (stratum-default src)))))
                          (incf sum v))
              do (ecase reduce
                   (:any (when any-p (s-set dst (ash j dg-log) 1)))
                   (:all (when all-p (s-set dst (ash j dg-log) 1)))
                   (:sum (s-set dst (ash j dg-log) sum)))))))

(defun s-refine (src dst)
  "Inverse hint: a set coarse src cell marks its fine dst cells suspect."
  (let* ((sg (stratum-granularity src)) (dg (stratum-granularity dst))
         (factor (truncate sg dg)))
    (assert (>= sg dg) () "s-refine: src granularity ~a < dst ~a" sg dg)
    (assert (= (* factor dg) sg) () "s-refine: granularities must nest")
    (let ((src-count (ceiling (stratum-heap-words src) sg)))
      (loop for i below src-count
            when (not (eql (s-get src (ash i (log2-int sg))) (stratum-default src)))
            do (loop for k below factor
                     do (s-set dst (ash (+ (* i factor) k) (log2-int dg)) 1))))))

;; ---- matrix stratum (remembered sets, closure) ---------------------------

(defclass matrix-stratum ()
  ((granularity :initarg :granularity :reader matrix-granularity)
   (direction   :initarg :direction :reader matrix-direction) ; :points-to :pointed-by
   (regions     :initarg :regions :reader matrix-regions)
   (bits        :accessor matrix-bits)           ; host bit-vector
   (words-per-row :reader matrix-words-per-row))
  (:default-initargs :direction :points-to))

(defmethod shared-initialize :after ((m matrix-stratum) slot-names &key)
  (declare (ignore slot-names))
  (unless (slot-boundp m 'words-per-row)
    (let* ((r (matrix-regions m))
           (bits-per-row r)
           (wpr bits-per-row))
      (setf (slot-value m 'words-per-row) wpr)
      (unless (slot-boundp m 'bits)
        (setf (matrix-bits m) (make-array (* wpr r)
                                          :element-type 'bit
                                          :initial-element 0))
        ;; diagonal must be zero (a self-reference is not a cross-region edge)
        (loop for i below r do (matrix-clear m i i))))))

(defun make-matrix-stratum (granularity regions &key (direction :points-to))
  (make-instance 'matrix-stratum :granularity granularity
                 :regions regions :direction direction))

(defun matrix-stratum-p (x) (typep x 'matrix-stratum))

(declaim (inline %m-bit-index))
(defun %m-bit-index (m i j)
  (+ (* i (matrix-words-per-row m)) j))

(defun matrix-ref (m i j)
  (sbit (matrix-bits m) (%m-bit-index m i j)))
(defun matrix-set (m i j)
  (setf (sbit (matrix-bits m) (%m-bit-index m i j)) 1))
(defun matrix-clear (m i j)
  (setf (sbit (matrix-bits m) (%m-bit-index m i j)) 0))

(defun matrix-row (m i)
  "Return a fresh bit-vector containing row I."
  (let* ((wpr (matrix-words-per-row m))
         (base (* i wpr))
         (row (make-array wpr :element-type 'bit :initial-element 0)))
    (replace row (matrix-bits m) :start2 base :end2 (+ base wpr))
    row))

(defun matrix-column (m j)
  "Return a fresh bit-vector (length regions) of column j."
  (let* ((r (matrix-regions m)) (col (make-array r :element-type 'bit
                                                  :initial-element 0)))
    (loop for i below r do (setf (sbit col i) (matrix-ref m i j)))
    col))

(defun matrix-clear-all (m) (fill (matrix-bits m) 0))

(defun matrix-closure (m roots &optional (max-passes nil))
  "Transitive closure from ROOTS (bit-vector of regions) over the matrix.
  Returns a fresh bit-vector of reached regions.  MAX-PASSES bounds diameter
  (NIL = run to fixpoint)."
  (let* ((r (matrix-regions m))
         (live (make-array r :element-type 'bit :initial-contents
                           (loop for i below r collect (if (< i (length roots))
                                                           (sbit roots i) 0))))
         (passes 0))
    (loop
      (when (and max-passes (>= passes max-passes)) (return))
      (let ((changed nil))
        (dotimes (i r)
          (when (eql 1 (sbit live i))
            (let ((base (* i (matrix-words-per-row m))))
              (dotimes (j r)
                (when (and (eql 1 (sbit (matrix-bits m) (+ base j)))
                           (zerop (sbit live j)))
                  (setf (sbit live j) 1 changed t))))))
        (incf passes)
        (unless changed (return))))
    live))

(defun matrix-closure-bounded (m roots passes)
  "Bounded closure: exactly PASSES OR-rounds (the spec's `repeat k times`)."
  (matrix-closure m roots passes))

;; ---- convenience ---------------------------------------------------------

(defun stratum-address-range (s start-word end-word)
  "Return (values start-idx end-idx) of cells covering [start,end) words."
  (values (%cell-index s start-word) (%cell-index s end-word)))
