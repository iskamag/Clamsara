(in-package #:clamsara.tests)

(def-suite test-gen :description "Generational collector tests"
  :in clamsara-tests)

(in-suite test-gen)

;;; --- GenCopy ---

(test gencopy-preserves-roots
  "GenCopy GC preserves root objects."
  (with-clamsara (:plan-type :gencopy :heap-size 65536)
    (let* ((plan *active-plan*)
           (vm (plan-vm plan))
           (addr (allocate-object plan 3)))
      (setf (vm-object-reference vm addr 0) 42)
      (clamsara-register-root addr)
      (clamsara-gc)
      (let ((new-root (first (rs-static-roots (vm-root-set vm)))))
        (is (not (null new-root)))
        (is (= 42 (vm-object-reference vm new-root 0)))))))

(test gencopy-transitive-closure
  "GenCopy preserves transitive references."
  (with-clamsara (:plan-type :gencopy :heap-size 65536)
    (let* ((plan *active-plan*)
           (vm (plan-vm plan))
           (root (allocate-object plan 2))
           (child (allocate-object plan 2)))
      (setf (vm-object-reference vm root 0) child)
      (setf (vm-object-reference vm child 0) 99)
      (clamsara-register-root root)
      (clamsara-gc)
      (let ((new-root (first (rs-static-roots (vm-root-set vm)))))
        (let ((c (vm-object-reference vm new-root 0)))
          (is (not (zerop c)))
          (is (= 99 (vm-object-reference vm c 0))))))))

;;; --- GenMS ---

(test genms-preserves-roots
  "GenMS GC preserves root objects."
  (with-clamsara (:plan-type :genms :heap-size 65536)
    (let* ((plan *active-plan*)
           (vm (plan-vm plan))
           (addr (allocate-object plan 3)))
      (setf (vm-object-reference vm addr 0) 42)
      (clamsara-register-root addr)
      (clamsara-gc)
      (let ((new-root (first (rs-static-roots (vm-root-set vm)))))
        (is (not (null new-root)))
        (is (= 42 (vm-object-reference vm new-root 0)))))))

;;; --- GenImmix ---

(test genimmix-preserves-roots
  "GenImmix GC preserves root objects."
  (with-clamsara (:plan-type :genimmix :heap-size 65536)
    (let* ((plan *active-plan*)
           (vm (plan-vm plan))
           (addr (allocate-object plan 3)))
      (setf (vm-object-reference vm addr 0) 42)
      (clamsara-register-root addr)
      (clamsara-gc)
      (let ((new-root (first (rs-static-roots (vm-root-set vm)))))
        (is (not (null new-root)))
        (is (= 42 (vm-object-reference vm new-root 0)))))))

;;; --- StickyImmix ---

(test stickyimmix-preserves-roots
  "StickyImmix GC preserves root objects."
  (with-clamsara (:plan-type :stickyimmix :heap-size 131072)
    (let* ((plan *active-plan*)
           (vm (plan-vm plan))
           (addr (allocate-object plan 3)))
      (setf (vm-object-reference vm addr 0) 42)
      (clamsara-register-root addr)
      (clamsara-gc)
      (is (= 42 (vm-object-reference vm addr 0))))))

;;; --- StickyMS ---

(test stickyms-preserves-roots
  "StickyMS GC preserves root objects."
  (with-clamsara (:plan-type :stickyms :heap-size 65536)
    (let* ((plan *active-plan*)
           (vm (plan-vm plan))
           (addr (allocate-object plan 3)))
      (setf (vm-object-reference vm addr 0) 42)
      (clamsara-register-root addr)
      (clamsara-gc)
      (is (= 42 (vm-object-reference vm addr 0))))))
