;;;; Compiler value-lifetime facts and bounded interpreter activation roots.
(in-package #:clamsara)

(defun %call-with-workload-function (client function entry arguments)
  (let* ((provider (workload-root-provider (workload-client-workload client)))
         (vm (workload-provider-vm provider))
         (frame (workload-provider-frame-count provider))
         (functions (workload-provider-functions provider))
         (saved (workload-provider-saved-values provider))
         (template (if (typep function 'maclina.machine:closure)
                       (maclina.machine:template function) function)))
    (when (= frame (length functions))
      (error 'workload-capability-error :operation 'workload-call
             :reason :vm-frame-capacity-exhausted))
    (unless (eq vm maclina.vm-cross::*vm*)
      (error 'workload-capability-error :operation 'workload-call
             :reason :foreign-vm))
    (let ((stack-top (maclina.vm-cross::vm-stack-top vm))
          (frame-pointer (maclina.vm-cross::vm-frame-pointer vm))
          (pc (maclina.vm-cross::vm-pc vm))
          (args (maclina.vm-cross::vm-args vm))
          (arg-count (maclina.vm-cross::vm-arg-count vm)))
      (setf (aref functions frame) function
            (aref saved frame)
            (when (gethash template (workload-client-cleanup-templates client))
              (maclina.vm-cross::vm-values vm))
            (workload-provider-frame-count provider) (1+ frame))
      (unwind-protect
           (apply entry arguments)
        ;; vm-cross normally restores its caller frame only on normal return.
        ;; These are interpreter registers, not guest-value copies. Never
        ;; restore VM-VALUES: the completed call/NLX owns its outgoing values.
        (setf (maclina.vm-cross::vm-stack-top vm) stack-top
              (maclina.vm-cross::vm-frame-pointer vm) frame-pointer
              (maclina.vm-cross::vm-pc vm) pc
              (maclina.vm-cross::vm-args vm) args
              (maclina.vm-cross::vm-arg-count vm) arg-count
              (aref functions frame) nil
              (aref saved frame) nil
              (workload-provider-frame-count provider) frame)))))

;; CLOSURE and FUNCTION are distinct Maclina classes, not a subtype pair.
(defmethod maclina.machine:compute-instance-function :around
    ((client workload-maclina-client) (function maclina.machine:closure))
  (let ((entry (call-next-method)))
    (lambda (&rest arguments)
      (declare (dynamic-extent arguments))
      (%call-with-workload-function client function entry arguments))))

(defun %workload-clear-unused-values (environment context)
  ;; A nonnegative receiving context keeps its values on the operand stack
  ;; (or discards them). Only -1 owns the multiple-value register. Emit the
  ;; VM's existing zero-count POP-VALUES, never guess liveness at collection.
  (when (and (typep maclina.machine:*client* 'workload-maclina-client)
             (not (minusp (maclina.compile::context-receiving context))))
    (maclina.compile::compile-literal
     0 environment (maclina.compile::new-context context :receiving 1))
    (maclina.compile::assemble context maclina.machine:pop-values)))

(defmethod maclina.compile::compile-combination :around
    (description form environment context)
  (multiple-value-prog1 (call-next-method)
    ;; Macros and special operators compile another form or use the special
    ;; compiler below. Avoid emitting duplicate clear instructions for them.
    (unless (typep description '(or trucler:macro-description
                                    trucler:special-operator-description))
      (%workload-clear-unused-values environment context))))

(defmethod maclina.compile::compile-special :around
    (operator form environment context)
  (declare (ignore operator form))
  (multiple-value-prog1 (call-next-method)
    (%workload-clear-unused-values environment context)))

(defmethod maclina.compile::compile-special :around
    ((operator (eql 'unwind-protect)) form environment context)
  (declare (ignore operator))
  (if (not (typep maclina.machine:*client* 'workload-maclina-client))
      (call-next-method)
      ;; This is Maclina's existing lowering, with an explicit cleanup-template
      ;; marker. Do not infer cleanup ownership from names or instruction PCs.
      (progn
        (maclina.compile::destructure-syntax (unwind-protect protected . cleanup)
            (form :source (maclina.compile::context-source context))
          (let* ((source (maclina.compile::expr-source-location
                          cleanup (maclina.compile::context-source context)))
                 (function
                   (maclina.compile::%compile-lambda-expression
                    `(lambda () ,@cleanup 0) environment context
                    :declarations () :source source)))
            (setf (gethash function
                           (workload-client-cleanup-templates maclina.machine:*client*))
                  t)
            (maclina.compile::assemble
             context maclina.machine:protect
             (maclina.compile::cfunction-literal-index function context)))
          (maclina.compile::compile-form
           protected environment
           (maclina.compile::new-context context :dynenv '(:protect)))
          (maclina.compile::assemble context maclina.machine:cleanup))
        (%workload-clear-unused-values environment context))))

(defmethod maclina.compile::compile-special :around
    ((operator (eql 'multiple-value-call)) form environment context)
  (declare (ignore operator))
  (if (not (typep maclina.machine:*client* 'workload-maclina-client))
      (call-next-method)
      (progn
        ;; Upstream passes CONTEXT to function lookup, so receiving=0 can
        ;; omit the callee itself. The function designator always needs one
        ;; operand, independently of how many result values the caller uses.
        (maclina.compile::destructure-syntax (multiple-value-call function . forms)
            (form :source (maclina.compile::context-source context))
          (maclina.compile::compile-fdesignator
           function environment (maclina.compile::new-context context :receiving 1))
          (if forms
              (progn
                (maclina.compile::compile-form
                 (first forms) environment
                 (maclina.compile::new-context context :receiving -1))
                (maclina.compile::assemble context maclina.machine:push-values)
                (dolist (argument (rest forms))
                  (maclina.compile::compile-form
                   argument environment
                   (maclina.compile::new-context context :receiving -1))
                  (maclina.compile::assemble context maclina.machine:append-values))
                (maclina.compile::emit-mv-call context))
              (maclina.compile::emit-call context 0)))
        (%workload-clear-unused-values environment context))))

(defmethod maclina.compile::load-literal-info :around
    ((client workload-maclina-client) (info maclina.compile::cfunction) environment)
  (declare (ignore environment))
  (let ((function (call-next-method))
        (templates (workload-client-cleanup-templates client)))
    (when (gethash info templates)
      (setf (gethash function templates) t)
      ;; Do not keep the compilation graph after linking the real function.
      (remhash info templates))
    function))
