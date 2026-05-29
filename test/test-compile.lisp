(in-package #:clamsara.tests)

(def-suite test-compile :description "Compilable framework tests"
  :in clamsara-tests)

(in-suite test-compile)

(test compile-to-functions-returns-alist
  "compile-to-functions returns an alist of (name . lambda-form)."
  (with-clamsara (:plan-type :marksweep :heap-size 65536)
    (let* ((plan *active-plan*)
           (forms (compile-to-functions plan)))
      (is (listp forms))
      (dolist (entry forms)
        (is (consp entry))
        (is (symbolp (car entry)))
        (is (consp (cdr entry))) ; lambda form
        (is (eq 'lambda (cadr entry)))))))

(test compile-to-functions-non-empty
  "compile-to-functions returns non-empty alist for any plan."
  (with-clamsara (:plan-type :marksweep :heap-size 65536)
    (let* ((plan *active-plan*)
           (forms (compile-to-functions plan)))
      (is (> (length forms) 0)
          "compile-to-functions must return at least one function form"))))

(test boot-gc-populates-function-table
  "boot-gc populates the plan's function table with compiled closures."
  (with-clamsara (:plan-type :marksweep :heap-size 65536)
    (let* ((plan *active-plan*)
           (table (plan-function-table plan)))
      ;; Before boot-gc, table might be empty or have some entries
      (let ((before-count (hash-table-count table)))
        (boot-gc plan)
        (let ((after-count (hash-table-count table)))
          (is (> after-count before-count)
              "boot-gc should add functions to the table"))))))

(test plan-collect-phase-runs-without-error
  "plan-collect-phase can be called without crashing."
  (with-clamsara (:plan-type :marksweep :heap-size 65536)
    (let* ((plan *active-plan*)
           (vm (plan-vm plan)))
      ;; Allocate and root an object
      (let ((addr (allocate-object plan 3)))
        (setf (vm-object-reference vm addr 0) 42)
        (clamsara-register-root addr)
        ;; Run phased collection
        (plan-collect-phase plan :major)
        ;; Verify object survived
        (let ((new-root (first (rs-static-roots (vm-root-set vm)))))
          (is (not (null new-root)))
          (is (= 42 (vm-object-reference vm new-root 0))))))))
