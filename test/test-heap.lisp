;;;; test/test-heap.lisp -- allocator + space protocol unit tests.

(in-package #:clamsara)

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
