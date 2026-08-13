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
  (vm-map-reference-slots vm addr
    (lambda (child)
      (when (vm-reference-p vm child)
        (setf errors (%sanity-visit vm (ref-strip-or-self vm child)
                                    reachable errors visits heap-size)))))
  errors)

(defun sanity-check (plan &key (check-mark t) (check-dlg t)
                              (check-rc t) (check-fwd t))
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
      ;; testing.tex §1: strong DLG for eager closure and trap Variant A;
      ;; for read-guarded strategies every public-to-private edge must be
      ;; recorded in the published-roots set and intercepted by the read
      ;; rule or a trapping stand-in (DLG-r).
      (sanity-check-dlg plan vm reachable errors))
    (when check-fwd
      ;; memory.tex §2 invariant: after release, no forwarding state remains
      ;; for reachable objects; off-heap tables are drained or consistent.
      (maphash
       (lambda (addr _)
         (declare (ignore _))
         (when (vm-object-is-forwarded-p vm addr)
           (push (format nil "reachable object ~a still forwarded" addr)
                 errors)))
       reachable))
    (when check-rc
      ;; testing.tex §1: for a :refcount-policy space, reference counts equal
      ;; the actual in-degree, by a verification trace.  (:hierarchical
      ;; spaces count at superblock granularity, not per object.)
      (when (some (lambda (s) (eq (space-policy s) :refcount))
                  (plan-spaces plan))
        (let ((rc (vm-rc-table vm)))
          (when rc
            (let ((in-degree (make-hash-table :test 'eql)))
              (maphash
               (lambda (src _)
                 (declare (ignore _))
                 (vm-map-reference-slots
                  vm src
                  (lambda (c)
                    (when (vm-reference-p vm c)
                      (let ((bare (ref-strip-or-self vm c)))
                        (incf (gethash bare in-degree 0)))))))
               reachable)
              (maphash
               (lambda (addr _)
                 (declare (ignore _))
                 (let ((expected (gethash addr in-degree 0))
                       (actual (vm-object-rc vm addr)))
                   (unless (eql expected actual)
                     (push (format nil "RC mismatch @ ~a: table ~a, in-degree ~a"
                                   addr actual expected)
                           errors))))
               in-degree))))))
    (nreverse errors)))

(defun sanity-errors (plan) (sanity-check plan))

(defun sanity-check-dlg (plan vm reachable errors)
  "DLG/DLG-r verification (testing.tex §1).  Strong DLG: no public object
  references a private one.  Read-guarded: every public-to-private edge is
  recorded in the published-roots set."
  (let ((strategy (plan-publication plan))
        (read-guarded (and (plan-publication plan)
                           (strategy-read-guarded-p
                            (plan-publication plan)))))
    (maphash
     (lambda (addr _)
       (declare (ignore _))
       (when (vm-object-is-public-p vm addr)
         (vm-map-reference-slots
          vm addr
          (lambda (c)
            (when (and (vm-reference-p vm c)
                       (not (vm-object-is-public-p
                             vm (ref-strip-or-self vm c))))
              (let ((bare (ref-strip-or-self vm c)))
                (cond
                  ((not read-guarded)
                   (push (format nil "DLG violated: public ~a -> private ~a"
                                 addr bare) errors))
                  ((let ((pr (and strategy
                                  (strategy-published-roots strategy))))
                     (not (and pr (published-edge-recorded-p
                                   pr vm addr bare))))
                   (push (format nil
                                 "DLG-r violated: public ~a -> private ~a not in published-roots"
                                 addr bare) errors)))))))))
     reachable))
  errors)
