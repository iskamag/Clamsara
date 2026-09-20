;;;; Adapter regressions, not full benchmark or all-representation acceptance.
(defpackage #:clamsara.workload.adapter.test
  (:use #:cl #:clamsara)
  (:export #:run-workload-adapter-tests))
(in-package #:clamsara.workload.adapter.test)

(defun run-workload-structure-cycle-test ()
  "Exercise the unchanged GCBench tree functions, not its full depth-18 run."
  (let* ((runtime (make-workload-runtime :extent 16384 :max-object-bytes 8192
                                        :root-capacity 512))
         (environment (clamsara::workload-runtime-environment runtime))
         (configuration (clamsara::workload-runtime-configuration runtime))
         (plan (clamsara::workload-runtime-plan runtime)))
    (unwind-protect
         (progn
           (workload-load
            environment (asdf:system-relative-pathname
                         :clamsara "test/fixtures/boehm-gc.lisp"))
           ;; Leave room for sixteen nodes. A 31-node tree then forces an
           ;; automatic collection with live constructor arguments/subtrees.
           (let* ((tree (workload-eval environment
                                       '(progn (dotimes (i 240) (clamsara::make-node))
                                               (clamsara::make-tree 4))))
                  (automatic (clamsara::%plan-automatic-result plan))
                  (seen (make-hash-table :test #'eq)))
             (assert (eq :complete (cycle-result-status automatic)))
             (assert (plusp (cycle-result-count automatic :objects-moved)))
             (labels ((walk (node)
                        (if (null node) 0
                            (progn
                              (assert (not (gethash node seen)))
                              (setf (gethash node seen) t)
                              (assert (eq 'clamsara::node
                                          (workload-read-slot environment node :slot0)))
                              (+ 1 (walk (workload-read-slot environment node :slot1))
                                 (walk (workload-read-slot environment node :slot2)))))))
               (assert (= 31 (walk tree))))
             (format t "WORKLOAD-STRUCTURE-CYCLE nodes=31 moved=~D~%"
                     (cycle-result-count automatic :objects-moved))))
      (dotimes (i (length (clamsara::workload-root-locations environment)))
        (clamsara::workload-temporary-root-clear environment i))
      (let ((vm (clamsara::workload-provider-vm
                 (clamsara::workload-runtime-root-provider runtime))))
        (setf (maclina.vm-cross::vm-values vm) nil
              (maclina.vm-cross::vm-stack-top vm) 0
              (maclina.vm-cross::vm-dynenv-stack vm) nil))
      (let ((result (make-cycle-result-record plan)))
        (collect configuration :all :explicit result)
        (assert (eq :complete (cycle-result-status result))))
      (close-workload-runtime runtime)))
  t)

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
               ;; These are the unmodified benchmark's bare DEFSTRUCT shape
               ;; and keyword constructor calls, not a host structure fallback.
               (workload-eval environment
                              '(defstruct adapter-node left right dummy1 dummy2))
               (check (equal '(11 22)
                             (multiple-value-list
                              (workload-eval
                               environment
                               '(let ((node (make-adapter-node :left 11 :right 22)))
                                  (values (adapter-node-left node)
                                          (adapter-node-right node)))))))
               (workload-eval environment '(defstruct adapter-other left right))
               (check (equal '(t nil 42 42)
                             (multiple-value-list
                              (workload-eval
                               environment
                               '(let ((node (make-adapter-node :left 11 :left 99)))
                                  (assert (= 11 (adapter-node-left node)))
                                  (values (adapter-node-p node)
                                          (adapter-other-p node)
                                          (setf (adapter-node-right node) 42)
                                          (adapter-node-right node)))))))
               (let* ((client (clamsara::workload-maclina-client environment))
                      (compiler-environment
                        (clamsara::workload-maclina-environment environment))
                      (constructor (clostrum:fdefinition
                                    client compiler-environment 'make-adapter-node))
                      (foreign-accessor (clostrum:fdefinition
                                         client compiler-environment
                                         'adapter-other-left))
                      (object (funcall constructor :left 11 :unknown 19
                                                   :allow-other-keys t)))
                 (check (workload-reference-p environment object))
                 (check (eq 'adapter-node
                            (workload-read-slot environment object :slot0)))
                 (check (= 11 (workload-read-slot environment object :slot1)))
                 (check (handler-case (progn (funcall foreign-accessor object) nil)
                          (type-error () t)))
                 (check (handler-case (progn (funcall constructor :unknown 19) nil)
                          (program-error () t)))
                 (check (handler-case (progn (funcall constructor :left) nil)
                          (program-error () t))))
               (dolist (form '((defstruct too-wide a b c d e f g h)
                               (defstruct (options (:type list)) x)
                               (defstruct defaults (x 17))
                               (defstruct duplicates x x)))
                 (check (handler-case
                            (progn (clamsara::%parse-simple-struct form) nil)
                          (clamsara::workload-capability-error () t))))
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
      (check (run-workload-structure-cycle-test))
      (format t "WORKLOAD-ADAPTER: ~D checks passed~%" checks)
      t)))
