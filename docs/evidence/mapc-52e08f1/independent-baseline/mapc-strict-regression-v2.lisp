;;;; Canonical strict baseline source v2. No production implementation.
;;;; V1 is preserved. PHASE was inherited CL:PHASE; renamed helper and all calls.
;;;; The expected ERROR gate now checks identity of one native sentinel condition.
;;;; Preserve MAPC-PROBE.LISP as historical source; do not use its cleanup policy.
;;;; The caller owns runtime construction. Pass a fresh, already-owned runtime
;;;; (suggested: extent 16384, max-object-bytes 8192, root-capacity 512).
;;;; RUN-MAPC-STRICT-CASE adopts that owner before any test action. It never
;;;; clears roots, consumes values, or closes after an unexpected failure.
(defpackage #:clamsara.workload.mapc.strict-draft
  (:use #:cl #:clamsara)
  (:export #:run-mapc-strict-case #:*owners* #:*cases*))
(in-package #:clamsara.workload.mapc.strict-draft)

(defstruct owner name runtime (phase :adopted) (status :retained)
  condition pre-unwind-registers)
(defvar *owners* nil) ; Real runtime/provider handles, not detached guest roots.
(define-condition expected-mapc-stop (error) ())
(define-condition wrong-host-designator (error) ())
(defun designator-callback (x)
  (declare (ignore x))
  (error 'wrong-host-designator)) ; Must NOT resolve here in guest execution.

(defun env (owner)
  (clamsara::workload-runtime-environment (owner-runtime owner)))
(defun provider (owner)
  (clamsara::workload-runtime-root-provider (owner-runtime owner)))
(defun vm (owner) (clamsara::workload-provider-vm (provider owner)))
(defun client (owner) (clamsara::workload-maclina-client (env owner)))
(defun guest-environment (owner)
  (clamsara::workload-maclina-environment (env owner)))
(defun registers (owner)
  (let ((vm (vm owner)))
    (list (maclina.vm-cross::vm-stack-top vm)
          (maclina.vm-cross::vm-frame-pointer vm)
          (maclina.vm-cross::vm-pc vm)
          (maclina.vm-cross::vm-args vm)
          (maclina.vm-cross::vm-arg-count vm)
          (clamsara::workload-provider-frame-count (provider owner)))))
(defun note-probe-phase (owner phase) (setf (owner-phase owner) phase))
(defun full-cycle (owner)
  (let* ((rt (owner-runtime owner))
         (record (make-cycle-result-record (clamsara::workload-runtime-plan rt))))
    (collect (clamsara::workload-runtime-configuration rt) :all :explicit record)
    (assert (eq :complete (cycle-result-status record)))
    record))
(defun automatic-movement (owner)
  (let ((record (clamsara::%plan-automatic-result
                 (clamsara::workload-runtime-plan (owner-runtime owner)))))
    (assert (eq :complete (cycle-result-status record)))
    (assert (plusp (cycle-result-count record :objects-moved)))))
(defun no-active-scopes (owner)
  (assert (zerop (clamsara::workload-provider-frame-count (provider owner)))))
(defun finish-success (owner)
  ;; Called ONLY after every assertion and case-owned definition/property
  ;; release succeeds. A failure here also keeps the runtime handle.
  (note-probe-phase owner :consume-proven-result)
  (workload-eval (env owner) nil)
  (note-probe-phase owner :discharge)
  (assert (zerop (cycle-result-count (full-cycle owner) :objects-discovered)))
  (note-probe-phase owner :close)
  (close-workload-runtime (owner-runtime owner))
  (setf (owner-phase owner) :complete (owner-status owner) :complete)
  owner)

(defun cons-form (items)
  ;; Native test-source construction only; NOT a guest REST/list bridge.
  (if (null items) nil `(cons ,(first items) ,(cons-form (rest items)))))
(defun semantic-form (lists)
  (let ((names (loop repeat (length lists) collect (gensym "INPUT-")))
        (args (loop repeat (length lists) collect (gensym "ELEMENT-"))))
    `(let (,@(loop for name in names for items in lists
                  collect `(,name ,(cons-form items)))
           (trace 0))
       (values
        (eq ,(first names)
            (funcall #'mapc
              (lambda ,args
                ,@(loop for arg in args collect `(setq trace (+ (* trace 10) ,arg)))
                ;; Ordinary callback multiple values are ignored by MAPC.
                (values 71 73))
              ,@names))
        trace))))

(defun check-direct-empty (owner)
  (note-probe-phase owner :direct-empty-arity)
  (let ((callback (workload-eval
                    (env owner)
                    '(lambda (a b) (declare (ignore a b))
                       (error 'expected-mapc-stop)))))
    (assert (typep callback 'maclina.machine:function))
    ;; Function object and two NIL lists. No guest allocation is needed in
    ;; MAPC. Do not rely on a compiler macro or a FUNCTIONP-only native closure.
    (assert (null (funcall (clostrum:fdefinition
                            (client owner) (guest-environment owner) 'cl:mapc)
                          callback nil nil)))))
(defun check-semantics (owner)
  ;; No circular/dotted lists or callback mutation of any traversed list.
  (dolist (lists '(((1 2))
                   ((1 2 9) (3 4))
                   ((1 2) (3 4) (5 6 7))
                   (nil)
                   (nil (3 4)) ((1 2) nil)
                   (nil (3 4) (5 6))
                   ((1 2) nil (5 6))
                   ((1 2) (3 4) nil)))
    (note-probe-phase owner (list :semantic lists))
    (let* ((form (semantic-form lists))
           (native (multiple-value-list (eval form))))
      (assert (eq t (first native)))
      (assert (equal native (multiple-value-list (workload-eval (env owner) form)))))))

(defun check-single-result (owner)
  (note-probe-phase owner :single-mapc-result)
  (let* ((form '(funcall #'mapc (lambda (x) (values x 71 73))
                         (cons 1 (cons 2 nil))))
         (native (multiple-value-list (eval form))))
    (assert (= 1 (length native)))
    (assert (equal '(1 2) (first native)))
    (workload-eval (env owner) form)
    (let* ((values (maclina.vm-cross::vm-values (vm owner)))
           (first (first values)))
      (assert (= 1 (length values)))
      (assert (= 1 (workload-read-slot (env owner) first :car)))
      (let ((second (workload-read-slot (env owner) first :cdr)))
        (assert (= 2 (workload-read-slot (env owner) second :car)))
        (assert (null (workload-read-slot (env owner) second :cdr)))))))

(defparameter *moving-form*
  '(let ((total 0))
     (values
      (funcall #'mapc
        (lambda (x y)
          (dotimes (i 600) (cons nil nil))
          (incf total (+ (car x) (car y)))
          (values x y))
        (cons (cons 1 nil) (cons (cons 2 nil) (cons (cons 3 nil) nil)))
        (cons (cons 10 nil) (cons (cons 20 nil) nil)))
      total)))
(defparameter *nested-form*
  '(let ((total 0))
     (values
      (funcall #'mapc
        (lambda (x y)
          (funcall #'mapc
            (lambda (p q)
              (dotimes (i 600) (cons nil nil))
              (incf total (+ (car x) (car y) (car p) (car q))))
            (cons (cons 3 nil) nil)
            (cons (cons 30 nil) nil)))
        (cons (cons 1 nil) (cons (cons 2 nil) (cons (cons 3 nil) nil)))
        (cons (cons 10 nil) (cons (cons 20 nil) nil)))
      total)))
(defparameter *closure-form*
  '(let ((total 0))
     (values
      (funcall #'mapc
        ;; This LET ends before MAPC starts. Only the actual callback closure
        ;; owns CAPTURE; no global/temporary/outer lexical alias retains it.
        (let ((capture (cons 7 nil)))
          (lambda (x)
            (dotimes (i 600) (cons nil nil))
            (incf total (+ (car x) (car capture)))))
        (cons (cons 1 nil) (cons (cons 2 nil) (cons (cons 3 nil) nil))))
      total)))

(defun check-returned-graph (owner expected-elements expected-total count)
  ;; Only the actual VM result remains an owner. Collect first; reacquire the
  ;; corrected value from the physical VM register. No saved host-ref oracle.
  (let ((record (full-cycle owner)))
    (assert (= count (cycle-result-count record :objects-discovered)))
    (assert (= count (cycle-result-count record :objects-moved))))
  (let* ((values (maclina.vm-cross::vm-values (vm owner)))
         (cursor (first values))
         (seen (make-hash-table :test #'eq)))
    (assert (= 2 (length values)))
    (assert (= expected-total (second values)))
    (dolist (expected expected-elements)
      (assert (workload-reference-p (env owner) cursor))
      (assert (not (gethash cursor seen)))
      (setf (gethash cursor seen) t)
      (let ((leaf (workload-read-slot (env owner) cursor :car)))
        (assert (workload-reference-p (env owner) leaf))
        (assert (not (gethash leaf seen)))
        (setf (gethash leaf seen) t)
        (assert (= expected (workload-read-slot (env owner) leaf :car)))
        (assert (null (workload-read-slot (env owner) leaf :cdr))))
      (setf cursor (workload-read-slot (env owner) cursor :cdr)))
    (assert (null cursor))
    (assert (= count (hash-table-count seen)))))
(defun check-moving (owner form known-total)
  (note-probe-phase owner :native-moving-semantic-oracle)
  (let ((native (multiple-value-list (eval form))))
    (assert (equal '(1 2 3) (mapcar #'car (first native))))
    (assert (= known-total (second native))))
  (note-probe-phase owner :managed-callback-movement)
  (workload-eval (env owner) form) ; discard host snapshot, not the VM owner
  (automatic-movement owner)
  (no-active-scopes owner)
  (note-probe-phase owner :corrected-return-graph)
  (check-returned-graph owner '(1 2 3) known-total 6))

(defun check-designator (owner)
  (note-probe-phase owner :install-case-owned-guest-callback)
  (assert (not (clostrum:fboundp (client owner) (guest-environment owner)
                                 'designator-callback)))
  (workload-eval (env owner) '(defparameter designator-total 0))
  (workload-eval (env owner)
                '(defun designator-callback (x)
                   (dotimes (i 600) (cons nil nil))
                   (incf designator-total (car x))))
  (note-probe-phase owner :symbol-designator)
  (assert (= 3 (workload-eval
                (env owner)
                '(progn
                   (funcall #'mapc 'designator-callback
                     (cons (cons 1 nil) (cons (cons 2 nil) nil)))
                   designator-total))))
  (automatic-movement owner)
  ;; Remove only definitions this successful case installed. A wrong lookup,
  ;; collection failure, or assertion above leaves them intact for inspection.
  (note-probe-phase owner :release-case-owned-definition)
  (clostrum:fmakunbound (client owner) (guest-environment owner) 'designator-callback)
  (workload-eval (env owner) '(makunbound 'designator-total)))

(defparameter *error-form*
  '(funcall #'mapc
     (lambda (x y)
       (dotimes (i 600) (cons nil nil))
       (unless (= 17 (car x)) (error 'wrong-host-designator))
       (unless (= 23 (car y)) (error 'wrong-host-designator))
       (signal-expected-mapc-stop))
     (cons (cons 17 nil) nil) (cons (cons 23 nil) nil)))
(defparameter *throw-form*
  '(catch 'mapc-done
     (funcall #'mapc
       (lambda (x y)
         (dotimes (i 600) (cons nil nil))
         (throw 'mapc-done (values x y)))
       (cons (cons 17 nil) nil) (cons (cons 23 nil) nil))))
(defun check-retry (owner before)
  (note-probe-phase owner :normal-call-after-nlx)
  (let ((form (semantic-form '((1 2 9) (3 4)))))
    (assert (equal (multiple-value-list (eval form))
                   (multiple-value-list (workload-eval (env owner) form)))))
  (assert (equal before (registers owner)))
  (no-active-scopes owner))
(defun check-error (owner)
  (let ((before (registers owner))
        (sentinel (make-condition 'expected-mapc-stop)))
    (note-probe-phase owner :native-error-identity)
    (assert (handler-case (error sentinel)
              (expected-mapc-stop (condition) (eq condition sentinel))))
    ;; Test-only native emitter: retains no managed argument/capture, does not
    ;; allocate guest storage, and signals precisely this condition object.
    (assert (not (clostrum:fboundp (client owner) (guest-environment owner)
                                   'signal-expected-mapc-stop)))
    (setf (clostrum:fdefinition (client owner) (guest-environment owner)
                               'signal-expected-mapc-stop)
          (lambda () (error sentinel)))
    (note-probe-phase owner :expected-callback-error)
    ;; A wrong-arity PROGRAM-ERROR is not the expected condition and must fail.
    (assert (handler-case (progn (workload-eval (env owner) *error-form*) nil)
              (expected-mapc-stop (condition) (eq condition sentinel))))
    (automatic-movement owner)
    (assert (equal before (registers owner)))
    (no-active-scopes owner)
    (check-retry owner before)
    ;; The emitter is released only after the expected history and retry pass.
    (clostrum:fmakunbound (client owner) (guest-environment owner)
                          'signal-expected-mapc-stop)))
(defun check-throw (owner)
  (let ((before (registers owner)))
    (note-probe-phase owner :native-throw-oracle)
    (assert (equal '(17 23) (mapcar #'car (multiple-value-list (eval *throw-form*)))))
    (note-probe-phase owner :throw-multiple-values)
    (workload-eval (env owner) *throw-form*)
    (automatic-movement owner)
    (assert (equal before (registers owner)))
    (no-active-scopes owner)
    (let ((record (full-cycle owner)))
      (assert (= 2 (cycle-result-count record :objects-discovered)))
      (assert (= 2 (cycle-result-count record :objects-moved))))
    (let ((values (maclina.vm-cross::vm-values (vm owner))))
      (assert (= 2 (length values)))
      (assert (not (eq (first values) (second values))))
      (loop for value in values for expected in '(17 23) do
        (assert (= expected (workload-read-slot (env owner) value :car)))
        (assert (null (workload-read-slot (env owner) value :cdr)))))
    ;; The expected thrown values are now proven. The next application call
    ;; explicitly replaces that successful result; this is not error cleanup.
    (check-retry owner before)))

(defun check-dderiv-load (owner pathname)
  ;; Workload reader uses CLAMSARA, exactly as the canonical runner does.
  (let* ((package (find-package :clamsara))
         (indicator (intern "DDERIV" package))
         (ops (list '+ '- '* (intern "//" package)))
         (names (mapcar (lambda (name) (intern name package))
                        '("DDERIV-AUX" "+DDERIV" "-DDERIV" "*DDERIV"
                          "//DDERIV" "DDERIV" "DDERIV-RUN" "TESTDDERIV")))
         (handlers (subseq names 1 5))
         (properties (clamsara::workload-client-properties (client owner))))
    (note-probe-phase owner :fixture-ownership-precheck)
    (dolist (name names)
      (assert (not (clostrum:fboundp (client owner) (guest-environment owner) name))))
    (dolist (op ops)
      (assert (not (nth-value 1 (gethash (clamsara::%property-key op indicator)
                                        properties)))))
    (note-probe-phase owner :original-dderiv-load)
    (workload-load (env owner) pathname) ; ALL original forms, unchanged bytes
    (note-probe-phase owner :four-property-identities)
    (loop for op in ops for handler in handlers do
      (assert (eq t (workload-eval
                      (env owner)
                      `(eq (get ',op ',indicator) (symbol-function ',handler))))))
    ;; Collect with these exact owners still published, then verify identity
    ;; again. This is not an all-DDERIV computation or movement claim.
    (full-cycle owner)
    (loop for op in ops for handler in handlers do
      (assert (eq (clamsara::%property-value (client owner) op indicator)
                  (clostrum:fdefinition (client owner) (guest-environment owner)
                                       handler))))
    (note-probe-phase owner :release-successful-fixture-load-owners)
    ;; No REMPROP host fallback or CLRHash; remove the four own property entries.
    (dolist (op ops) (remhash (clamsara::%property-key op indicator) properties))
    (dolist (name names)
      (clostrum:fmakunbound (client owner) (guest-environment owner) name))))

(defparameter *cases*
  '(:direct-empty :semantics :moving :nested :closure :designator :error :throw
    :dderiv-load))
(defun run-mapc-strict-case (runtime case &key pathname)
  "Use a fresh caller-owned runtime. Stop after failure; inspect *OWNERS*.
No runtime is constructed here, and there is no unconditional cleanup."
  (let ((owner (make-owner :name case :runtime runtime)))
    (push owner *owners*)
    (handler-bind
        ((error (lambda (condition)
                  ;; Observe without handling, unwinding, collecting, printing
                  ;; guest graphs, consuming results, or closing the runtime.
                  (setf (owner-condition owner) condition
                        (owner-pre-unwind-registers owner) (registers owner)
                        (owner-status owner) :failed-retained))))
      (ecase case
        (:direct-empty (check-direct-empty owner))
        (:semantics (check-semantics owner) (check-single-result owner))
        (:moving (check-moving owner *moving-form* 33))
        (:nested (check-moving owner *nested-form* 99))
        (:closure (check-moving owner *closure-form* 27))
        (:designator (check-designator owner))
        (:error (check-error owner))
        (:throw (check-throw owner))
        (:dderiv-load (assert pathname) (check-dderiv-load owner pathname)))
      (finish-success owner))))

;;;; CAPACITY GATE IS NOT IMPLEMENTED OR CLAIMED BY THIS DRAFT.
;;;; See strict-native-scope-design.md: a future test-only construction seam
;;;; must provision actual physical capacities, not falsify FRAME-COUNT and
;;;; not invoke %PROVIDER-REFRESH outside its protected snapshot boundary.
;;;; Required: exact-fit / one-short root tokens, activation slots, cursor-row
;;;; cell arena, control queue; shared closure dedup; nested outer ownership;
;;;; zero callbacks/guest allocations/stores and unchanged VM/provider state
;;;; on admission rejection; prove retained live graph then retry normal call.
;;;; Arbitrary host FUNCTIONP objects/captures are NOT admitted by these tests.
