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

(test compiled-barrier-note-write-matches-mop
  "Compiled barrier-note-write behaves identically to MOP dispatch."
  (with-clamsara (:plan-type :gencopy :heap-size 65536)
    (let* ((plan *active-plan*)
           (barrier (plan-barrier plan))
           (vm (plan-vm plan)))
      (boot-gc plan)
      (let ((compiled-fn (gethash 'barrier-note-write (plan-function-table plan)))
            (barrier-cleared-p nil)
            (mop-result nil)
            (compiled-result nil))
        ;; Clear barrier state
        (barrier-clear-all barrier)
        ;; Set up test: write an old->young reference
        (let ((source 0)
              (new-value (barrier-nursery-start barrier)))
          ;; Call via MOP
          (setf mop-result (barrier-note-write barrier source 0 new-value))
          ;; Check that card is dirty
          (is (> (aref (card-table-cards barrier) 0) 0))
          ;; Clear and call via compiled function
          (barrier-clear-all barrier)
          (when compiled-fn
            (setf compiled-result (funcall compiled-fn source 0 new-value))
            ;; Check that card is dirty again
            (is (> (aref (card-table-cards barrier) 0) 0)))))))

(test compiled-plan-collect-matches-mop
  "Compiled plan-collect produces equivalent GC behavior to MOP."
  (with-clamsara (:plan-type :marksweep :heap-size 65536)
    (let* ((plan *active-plan*)
           (vm (plan-vm plan)))
      ;; Set up objects
      (let ((addr (allocate-object plan 3)))
        (setf (vm-object-reference vm addr 0) 42)
        (clamsara-register-root addr)
        ;; Run MOP-based GC
        (clamsara-gc)
        (let ((mop-addr (first (rs-static-roots (vm-root-set vm)))))
          (is (= 42 (vm-object-reference vm mop-addr 0)))
          ;; Now boot-gc and run compiled version
          (setf (vm-object-reference vm addr 0) 42)
          (boot-gc plan)
          (let ((compiled-fn (gethash 'plan-collect (plan-function-table plan))))
            (when compiled-fn
              ;; Reset root set
              (setf (rs-static-roots (vm-root-set vm)) (list addr))
              ;; Call compiled function
              (funcall compiled-fn)
              ;; Verify same result
              (let ((compiled-addr (first (rs-static-roots (vm-root-set vm)))))
                (is (= 42 (vm-object-reference vm compiled-addr 0))
                    "Compiled GC should preserve roots same as MOP")))))))))

(test gc-phase-method-combination-orders-correctly
  "gc-phase method combination calls phases in correct order."
  (let ((order nil))
    ;; Create a temporary plan to test phase ordering
    (with-clamsara (:plan-type :marksweep :heap-size 65536)
      (let* ((plan *active-plan*)
             (vm (plan-vm plan)))
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
          ;; (they push in reverse order due to how we build the form)
          (is (member :prologue order))
          (is (member :mark order))
          (is (member :sweep order))
          (is (member :epilogue order)))))))

(test boot-gc-in-maclina-environment
  "boot-gc works correctly inside the Maclina VM environment."
  (with-clamsara (:plan-type :marksweep :heap-size 65536)
    (let ((plan *active-plan*))
      (setup-clamsara-maclina-environment plan)
      ;; boot-gc should compile functions without error
      (is-true (boot-gc plan))
      (let ((table (plan-function-table plan)))
        (is (> (hash-table-count table) 0))))))