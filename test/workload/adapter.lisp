;;;; Adapter regressions, not full benchmark or all-representation acceptance.
(defpackage #:clamsara.workload.adapter.test
  (:use #:cl #:clamsara)
  (:export #:run-workload-adapter-tests))
(in-package #:clamsara.workload.adapter.test)

(defun run-workload-adapter-tests ()
  (let ((checks 0))
    (flet ((check (value)
             (assert value)
             (incf checks)))
      (let ((smoke (run-workload-smoke :extent 65536)))
        (check (eq :complete (getf smoke :status)))
        (check (= 2 (getf smoke :objects-moved))))
      (let* ((runtime (make-workload-runtime :extent 65536
                                            :max-object-bytes 16384
                                            :root-capacity 512))
             (environment (clamsara::workload-runtime-environment runtime))
             (configuration (clamsara::workload-runtime-configuration runtime))
             (plan (clamsara::workload-runtime-plan runtime)))
        (unwind-protect
             (progn
               (check (equal '(7 8)
                             (multiple-value-list
                              (workload-eval environment '(time (values 7 8))))))
               (check (= 1 (workload-eval environment
                                        '(let ((count 0))
                                           (time (incf count))
                                           count))))
               ;; Keywords are constants, including symbols interned after
               ;; environment construction. They must not create special cells.
               (let* ((client (clamsara::workload-maclina-client environment))
                      (compiler-environment
                        (clamsara::workload-maclina-environment environment))
                      (keyword (intern (symbol-name (gensym "ADAPTER-KEY-"))
                                       (find-package "KEYWORD")))
                      (before (clamsara::workload-client-global-cell-count client))
                      (description
                        (trucler:describe-variable client compiler-environment
                                                   keyword)))
                 (check (typep description 'trucler:constant-variable-description))
                 (check (eq keyword (trucler:name description)))
                 (check (eq keyword (trucler:value description)))
                 (check (eq keyword (workload-eval environment keyword)))
                 (check (= before
                           (clamsara::workload-client-global-cell-count client)))
                 (check (null (trucler:describe-variable
                               client compiler-environment (gensym "UNKNOWN-")))))
               (check (equal '(:left :right :element-type :lambda-list t nil)
                             (multiple-value-list
                              (workload-eval environment
                                             '(values :left :right :element-type
                                                      :lambda-list t nil)))))
               (check (= 12 (workload-eval
                            environment
                            '((lambda (&key left right) (+ left right))
                              :left 5 :right 7))))
               ;; Native backquote/comma syntax must be expanded, not called
               ;; as a function or mistaken for a numeric object.
               (workload-eval environment
                              '(defmacro adapter-add-one (value) `(+ ,value 1)))
               (check (= 5 (workload-eval environment '(adapter-add-one 4))))
               (workload-eval environment
                              '(defmacro adapter-tree-size (value)
                                 `(1- (ash 1 (1+ ,value)))))
               (check (= 31 (workload-eval environment
                                         '(let ((depth 4))
                                            (adapter-tree-size depth)))))
               (check (= 31 (workload-eval environment
                                         '(adapter-tree-size (+ 2 2)))))
               (check (= 31 (workload-eval environment
                                         '(macrolet ((size (value)
                                                       `(1- (ash 1 (1+ ,value)))))
                                            (size 4)))))
               (check (null clamsara::*workload-source-execution-p*))
               ;; Macro source data must not enable a host-list fallback for
               ;; ordinary runtime calls after macroexpansion returns.
               (check (handler-case
                          (progn
                            (funcall
                             (clostrum:fdefinition
                              (clamsara::workload-maclina-client environment)
                              (clamsara::workload-maclina-environment environment)
                              'cl:car)
                             (list 1 2))
                            nil)
                        (type-error () t)))
               (let ((object (workload-allocate environment :cons 2
                                               '((:car 11) (:cdr 22)))))
                 (check (workload-reference-p environment object))
                 (check (= 11 (workload-read-slot environment object :car)))
                 (check (= 22 (workload-read-slot environment object :cdr))))
               (check (handler-case
                          (progn (clamsara::workload-ensure-reference environment (list 1 2)) nil)
                        (clamsara::workload-capability-error () t))))
          ;; Explicitly discharge this fixture's payload before shutdown.
          ;; General adapter shutdown semantics remain a separate work item.
          (dotimes (i (length (clamsara::workload-root-locations environment)))
            (clamsara::workload-temporary-root-clear environment i))
          (let ((vm (clamsara::workload-provider-vm
                     (clamsara::workload-runtime-root-provider runtime))))
            (setf (maclina.vm-cross::vm-values vm) nil
                  (maclina.vm-cross::vm-stack-top vm) 0
                  (maclina.vm-cross::vm-dynenv-stack vm) nil))
          (let ((result (make-cycle-result-record plan)))
            (collect configuration :all :explicit result)
            (check (eq :complete (cycle-result-status result))))
          (close-workload-runtime runtime)))
      (format t "WORKLOAD-ADAPTER: ~D checks passed~%" checks)
      t)))
