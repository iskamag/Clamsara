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
      ;; memory.tex §2 invariant: after release, no forwarding state remains.
      ;; Check both reachable objects and the *whole* off-heap table: an entry
      ;; for a dead object is just as dangerous when that address is reused.
      (maphash
       (lambda (addr _)
         (declare (ignore _))
         (when (vm-object-is-forwarded-p vm addr)
           (push (format nil "reachable object ~a still forwarded" addr)
                 errors)))
       reachable)
      (let ((fwd (vm-fwd-table vm)))
        (when fwd
          (loop for addr fixnum below (length fwd)
                for destination = (aref fwd addr)
                when (plusp destination)
                  do (push (format nil
                                   "forwarding table not clear @ ~a -> ~a"
                                   addr destination)
                           errors)))))
    (when check-rc
      ;; testing.tex §1: for a :refcount-policy space, reference counts equal
      ;; the actual in-degree, by a verification trace.  Hierarchical spaces
      ;; keep this count per superblock, not in each object's dense RC slot.
      (let ((hierarchical
              (find-if (lambda (s) (eq (space-policy s) :hierarchical))
                       (plan-spaces plan))))
        (cond
          (hierarchical
           (setf errors
                 (%sanity-check-hierarchical-space plan vm hierarchical errors)))
          ((some (lambda (s) (eq (space-policy s) :refcount))
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
                 ;; Check every table cell, including zero cells, so a stale
                 ;; count with no currently reachable incoming edge is found.
                 (loop for addr fixnum below (length rc)
                       for actual = (aref rc addr)
                       for expected = (gethash addr in-degree 0)
                       unless (eql expected actual)
                         do (push
                             (format nil "RC mismatch @ ~a: table ~a, in-degree ~a"
                                     addr actual expected)
                             errors)))))))))
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


(defun %sanity-for-each-object-in-space (vm space function)
  "Call FUNCTION on every object start currently belonging to SPACE.
This deliberately walks the object-start stratum rather than allocator internals:
freed blocks have had those bits cleared, while the check remains useful for
custom hierarchical allocators too."
  (let ((starts (vm-object-start vm))
        (alignment (vm-min-alignment-words vm)))
    (when starts
      (loop for address fixnum from (space-base-address space)
              below (space-end-address space) by alignment
            when (s-test-bit starts address)
              do (funcall function address))))
  space)

