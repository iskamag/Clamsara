;;;; Standalone failing-then-passing acceptance probe for VM value lifetimes.
;;;; Run from the repository root:
;;;;   sbcl --noinform --non-interactive --load tools/probe-workload-values.lisp
;;;; This is deliberately not folded into the existing passing adapter suite.
(require :asdf)
(asdf:load-system :clamsara/workload)

(defpackage #:clamsara.workload.values.probe
  (:use #:cl #:clamsara))
(in-package #:clamsara.workload.values.probe)

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

(defun run-value-case (name form check)
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
           (setf report
                 (handler-case
                     (let ((values (multiple-value-list
                                    (workload-eval environment form)))
                           (automatic (clamsara::%plan-automatic-result plan)))
                       (assert (eq :complete (cycle-result-status automatic)))
                       (funcall check environment values)
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

(let ((reports
        (list
         (run-value-case
          :discarded-result
          '(progn (clamsara::make-tree 7)
                  (let ((node (clamsara::make-node)))
                    (clamsara::populate 5 node) node))
          (lambda (environment values)
            (assert (= 1 (length values)))
            (assert (= 63 (tree-node-count environment (first values))))))
         (run-value-case
          :multiple-value-prog1
          '(multiple-value-prog1
               (values (clamsara::make-node :left 17)
                       (clamsara::make-node :right 23))
             (dotimes (i 300) (clamsara::make-node)))
          #'check-two-values)
         (run-value-case
          :unwind-protect-values
          '(unwind-protect
                (values (clamsara::make-node :left 17)
                        (clamsara::make-node :right 23))
             ;; An interpreted call overwrites VM-VALUES before allocation.
             (clamsara::make-tree 0)
             (dotimes (i 300) (clamsara::make-node)))
          #'check-two-values))))
  (unless (every (lambda (report) (eq :complete (getf report :status))) reports)
    (error "Managed VM value-lifetime acceptance failed: ~S" reports)))
