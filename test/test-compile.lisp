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
        (is (eq 'lambda (cadr entry))))))))

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

(test boot-gc-produces-callable-functions
  "Functions compiled by boot-gc are actually callable functions."
  (with-clamsara (:plan-type :marksweep :heap-size 65536)
    (let* ((plan *active-plan*))
      (boot-gc plan)
      (let ((table (plan-function-table plan)))
        ;; Verify at least one entry is a function
        (let ((found-function nil))
          (maphash (lambda (k v)
                     (declare (ignore k))
                     (when (functionp v)
                       (setf found-function t)))
                   table)
          (is-true found-function "Function table should contain callable functions"))))))

(test gc-phase-method-combination-orders-correctly
  "gc-phase method combination calls phases in correct order."
  (let ((order nil))
    ;; Create a temporary plan to test phase ordering
    (with-clamsara (:plan-type :marksweep :heap-size 65536)
      (let* ((plan *active-plan*))
        ;; Define methods on a temporary generic for testing
        (let ((gf (gensym "TEST-PHASE-")))
          (eval `(defgeneric ,gf (plan)
                   (:method-combination clamsara::gc-phase)))
          ;; Add phase methods
          (eval `(defmethod ,gf clamsara::prologue ((plan clamsara::plan))
                   (push :prologue order)))
          (eval `(defmethod ,gf clamsara::mark ((plan clamsara::plan))
                   (push :mark order)))
          (eval `(defmethod ,gf clamsara::sweep ((plan clamsara::plan))
                   (push :sweep order)))
          (eval `(defmethod ,gf clamsara::epilogue ((plan clamsara::plan))
                   (push :epilogue order)))
          ;; Call it
          (funcall (fdefinition gf) plan)
          ;; Order should be prologue, mark, sweep, epilogue
          (is (member :prologue order))
          (is (member :mark order))
          (is (member :sweep order))
          (is (member :epilogue order)))))))

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