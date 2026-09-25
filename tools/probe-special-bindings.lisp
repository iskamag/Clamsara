;;;; Plain Maclina vs native binding semantics. No Clamsara is loaded.
;;;; This is an honest failing gate while the separate nonlocal-exit defects
;;;; remain.
;;;; Keyword arguments are explicitly quoted because the plain client does not
;;;; automatically describe new keywords as constants.

(require :asdf)
(asdf:load-system :extrinsicl)
(asdf:load-system :extrinsicl/maclina)
(asdf:load-system :clostrum-basic)
(asdf:load-system :trucler-native)
(assert (not (find-package :clamsara)))
(defpackage #:binding-native (:use #:cl))
(defpackage #:binding-vm (:use #:cl))
(let* ((client (make-instance 'maclina.vm-cross:client))
       (env (make-instance 'clostrum-basic:run-time-environment))
       (maclina.machine:*client* client)
       (mismatches 0) (cases 0))
  (extrinsicl:install-cl (make-instance 'trucler-native:client) env)
  (extrinsicl::install-environment-accessors client env)
  (extrinsicl::install-proclaim client env)
  (extrinsicl.maclina:install-eval client env)
  (maclina.vm-cross:initialize-vm 65536 client)
  (flet ((read-in (text package)
           (let ((*package* (find-package package)))
             (with-input-from-string (stream text)
               (let ((form (read stream)))
                 (assert (eq :eof (read stream nil :eof)))
                 form)))))
    (dolist (text '("(defvar special-param 0)"
                    "(defvar special-other 100)"
                    "(defvar special-rest nil)"
                    "(defvar special-flag nil)"
                    "(defun read-param () special-param)"
                    "(defun read-other () special-other)"
                    "(defun read-flag () special-flag)"
                    "(defun write-param (x) (setq special-param x))"
                    "(defun update-param (special-param) (setq special-param (1+ special-param)) (values special-param (read-param)))"
                    "(defun explicit-param (special-param) (declare (special special-param)) (setq special-param (1+ special-param)) (values special-param (read-param)))"
                    "(defun rebind-param (special-param) (declare (special special-param)) (let ((special-param 99)) (read-param)))"
                    "(defun rebind-star (special-param) (let* ((special-param 99) (x (read-param))) (values x special-param)))"
                    "(defun optional-default (special-param &optional (x (read-param))) (values special-param x))"
                    "(defun key-default (special-param &key (x (read-param))) (values special-param x))"
                    "(defun aux-default (special-param &aux (x (read-param))) (values special-param x))"
                    "(defun two-required (special-param special-other) (setq special-param (1+ special-param) special-other (1+ special-other)) (values special-param (read-param) special-other (read-other)))"
                    "(defun optional-special (&optional (special-param 17 special-flag)) (setq special-param (1+ special-param)) (values special-param (read-param) special-flag (read-flag)))"
                    "(defun key-special (&key (special-param 17 special-flag)) (setq special-param (1+ special-param)) (values special-param (read-param) special-flag (read-flag)))"
                    "(defun rest-special (&rest special-rest) (let ((special-rest (cdr special-rest))) (values (car special-rest) (funcall (lambda () (car special-rest))))))"
                    "(defun aux-special (&aux (special-param 17)) (setq special-param (1+ special-param)) (values special-param (read-param)))"
                    "(defun required-closure (special-param) (let ((f (lambda () (setq special-param (1+ special-param)) (read-param)))) (setq special-param 42) (funcall f)))"
                    "(defun make-reader (special-param) (lambda () special-param))"
                    "(defun callee-writes (special-param) (write-param 37) (values special-param (read-param)))"
                    "(defun throwing-param (special-param) (setq special-param (1+ special-param)) (throw (quote exit) (read-param)))"
                    "(defun returning-param (special-param) (setq special-param (1+ special-param)) (return-from returning-param (read-param)))"
                    "(defun cleanup-param (special-param) (unwind-protect (progn (setq special-param (1+ special-param)) (throw (quote exit) (read-param))) (setq special-other (read-param))))"
                    "(defun read-local () (declare (special local-param)) local-param)"
                    "(defun local-shadow (local-param) (declare (special local-param)) (let ((local-param 99)) (values local-param (read-local))))"
                    "(defun local-required (local-param) (declare (special local-param)) (setq local-param (1+ local-param)) (values local-param (read-local)))"))
      (eval (read-in text :binding-native))
      (maclina.compile:eval (read-in text :binding-vm) env client))
    (dolist (text '("(update-param 17)"
                    "(explicit-param 17)"
                    "(rebind-param 17)"
                    "(rebind-star 17)"
                    "(optional-default 17)"
                    "(optional-default 17 23)"
                    "(key-default 17)"
                    "(key-default 17 (quote :x) 23)"
                    "(aux-default 17)"
                    "(two-required 17 23)"
                    "(optional-special)"
                    "(optional-special 23)"
                    "(key-special)"
                    "(key-special (quote :special-param) 23)"
                    "(rest-special 17 23 42)"
                    "(aux-special)"
                    "(required-closure 17)"
                    "(let ((f (make-reader 17))) (let ((special-param 88)) (funcall f)))"
                    "(callee-writes 17)"
                    "(flet ((f (special-param) (setq special-param (1+ special-param)) (read-param))) (f 17))"
                    "(labels ((f (special-param) (setq special-param (1+ special-param)) (g)) (g () (read-param))) (f 17))"
                    "((lambda (special-param) (setq special-param (1+ special-param)) (read-param)) 17)"
                    "((lambda (special-param) ((lambda (special-param) (setq special-param (1+ special-param)) (read-param)) 23)) 17)"
                    "(let ((special-param 9)) (values (catch (quote exit) (throwing-param 17)) (read-param)))"
                    "(let ((special-param 9)) (values (returning-param 17) (read-param)))"
                    "(let ((special-param 9) (special-other 100)) (values (catch (quote exit) (cleanup-param 17)) (read-param) (read-other)))"
                    "(local-shadow 17)"
                    "(local-required 17)"
                    "(let ((special-param 7)) (let ((special-param 17) (special-other special-param)) (values (read-param) (read-other))))"
                    "(let ((special-param 7)) (let* ((special-param 17) (special-other special-param)) (values (read-param) (read-other))))"
                    "(let ((special-param 9)) (multiple-value-bind (special-param special-other) (values 17 23) (values (read-param) (read-other))))"
                    "(let ((special-param 9)) (progv (quote (special-param)) (quote (17)) (setq special-param 23) (read-param)))"
                    "(let ((special-param 9)) (let ((f (lambda (special-param &optional (x (read-param)) &key (y (read-param)) &aux (z (read-param))) (values special-param x y z)))) (funcall f 17)))"
                    "(values special-param special-other special-rest special-flag)"))
      (incf cases)
      ;; Each case has a fresh VM so an earlier error cannot corrupt the next
      ;; case's registers. Errors remain explicit mismatches, never passes.
      (maclina.vm-cross:initialize-vm 65536 client)
      (let ((native (list :values (multiple-value-list (eval (read-in text :binding-native)))))
            (vm (handler-case
                    (list :values (multiple-value-list
                                   (maclina.compile:eval (read-in text :binding-vm) env client)))
                  (error (condition)
                    (list :error (class-name (class-of condition))
                          (princ-to-string condition))))))
        (format t "~&BINDING ~D native=~S vm=~S equal=~S~%" cases native vm (equal native vm))
        (unless (equal native vm)
          (incf mismatches)
          (format t "FORM ~A~%" text)))))
  (format t "~&BINDING-MATRIX cases=~D mismatches=~D~%" cases mismatches)
  (assert (zerop mismatches)))
