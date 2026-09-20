;;;; Regression for upstream required/global special-variable compilation.
;;;; This deliberately loads no Clamsara implementation or adapter methods.
(require :asdf)
(asdf:load-system :extrinsicl)
(asdf:load-system :extrinsicl/maclina)
(asdf:load-system :clostrum-basic)
(asdf:load-system :trucler-native)
(assert (not (find-package :clamsara)))
(defpackage #:special-native (:use #:cl))
(defpackage #:special-vm (:use #:cl))
(let* ((client (make-instance 'maclina.vm-cross:client))
       (env (make-instance 'clostrum-basic:run-time-environment))
       (maclina.machine:*client* client)
       (mismatches 0))
  (extrinsicl:install-cl (make-instance 'trucler-native:client) env)
  (extrinsicl::install-environment-accessors client env)
  (extrinsicl::install-proclaim client env)
  (extrinsicl.maclina:install-eval client env)
  (maclina.vm-cross:initialize-vm 65536 client)
  (flet ((read-in (text package)
           (let ((*package* (find-package package))) (read-from-string text))))
    (dolist (text '("(defvar special-param 0)"
                    "(defun read-param () special-param)"
                    "(defun update-param (special-param) (setq special-param (1+ special-param)) (values special-param (read-param)))"
                    "(defun explicit-param (special-param) (declare (special special-param)) (setq special-param (1+ special-param)) (values special-param (read-param)))"
                    "(defun rebind-param (special-param) (declare (special special-param)) (let ((special-param 99)) (read-param)))"))
      (eval (read-in text :special-native))
      (maclina.compile:eval (read-in text :special-vm) env client))
    (dolist (text '("(update-param 17)" "(explicit-param 17)" "(rebind-param 17)"))
      (let ((native (multiple-value-list (eval (read-in text :special-native))))
            (vm (multiple-value-list
                 (maclina.compile:eval (read-in text :special-vm) env client))))
        (format t "~&SPECIAL-PARAM ~A native=~S vm=~S equal=~S~%"
                text native vm (equal native vm))
        (unless (equal native vm) (incf mismatches)))))
  (assert (zerop mismatches)))
