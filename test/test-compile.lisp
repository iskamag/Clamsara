(in-package #:clamsara.tests)

(def-suite test-compile :description "Compilable framework tests"
  :in clamsara-tests)

(in-suite test-compile)

(test compile-to-functions-returns-alist
  "compile-to-functions returns (name . lambda-form) alist of unevaluated forms."
  (with-clamsara (:plan-type :marksweep :heap-size 65536)
    (let ((forms (compile-to-functions *active-plan*)))
      (is (listp forms))
      (is (> (length forms) 0))
      (dolist (entry forms)
        (is (consp entry))
        (is (symbolp (car entry)))
        (is (listp (cdr entry)) "~A should be a lambda form" (car entry))
        (is (eq 'lambda (first (cdr entry)))
            "~A should be a lambda form" (car entry))))))

(test boot-gc-populates-function-table
  "boot-gc populates the function table with compiled functions."
  (with-clamsara (:plan-type :marksweep :heap-size 65536)
    (let* ((plan *active-plan*)
           (table (plan-function-table plan))
           (before (hash-table-count table)))
      (is (zerop before) "Function table should be empty before boot-gc")
      (boot-gc plan)
      (is (> (hash-table-count table) before) "boot-gc should populate the table"))))

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
  "All 9 plan types can run boot-gc, populating the function table."
  (dolist (plan-type '(:nogc :semispace :marksweep :immix
                       :gencopy :genms :genimmix :stickyimmix :stickyms))
    (with-clamsara (:plan-type plan-type :heap-size 65536)
      (let* ((plan *active-plan*)
             (table (plan-function-table plan))
             (before (hash-table-count table)))
        (is (zerop before) "Table should be empty before boot-gc for ~A" plan-type)
        (boot-gc plan)
        (is (> (hash-table-count table) before)
            "boot-gc should populate table for ~A" plan-type)))))

(test compiled-gc-matches-clos-gc
  "Compiled and CLOS-dispatch GC produce identical results for the same graph."
  (labels ((gc-round (plan-type use-compiled-p)
             "Build a graph, GC via CLOS or compiled path, return surviving state."
             (with-clamsara (:plan-type plan-type :heap-size 131072)
               (let* ((plan *active-plan*)
                      (vm (plan-vm plan))
                      (addr (allocate-fill plan 5 10 20 30 40 50)))
                 (clamsara-register-root addr)
                 ;; Link a chain of cons cells into slot 1
                 (let ((list-head (build-linked-list plan 10)))
                   (setf (vm-object-reference vm addr 1) (or list-head 0)))
                 (when use-compiled-p (boot-gc plan))
                 (plan-collect plan)
                 (let ((survivor (get-root-addr plan)))
                   (unless survivor (return-from gc-round nil))
                   (list :slot0 (vm-object-reference vm survivor 0)
                         :slot1 (vm-object-reference vm survivor 1)
                         :slot2 (vm-object-reference vm survivor 2)
                         :slot3 (vm-object-reference vm survivor 3)
                         :slot4 (vm-object-reference vm survivor 4)
                         :list-len (linked-list-length plan
                                       (vm-object-reference vm survivor 1))))))))
    (dolist (plan-type '(:marksweep :semispace :immix
                         :gencopy :genms :genimmix :stickyimmix :stickyms))
      (let ((clos-result (gc-round plan-type nil))
            (compiled-result (gc-round plan-type t)))
        (is (not (null clos-result))
            "CLOS-path GC should preserve roots for ~A" plan-type)
        (is (not (null compiled-result))
            "Compiled-path GC should preserve roots for ~A" plan-type)
        (is (equal clos-result compiled-result)
            "CLOS and compiled GC results differ for ~A:~%  CLOS: ~S~%  Compiled: ~S"
            plan-type clos-result compiled-result)))))
