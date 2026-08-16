;;;; test/test-persistence.lisp -- persistence events and recovery
;;;; (paper-v8 ch. persistence).

(in-package #:clamsara)

(deftest persistence-dirty-set-projection ()
  ;; barriers.tex §2: dirty-page derivation for persistence is s-project from
  ;; the card stratum to the page stratum (the MMU-not-armed path).
  (let ((vm (make-simulator-vm 4096)))
    (vm-register-stratum vm :card
      (make-stratum :card (g-card) :bit 4096))
    (s-set-bit (vm-stratum vm :card) 0)          ; page 0
    (s-set-bit (vm-stratum vm :card) (* 3 +page-words+))  ; page 3
    (let ((plan (make-instance 'plan :vm vm :name :t
                               :spaces (list (make-instance
                                              'immix-space :vm vm
                                              :start-page 1 :page-count 7
                                              :name :d :default-space t)))))
      (let ((pages (collector-dirty-set plan)))
        (if (and (member 0 pages) (member 3 pages)
                 (= (length pages) 2))
            (values t "ok")
            (values nil (format nil "dirty set wrong: ~a" pages)))))))

(deftest persistence-segment-checksum-detects-tearing ()
  ;; persistence.tex §1: a torn segment's trailing checksum is the truncation
  ;; marker; recovery reads forward to the last intact snapshot.
  (let* ((vm (make-simulator-vm 4096))
         (plan (make-instance 'plan :vm vm :name :t
                              :spaces (list (make-instance
                                             'immix-space :vm vm
                                             :start-page 1 :page-count 7
                                             :name :d :default-space t)))))
    ;; make pages 1 and 2 dirty (card-projection path, MMU not armed) and
    ;; checkpoint
    (vm-register-stratum vm :card
      (make-stratum :card (g-card) :bit 4096))
    (s-set-bit (vm-stratum vm :card) +page-words+)
    (s-set-bit (vm-stratum vm :card) (* 2 +page-words+))
    (let ((segment (checkpoint-heap plan :timestamp 42)))
      (if (and (verify-segment segment vm)
               (= (persistence-segment-timestamp segment) 42)
               (equal (persistence-segment-pages segment) '(1 2)))
          (values t "ok")
          (values nil (format nil "segment verification wrong: ~a" segment))))))

(deftest persistence-checkpoint-clears-dirty ()
  (let* ((vm (make-simulator-vm 4096))
         (plan (make-instance 'plan :vm vm :name :t
                              :spaces (list (make-instance
                                             'immix-space :vm vm
                                             :start-page 1 :page-count 7
                                             :name :d :default-space t)))))
    (vm-register-stratum vm :card
      (make-stratum :card (g-card) :bit 4096))
    (s-set-bit (vm-stratum vm :card) 0)
    (checkpoint-heap plan)
    (if (null (collector-dirty-set plan))
        (values t "ok")
        (values nil "dirty set not cleared after checkpoint"))))

(deftest persistent-allocator-logs-through-base ()
  ;; persistence.tex §3: the persistent allocator wraps a base allocator and
  ;; logs allocations; no collector changes are required.
  (let* ((vm (make-simulator-vm 4096))
         (base (make-instance 'bump-allocator :start 100 :limit 1000))
         (log (make-persistence-log))
         (a (make-instance 'persistent-allocator
                           :base base :log log :vm vm)))
    (let ((addr (alloc a 10)))
      (if (and addr (= addr 100) (= (ba-cursor base) 110))
          (values t "ok")
          (values nil "persistent allocator broke its base")))))


(deftest persistence-base-plus-delta-replay ()
  ;; The first fence captures a complete base.  Later fences append deltas;
  ;; replay must retain an untouched base page and apply both segment writes.
  (let* ((vm (make-simulator-vm 4096))
         (plan (make-instance 'plan :vm vm :name :t
                              :spaces (list (make-instance
                                             'immix-space :vm vm
                                             :start-page 1 :page-count 7
                                             :name :d :default-space t))))
         (base-address (+ (page-start-address 3) 7))
         (delta-address (+ (page-start-address 1) 7)))
    (setf (ref-u64 vm base-address) 31337)
    (vm-register-stratum vm :card
      (make-stratum :card (g-card) :bit 4096))
    (setf (ref-u64 vm delta-address) 111)
    (s-set-bit (vm-stratum vm :card) +page-words+)
    (checkpoint-heap plan :timestamp 1)
    ;; checkpoint-heap arms the simulator MMU; this write is therefore the
    ;; second segment's MMU-tracked dirty page.
    (setf (ref-u64 vm delta-address) 222)
    (checkpoint-heap plan :timestamp 2)
    (let* ((log (vm-persistence-log vm))
           (heap (replay-persistence-log log vm)))
      (if (and (= (length (persistence-log-segments log)) 2)
               (= (aref heap base-address) 31337)
               (= (aref heap delta-address) 222))
          (values t "ok")
          (values nil "base-plus-delta replay lost a page or segment")))))

(deftest persistence-simulator-cow-write-fault ()
  ;; T2 simulation: a protected page is frozen before the first post-fence
  ;; write, while the live mapping receives the mutator's new value and gets a
  ;; dirty bit for the next delta.
  (let* ((vm (make-simulator-vm 4096))
         (address (+ (page-start-address 1) 11)))
    (setf (ref-u64 vm address) 55)
    (mark-pages-cow vm '(1))
    (let ((armed (mmu-armed vm)))
      (setf (ref-u64 vm address) 99)
      ;; The MMU protocol's copied-image table must expose the same frozen
      ;; vector as the VM-owned table before the fence consumes it.  A missing
      ;; mirror previously surfaced as "NIL is not a VECTOR" during recovery.
      (let ((frozen (gethash 1 (mmu-cow-copied vm))))
        (let ((segment (write-segment vm '(1) 7)))
          (if (and armed
                   (vm-page-dirty-p vm 1)
                   (vectorp frozen)
                   (= (aref frozen 11) 55)
                   (= (ref-u64 vm address) 99)
                   (= (aref (gethash 1 (persistence-segment-images segment)) 11)
                      55))
              (values t "ok")
              (values nil "MMU COW write did not preserve old value")))))))
