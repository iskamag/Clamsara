(in-package #:clamsara.tests)

(def-suite test-compile :description "Compilable framework tests"
  :in clamsara-tests)

(in-suite test-compile)

(test compile-to-functions-returns-alist
  "compile-to-functions returns (name . lambda-form) alist."
  (with-clamsara (:plan-type :marksweep :heap-size 65536)
    (let ((forms (compile-to-functions *active-plan*)))
      (is (listp forms))
      (is (> (length forms) 0))
      (dolist (entry forms)
        (is (consp entry))
        (is (symbolp (car entry)))
        (is (consp (cdr entry)))
        (is (eq 'lambda (cadr entry)))))))

(test boot-gc-populates-function-table
  "boot-gc populates the function table with compiled functions."
  (with-clamsara (:plan-type :marksweep :heap-size 65536)
    (let* ((plan *active-plan*)
           (table (plan-function-table plan))
           (before (hash-table-count table)))
      (boot-gc plan)
      (is (> (hash-table-count table) before)))))

(test plan-collect-phase-cleans-up
  "plan-collect-phase runs without error and preserves roots."
  (with-clamsara (:plan-type :marksweep :heap-size 65536)
    (let* ((plan *active-plan*)
           (vm (plan-vm plan))
           (addr (allocate-fill plan 3 42 99 777)))
      (clamsara-register-root addr)
      (plan-collect-phase plan :major)
      (let ((survivor (get-root-addr plan)))
        (is (not (null survivor)))
        (is (= 42 (vm-object-reference vm survivor 0)))))))

(test compile-to-functions-across-all-plans
  "All 9 plan types return valid compile-to-functions output."
  (dolist (plan-type '(:nogc :semispace :marksweep :immix
                       :gencopy :genms :genimmix :stickyimmix :stickyms))
    (with-clamsara (:plan-type plan-type :heap-size 65536)
      (let ((forms (compile-to-functions *active-plan*)))
        (is (> (length forms) 0))))))

(test boot-gc-across-all-plans
  "All 9 plan types can run boot-gc without error."
  (dolist (plan-type '(:nogc :semispace :marksweep :immix
                       :gencopy :genms :genimmix :stickyimmix :stickyms))
    (with-clamsara (:plan-type plan-type :heap-size 65536)
      (let* ((plan *active-plan*)
             (table (plan-function-table plan))
             (before (hash-table-count table)))
        (boot-gc plan)
        (is (> (hash-table-count table) before))))))
