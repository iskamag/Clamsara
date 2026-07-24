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
  ((bitmap :reader pr-bitmap)))
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

(defmethod page-resource-get ((pr bitmap-page-resource) n-pages &key &allow-other-keys)
  (let ((bm (pr-bitmap pr)) (total (pr-total-pages pr)))
    (loop for start from 1 to (- total n-pages)
          when (loop for k below n-pages always (zerop (sbit bm (+ start k))))
          do (loop for k below n-pages do (setf (sbit bm (+ start k)) 1))
             (return start))))

(defmethod page-resource-release ((pr bitmap-page-resource) start n-pages)
  (let ((bm (pr-bitmap pr)))
    (loop for k below n-pages do (setf (sbit bm (+ start k)) 0))))

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
