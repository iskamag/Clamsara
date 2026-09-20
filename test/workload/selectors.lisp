;;;; Standard composed cons readers must use the managed payload boundary.
(defpackage #:clamsara.workload.selectors.test
  (:use #:cl #:clamsara)
  (:export #:run-workload-selector-tests))
(in-package #:clamsara.workload.selectors.test)

(defun tree (depth &optional (label 0))
  (if (zerop depth) label
      (cons (tree (1- depth) (1+ (* 2 label)))
            (tree (1- depth) (+ 2 (* 2 label))))))

(defun selector (width bits)
  (find-symbol (format nil "C~AR"
                       (coerce (loop for i below width
                                     collect (if (logbitp i bits) #\D #\A))
                               'string))
               :common-lisp))

(defun run-workload-selector-tests ()
  (let* ((native-cadr (fdefinition 'cl:cadr))
         (rt (make-workload-runtime :extent 16384 :max-object-bytes 8192
                                   :root-capacity 512))
         (env (clamsara::workload-runtime-environment rt))
         (checks 0))
    (unwind-protect
         (flet ((check (truth) (incf checks) (assert truth)))
           (loop for width from 2 to 4 do
             (dotimes (bits (ash 1 width))
               (let* ((name (selector width bits)) (host-tree (tree width))
                      (expected (funcall (fdefinition name) host-tree)))
                 (check (= expected (workload-eval env `(,name ',host-tree))))
                 (check (null (workload-eval env `(,name nil))))
                 (check (equal '(99 99)
                               (multiple-value-list
                                (workload-eval
                                 env `(let ((tree ',host-tree))
                                        (values (setf (,name tree) 99)
                                                (,name tree))))))))))
           (let ((function (clostrum:fdefinition
                            (clamsara::workload-maclina-client env)
                            (clamsara::workload-maclina-environment env) 'cl:cadr)))
             (check (handler-case (progn (funcall function (list 17 23)) nil)
                      (type-error () t))))
           (check (handler-case
                      (progn (workload-eval env '(cadr (cons 17 23))) nil)
                    (type-error () t)))
           (check (= 2 (workload-eval
                        env '(let ((tree (cons 1 (cons 2 nil))) (count 0))
                               (setf (cadr (prog1 tree (incf count)))
                                     (progn (incf count) 99))
                               count))))
           (check (eq native-cadr (fdefinition 'cl:cadr)))
           ;; These accessors still operate on host syntax in macro execution.
           (workload-eval env '(defmacro selector-second (form) (cadr form)))
           (check (= 17 (workload-eval env '(selector-second (+ 17 23)))))
           (check (= 23 (workload-eval
                         env '(macrolet ((pick (form) (caddr form)))
                                (pick (+ 17 23))))))
           (check (= 40 (workload-eval
                         env '(let ((list (cons 1 (cons 2 (cons 3 nil)))))
                                (setf (cadr list) 17 (caddr list) 23)
                                (+ (cadr list) (caddr list))))))
           (workload-eval env
                          '(defmacro selector-write ()
                             (let ((form (cons 1 (cons 2 nil))))
                               (setf (cadr form) 17)
                               (cadr form))))
           (check (= 17 (workload-eval env '(selector-write))))
           (let ((host-tree (tree 4)))
             (check (= (cadddr host-tree)
                       (workload-eval
                        env `(let ((tree ',host-tree))
                               (dotimes (i 600) (cons nil nil))
                               (cadddr tree)))))
             (let ((automatic (clamsara::%plan-automatic-result
                               (clamsara::workload-runtime-plan rt))))
               (check (eq :complete (cycle-result-status automatic)))
               (check (= 15 (cycle-result-count automatic :objects-moved))))))
      (workload-eval env nil)
      (close-workload-runtime rt))
    (format t "WORKLOAD-SELECTORS: ~D checks passed~%" checks)
    t))
