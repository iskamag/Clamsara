;;;; Published code must retain and correct its managed literal/capture cells.
(defpackage #:clamsara.workload.code-roots.test
  (:use #:cl #:clamsara)
  (:export #:run-workload-code-root-tests))
(in-package #:clamsara.workload.code-roots.test)

(defun runtime ()
  (make-workload-runtime :extent 16384 :max-object-bytes 8192 :root-capacity 512))

(defun full-cycle (runtime)
  (let ((record (make-cycle-result-record (clamsara::workload-runtime-plan runtime))))
    (collect (clamsara::workload-runtime-configuration runtime) :all :explicit record)
    (assert (eq :complete (cycle-result-status record)))
    record))

(defun active-literal ()
  (let* ((rt (runtime)) (env (clamsara::workload-runtime-environment rt))
         (object (workload-eval env '(cons 17 23))))
    (unwind-protect
         (progn
           (assert (= 17 (workload-eval
                          env `(progn (dotimes (i 600) (cons nil nil))
                                      (car ,object)))))
           (let ((automatic (clamsara::%plan-automatic-result
                             (clamsara::workload-runtime-plan rt))))
             (assert (eq :complete (cycle-result-status automatic)))
             (assert (= 1 (cycle-result-count automatic :objects-moved)))))
      ;; Only this probe's returned value is consumed. No root graph is erased.
      (workload-eval env nil)
      (close-workload-runtime rt))))

(defun published-code (kind)
  (let* ((rt (runtime)) (env (clamsara::workload-runtime-environment rt))
         (client (clamsara::workload-maclina-client env))
         (compiler-env (clamsara::workload-maclina-environment env)))
    (unwind-protect
         (progn
           (ecase kind
             (:literal
              (let ((object (workload-eval env '(cons 17 23))))
                (workload-eval env `(defun code-root-holder () ,object))))
             (:closure
              (setf (clostrum:fdefinition client compiler-env 'code-root-holder)
                    (workload-eval
                     env '(let ((object (cons 17 23))) (lambda () object)))))
             (:macro
              (setf (clostrum:macro-function client compiler-env 'code-root-holder)
                    (workload-eval
                     env '(let ((object (cons 17 23)))
                            (lambda (form environment)
                              (declare (ignore form environment)) object))))))
           (workload-eval env nil)
           ;; The function is not active or present in VM-VALUES at this stop.
           (let ((record (full-cycle rt)))
             (assert (= 1 (cycle-result-count record :objects-discovered)))
             (assert (= 1 (cycle-result-count record :objects-moved))))
           (let* ((function (if (eq kind :macro)
                                (clostrum:macro-function client compiler-env
                                                         'code-root-holder)
                                (clostrum:fdefinition client compiler-env
                                                     'code-root-holder)))
                  (object (if (eq kind :macro)
                              (funcall function '(code-root-holder) compiler-env)
                              (funcall function))))
             (assert (= 17 (workload-read-slot env object :car)))
             (assert (= 23 (workload-read-slot env object :cdr))))
           ;; Removing the only definition must release its code-owned payload.
           ;; A registry of every function ever compiled would leak here.
           (clostrum:fmakunbound client compiler-env 'code-root-holder)
           (workload-eval env nil)
           (assert (zerop (cycle-result-count (full-cycle rt) :objects-discovered))))
      (clostrum:fmakunbound client compiler-env 'code-root-holder)
      (workload-eval env nil)
      (close-workload-runtime rt))))

(defun run-workload-code-root-tests ()
  (active-literal)
  (format t "WORKLOAD-CODE-ROOTS :ACTIVE-LITERAL :COMPLETE~%")
  (dolist (kind '(:literal :closure :macro))
    (published-code kind)
    (format t "WORKLOAD-CODE-ROOTS ~S :COMPLETE~%" kind))
  t)
