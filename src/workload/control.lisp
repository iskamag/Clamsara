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


(defun %provider-mapc-admission (provider function list-count &key active-scope-p)
  "Check this extent and the known callback entry, not arbitrary future work."
  (let* ((vm (workload-provider-vm provider))
         (template (typecase function
                     (maclina.machine:function function)
                     (maclina.machine:closure (maclina.machine:template function))))
         (entry-slots (if template
                          (+ list-count (maclina.machine:locals-frame-size template)) 0))
         (cells (if active-scope-p 0 (1+ (* 2 list-count))))
         (frames (+ (if active-scope-p 0 1) (if template 1 0)))
         (frame (workload-provider-frame-count provider)))
    (unless (and vm (eq vm maclina.vm-cross::*vm*))
      (error 'workload-capability-error :operation 'workload-mapc :reason :foreign-vm))
    (when (or (> (+ frame frames) (length (workload-provider-functions provider)))
              (> (+ frame frames) (length (workload-provider-saved-values provider))))
      (error 'workload-capability-error :operation 'workload-mapc
             :reason :vm-frame-capacity-exhausted))
    (when (> (+ (workload-provider-native-cell-count provider) cells)
             (length (workload-provider-native-cells provider)))
      (error 'workload-capability-error :operation 'workload-mapc
             :reason :native-cell-capacity-exhausted))
    (let* ((top (maclina.vm-cross::vm-stack-top vm))
           (end (+ top entry-slots)))
      (when (> end (length (maclina.vm-cross::vm-stack vm)))
        (error 'workload-capability-error :operation 'workload-mapc
               :reason :vm-stack-capacity-exhausted))
      (multiple-value-bind (current controls)
          (%provider-root-demand
           provider :extra-function function
           :entry-local-start (and template (+ top list-count)) :entry-end end)
        (when (> controls (length (workload-root-walk-queue
                                  (workload-provider-control-walk provider))))
          (error 'workload-capability-error :operation 'workload-mapc
                 :reason :control-root-capacity-exhausted))
        (let ((demand (+ current cells entry-slots)))
          (when (or (> demand (workload-provider-capacity provider))
                    (> demand (length (workload-provider-locations provider))))
            (error 'workload-capability-error :operation 'workload-mapc
                   :reason :root-provider-capacity-exhausted))
          ;; Live frame/cell extents are the reservation. A nested census
          ;; counts them; no separate counter can double-spend that storage.
          demand)))))

(defun %workload-mapc (environment designator lists)
  "MAPC over managed lists, using bounded, registered native control cells.
Known ML controls use their existing root sources. As elsewhere in this
adapter, arbitrary foreign native callable captures remain an open boundary."
  (%require-open environment 'mapc)
  (unless lists (error 'program-error))
  (let* ((client (workload-maclina-client environment))
         (runtime (workload-maclina-environment environment))
         (function (if (symbolp designator)
                       (clostrum:fdefinition client runtime designator) designator))
         (provider (workload-root-provider environment))
         (count (length lists)))
    (unless (functionp function)
      (error 'type-error :datum function :expected-type 'function))
    ;; No callback, allocation or moving value transfer occurs on the empty
    ;; path. In particular there is no need to claim an unused native extent.
    (when (some #'null lists) (return-from %workload-mapc (first lists)))
    (%provider-mapc-admission provider function count)
    (let* ((frame (workload-provider-frame-count provider))
           (start (workload-provider-native-cell-count provider))
           (end (+ start 1 (* 2 count)))
           (cells (workload-provider-native-cells provider))
           (functions (workload-provider-functions provider))
           (saved (workload-provider-saved-values provider))
           (return-cell (aref cells start))
           (arguments (aref cells (+ start 1 count))))
      (unwind-protect
           (progn
             ;; Initialize only this unowned extent. Its chain links then stay
             ;; unchanged until release; nested extents have distinct cells.
             (loop for i from start below end do
               (setf (car (aref cells i)) nil
                     (cdr (aref cells i))
                     (if (< (1+ i) end) (aref cells (1+ i)) nil)))
             (setf (car return-cell) (first lists))
             (loop for list in lists for i from (1+ start) do
               (setf (car (aref cells i)) list))
             (setf lists nil
                   (aref functions frame) function
                   (aref saved frame) return-cell
                   (workload-provider-native-cell-count provider) end
                   (workload-provider-frame-count provider) (1+ frame))
             (loop
               ;; Stop before reading any CAR when any list has ended.
               (dotimes (i count)
                 (when (null (car (aref cells (+ start 1 i))))
                   (return-from %workload-mapc (car return-cell))))
               (%provider-mapc-admission provider function count :active-scope-p t)
               (dotimes (i count)
                 (setf (car (aref cells (+ start 1 count i)))
                       (%guest-car environment (car (aref cells (+ start 1 i))))))
               ;; This is the registered argument suffix, not a detached copy.
               (apply function arguments)
               (dotimes (i count)
                 (let ((cursor-cell (aref cells (+ start 1 i))))
                   (setf (car cursor-cell) (%guest-cdr environment (car cursor-cell))
                         (car (aref cells (+ start 1 count i))) nil)))))
        ;; No managed allocation occurs between reloading the return value and
        ;; its caller receiving it. Never restore/clear VM-VALUES on an NLX.
        (loop for i from start below end do
          (setf (car (aref cells i)) nil (cdr (aref cells i)) nil))
        (setf (aref functions frame) nil (aref saved frame) nil
              (workload-provider-native-cell-count provider) start
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
