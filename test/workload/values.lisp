;;;; Managed VM result, cleanup, and active-closure lifetime acceptance.
(defpackage #:clamsara.workload.values.test
  (:use #:cl #:clamsara)
  (:export #:run-workload-value-lifetime-tests))
(in-package #:clamsara.workload.values.test)

(defun tree-node-count (environment reference)
  (if (null reference) 0
      (+ 1 (tree-node-count
            environment (workload-read-slot environment reference :slot1))
         (tree-node-count
          environment (workload-read-slot environment reference :slot2)))))

(defun check-two-values (environment values)
  (assert (= 2 (length values)))
  (assert (= 17 (workload-read-slot environment (first values) :slot1)))
  (assert (= 23 (workload-read-slot environment (second values) :slot2))))

(defun vm-registers (vm)
  (list (maclina.vm-cross::vm-stack-top vm)
        (maclina.vm-cross::vm-frame-pointer vm)
        (maclina.vm-cross::vm-pc vm)
        (maclina.vm-cross::vm-args vm)
        (maclina.vm-cross::vm-arg-count vm)))

(defun check-frame-failure (environment provider)
  (let* ((vm (clamsara::workload-provider-vm provider))
         (before (vm-registers vm))
         (client (clamsara::workload-maclina-client environment))
         (compiler-environment (clamsara::workload-maclina-environment environment))
         (failure (make-condition 'simple-error :format-control "Expected VM failure")))
    (setf (clostrum:fdefinition client compiler-environment 'signal-probe-failure)
          (lambda () (error failure)))
    (assert (handler-case
                (progn (workload-eval environment '(signal-probe-failure)) nil)
              (error (condition) (eq condition failure))))
    (assert (equal before (vm-registers vm)))
    (assert (zerop (clamsara::workload-provider-frame-count provider)))))

(defun check-frame-capacity (environment provider)
  (let* ((vm (clamsara::workload-provider-vm provider))
         (before (vm-registers vm))
         (values (maclina.vm-cross::vm-values vm))
         (callee (clostrum:fdefinition
                  (clamsara::workload-maclina-client environment)
                  (clamsara::workload-maclina-environment environment)
                  'clamsara::make-tree))
         (count (clamsara::workload-provider-frame-count provider))
         (capacity (length (clamsara::workload-provider-functions provider))))
    (unwind-protect
         (progn
           (setf (clamsara::workload-provider-frame-count provider) capacity)
           (assert (handler-case (progn (funcall callee 0) nil)
                     (clamsara::workload-capability-error (condition)
                       (eq :vm-frame-capacity-exhausted
                           (clamsara::workload-error-reason condition)))))
           (assert (= capacity (clamsara::workload-provider-frame-count provider)))
           (assert (equal before (vm-registers vm)))
           (assert (eq values (maclina.vm-cross::vm-values vm))))
      (setf (clamsara::workload-provider-frame-count provider) count))))

(defun run-value-case (name form check &optional before)
  (let* ((runtime (make-workload-runtime :extent 16384 :max-object-bytes 8192
                                        :root-capacity 512))
         (environment (clamsara::workload-runtime-environment runtime))
         (configuration (clamsara::workload-runtime-configuration runtime))
         (provider (clamsara::workload-runtime-root-provider runtime))
         (plan (clamsara::workload-runtime-plan runtime))
         (report nil))
    (unwind-protect
         (progn
           (workload-load environment
                          (asdf:system-relative-pathname
                           :clamsara "test/fixtures/boehm-gc.lisp"))
           (when before (funcall before environment provider))
           (setf report
                 (handler-case
                     (let ((values (multiple-value-list
                                    (workload-eval environment form)))
                           (automatic (clamsara::%plan-automatic-result plan)))
                       (assert (eq :complete (cycle-result-status automatic)))
                       (funcall check environment values)
                       (assert (zerop (clamsara::workload-provider-frame-count provider)))
                       (assert (zerop (maclina.vm-cross::vm-stack-top
                                       (clamsara::workload-provider-vm provider))))
                       (list :case name :status :complete
                             :moved (cycle-result-count automatic :objects-moved)))
                   (error (condition)
                     (list :case name :status :failed
                           :condition (princ-to-string condition))))))
      ;; Discharge only this probe's application roots. Cleanup failures are
      ;; not suppressed, and these steps are not general teardown acceptance.
      (dotimes (i (length (clamsara::workload-root-locations environment)))
        (clamsara::workload-temporary-root-clear environment i))
      (let ((vm (clamsara::workload-provider-vm provider)))
        (setf (maclina.vm-cross::vm-values vm) nil
              (maclina.vm-cross::vm-stack-top vm) 0
              (maclina.vm-cross::vm-dynenv-stack vm) nil))
      (let ((result (make-cycle-result-record plan)))
        (collect configuration :all :explicit result)
        (assert (eq :complete (cycle-result-status result))))
      (close-workload-runtime runtime))
    (format t "VALUE-LIFETIME ~S~%" report)
    report))

(defun check-long-lived-tree (environment values)
  (assert (= 1 (length values)))
  (assert (= 63 (tree-node-count environment (first values)))))

(defun run-workload-value-lifetime-tests ()
  (let ((reports
          (list
           (run-value-case :discarded-result
             '(progn (clamsara::make-tree 7)
                  (let ((node (clamsara::make-node)))
                    (clamsara::populate 5 node) node))
             #'check-long-lived-tree)
           (run-value-case :multiple-value-prog1
             '(multiple-value-prog1
               (values (clamsara::make-node :left 17)
                       (clamsara::make-node :right 23))
             (dotimes (i 300) (clamsara::make-node)))
             #'check-two-values)
           (run-value-case :unwind-protect-values
             '(unwind-protect
                (values (clamsara::make-node :left 17)
                        (clamsara::make-node :right 23))
             (clamsara::make-tree 0)
             (dotimes (i 300) (clamsara::make-node)))
             #'check-two-values)
           (run-value-case :throw-values
             '(catch 'done
             (unwind-protect
                  (throw 'done (values (clamsara::make-node :left 17)
                                       (clamsara::make-node :right 23)))
               (clamsara::make-tree 0)
               (dotimes (i 300) (clamsara::make-node))))
             #'check-two-values)
           (run-value-case :return-from-values
             '(block done
             (unwind-protect
                  (return-from done (values (clamsara::make-node :left 17)
                                            (clamsara::make-node :right 23)))
               (clamsara::make-tree 0)
               (dotimes (i 300) (clamsara::make-node))))
             #'check-two-values)
           (run-value-case :nested-protected-values
             '(unwind-protect
                (values (clamsara::make-node :left 17)
                        (clamsara::make-node :right 23))
             (multiple-value-call #'values
               (unwind-protect
                    (values (clamsara::make-node :left 29)
                            (clamsara::make-node :right 31))
                 (clamsara::make-tree 0)
                 (dotimes (i 300) (clamsara::make-node))))
             (dotimes (i 300) (clamsara::make-node)))
             #'check-two-values)
           (run-value-case :error-frame-recovery
             '(multiple-value-prog1
                  (values (clamsara::make-node :left 17)
                          (clamsara::make-node :right 23))
                (dotimes (i 300) (clamsara::make-node)))
             #'check-two-values #'check-frame-failure)
           (run-value-case :frame-capacity-recovery
             '(multiple-value-prog1
                  (values (clamsara::make-node :left 17)
                          (clamsara::make-node :right 23))
                (dotimes (i 300) (clamsara::make-node)))
             #'check-two-values #'check-frame-capacity)
           (run-value-case :active-closure-cell
             '(funcall
             (funcall (lambda (node)
                        (lambda ()
                          (clamsara::make-tree 0)
                          (dotimes (i 300) (clamsara::make-node))
                          (setq node node)
                          (values node (clamsara::make-node :right 23))))
                      (clamsara::make-node :left 17)))
             #'check-two-values))))
    (unless (every (lambda (report) (eq :complete (getf report :status))) reports)
      (error "Managed VM value-lifetime acceptance failed: ~S" reports))
    t))
