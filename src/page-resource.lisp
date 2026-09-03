;;;; page-resource.lisp -- physical page allocation (paper-v8 ch. heap).
;;;;
;;;; Three policies: bitmap (linear scan), monotone (bump, no release),
;;;; free-list (releasable, coalescing).  The simulator heap is one big
;;;; (unsigned-byte 64) array; pages are 512-word runs.

(in-package #:clamsara)

(defclass page-resource ()
  ((total-pages :initarg :total-pages :reader pr-total-pages)
   (heap        :initarg :heap :reader pr-heap)))

(defclass bitmap-page-resource (page-resource)
  ;; FIRST-PAGE excludes the front of a resource from allocation.  The VM-wide
  ;; default resource reserves page 0 for the null sentinel; a per-space
  ;; resource (the large-object space) must not, because its page 0 is an
  ;; ordinary payload page and an exact-fit request at the end of the space
  ;; would otherwise be unreachable.
  ((bitmap :reader pr-bitmap)
   (first-page :initarg :first-page :reader pr-first-page :initform 1)))
(defclass monotone-page-resource (page-resource)
  ((cursor :accessor pr-cursor :initform 1))) ; reserve page 0 (null)
(defclass free-list-page-resource (page-resource)
  ((free :accessor pr-free :initform nil))) ; sorted (start . len) runs

(defmethod shared-initialize :after ((pr bitmap-page-resource) slot-names &key)
  (declare (ignore slot-names))
  (unless (slot-boundp pr 'bitmap)
    (setf (slot-value pr 'bitmap)
          (make-array (pr-total-pages pr) :element-type 'bit :initial-element 0))))

(defmethod shared-initialize :after ((pr free-list-page-resource) slot-names &key)
  (declare (ignore slot-names))
  (unless (slot-boundp pr 'free)
    (setf (pr-free pr) (list (cons 1 (1- (pr-total-pages pr))))))) ; skip page 0

(defun page-resource-p (x) (typep x 'page-resource))

(defun pr-allocated-p (pr page-index)
  (etypecase pr
    (bitmap-page-resource (eql 1 (sbit (pr-bitmap pr) page-index)))
    (monotone-page-resource (> page-index (1- (pr-cursor pr))))
    (free-list-page-resource (not (find page-index (pr-free pr)
                                        :test (lambda (p run)
                                                (<= (car run) p (1- (+ (car run) (cdr run))))))))))

;; Dense bitmap mechanics accept only raw boot storage and fixnum geometry.
;; Generic page-resource dispatch and CLOS slot extraction stay in the thin
;; methods below; LOS binds these raw values into its arena during construction.
(declaim (inline %bitmap-pages-get %bitmap-pages-release))
(defun %bitmap-pages-get (bitmap total first n-pages)
  (declare (type simple-bit-vector bitmap)
           (type fixnum total first n-pages)
           (optimize (speed 3) (safety 0)))
  (loop for start fixnum from first to (- total n-pages)
        when (loop for k fixnum below n-pages
                   always (zerop (sbit bitmap (+ start k))))
          do (loop for k fixnum below n-pages
                   do (setf (sbit bitmap (+ start k)) 1))
             (return start)))

(defun %bitmap-pages-release (bitmap start n-pages)
  (declare (type simple-bit-vector bitmap)
           (type fixnum start n-pages)
           (optimize (speed 3) (safety 0)))
  (loop for k fixnum below n-pages
        do (setf (sbit bitmap (+ start k)) 0)))

(defmethod page-resource-get ((pr bitmap-page-resource) n-pages
                              &key &allow-other-keys)
  (%bitmap-pages-get (pr-bitmap pr) (pr-total-pages pr)
                     (pr-first-page pr) n-pages))

(defmethod page-resource-release ((pr bitmap-page-resource) start n-pages)
  (%bitmap-pages-release (pr-bitmap pr) start n-pages))

(defmethod page-resource-get ((pr monotone-page-resource) n-pages &key &allow-other-keys)
  (let ((c (pr-cursor pr)) (total (pr-total-pages pr)))
    (when (<= (+ c n-pages) total)
      (incf (pr-cursor pr) n-pages)
      c)))

(defmethod page-resource-release ((pr monotone-page-resource) start n-pages)
  (declare (ignore start n-pages))
  nil) ; monotone never releases

(defmethod page-resource-get ((pr free-list-page-resource) n-pages &key &allow-other-keys)
  (loop for cell on (pr-free pr)
        for (start . len) = (car cell)
        when (>= len n-pages)
        do (if (= len n-pages)
               (setf (pr-free pr) (delete (car cell) (pr-free pr)))
               (decf (cdr (car cell)) n-pages))
           (return start)))

(defmethod page-resource-release ((pr free-list-page-resource) start n-pages)
  (let* ((cell (sort (cons (cons start n-pages) (pr-free pr))
                     (lambda (a b) (< (car a) (car b))))))
    ;; coalesce adjacent runs
    (setf (pr-free pr)
          (loop with result = nil
                for (s . l) in cell
                if (null result) do (push (cons s l) result)
                else if (= s (+ (car (first result)) (cdr (first result))))
                do (incf (cdr (first result)) l)
                else do (push (cons s l) result)
                finally (return (nreverse result))))))