(defun %sanity-hierarchical-block-in-use-p (space block)
  (let ((allocator (space-allocator space)))
    (and (typep allocator 'hierarchical-allocator)
         (hierarchical-block-in-use-p allocator block))))

(defun %sanity-check-hierarchy-matrices (space vm errors)
  "Validate the shape and referents of Claimore's per-SB/per-MB matrices.
Relations are remembered sets and may legitimately be stale after a slot is
rewritten; they must not, however, point at a freed/foreign region."
  (let* ((mps (sb-mbs-per-superblock space))
         (bpm (sb-blocks-per-metablock space))
         (nmb (sb-mb-count space))
         (nblocks (sb-block-count space))
         (nsb (sb-count space))
         (mb-matrices (sb-mb-matrices space))
         (block-matrices (sb-block-matrices space)))
    (unless (and mb-matrices (= (length mb-matrices) nsb))
      (push (format nil "hierarchical MB matrix table has wrong size: ~a (expected ~a)"
                    (if mb-matrices (length mb-matrices) 0) nsb)
            errors))
    (when mb-matrices
      (dotimes (sb (min nsb (length mb-matrices)))
        (let ((matrix (aref mb-matrices sb)))
          (unless (matrix-stratum-p matrix)
            (push (format nil "hierarchical MB matrix ~a is missing" sb) errors))
          (when (matrix-stratum-p matrix)
            (let ((regions (matrix-regions matrix)))
              (unless (= regions mps)
                (push (format nil "hierarchical MB matrix ~a has ~a regions (expected ~a)"
                              sb regions mps) errors))
              (dotimes (i regions)
                (dotimes (j regions)
                  (when (eql 1 (matrix-ref matrix i j))
                    (cond
                      ((= i j)
                       (push (format nil "hierarchical MB matrix ~a has diagonal edge ~a"
                                     sb i) errors))
                      (t
                       (let ((src (+ (* sb mps) i))
                             (dst (+ (* sb mps) j))))
                         (unless (and (< src nmb) (< dst nmb)
                                      (loop for b below bpm
                                            thereis
                                            (%sanity-hierarchical-block-in-use-p
                                             space (+ (* src bpm) b)))
                                      (loop for b below bpm
                                            thereis
                                            (%sanity-hierarchical-block-in-use-p
                                             space (+ (* dst bpm) b))))
                           (push
                            (format nil "hierarchical MB matrix edge ~a[~a,~a] targets unused metablock"
                                    sb i j)
                            errors)))))))))))))
    (unless (and block-matrices (= (length block-matrices) nmb))
      (push (format nil "hierarchical block matrix table has wrong size: ~a (expected ~a)"
                    (if block-matrices (length block-matrices) 0) nmb)
            errors))
    (when block-matrices
      (dotimes (mb (min nmb (length block-matrices)))
        (let ((matrix (aref block-matrices mb)))
          (unless (matrix-stratum-p matrix)
            (push (format nil "hierarchical block matrix ~a is missing" mb) errors))
          (when (matrix-stratum-p matrix)
            (let ((regions (matrix-regions matrix)))
              (unless (= regions bpm)
                (push (format nil "hierarchical block matrix ~a has ~a regions (expected ~a)"
                              mb regions bpm) errors))
              (dotimes (i regions)
                (dotimes (j regions)
                  (when (eql 1 (matrix-ref matrix i j))
                    (cond
                      ((= i j)
                       (push (format nil "hierarchical block matrix ~a has diagonal edge ~a"
                                     mb i) errors))
                      (t
                       (let ((src (+ (* mb bpm) i))
                             (dst (+ (* mb bpm) j))))
                         (unless (and (< src nblocks) (< dst nblocks)
                                      (%sanity-hierarchical-block-in-use-p space src)
                                      (%sanity-hierarchical-block-in-use-p space dst))
                           (push
                            (format nil "hierarchical block matrix edge ~a[~a,~a] targets unused block"
                                    mb i j)
                            errors))))))))))))
  errors)

(defun %sanity-check-hierarchy-escape (space vm errors)
  "Ensure escape metadata is confined to live blocks and has only the three
Cla(i)more direction bits.  Direction bits are remembered and need not be
retracted when a slot is overwritten; freeing/reusing a block must clear them."
  (let* ((nblocks (sb-block-count space))
         (escape (or (sb-escape space) (vm-stratum vm :block-escape))))
    (unless escape
      (push "hierarchical escape stratum is missing" errors))
    (when escape
      (dotimes (block nblocks)
        (let ((bits (sb-escape-value space vm block)))
          (unless (zerop (logand bits (lognot 7)))
            (push (format nil "hierarchical escape @ block ~a has invalid bits ~a"
                          block bits) errors))
          (when (and (not (%sanity-hierarchical-block-in-use-p space block))
                     (not (zerop bits)))
            (push (format nil "hierarchical escape @ free block ~a is ~a"
                          block bits) errors)))))
  errors))

(defun %sanity-check-hierarchical-space (plan vm space errors)
  "Check Claimore hierarchy metadata against the current heap.
The RC table is exact at superblock granularity.  Matrix and escape metadata
are remembered sets: their entries are required to name in-use regions, not
necessarily current edges (removing an edge does not synchronously clear a
remembered-set bit)."
  (let* ((nsb (sb-count space))
         (counts (sb-refcounts space))
         (expected (make-array nsb :element-type 'fixnum :initial-element 0))
         (rc (vm-rc-table vm)))
    (unless counts
      (push "hierarchical superblock RC table is missing" errors))
    (when counts
      (unless (= (length counts) nsb)
        (push (format nil "hierarchical RC table has wrong size: ~a (expected ~a)"
                      (length counts) nsb) errors))
      ;; Barrier deltas are logged for every mature target, regardless of the
      ;; source space.  Count the same in-degree from every live object slot.
      (dolist (source-space (plan-spaces plan))
        (%sanity-for-each-object-in-space
         vm source-space
         (lambda (source)
           (vm-map-reference-slots
            vm source
            (lambda (child)
              (when (and (vm-reference-p vm child)
                         (space-contains-p space
                                           (ref-strip-or-self vm child)))
                (let ((sb (sb-index space (ref-strip-or-self vm child))))
                  (when (< sb nsb) (incf (aref expected sb))))))))))
      (loop for sb below (max nsb (length counts))
            for actual = (if (< sb (length counts)) (aref counts sb) 0)
            for wanted = (if (< sb nsb) (aref expected sb) 0)
            unless (eql actual wanted)
              do (push (format nil
                               "hierarchical RC mismatch SB ~a: table ~a, in-degree ~a"
                               sb actual wanted)
                       errors)))
    ;; Per-object RC cells are not authoritative for Claimore and must remain
    ;; clear; a stale cell can otherwise be mistaken for a future object.
    (%sanity-for-each-object-in-space
     vm space
     (lambda (address)
       (when (and rc (< address (length rc))
                  (not (zerop (aref rc address))))
         (push (format nil "hierarchical object RC @ ~a is ~a (expected zero)"
                       address (aref rc address)) errors))))
    (setf errors (%sanity-check-hierarchy-matrices space vm errors))
    (setf errors (%sanity-check-hierarchy-escape space vm errors))
  errors))
