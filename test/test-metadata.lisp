(in-package #:clamsara.tests)

(def-suite test-metadata :description "Side metadata tests"
  :in clamsara-tests)

(in-suite test-metadata)

(test metadata-mark-bits
  "Mark bits work correctly."
  (with-clamsara (:plan-type :marksweep :heap-size 65536)
    (let* ((plan *active-plan*)
           (vm (plan-vm plan))
           (addr (allocate-object plan 2)))
      (is (not (vm-object-is-marked-p vm addr)))
      (setf (vm-object-is-marked-p vm addr) t)
      (is (vm-object-is-marked-p vm addr))
      (setf (vm-object-is-marked-p vm addr) nil)
      (is (not (vm-object-is-marked-p vm addr))))))

(test metadata-forwarding
  "Forwarding pointers work correctly."
  (with-clamsara (:plan-type :marksweep :heap-size 65536)
    (let* ((plan *active-plan*)
           (vm (plan-vm plan))
           (addr (allocate-object plan 2)))
      (is (not (vm-object-is-forwarded-p vm addr)))
      (setf (vm-object-forwarding-pointer vm addr) 999)
      (is (vm-object-is-forwarded-p vm addr))
      (is (= 999 (vm-object-forwarding-pointer vm addr))))))

(test metadata-log-bits
  "Log bits work correctly."
  (with-clamsara (:plan-type :marksweep :heap-size 65536)
    (let* ((plan *active-plan*)
           (vm (plan-vm plan))
           (addr (allocate-object plan 2)))
      (is (not (vm-object-is-logged-p vm addr)))
      (setf (vm-object-is-logged-p vm addr) t)
      (is (vm-object-is-logged-p vm addr))
      (setf (vm-object-is-logged-p vm addr) nil)
      (is (not (vm-object-is-logged-p vm addr))))))

(test metadata-age
  "Object age metadata works."
  (with-clamsara (:plan-type :marksweep :heap-size 65536)
    (let* ((plan *active-plan*)
           (vm (plan-vm plan))
           (addr (allocate-object plan 2)))
      (is (= 0 (vm-object-age vm addr)))
      (setf (vm-object-age vm addr) 5)
      (is (= 5 (vm-object-age vm addr))))))

(test metadata-generation
  "Object generation metadata works."
  (with-clamsara (:plan-type :marksweep :heap-size 65536)
    (let* ((plan *active-plan*)
           (vm (plan-vm plan))
           (addr (allocate-object plan 2)))
      (is (= 0 (vm-object-generation vm addr)))
      (setf (vm-object-generation vm addr) 1)
      (is (= 1 (vm-object-generation vm addr))))))
