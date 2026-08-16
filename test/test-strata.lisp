;;;; test/test-strata.lisp -- stratum + matrix closure unit tests.

(in-package #:clamsara)

(deftest strata-scalar ()
  (let ((s (make-stratum :mark (g-word) :bit 65536)))
    (s-set-bit s 5) (s-set-bit s 100) (s-set-bit s 65535)
    (if (= (s-popcount s) 3) (values t "scalar ok")
        (values nil "popcount wrong"))))

(deftest strata-rejects-concurrent-active-set ()
  (let ((caught nil))
    (handler-case
        (make-stratum :unsafe (g-word) :bit 32
                      :storage :contiguous-with-active-set
                      :concurrent t)
      (clamsara-error () (setf caught t)))
    (if caught
        (values t "concurrent active-set rejected")
        (values nil "concurrent active-set accepted"))))

(deftest strata-heap-base-indexing ()
  (let ((s (make-stratum :base (g-card) :bit 256 :heap-base 128)) got)
    (s-set-bit s 128)
    (s-set-bit s (+ 128 (g-card)))
    (s-for-set-cells s nil (lambda (address) (push address got)))
    (s-clear-range s 128 (+ 128 (g-card)))
    (if (and (= (s-get s 128) 0)
             (= (s-get s (+ 128 (g-card))) 1)
             (= (s-popcount s) 1)
             (equal (sort got #'<) (list 128 (+ 128 (g-card)))))
        (values t "heap-base indexing ok")
        (values nil "heap-base indexing wrong"))))

(deftest strata-u4 ()
  (let ((s (make-stratum :age (g-word) :u4 65536)))
    (s-set s 8 7) (s-set s 9 15)
    (if (and (= (s-get s 8) 7) (= (s-get s 9) 15)) (values t "u4 ok")
        (values nil "u4 wrong"))))

(deftest strata-for-set-cells ()
  (let ((s (make-stratum :m (g-word) :bit 65536)) got)
    (s-set-bit s 5) (s-set-bit s 100) (s-set-bit s 65535)
    (s-for-set-cells s nil (lambda (a) (push a got)))
    (if (equal (sort got #'<) '(5 100 65535)) (values t "iter ok")
        (values nil "iteration wrong"))))

(deftest strata-project ()
  (let ((card (make-stratum :card (g-card) :bit 65536))
        (pg (make-stratum :pg (g-block) :bit 65536)))
    (s-set-bit card 0) (s-set-bit card (* 5 (g-card)))
    (s-project card pg :any)
    (if (= (s-popcount pg) 2) (values t "project ok")
        (values nil "project wrong"))))

(deftest matrix-closure ()
  (let ((m (make-matrix-stratum (g-block) 8)))
    (matrix-set m 0 1) (matrix-set m 1 2) (matrix-set m 2 4)
    (let ((roots (make-array 8 :element-type 'bit :initial-element 0)))
      (setf (sbit roots 0) 1)
      (let ((live (matrix-closure m roots)))
        (if (and (eql 1 (sbit live 0)) (eql 1 (sbit live 1))
                 (eql 1 (sbit live 2)) (eql 1 (sbit live 4))
                 (eql 0 (sbit live 3)))
            (values t "closure ok")
            (values nil "closure wrong"))))))

(deftest matrix-closure-pointed-by ()
  ;; In a pointed-by matrix M[target,source], outgoing edges are columns,
  ;; rather than rows.  This is the transpose of the points-to representation.
  (let ((m (make-matrix-stratum (g-block) 8 :direction :pointed-by)))
    (matrix-set m 1 0) (matrix-set m 2 1) (matrix-set m 4 2)
    (let ((roots (make-array 8 :element-type 'bit :initial-element 0)))
      (setf (sbit roots 0) 1)
      (let ((live (matrix-closure m roots)))
        (if (and (eql 1 (sbit live 0)) (eql 1 (sbit live 1))
                 (eql 1 (sbit live 2)) (eql 1 (sbit live 4))
                 (eql 0 (sbit live 3)))
            (values t "pointed-by closure ok")
            (values nil "pointed-by closure traversed rows"))))))

(deftest private-space-defaults-to-request-scope ()
  ;; The private space class carries ownership in its constraints; a plan
  ;; cannot accidentally treat it as global merely because no initarg was
  ;; supplied by its constructor.
  (let* ((vm (make-simulator-vm 4096))
         (s (make-instance 'private-immix-space :vm vm
                           :start-page 1 :page-count 2 :name :private)))
    (if (eq (scope (space-constraints s)) :request)
        (values t "private scope ok")
        (values nil "private space defaulted to global"))))

(deftest plan-rejects-private-space-with-global-scope ()
  ;; Scope is an invariant across the plan and every non-global space, not
  ;; just a requirement that a plan publication strategy be non-NIL.
  (let* ((vm (make-simulator-vm 4096))
         (s (make-instance 'private-immix-space :vm vm
                           :start-page 1 :page-count 2 :name :private))
         (caught nil))
    (handler-case
        (finalize-plan
         (make-instance 'plan :name :bad-scope :vm vm :spaces (list s)))
      (plan-incompatible () (setf caught t)))
    (if caught
        (values t "scope mismatch rejected")
        (values nil "global plan accepted private space"))))

(deftest plan-rejects-private-scope-without-private-space ()
  (let* ((vm (make-simulator-vm 4096))
         (s (make-instance 'immix-space :vm vm
                           :start-page 1 :page-count 2 :name :global))
         (caught nil))
    (handler-case
        (finalize-plan
         (make-instance 'plan :name :bad-scope :vm vm :spaces (list s)
                        :publication (make-instance 'eager-closure)
                        :constraints (make-instance 'plan-constraints
                                                    :scope :request)))
      (plan-incompatible () (setf caught t)))
    (if caught
        (values t "missing private space rejected")
        (values nil "private plan accepted only global spaces"))))

(deftest matrix-peel ()
  ;; Greatest-fixpoint peel (iskamag.com/posts/remsets).  Same graph as the
  ;; closure test; with region 0 as the only root, the peeled live set must
  ;; equal the forward closure (both compute the root-reachable set).
  (let ((m (make-matrix-stratum (g-block) 8)))
    (matrix-set m 0 1) (matrix-set m 1 2) (matrix-set m 2 4)
    (let ((roots (make-array 8 :element-type 'bit :initial-element 0)))
      (setf (sbit roots 0) 1)
      (let ((live (matrix-peel m roots)))
        (if (and (eql 1 (sbit live 0)) (eql 1 (sbit live 1))
                 (eql 1 (sbit live 2)) (eql 1 (sbit live 4))
                 (eql 0 (sbit live 3)) (eql 0 (sbit live 5)))
            (values t "peel ok")
            (values nil "peel wrong"))))))

(deftest matrix-peel-agrees-with-closure ()
  ;; A greatest-fixpoint peel with roots pinned converges to the same live set
  ;; as the least-fixpoint forward closure from those roots.
  (let ((m (make-matrix-stratum (g-block) 12))
        (roots (make-array 12 :element-type 'bit :initial-element 0)))
    ;; a small sparse graph: 0->1, 1->3, 2->3, 3->5, 4->5, 5->7, 6->9, 8->2
    (dolist (edge '((0 1) (1 3) (2 3) (3 5) (4 5) (5 7) (6 9) (8 2)))
      (matrix-set m (first edge) (second edge)))
    (setf (sbit roots 0) 1 (sbit roots 2) 1 (sbit roots 6) 1)
    (let ((reached (matrix-closure m roots))
          (peeled (matrix-peel m roots)))
      (if (equalp reached peeled)
          (values t "ok")
          (values nil (format nil "closure ~a != peel ~a"
                              (coerce reached 'list) (coerce peeled 'list)))))))

(deftest matrix-row-into-and-column-into-use-preallocated-buffer ()
  (let ((m (make-matrix-stratum (g-block) 8)))
    (matrix-set m 0 1) (matrix-set m 0 4)
    (let ((row-buf (make-array 8 :element-type 'bit :initial-element 0))
          (col-buf (make-array 8 :element-type 'bit :initial-element 0)))
      (matrix-row-into m 0 row-buf)
      (matrix-column-into m 1 col-buf)
      (if (and (eql 1 (sbit row-buf 1)) (eql 1 (sbit row-buf 4))
               (eql 0 (sbit row-buf 0))          ; diagonal cleared
               (eql 1 (sbit col-buf 0)))         ; column 1 has a 1 in row 0
          (values t "ok")
          (values nil "row/column-into wrong")))))

#+sbcl
(progn
  (sb-alien:define-alien-variable
      ("bytes_allocated" %matrix-bytes-allocated)
      sb-alien:unsigned-long)
  (deftest matrix-closure-and-peel-are-allocation-free ()
    ;; strata.md §6: the collector cannot call the host allocator.  The matrix
    ;; closure and peel must run entirely on boot-allocated scratch, matching
    ;; the bitmatrices C reference's `static` storage.
    (let ((m (make-matrix-stratum (g-block) 256))
          (roots (make-array 256 :element-type 'bit :initial-element 0)))
      (dotimes (i 256)
        (dotimes (k 4)
          (matrix-set m i (mod (+ i 1 (* k 37)) 256))))
      (dotimes (k 3) (setf (sbit roots (* k 85)) 1))
      (matrix-closure m roots)
      (matrix-peel m roots)
      (sb-vm::close-thread-alloc-region)
      (let ((before %matrix-bytes-allocated))
        (dotimes (i 10000)
          (matrix-closure m roots)
          (matrix-peel m roots))
        (let ((bytes (- %matrix-bytes-allocated before)))
          (if (zerop bytes)
              (values t "ok")
              (values nil (format nil "matrix consed ~D host bytes" bytes))))))))

(deftest page-resource ()
  (let ((pr (make-instance 'bitmap-page-resource :total-pages 64 :heap nil)))
    (let ((p1 (page-resource-get pr 3)) (p2 (page-resource-get pr 2)))
      (page-resource-release pr p1 3)
      (if (and p1 p2 (not (= p1 p2)) (= (page-resource-get pr 3) p1))
          (values t "pr ok") (values nil "pr wrong")))))
