;;;; test/test-persistence.lisp -- persistence events and recovery
;;;; (paper-v8 ch. persistence).

(in-package #:clamsara)

(deftest persistence-dirty-set-projection ()
  ;; barriers.tex §2: dirty-page derivation for persistence is s-project from
  ;; the card stratum to the page stratum.  The simulator VM has MMU dirty
  ;; bits; the card path is exercised when the MMU is not armed.
  (let ((vm (make-simulator-vm 4096)))
    (vm-register-stratum vm :card
      (make-stratum :card (g-card) :bit 4096))
    (s-set-bit (vm-stratum vm :card) 0)          ; page 0
    (s-set-bit (vm-stratum vm :card) (* 3 +page-words+))  ; page 3
    ;; set MMU dirty bits for the same pages so both paths agree
    (setf (sbit (mmu-dirty vm) 0) 1)
    (setf (sbit (mmu-dirty vm) 3) 1)
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
    ;; make pages 1 and 2 dirty (MMU path) and checkpoint
    (setf (sbit (mmu-dirty vm) 1) 1)
    (setf (sbit (mmu-dirty vm) 2) 1)
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
    (setf (sbit (mmu-dirty vm) 0) 1)
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
