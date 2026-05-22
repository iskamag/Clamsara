(in-package #:clamsara.tests)

(def-suite test-object :description "Object model tests"
  :in clamsara-tests)

(in-suite test-object)

(test object-creation
  "Create and access object fields."
  (with-clamsara (:plan-type :marksweep :heap-size 65536)
    (let* ((plan *active-plan*)
           (vm (plan-vm plan))
           (addr (allocate-object plan 3)))
      (is (not (null addr)))
      (is (vm-object-start-p vm addr))
      (is (= 3 (vm-object-reference-count vm addr)))
      (is (= 4 (vm-object-total-words vm addr)))
      (is (= +type-tag-object+ (vm-object-type-tag vm addr))))))

(test object-reference-write-and-read
  "Write and read object references."
  (with-clamsara (:plan-type :marksweep :heap-size 65536)
    (let* ((plan *active-plan*)
           (vm (plan-vm plan))
           (addr (allocate-object plan 5)))
      (setf (vm-object-reference vm addr 0) 42)
      (setf (vm-object-reference vm addr 1) 99)
      (setf (vm-object-reference vm addr 4) 777)
      (is (= 42 (vm-object-reference vm addr 0)))
      (is (= 99 (vm-object-reference vm addr 1)))
      (is (= 777 (vm-object-reference vm addr 4))))))

(test object-flag-operations
  "Object flag set/clear."
  (with-clamsara (:plan-type :marksweep :heap-size 65536)
    (let* ((plan *active-plan*)
           (vm (plan-vm plan))
           (addr (allocate-object plan 2)))
      (setf (vm-object-is-marked-p vm addr) t)
      (is (vm-object-is-marked-p vm addr))
      (setf (vm-object-is-marked-p vm addr) nil)
      (is (not (vm-object-is-marked-p vm addr))))))

(test object-copy
  "Object copying preserves data."
  (with-clamsara (:plan-type :semispace :heap-size 65536)
    (let* ((plan *active-plan*)
           (vm (plan-vm plan))
           (src (allocate-object plan 3)))
      (setf (vm-object-reference vm src 0) 10)
      (setf (vm-object-reference vm src 1) 20)
      (setf (vm-object-reference vm src 2) 30)
      (let ((dst (allocate-object plan 3)))
        (vm-object-copy vm src dst)
        (is (= 10 (vm-object-reference vm dst 0)))
        (is (= 20 (vm-object-reference vm dst 1)))
        (is (= 30 (vm-object-reference vm dst 2)))))))

(test cons-cell
  "Cons cell allocation and access."
  (with-clamsara (:plan-type :marksweep :heap-size 65536)
    (let* ((plan *active-plan*)
           (vm (plan-vm plan))
           (addr (allocate-cons plan 1 2)))
      (is (not (null addr)))
      (is (vm-object-start-p vm addr))
      (is (= +type-tag-cons+ (vm-object-type-tag vm addr)))
      (is (= 1 (vm-object-reference vm addr 0)))
      (is (= 2 (vm-object-reference vm addr 1))))))

(test valid-reference-check
  "vm-valid-reference-p correctly validates addresses."
  (with-clamsara (:plan-type :marksweep :heap-size 65536)
    (let* ((plan *active-plan*)
           (vm (plan-vm plan))
           (addr (allocate-object plan 2)))
      (is (vm-valid-reference-p vm addr))
      (is (not (vm-valid-reference-p vm 0)))
      (is (not (vm-valid-reference-p vm 999999999))))))
