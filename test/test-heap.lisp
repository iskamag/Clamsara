;;;; test/test-heap.lisp -- allocator + space protocol unit tests.

(in-package #:clamsara)

(deftest exported-space-p-is-defined ()
  (let ((space (make-instance 'space :start-page 0 :page-count 1)))
    (if (and (space-p space) (not (space-p 42)))
        (values t "ok")
        (values nil "SPACE-P export does not recognize space instances"))))

(deftest free-list-allocator ()
  (let ((a (make-instance 'free-list-allocator :start 100 :limit 100000))
        addrs)
    (dotimes (i 300)
      (let ((x (alloc a 6)))
        (unless x (return-from free-list-allocator (values nil "alloc failed")))
        (push x addrs)))
    (dolist (x (nreverse addrs)) (free a x 6))
    (if (alloc a 6) (values t "ok") (values nil "realloc failed"))))

(deftest bump-allocator ()
  (let ((a (make-instance 'bump-allocator :start 0 :limit 1000)))
    (alloc a 10) (alloc a 20)
    (if (= (ba-cursor a) 30) (values t "ok") (values nil "bump wrong"))))

(deftest space-contains ()
  (let* ((vm (make-simulator-vm 8192))
         (s (make-instance 'mark-sweep-space :vm vm :start-page 1
                          :page-count 4 :name :t)))
    (if (and (space-contains-p s (ash 1 +log-page-words+))
             (not (space-contains-p s (ash 6 +log-page-words+))))
        (values t "ok") (values nil "contains wrong"))))


(deftest superblock-search-indexes-nonzero-superblocks ()
  ;; Escape targets are addressed by global metablock index, while each
  ;; superblock's closure uses local indices.  A target in SB 1 must therefore
  ;; seed local metablock 1 rather than being silently skipped.
  (let* ((vm (make-simulator-vm 65536))
         (space (make-instance 'superblock-space :vm vm :start-page 1
                               :page-count 64 :name :hierarchy
                               :blocks-per-metablock 2
                               :metablocks-per-superblock 2))
         (allocator (space-allocator space))
         (source-block 4)             ; SB 1, local metablock 0
         (target-block 6))            ; SB 1, local metablock 1
    (setf (aref (hierarchical-allocator-cursors allocator) source-block)
          (+ (sb-block-base space source-block) 1)
          (aref (hierarchical-allocator-cursors allocator) target-block)
          (+ (sb-block-base space target-block) 1))
    (vm-add-root vm (sb-block-base space source-block))
    (setf (sb-escape-value space vm target-block) +escape-from-foreign+)
    (superblock-search space vm)
    (if (= 1 (sbit (aref (%sb-reached-mbs space) 1) 1))
        (values t "ok")
        (values nil "nonzero-superblock metablock was not reached"))))

(deftest superblock-release-zero-count-covers-all-metablocks ()
  ;; A zero-count SB must release blocks in every metablock, not only the
  ;; first one.  Block 6 is SB 1's second metablock with this small geometry.
  (let* ((vm (make-simulator-vm 65536))
         (space (make-instance 'superblock-space :vm vm :start-page 1
                               :page-count 64 :name :hierarchy
                               :blocks-per-metablock 2
                               :metablocks-per-superblock 2))
         (a (space-allocator space))
         (counts (sb-refcounts space))
         (block 6)
         (address (sb-block-base space block)))
    (setf (aref counts 1) 0
          (aref (hierarchical-allocator-cursors a) block) (+ address 2))
    (vm-write-header vm address +tag-object+ 1)
    (superblock-release-zero-count space vm)
    (if (and (= (sb-index space address) 1)
             (= (sb-mb-index space address) 3)
             (minusp (aref (hierarchical-allocator-cursors a) block))
             (not (s-test-bit (vm-object-start vm) address)))
        (values t "ok")
        (values nil "zero-count release skipped a later metablock"))))

(deftest superblock-rebuilds-relations-from-live-payloads ()
  ;; Relocation copies payloads without mutator barriers; rebuilding from live
  ;; layouts must restore both block- and metablock-level edges.
  (let* ((vm (make-simulator-vm 8192))
         (space (make-instance 'superblock-space :vm vm :start-page 1
                               :page-count 5 :name :hierarchy
                               :block-words +g-block+
                               :blocks-per-metablock 2
                               :metablocks-per-superblock 2))
         (a (space-allocator space))
         (source (sb-block-base space 0))
         (target (sb-block-base space 1))
         (foreign-target (sb-block-base space 3)))
    (setf (aref (hierarchical-allocator-cursors a) 0) (+ source 2)
          (aref (hierarchical-allocator-cursors a) 1) (+ target 1)
          (aref (hierarchical-allocator-cursors a) 3) (+ foreign-target 1))
    (vm-write-header vm source +tag-object+ 2)
    (vm-write-header vm target +tag-object+ 0)
    (vm-write-header vm foreign-target +tag-object+ 0)
    (setf (vm-object-reference vm source 0) target
          (vm-object-reference vm source 1) foreign-target)
    (superblock-rebuild-relations space vm)
    (let ((bm (aref (%sb-block-matrices space) 0))
          (mm (aref (%sb-mb-matrices space) 0)))
      (if (and (= 1 (matrix-ref bm 0 1))
               (= 1 (matrix-ref mm 0 1)))
          (values t "relations rebuilt from payload")
          (values nil "relation rebuild omitted a live payload edge")))))

(deftest hierarchical-free-clears-empty-metablock-parent-edge ()
  ;; The MB matrix is a parent-SB remembered set.  Once the final block in a
  ;; target MB dies, both directions of that MB's parent row/column must be
  ;; gone; a trailing partial MB must still retain its declared geometry.
  (let* ((vm (make-simulator-vm 8192))
         ;; Five blocks gives two full MBs plus a one-block trailing MB.
         (space (make-instance 'superblock-space :vm vm :start-page 1
                               :page-count 5 :name :hierarchy
                               :block-words +g-block+
                               :blocks-per-metablock 2
                               :metablocks-per-superblock 2))
         (a (space-allocator space))
         (source-block 0)
         (target-block 2)
         (source (sb-block-base space source-block))
         (target (sb-block-base space target-block))
         (matrix (aref (%sb-mb-matrices space) 0)))
    ;; Make one live block in each of MB 0 and MB 1.  MB 2 is the trailing
    ;; partial MB and remains entirely unused.
    (setf (aref (hierarchical-allocator-cursors a) source-block) (+ source 2)
          (aref (hierarchical-allocator-cursors a) target-block) (+ target 2))
    (vm-write-header vm source +tag-object+ 1)
    (vm-write-header vm target +tag-object+ 1)
    (superblock-note-write space vm source target)
    (let ((target-local-mb (sb-local-mb space (sb-mb-index space target))))
      (if (and (= 1 (matrix-ref matrix 0 target-local-mb))
               (logtest (sb-escape-value space vm target-block)
                        +escape-pointed-to-by-older+))
          (progn
            (hierarchical-free-block a vm target-block)
            (let ((errors (%sanity-check-hierarchical-space nil vm space nil)))
              (if (and (zerop (matrix-ref matrix 0 target-local-mb))
                       (every (lambda (i) (zerop (matrix-ref matrix i target-local-mb)))
                              (loop for i below (sb-mbs-per-superblock space) collect i))
                       (every (lambda (i) (zerop (matrix-ref matrix target-local-mb i)))
                              (loop for i below (sb-mbs-per-superblock space) collect i))
                       (zerop (sb-escape-value space vm target-block))
                       (= 3 (sb-mb-count space))
                       (= 3 (length (%sb-block-matrices space)))
                       (null errors))
                  (values t "ok")
                  (values nil
                          (format nil "stale parent metadata or sanity errors: ~{~a~^; ~}"
                                  errors)))))
          (values nil "source-to-target MB edge was not installed")))))

(deftest mature-source-hierarchy-rejects-foreign-target ()
  ;; A mature source may point into the nursery; that edge must not be fed to
  ;; mature-space block/metablock matrices as if the target were mature.
  (with-clamsara (:plan-type :claimore :heap-size 65536)
    (let* ((vm *clamsara-vm*)
           (plan *clamsara-plan*)
           (mature (cl-mature plan))
           (source (alloc (space-allocator mature) 2))
           (target (clamsara-allocate-object 0)))
      (vm-write-header vm source +tag-object+ 1)
      (let* ((source-block (sb-block-index mature source))
             (source-mb (floor source-block (%sb-bpm mature)))
             (matrix (aref (%sb-mb-matrices mature)
                           (floor source-mb (%sb-mps mature)))))
        (barrier-note-write vm (plan-barrier plan) source 0 target)
        (if (and (zerop (matrix-ref matrix
                                   (sb-local-mb mature source-mb)
                                   (sb-local-mb mature source-mb)))
                 (zerop (sb-escape-value mature vm source-block)))
            (values t "ok")
            (values nil "foreign target polluted mature hierarchy metadata"))))))


;; ---- LOS allocator: dense page-indexed extent bookkeeping ------------------

#+sbcl
(sb-alien:define-alien-variable
    ("bytes_allocated" %los-test-bytes-allocated)
    sb-alien:unsigned-long)

#+sbcl
(deftest los-allocation-makes-no-host-allocations ()
  ;; First-call AND repeated-call measurement of the authored hot bodies
  ;; (no warm-up credit, no warm-up substitution): the measured windows call
  ;; the ordinary functions %LOS-ALLOC / %LOS-FREE / %LOS-RESET directly, so
  ;; generic-function dispatch is explicitly EXCLUDED from the windows (CLOS
  ;; overhead is accounted separately from the allocator body).  The extent
  ;; table is allocated with the allocator at boot, so every window must
  ;; report exactly zero host bytes.
  ;; 2621440 words = 5120 pages; the semispace carve gives LOS 1/16 = 320
  ;; pages, so 101 extents of 3 pages (303) fit with a small margin.
  (let* ((vm (make-simulator-vm 2621440))
         (plan (make-collector :semispace vm 2621440)))
    (boot-gc plan)
    (let* ((a (space-allocator (plan-los plan)))
           ;; Extract the boot arena before every measurement.  This is the
           ;; explicit CLOS boundary; the windows below contain raw structure,
           ;; fixnum, and bit-vector operations only.
           (arena (los-hot-arena a))
           (extents (los-hot-arena-extents arena))
           (base-page (los-hot-arena-base-page arena)))
      ;; FIRST %LOS-ALLOC call
      (sb-vm::close-thread-alloc-region)
      (let ((before %los-test-bytes-allocated))
        (let ((addr (%los-alloc arena 1100)))     ; 1100 words -> 3-page extent
          (sb-vm::close-thread-alloc-region)
          (let ((bytes (- %los-test-bytes-allocated before)))
            (unless (and addr (zerop bytes))
              (return-from los-allocation-makes-no-host-allocations
                (values nil (format nil "first %los-alloc call consed ~D host bytes" bytes))))))
        ;; REPEATED %LOS-ALLOC calls: every allocation must succeed (the
        ;; resource fits) and the window must stay at zero host bytes (the
        ;; extent table never grows).
        (setf before %los-test-bytes-allocated)
        (dotimes (i 100)
          (let ((addr (%los-alloc arena 1100)))
            (unless addr
              (return-from los-allocation-makes-no-host-allocations
                (values nil
                        (format nil "LOS alloc ~D of 100 failed: extent/resource exhausted" i))))))
        (sb-vm::close-thread-alloc-region)
        (let ((bytes (- %los-test-bytes-allocated before)))
          (unless (zerop bytes)
            (return-from los-allocation-makes-no-host-allocations
              (values nil (format nil "100 %%los-alloc calls consed ~D host bytes" bytes)))))
        ;; DIRECT %LOS-FREE of every recorded run
        (setf before %los-test-bytes-allocated)
        (loop for rel below (length extents)
              for pages = (aref extents rel)
              when (plusp pages)
                do (%los-free arena (ash (+ rel base-page) +log-page-words+)))
        (sb-vm::close-thread-alloc-region)
        (let ((bytes (- %los-test-bytes-allocated before)))
          (unless (zerop bytes)
            (return-from los-allocation-makes-no-host-allocations
              (values nil (format nil "101 %%los-free calls consed ~D host bytes" bytes)))))
        ;; DIRECT %LOS-RESET on an empty table
        (setf before %los-test-bytes-allocated)
        (%los-reset arena)
        (sb-vm::close-thread-alloc-region)
        (let ((bytes (- %los-test-bytes-allocated before)))
          (if (zerop bytes)
              (values t "ok: first/repeated %los-alloc, %los-free, %los-reset all 0 host bytes (dispatch excluded)")
              (values nil (format nil "%%los-reset consed ~D host bytes" bytes))))))))

(defun %los-extent-count (a)
  (loop for e across (los-extents a) count (plusp e)))

(deftest los-extents-record-exact-runs ()
  ;; A 2-page request records an extent of exactly 2 at the start page and
  ;; nothing elsewhere; a middle-page address is a no-op on free; freeing
  ;; the recorded start releases exactly the recorded run.
  (let* ((vm (make-simulator-vm 65536))
         (plan (make-collector :semispace vm 65536)))
    (boot-gc plan)
    (let* ((a (space-allocator (plan-los plan)))
           (addr (alloc a (+ +page-words+ 7))))    ; 519 words -> 2 pages
      (unless addr
        (return-from los-extents-record-exact-runs (values nil "alloc failed")))
      (let* ((rel (- (address-page addr) (los-base-page a)))
             (extent (aref (los-extents a) rel)))
        (unless (= extent 2)
          (return-from los-extents-record-exact-runs
            (values nil (format nil "extent ~a is not exactly 2 pages" extent))))
        (unless (and (= (%los-extent-count a) 1)
                     (loop for i below (length (los-extents a))
                           never (and (/= i rel) (plusp (aref (los-extents a) i)))))
          (return-from los-extents-record-exact-runs
            (values nil "extent recorded outside the start page")))
        ;; middle of the run: no-op
        (free a (+ addr +page-words+) 0)
        (unless (= (%los-extent-count a) 1)
          (return-from los-extents-record-exact-runs
            (values nil "middle-page free released a live run")))
        ;; exact run release
        (free a addr 0)
        (unless (and (zerop (%los-extent-count a))
                     (zerop (aref (los-extents a) rel)))
          (return-from los-extents-record-exact-runs
            (values nil "start-page free did not clear the extent")))
        ;; pages returned to the resource and reusable
        (let ((again (alloc a (+ +page-words+ 7))))
          (if (and again (= (%los-extent-count a) 1))
              (values t "ok")
              (values nil (values nil (values nil (values nil "released pages not reusable"))))))))))

(deftest los-extents-coexist-and-reset ()
  ;; Two live large objects coexist as two extents; allocator-reset releases
  ;; both and clears the table.
  (let* ((vm (make-simulator-vm 65536))
         (plan (make-collector :semispace vm 65536)))
    (boot-gc plan)
    (let* ((a (space-allocator (plan-los plan)))
           (x (alloc a 10))
           (y (alloc a (+ +page-words+ 3))))
      (unless (and x y (= (%los-extent-count a) 2))
        (return-from los-extents-coexist-and-reset
          (values nil (format nil "expected 2 extents, got ~a" (%los-extent-count a)))))
      (let ((alive (loop for e across (los-extents a) sum e)))
        (allocator-reset a)
        (if (and (zerop (%los-extent-count a))
                 (zerop (loop for e across (los-extents a) sum e))
                 (= alive (+ 1 (ceiling (+ +page-words+ 3) +page-words+))))
            (values t "ok")
            (values nil "reset did not release exact page totals"))))))

