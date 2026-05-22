(in-package #:clamsara.tests)

(def-suite test-plan :description "Plan tests"
  :in clamsara-tests)

(in-suite test-plan)

(test with-clamsara-creates-plan
  "WITH-CLAMSARA establishes an active plan."
  (is (null *active-plan*))
  (with-clamsara (:plan-type :semispace :heap-size 32768)
    (is (not (null *active-plan*)))
    (is (typep *active-plan* 'semispace-plan)))
  (is (null *active-plan*)))

(test plan-type-nogc
  "NoGC plan can be created."
  (with-clamsara (:plan-type :nogc :heap-size 65536)
    (is (typep *active-plan* 'nogc-plan))
    (let* ((plan *active-plan*)
           (addr (plan-allocate plan 5 :default)))
      (is (not (null addr))))))

(test plan-type-semispace
  "SemiSpace plan has two spaces."
  (with-clamsara (:plan-type :semispace :heap-size 65536)
    (let ((plan *active-plan*))
      (is (typep plan 'semispace-plan))
      (is (= 2 (length (plan-spaces plan))))
      (is (not (null (plan-from-space plan))))
      (is (not (null (plan-to-space plan)))))))

(test plan-type-marksweep
  "MarkSweep plan has one space."
  (with-clamsara (:plan-type :marksweep :heap-size 65536)
    (let ((plan *active-plan*))
      (is (typep plan 'marksweep-plan))
      (is (>= (length (plan-spaces plan)) 1)))))

(test plan-type-immix
  "Immix plan can be created."
  (with-clamsara (:plan-type :immix :heap-size 65536)
    (let ((plan *active-plan*))
      (is (typep plan 'immix-plan))
      (is (>= (length (plan-spaces plan)) 1)))))

(test plan-allocation-and-gc-marksweep
  "Allocation and GC in MarkSweep."
  (with-clamsara (:plan-type :marksweep :heap-size 65536)
    (let* ((plan *active-plan*)
           (vm (plan-vm plan))
           (addr (allocate-object plan 2)))
      (setf (vm-object-reference vm addr 0) 42)
      (clamsara-register-root addr)
      (clamsara-gc)
      ;; Object should still be valid after GC
      (is (vm-object-start-p vm addr))
      (is (= 42 (vm-object-reference vm addr 0))))))

(test plan-allocation-and-gc-semispace
  "Allocation and GC in SemiSpace."
  (with-clamsara (:plan-type :semispace :heap-size 65536)
    (let* ((plan *active-plan*)
           (vm (plan-vm plan))
           (addr (allocate-object plan 3)))
      (setf (vm-object-reference vm addr 0) 10)
      (setf (vm-object-reference vm addr 1) 20)
      (clamsara-register-root addr)
      (clamsara-gc)
      ;; After SemiSpace GC, the object may have been copied,
      ;; but the root should be updated to the forwarded address
      (let ((new-addr (vm-object-forwarding-pointer vm addr)))
        (if new-addr
            (progn
              (is (= 10 (vm-object-reference vm new-addr 0)))
              (is (= 20 (vm-object-reference vm new-addr 1))))
            (progn
              (is (= 10 (vm-object-reference vm addr 0)))
              (is (= 20 (vm-object-reference vm addr 1)))))))))

(test plan-handle-allocation-failure
  "Plan handles allocation failure by triggering GC."
  (with-clamsara (:plan-type :marksweep :heap-size 1024)
    (let* ((plan *active-plan*)
           (vm (plan-vm plan))
           (root (allocate-object plan 100)))
      (clamsara-register-root root)
      (setf (vm-object-reference vm root 0) root)
      ;; Try to allocate a lot — should trigger GC
      (let ((big (allocate-object plan 500)))
        (is (not (null big)))))))
