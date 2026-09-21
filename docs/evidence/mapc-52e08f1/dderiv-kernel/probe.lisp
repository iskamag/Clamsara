;;;; Kernel oracles on the unmodified fixture; not the full TESTDDERIV run.
(defpackage #:clamsara.mapc.dderiv-kernel (:use #:cl))
(in-package #:clamsara.mapc.dderiv-kernel)
(defvar *runtime* nil)
(defvar *phase* :native-setup)
(defvar *failed-condition* nil)
(defvar *passed* 0)
(defvar *native-package* (make-package "CLAMSARA.DDERIV.NATIVE-ORACLE" :use '("CL")))
(defvar *forms* '("(dderiv '(+ (* 3 x x) (* a x x) (* b x) 5))"
                  "(dderiv '(- x y 4))" "(dderiv '(// x y))"
                  "(dderiv 'x)" "(dderiv 'y)" "(dderiv '(unknown x))"))
(defun shape (value source-package &optional environment)
  (cond ((and environment (clamsara:workload-reference-p environment value))
         (list :cons (shape (clamsara:workload-read-slot environment value :car)
                           source-package environment)
                     (shape (clamsara:workload-read-slot environment value :cdr)
                           source-package environment)))
        ((consp value) (list :cons (shape (car value) source-package)
                                  (shape (cdr value) source-package)))
        ((symbolp value)
         (list :symbol (if (eq (symbol-package value) source-package) :source
                          (package-name (symbol-package value))) (symbol-name value)))
        ((integerp value) value)
        (t (error "Unsupported oracle leaf ~S" value))))
(defun full-cycle ()
  (let ((record (clamsara:make-cycle-result-record
                 (clamsara::workload-runtime-plan *runtime*))))
    (clamsara:collect (clamsara::workload-runtime-configuration *runtime*)
                      :all :explicit record)
    (assert (eq :complete (clamsara:cycle-result-status record))) record))
(handler-case
    (progn
      (let ((*package* *native-package*))
        (load (asdf:system-relative-pathname :clamsara "bench/gabriel/reference/dderiv.cl")))
      ;; Establish the actual runtime owner before any workload actions.
      (setf *runtime* (clamsara:make-workload-runtime))
      (setf *phase* :managed-fixture-load)
      (let* ((environment (clamsara::workload-runtime-environment *runtime*))
             (provider (clamsara::workload-runtime-root-provider *runtime*))
             (package (find-package :clamsara)))
        (clamsara:workload-load environment
          (asdf:system-relative-pathname :clamsara "bench/gabriel/reference/dderiv.cl"))
        (dolist (text *forms*)
          (setf *phase* (list :kernel text))
          (let* ((native (let ((*package* *native-package*))
                           (shape (eval (read-from-string text)) *native-package*)))
                 (form (let ((*package* package)) (read-from-string text))))
            (clamsara:workload-eval environment form)
            ;; Reacquire from the real VM result after a real complete cycle.
            (full-cycle)
            (let* ((values (maclina.vm-cross::vm-values
                             (clamsara::workload-provider-vm provider)))
                   (actual (shape (first values) package environment)))
              (assert (= 1 (length values)))
              (assert (equal native actual))
              (incf *passed*)
              (format t "~&DDERIV-KERNEL-PASS ~A~%" text))))
        ;; Only all-success reaches exact case-owned release and discharge.
        (setf *phase* :release)
        (let* ((client (clamsara::workload-maclina-client environment))
               (runtime (clamsara::workload-maclina-environment environment))
               (properties (clamsara::workload-client-properties client))
               (indicator (intern "DDERIV" package)))
          (dolist (name '("+" "-" "*" "//"))
            (remhash (clamsara::%property-key (intern name package) indicator) properties))
          (dolist (name '("DDERIV-AUX" "+DDERIV" "-DDERIV" "*DDERIV"
                          "//DDERIV" "DDERIV" "DDERIV-RUN" "TESTDDERIV"))
            (clostrum:fmakunbound client runtime (intern name package))))
        (clamsara:workload-eval environment nil)
        (assert (zerop (clamsara:cycle-result-count (full-cycle) :objects-discovered)))
        (clamsara:close-workload-runtime *runtime*)
        (assert (null (clamsara::workload-runtime-configuration *runtime*)))
        (setf *phase* :complete))
      (format t "~&DDERIV-KERNEL-SUMMARY passed=~D status=~S~%" *passed* *phase*))
  (error (condition)
    (setf *failed-condition* condition)
    (format t "~&DDERIV-KERNEL-FAIL phase=~S passed=~D [~S] ~A~%"
            *phase* *passed* (type-of condition) condition)
    (when *runtime*
      (format t "~&DDERIV-KERNEL-OWNER config=~S token-active=~S~%"
              (clamsara::%configuration-state (clamsara::workload-runtime-configuration *runtime*))
              (clamsara::simulator-provider-token-active-p
               (clamsara::workload-runtime-root-token *runtime*))))))
(assert (null *failed-condition*))
(assert (= *passed* 6))
