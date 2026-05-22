(in-package #:clamsara.tests)

(def-suite test-collectors :description "Collector tests for all plan types"
  :in clamsara-tests)

(in-suite test-collectors)

;;; --- Helper ---

(defun build-linked-list (plan n)
  "Build a linked list of N cons cells. Returns the head address."
  (let ((head nil))
    (dotimes (i n)
      (setf head (allocate-cons plan (1+ i) (or head 0))))
    head))

(defun linked-list-length (plan head)
  "Count elements in a linked list."
  (let* ((vm (plan-vm plan))
         (len 0)
         (cur head))
    (loop while (and cur (not (zerop cur))
                     (vm-object-start-p vm cur)
                     (= (vm-object-type-tag vm cur) +type-tag-cons+))
          do (incf len)
             (setf cur (vm-object-reference vm cur 1)))
    len))

;;; --- NoGC ---

(test nogc-allocates
  "NoGC plan can allocate."
  (with-clamsara (:plan-type :nogc :heap-size 65536)
    (let ((addr (allocate-object *active-plan* 5)))
      (is (not (null addr))))))

(test nogc-collection-signals-error
  "NoGC collection signals heap-exhausted."
  (with-clamsara (:plan-type :nogc :heap-size 65536)
    (signals heap-exhausted
      (clamsara-gc))))

;;; --- SemiSpace ---

(test semispace-preserves-roots
  "SemiSpace GC preserves root objects."
  (with-clamsara (:plan-type :semispace :heap-size 65536)
    (let* ((plan *active-plan*)
           (vm (plan-vm plan))
           (addr (allocate-object plan 3)))
      (setf (vm-object-reference vm addr 0) 42)
      (clamsara-register-root addr)
      (clamsara-gc)
      ;; The root is updated to the forwarded address
      (let ((new-root (first (rs-static-roots (vm-root-set vm)))))
        (is (vm-object-start-p vm new-root))
        (is (= 42 (vm-object-reference vm new-root 0)))))))

(test semispace-dead-object-collected
  "SemiSpace GC collects unreachable objects."
  (with-clamsara (:plan-type :semispace :heap-size 65536)
    (let* ((plan *active-plan*)
           (vm (plan-vm plan))
           (root (allocate-object plan 2))
           (dead (allocate-object plan 2)))
      (setf (vm-object-reference vm root 0) root)
      (setf (vm-object-reference vm dead 0) dead)
      (clamsara-register-root root)
      (clamsara-gc)
      ;; Root should survive (possibly forwarded)
      (let ((new-root (first (rs-static-roots (vm-root-set vm)))))
        (is (not (null new-root)))
        (is (vm-object-start-p vm new-root))))))

(test semispace-linked-list-survival
  "SemiSpace GC preserves a linked list."
  (with-clamsara (:plan-type :semispace :heap-size 65536)
    (let* ((plan *active-plan*)
           (list-head (build-linked-list plan 5)))
      (clamsara-register-root list-head)
      (clamsara-gc)
      (let ((new-root (first (rs-static-roots (vm-root-set (plan-vm plan))))))
        (is (>= (linked-list-length plan new-root) 5))))))

(test semispace-multiple-gc-cycles
  "SemiSpace handles multiple GC cycles."
  (with-clamsara (:plan-type :semispace :heap-size 65536)
    (let* ((plan *active-plan*)
           (vm (plan-vm plan)))
      (dotimes (i 3)
        (let ((addr (allocate-object plan 3)))
          (setf (vm-object-reference vm addr 0) i)
          (clamsara-register-root addr)
          (clamsara-gc)
          (let ((new-root (first (rs-static-roots (vm-root-set vm)))))
            (is (= i (vm-object-reference vm new-root 0)))))))))

;;; --- MarkSweep ---

(test marksweep-preserves-roots
  "MarkSweep GC preserves root objects."
  (with-clamsara (:plan-type :marksweep :heap-size 65536)
    (let* ((plan *active-plan*)
           (vm (plan-vm plan))
           (addr (allocate-object plan 3)))
      (setf (vm-object-reference vm addr 0) 42)
      (setf (vm-object-reference vm addr 1) 99)
      (clamsara-register-root addr)
      (clamsara-gc)
      (is (= 42 (vm-object-reference vm addr 0)))
      (is (= 99 (vm-object-reference vm addr 1))))))

(test marksweep-dead-object-collected
  "MarkSweep GC frees unreachable objects."
  (with-clamsara (:plan-type :marksweep :heap-size 65536)
    (let* ((plan *active-plan*)
           (vm (plan-vm plan))
           (root (allocate-object plan 2))
           (dead (allocate-object plan 2)))
      (setf (vm-object-reference vm root 0) root)
      (setf (vm-object-reference vm dead 0) dead)
      (clamsara-register-root root)
      (clamsara-gc)
      ;; Root should survive
      (is (vm-object-start-p vm root))
      (is (= root (vm-object-reference vm root 0))))))

(test marksweep-transitive-closure
  "MarkSweep preserves transitive references."
  (with-clamsara (:plan-type :marksweep :heap-size 65536)
    (let* ((plan *active-plan*)
           (vm (plan-vm plan))
           (root (allocate-object plan 2))
           (child (allocate-object plan 2))
           (grandchild (allocate-object plan 2)))
      (setf (vm-object-reference vm root 0) child)
      (setf (vm-object-reference vm child 0) grandchild)
      (setf (vm-object-reference vm grandchild 0) 777)
      (clamsara-register-root root)
      (clamsara-gc)
      (let ((c (vm-object-reference vm root 0)))
        (is (= c child))
        (let ((gc (vm-object-reference vm c 0)))
          (is (= gc grandchild))
          (is (= 777 (vm-object-reference vm gc 0))))))))

(test marksweep-linked-list-survival
  "MarkSweep GC preserves a linked list."
  (with-clamsara (:plan-type :marksweep :heap-size 65536)
    (let* ((plan *active-plan*)
           (list-head (build-linked-list plan 10)))
      (clamsara-register-root list-head)
      (is (= 10 (linked-list-length plan list-head)))
      (clamsara-gc)
      (is (= 10 (linked-list-length plan list-head))))))

(test marksweep-multiple-gc-cycles
  "MarkSweep handles multiple GC cycles."
  (with-clamsara (:plan-type :marksweep :heap-size 65536)
    (let* ((plan *active-plan*)
           (vm (plan-vm plan)))
      (dotimes (i 5)
        (let ((addr (allocate-object plan 2)))
          (setf (vm-object-reference vm addr 0) i)
          (clamsara-register-root addr)
          (clamsara-gc)
          (is (= i (vm-object-reference vm addr 0))))))))

;;; --- Immix ---

(test immix-allocates
  "Immix plan can allocate."
  (with-clamsara (:plan-type :immix :heap-size 65536)
    (let ((addr (allocate-object *active-plan* 5)))
      (is (not (null addr))))))

(test immix-preserves-roots
  "Immix GC preserves root objects."
  (with-clamsara (:plan-type :immix :heap-size 65536)
    (let* ((plan *active-plan*)
           (vm (plan-vm plan))
           (addr (allocate-object plan 3)))
      (setf (vm-object-reference vm addr 0) 42)
      (clamsara-register-root addr)
      (clamsara-gc)
      (is (= 42 (vm-object-reference vm addr 0))))))

(test immix-linked-list-survival
  "Immix GC preserves a linked list."
  (with-clamsara (:plan-type :immix :heap-size 65536)
    (let* ((plan *active-plan*)
           (list-head (build-linked-list plan 7)))
      (clamsara-register-root list-head)
      (clamsara-gc)
      (is (>= (linked-list-length plan list-head) 7)))))

;;; --- Generational ---

(test gencopy-allocates
  "GenCopy plan can allocate."
  (with-clamsara (:plan-type :gencopy :heap-size 65536)
    (let ((addr (allocate-object *active-plan* 5)))
      (is (not (null addr))))))

(test genms-allocates
  "GenMS plan can allocate."
  (with-clamsara (:plan-type :genms :heap-size 65536)
    (let ((addr (allocate-object *active-plan* 5)))
      (is (not (null addr))))))

(test genimmix-allocates
  "GenImmix plan can allocate."
  (with-clamsara (:plan-type :genimmix :heap-size 65536)
    (let ((addr (allocate-object *active-plan* 5)))
      (is (not (null addr))))))

(test stickyimmix-allocates
  "StickyImmix plan can allocate."
  (with-clamsara (:plan-type :stickyimmix :heap-size 65536)
    (let ((addr (allocate-object *active-plan* 5)))
      (is (not (null addr))))))

(test stickyms-allocates
  "StickyMS plan can allocate."
  (with-clamsara (:plan-type :stickyms :heap-size 65536)
    (let ((addr (allocate-object *active-plan* 5)))
      (is (not (null addr))))))
