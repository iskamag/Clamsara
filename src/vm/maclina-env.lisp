(in-package #:clamsara)

;;; --- Maclina Environment ---
;;; Creates a Clostrum environment backed by maclina-vm.

(defvar *clamsara-maclina-env* nil
  "The active Maclina Clostrum environment.")

(defvar *clamsara-maclina-client* nil
  "The active Maclina client.")

(defun setup-clamsara-maclina-environment (plan &key (stack-size 65536))
  "Create a Clostrum environment with Maclina backed by Clamsara."
  (let* ((client (make-instance 'clamsara-maclina-client :plan plan))
         (rte (make-instance 'clostrum-basic:run-time-environment)))
    (setf maclina.machine:*client* client)
    (maclina.vm-cross:initialize-vm stack-size client)
    (let ((trucler-client (make-instance 'trucler-native:client)))
      (extrinsicl:install-cl trucler-client rte)
      (extrinsicl.maclina:install-eval client rte)
      (install-clamsara-overrides client rte plan)
      (install-clamsara-reader client rte))
    (setf *clamsara-maclina-client* client
          *clamsara-maclina-env* rte)
    (values client rte)))

(defun install-clamsara-overrides (client env plan)
  "Install Clamsara-backed functions into the Clostrum environment."
  (declare (ignore client))
  (let ((vm (plan-vm plan)))
    ;; CONS
    (setf (clostrum:fdefinition client env 'cons)
          (lambda (car cdr)
            (let ((addr (plan-allocate plan 3 :default)))
              (when (null addr)
                (error 'heap-exhausted :plan plan))
              (setf (vm-object-header vm addr) (make-object-header 2 :type-tag +type-tag-cons+))
              (setf (vm-object-reference vm addr 0) car)
              (setf (vm-object-reference vm addr 1) cdr)
              addr)))
    ;; CAR / CDR
    (setf (clostrum:fdefinition client env 'car)
          (lambda (x)
            (if (and (integerp x) (not (zerop x))
                     (vm-object-start-p vm x)
                     (= (vm-object-type-tag vm x) +type-tag-cons+))
                (vm-object-reference vm x 0)
                (cl:car x))))
    (setf (clostrum:fdefinition client env 'cdr)
          (lambda (x)
            (if (and (integerp x) (not (zerop x))
                     (vm-object-start-p vm x)
                     (= (vm-object-type-tag vm x) +type-tag-cons+))
                (vm-object-reference vm x 1)
                (cl:cdr x))))
    ;; OBJECT-REFERENCE — raw slot access for MMTk-backed objects
    (setf (clostrum:fdefinition client env 'object-reference)
          (lambda (addr idx) (vm-object-reference vm addr idx)))
    (setf (clostrum:fdefinition client env '(setf object-reference))
          (lambda (new addr idx)
            (vm-object-reference-store vm addr idx new :barrier-p t)))
    ;; OBJECT-START-P
    (setf (clostrum:fdefinition client env 'object-start-p)
          (lambda (addr) (vm-object-start-p vm addr)))
    ;; OBJECT-TYPE-TAG
    (setf (clostrum:fdefinition client env 'object-type-tag)
          (lambda (addr) (vm-object-type-tag vm addr)))
    ;; OBJECT-SIZE
    (setf (clostrum:fdefinition client env 'object-size)
          (lambda (addr) (vm-object-reference-count vm addr)))
    ;; %MAKE-STRUCT-RAW — allocate N slots, write header, return raw address
    (setf (clostrum:fdefinition client env '%make-struct-raw)
          (lambda (n-slots &rest init-vals)
            (let ((addr (plan-allocate plan (+ 1 n-slots) :default)))
              (when (null addr)
                (error 'heap-exhausted :plan plan))
              (setf (vm-object-header vm addr)
                    (make-object-header n-slots :type-tag +type-tag-struct+))
              (loop for i from 0 for v in init-vals
                    do (setf (vm-object-reference vm addr i) v))
              addr)))
    ;; STRUCT-REF / STRUCT-SET
    (setf (clostrum:fdefinition client env '%struct-ref)
          (lambda (addr idx) (vm-object-reference vm addr idx)))
    (setf (clostrum:fdefinition client env '%struct-set)
          (lambda (new-val addr idx)
            (vm-object-reference-store vm addr idx new-val :barrier-p t)
            new-val))))

(defun install-clamsara-reader (client env)
  "Install the Eclector read function into the Clostrum environment."
  (declare (ignore client))
  (setf (clostrum:fdefinition client env 'read)
        (lambda (&optional (stream *standard-input*) (eof-error-p t) eof-value recursive-p)
          (declare (ignore recursive-p))
          (let ((eclector.reader:*readtable* (make-clamsara-readtable)))
            (eclector.reader:read stream eof-error-p eof-value))))
  (setf (clostrum:fdefinition client env 'read-from-string)
        (lambda (string &optional (eof-error-p t) eof-value &key (start 0) end preserve-whitespace)
          (declare (ignore preserve-whitespace))
          (let ((eclector.reader:*readtable* (make-clamsara-readtable)))
            (eclector.reader:read-from-string string eof-error-p eof-value
                                              :start start :end end)))))

(defun make-clamsara-readtable ()
  "Create a readtable for the Clamsara Maclina environment."
  (let ((rt (make-instance 'eclector.readtable.simple:readtable)))
    (eclector.reader:set-standard-syntax-and-macros rt)
    rt))

;;; --- High-level API ---

(defun clamsara-maclina-eval (form)
  "Evaluate FORM in the Clamsara-Maclina environment."
  (let ((eval-fn (clostrum:fdefinition *clamsara-maclina-client*
                                       *clamsara-maclina-env* 'eval)))
    (funcall eval-fn form)))

(defun clamsara-maclina-eval-string (string)
  "Evaluate STRING in the Clamsara-Maclina environment."
  (let ((fn (clostrum:fdefinition *clamsara-maclina-client*
                                  *clamsara-maclina-env* 'eval)))
    (funcall fn (clamsara-read-from-string string))))

(defun clamsara-read-from-string (string)
  "Read a Lisp form from STRING using Eclector."
  (let ((eclector.reader:*readtable* (make-clamsara-readtable)))
    (eclector.reader:read-from-string string)))

(defmacro with-clamsara-maclina ((&key (plan-type :marksweep) (heap-size 65536)
                                        (stack-size 65536))
                                 &body body)
  "Execute BODY with an active Clamsara-Maclina environment.
Creates a maclina-vm and plan, sets up the Clostrum environment,
and restores previous state on exit."
  (let ((prev-client (gensym "PREV-CLIENT"))
        (prev-cc (gensym "PREV-CC"))
        (prev-ce (gensym "PREV-CE"))
        (vm-var (gensym "VM"))
        (plan-var (gensym "PLAN")))
    `(let ((,prev-client (when (boundp 'maclina.machine:*client*)
                           maclina.machine:*client*))
           (,prev-cc *clamsara-maclina-client*)
           (,prev-ce *clamsara-maclina-env*))
       (let* ((,vm-var (make-maclina-vm :heap-size ,heap-size))
              (,plan-var (make-plan ,plan-type ,vm-var ,heap-size))
              (*active-plan* ,plan-var)
              (*active-vm* ,vm-var))
         (setup-clamsara-maclina-environment *active-plan* :stack-size ,stack-size)
         (unwind-protect
              (progn ,@body)
           (setf maclina.machine:*client* ,prev-client
                 *clamsara-maclina-client* ,prev-cc
                 *clamsara-maclina-env* ,prev-ce
                 *active-plan* nil
                 *active-vm* nil))))))
