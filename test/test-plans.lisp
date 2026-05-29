(in-package #:clamsara.tests)

(def-suite test-plans :description "Systematic tests for all 9 GC plans"
  :in clamsara-tests)

(in-suite test-plans)

;;; --- Helpers ---

(defun %root-test-body (vm)
  "Common body for root-preservation tests."
  (let ((addr (allocate-fill *active-plan* 3 42 99 777)))
    (clamsara-register-root addr)
    (clamsara-gc)
    (let ((s (get-root-addr *active-plan*)))
      (is (not (null s)))
      (is (vm-object-start-p vm s))
      (is (= 42 (vm-object-reference vm s 0)))
      (is (= 99 (vm-object-reference vm s 1)))
      (is (= 777 (vm-object-reference vm s 2))))))

(defun %dead-test-body (vm)
  "Common body for dead-reclamation tests."
  (let ((root (allocate-fill *active-plan* 2 0 0))
        (dead (allocate-fill *active-plan* 2 0 0)))
    (setf (vm-object-reference vm root 0) root)
    (setf (vm-object-reference vm dead 0) dead)
    (clamsara-register-root root)
    (clamsara-gc)
    (is (vm-object-start-p vm root))
    (is (not (vm-object-is-marked-p vm dead)))
    (is (not (null (allocate-object *active-plan* 3))))))

(defun %list-test-body (vm)
  "Common body for linked-list preservation tests."
  (let* ((head (build-linked-list *active-plan* 50))
         (vals (linked-list-values *active-plan* head)))
    (clamsara-register-root head)
    (clamsara-gc)
    (let ((s (get-root-addr *active-plan*)))
      (is (= 50 (length (linked-list-values *active-plan* s))))
      (is (equal vals (linked-list-values *active-plan* s))))))

(defun %closure-test-body (vm)
  "Common body for transitive-closure tests."
  (let* ((grandchild (allocate-fill *active-plan* 2 777 0))
         (child (allocate-fill *active-plan* 2 grandchild 0))
         (root  (allocate-fill *active-plan* 2 child 0)))
    (clamsara-register-root root)
    (clamsara-gc)
    (let ((s (get-root-addr *active-plan*)))
      (let ((c (vm-object-reference vm s 0)))
        (is (not (zerop c)))
        (let ((g (vm-object-reference vm c 0)))
          (is (not (zerop g)))
          (is (= 777 (vm-object-reference vm g 0))))))))

(defun %cycle-test-body (vm)
  "Common body for multi-cycle tests."
  (dotimes (i 5)
    (clear-roots *active-plan*)
    (let ((addr (allocate-fill *active-plan* 2 i 0)))
      (clamsara-register-root addr)
      (clamsara-gc)
      (is (= i (vm-object-reference vm (get-root-addr *active-plan*) 0))))))

(defun %stress-test-body (vm)
  "Common body for allocation stress tests."
  (let ((roots nil))
    (dotimes (i 80)
      (let ((addr (allocate-fill *active-plan* 2 i 0)))
        (push addr roots)))
    (dolist (r roots) (clamsara-register-root r))
    (clamsara-gc)
    (let ((vals (sort (loop for r in (rs-static-roots (vm-root-set vm))
                            collect (vm-object-reference vm r 0))
                      #'<)))
      (is (equal (loop for i from 0 below 80 collect i) vals)))))

;;; --- Non-collecting plan tests ---

(test nogc-allocates
  "NoGC plan allocates objects."
  (with-clamsara (:plan-type :nogc :heap-size 65536)
    (is (not (null (allocate-object *active-plan* 5))))))

(test nogc-collection-is-fatal
  "NoGC collection signals heap-exhausted."
  (with-clamsara (:plan-type :nogc :heap-size 65536)
    (signals heap-exhausted (clamsara-gc))))

(test nogc-root-test
  "NoGC preserves rooted object data (no GC needed)."
  (with-clamsara (:plan-type :nogc :heap-size 65536)
    (let* ((vm (plan-vm *active-plan*))
           (addr (allocate-fill *active-plan* 3 42 99 777)))
      (is (= 42 (vm-object-reference vm addr 0))))))

;;; --- SemiSpace ---

(test semispace-allocates
  "SemiSpace plan allocates objects."
  (with-clamsara (:plan-type :semispace :heap-size 131072)
    (is (not (null (allocate-object *active-plan* 5))))))

(test semispace-preserves-root
  "SemiSpace GC preserves rooted object data."
  (with-clamsara (:plan-type :semispace :heap-size 131072)
    (%root-test-body (plan-vm *active-plan*))))

(test semispace-reclaims-dead
  "SemiSpace GC reclaims unreachable objects."
  (with-clamsara (:plan-type :semispace :heap-size 131072)
    (%dead-test-body (plan-vm *active-plan*))))

(test semispace-linked-list
  "SemiSpace GC preserves linked lists."
  (with-clamsara (:plan-type :semispace :heap-size 131072)
    (%list-test-body (plan-vm *active-plan*))))

(test semispace-transitive-closure
  "SemiSpace preserves transitive closure."
  (with-clamsara (:plan-type :semispace :heap-size 131072)
    (%closure-test-body (plan-vm *active-plan*))))

(test semispace-multi-cycle
  "SemiSpace handles multiple GC cycles."
  (with-clamsara (:plan-type :semispace :heap-size 131072)
    (%cycle-test-body (plan-vm *active-plan*))))

(test semispace-stress
  "SemiSpace survives allocation stress."
  (with-clamsara (:plan-type :semispace :heap-size 262144)
    (%stress-test-body (plan-vm *active-plan*))))

(test semispace-swaps-after-gc
  "SemiSpace swaps from/to after collection."
  (with-clamsara (:plan-type :semispace :heap-size 65536)
    (let* ((plan *active-plan*)
           (from-before (plan-from-space plan))
           (to-before (plan-to-space plan)))
      (let ((addr (allocate-fill plan 3 1 2 3)))
        (clamsara-register-root addr)
        (clamsara-gc))
      (is (not (eq (plan-from-space plan) from-before)))
      (is (eq (plan-from-space plan) to-before)))))

;;; --- MarkSweep ---

(test marksweep-allocates
  "MarkSweep plan allocates objects."
  (with-clamsara (:plan-type :marksweep :heap-size 131072)
    (is (not (null (allocate-object *active-plan* 5))))))

(test marksweep-preserves-root
  "MarkSweep GC preserves rooted object data."
  (with-clamsara (:plan-type :marksweep :heap-size 131072)
    (%root-test-body (plan-vm *active-plan*))))

(test marksweep-reclaims-dead
  "MarkSweep GC reclaims unreachable objects."
  (with-clamsara (:plan-type :marksweep :heap-size 131072)
    (%dead-test-body (plan-vm *active-plan*))))

(test marksweep-linked-list
  "MarkSweep GC preserves linked lists."
  (with-clamsara (:plan-type :marksweep :heap-size 131072)
    (%list-test-body (plan-vm *active-plan*))))

(test marksweep-transitive-closure
  "MarkSweep preserves transitive closure."
  (with-clamsara (:plan-type :marksweep :heap-size 131072)
    (%closure-test-body (plan-vm *active-plan*))))

(test marksweep-multi-cycle
  "MarkSweep handles multiple GC cycles."
  (with-clamsara (:plan-type :marksweep :heap-size 131072)
    (%cycle-test-body (plan-vm *active-plan*))))

(test marksweep-stress
  "MarkSweep survives allocation stress."
  (with-clamsara (:plan-type :marksweep :heap-size 262144)
    (%stress-test-body (plan-vm *active-plan*))))

;;; --- Immix ---

(test immix-allocates
  "Immix plan allocates objects."
  (with-clamsara (:plan-type :immix :heap-size 131072)
    (is (not (null (allocate-object *active-plan* 5))))))

(test immix-preserves-root
  "Immix GC preserves rooted object data."
  (with-clamsara (:plan-type :immix :heap-size 131072)
    (%root-test-body (plan-vm *active-plan*))))

(test immix-reclaims-dead
  "Immix GC reclaims unreachable objects."
  (with-clamsara (:plan-type :immix :heap-size 131072)
    (%dead-test-body (plan-vm *active-plan*))))

(test immix-linked-list
  "Immix GC preserves linked lists."
  (with-clamsara (:plan-type :immix :heap-size 131072)
    (%list-test-body (plan-vm *active-plan*))))

(test immix-transitive-closure
  "Immix preserves transitive closure."
  (with-clamsara (:plan-type :immix :heap-size 131072)
    (%closure-test-body (plan-vm *active-plan*))))

(test immix-multi-cycle
  "Immix handles multiple GC cycles."
  (with-clamsara (:plan-type :immix :heap-size 131072)
    (%cycle-test-body (plan-vm *active-plan*))))

(test immix-stress
  "Immix survives allocation stress."
  (with-clamsara (:plan-type :immix :heap-size 262144)
    (%stress-test-body (plan-vm *active-plan*))))

(test immix-block-creation
  "Immix creates blocks during allocation."
  (with-clamsara (:plan-type :immix :heap-size 65536)
    (let* ((space (plan-get-space *active-plan* :default))
           (blocks (immix-space-blocks space)))
      (is (hash-table-p blocks))
      (dotimes (i 10) (allocate-object *active-plan* 50))
      (is (> (hash-table-count (immix-space-blocks space)) 0)))))

;;; --- GenCopy ---

(test gencopy-allocates
  "GenCopy plan allocates objects."
  (with-clamsara (:plan-type :gencopy :heap-size 131072)
    (is (not (null (allocate-object *active-plan* 5))))))

(test gencopy-preserves-root
  "GenCopy GC preserves rooted object data."
  (with-clamsara (:plan-type :gencopy :heap-size 131072)
    (%root-test-body (plan-vm *active-plan*))))

(test gencopy-reclaims-dead
  "GenCopy GC reclaims unreachable objects."
  (with-clamsara (:plan-type :gencopy :heap-size 131072)
    (%dead-test-body (plan-vm *active-plan*))))

(test gencopy-linked-list
  "GenCopy GC preserves linked lists."
  (with-clamsara (:plan-type :gencopy :heap-size 131072)
    (%list-test-body (plan-vm *active-plan*))))

(test gencopy-transitive-closure
  "GenCopy preserves transitive closure."
  (with-clamsara (:plan-type :gencopy :heap-size 131072)
    (%closure-test-body (plan-vm *active-plan*))))

(test gencopy-multi-cycle
  "GenCopy handles multiple GC cycles."
  (with-clamsara (:plan-type :gencopy :heap-size 131072)
    (%cycle-test-body (plan-vm *active-plan*))))

(test gencopy-stress
  "GenCopy survives allocation stress."
  (with-clamsara (:plan-type :gencopy :heap-size 262144)
    (%stress-test-body (plan-vm *active-plan*))))

;;; --- GenMS ---

(test genms-allocates
  "GenMS plan allocates objects."
  (with-clamsara (:plan-type :genms :heap-size 131072)
    (is (not (null (allocate-object *active-plan* 5))))))

(test genms-preserves-root
  "GenMS GC preserves rooted object data."
  (with-clamsara (:plan-type :genms :heap-size 131072)
    (%root-test-body (plan-vm *active-plan*))))

(test genms-reclaims-dead
  "GenMS GC reclaims unreachable objects."
  (with-clamsara (:plan-type :genms :heap-size 131072)
    (%dead-test-body (plan-vm *active-plan*))))

(test genms-linked-list
  "GenMS GC preserves linked lists."
  (with-clamsara (:plan-type :genms :heap-size 131072)
    (%list-test-body (plan-vm *active-plan*))))

(test genms-transitive-closure
  "GenMS preserves transitive closure."
  (with-clamsara (:plan-type :genms :heap-size 131072)
    (%closure-test-body (plan-vm *active-plan*))))

(test genms-multi-cycle
  "GenMS handles multiple GC cycles."
  (with-clamsara (:plan-type :genms :heap-size 131072)
    (%cycle-test-body (plan-vm *active-plan*))))

(test genms-stress
  "GenMS survives allocation stress."
  (with-clamsara (:plan-type :genms :heap-size 262144)
    (%stress-test-body (plan-vm *active-plan*))))

;;; --- GenImmix ---

(test genimmix-allocates
  "GenImmix plan allocates objects."
  (with-clamsara (:plan-type :genimmix :heap-size 131072)
    (is (not (null (allocate-object *active-plan* 5))))))

(test genimmix-preserves-root
  "GenImmix GC preserves rooted object data."
  (with-clamsara (:plan-type :genimmix :heap-size 131072)
    (%root-test-body (plan-vm *active-plan*))))

(test genimmix-reclaims-dead
  "GenImmix GC reclaims unreachable objects."
  (with-clamsara (:plan-type :genimmix :heap-size 131072)
    (%dead-test-body (plan-vm *active-plan*))))

(test genimmix-linked-list
  "GenImmix GC preserves linked lists."
  (with-clamsara (:plan-type :genimmix :heap-size 131072)
    (%list-test-body (plan-vm *active-plan*))))

(test genimmix-transitive-closure
  "GenImmix preserves transitive closure."
  (with-clamsara (:plan-type :genimmix :heap-size 131072)
    (%closure-test-body (plan-vm *active-plan*))))

(test genimmix-multi-cycle
  "GenImmix handles multiple GC cycles."
  (with-clamsara (:plan-type :genimmix :heap-size 131072)
    (%cycle-test-body (plan-vm *active-plan*))))

(test genimmix-stress
  "GenImmix survives allocation stress."
  (with-clamsara (:plan-type :genimmix :heap-size 262144)
    (%stress-test-body (plan-vm *active-plan*))))

;;; --- StickyImmix ---

(test stickyimmix-allocates
  "StickyImmix plan allocates objects."
  (with-clamsara (:plan-type :stickyimmix :heap-size 131072)
    (is (not (null (allocate-object *active-plan* 5))))))

(test stickyimmix-preserves-root
  "StickyImmix GC preserves rooted object data."
  (with-clamsara (:plan-type :stickyimmix :heap-size 131072)
    (%root-test-body (plan-vm *active-plan*))))

(test stickyimmix-reclaims-dead
  "StickyImmix GC reclaims unreachable objects."
  (with-clamsara (:plan-type :stickyimmix :heap-size 131072)
    (%dead-test-body (plan-vm *active-plan*))))

(test stickyimmix-linked-list
  "StickyImmix GC preserves linked lists."
  (with-clamsara (:plan-type :stickyimmix :heap-size 131072)
    (%list-test-body (plan-vm *active-plan*))))

(test stickyimmix-transitive-closure
  "StickyImmix preserves transitive closure."
  (with-clamsara (:plan-type :stickyimmix :heap-size 131072)
    (%closure-test-body (plan-vm *active-plan*))))

(test stickyimmix-multi-cycle
  "StickyImmix handles multiple GC cycles."
  (with-clamsara (:plan-type :stickyimmix :heap-size 131072)
    (%cycle-test-body (plan-vm *active-plan*))))

(test stickyimmix-stress
  "StickyImmix survives allocation stress."
  (with-clamsara (:plan-type :stickyimmix :heap-size 262144)
    (%stress-test-body (plan-vm *active-plan*))))

;;; --- StickyMS ---

(test stickyms-allocates
  "StickyMS plan allocates objects."
  (with-clamsara (:plan-type :stickyms :heap-size 131072)
    (is (not (null (allocate-object *active-plan* 5))))))

(test stickyms-preserves-root
  "StickyMS GC preserves rooted object data."
  (with-clamsara (:plan-type :stickyms :heap-size 131072)
    (%root-test-body (plan-vm *active-plan*))))

(test stickyms-reclaims-dead
  "StickyMS GC reclaims unreachable objects."
  (with-clamsara (:plan-type :stickyms :heap-size 131072)
    (%dead-test-body (plan-vm *active-plan*))))

(test stickyms-linked-list
  "StickyMS GC preserves linked lists."
  (with-clamsara (:plan-type :stickyms :heap-size 131072)
    (%list-test-body (plan-vm *active-plan*))))

(test stickyms-transitive-closure
  "StickyMS preserves transitive closure."
  (with-clamsara (:plan-type :stickyms :heap-size 131072)
    (%closure-test-body (plan-vm *active-plan*))))

(test stickyms-multi-cycle
  "StickyMS handles multiple GC cycles."
  (with-clamsara (:plan-type :stickyms :heap-size 131072)
    (%cycle-test-body (plan-vm *active-plan*))))

(test stickyms-stress
  "StickyMS survives allocation stress."
  (with-clamsara (:plan-type :stickyms :heap-size 262144)
    (%stress-test-body (plan-vm *active-plan*))))

;;; --- Plan-specific tests ---

(test copying-plans-preserve-deep-trees
  "Copying plans preserve deep binary trees across GC."
  (dolist (plan-type '(:semispace :gencopy))
    (with-clamsara (:plan-type plan-type :heap-size 262144)
      (let ((tree (build-binary-tree *active-plan* 6)))
        (is (verify-binary-tree *active-plan* tree 6))
        (clamsara-register-root tree)
        (dotimes (i 3) (clamsara-gc))
        (is (verify-binary-tree *active-plan* (get-root-addr *active-plan*) 6))))))

(test nonmoving-plans-preserve-address
  "Non-moving plans keep object addresses across GC."
  (dolist (plan-type '(:marksweep :immix))
    (with-clamsara (:plan-type plan-type :heap-size 65536)
      (let* ((vm (plan-vm *active-plan*))
             (addr (allocate-fill *active-plan* 3 42 99 0)))
        (clamsara-register-root addr)
        (clamsara-gc)
        (is (= 42 (vm-object-reference vm addr 0)))
        (is (= 99 (vm-object-reference vm addr 1)))))))
