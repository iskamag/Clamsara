;;;; sanity.lisp -- the post-collection invariant checker (paper-v8 ch. testing).

(in-package #:clamsara)

(defun %sanity-visit (vm addr reachable errors visits heap-size)
  "Mark ADDR reachable, validate it, recurse into its children.  Returns new ERRORS."
  (when (or (<= addr 0) (gethash addr reachable))
    (return-from %sanity-visit errors))
  (setf (gethash addr reachable) t)
  (incf (svref visits 0))
  (when (> (svref visits 0) heap-size)
    (return-from %sanity-visit
      (cons "sanity traversal exceeded heap size (cycle?)" errors)))
  (unless (vm-object-start-p vm addr)
    (return-from %sanity-visit
      (cons (format nil "reachable ref ~a is not an object start" addr) errors)))
  (when (vm-object-is-forwarded-p vm addr)
    (push (format nil "reachable object ~a is still forwarded" addr) errors))
  (dotimes (i (vm-object-reference-count vm addr) errors)
    (let ((child (vm-object-reference vm addr i)))
      (when (vm-reference-p vm child)
        (setf errors (%sanity-visit vm (ref-strip-or-self vm child)
                                    reachable errors visits heap-size))))))

(defun sanity-check (plan &key (check-mark t) (check-dlg t))
  "Return a list of invariant-violation strings (empty = heap consistent)."
  (let* ((vm (plan-vm plan))
         (heap-size (vm-heap-size vm))
         (reachable (make-hash-table :test 'eql))
         (visits (vector 0))
         (errors nil))
    (declare (fixnum heap-size))
    (map nil (lambda (ref)
               (let ((addr (ref-strip-or-self vm ref)))
                 (when (vm-reference-p vm ref)
                   (setf errors (%sanity-visit vm addr reachable errors
                                               visits heap-size)))))
         (vm-root-vector vm))
    (when check-mark
      (let ((mark (vm-stratum vm :mark)))
        (when mark
          (let ((n (s-popcount mark)))
            (unless (zerop n)
              (push (format nil "mark stratum not clear: ~d bits remain" n) errors))))))
    (when check-dlg
      (maphash
       (lambda (addr _)
         (declare (ignore _))
         (when (vm-object-is-public-p vm addr)
           (dotimes (i (vm-object-reference-count vm addr))
             (let ((c (vm-object-reference vm addr i)))
               (when (and (vm-reference-p vm c)
                          (not (vm-object-is-public-p vm (ref-strip-or-self vm c))))
                 (push (format nil "DLG violated: public ~a -> private ~a"
                               addr (ref-strip-or-self vm c))
                       errors))))))
       reachable))
    (nreverse errors)))

(defun sanity-errors (plan) (sanity-check plan))
