;;;; SOURCE-ONLY DRAFT. Never executed or read by a Lisp during this review.
;;;; Load only after parent review. No load-time run, dependency patch or fixture edit.
(defpackage #:clamsara.list-next.draft
  (:use #:cl)
  (:export #:*owners* #:run-behavior #:run-capacity #:run-host-payload-rejection
           #:*general-rest-diagnostics*))
(in-package #:clamsara.list-next.draft)

(defstruct owner name runtime (phase :created) condition before at-signal evidence)
(defvar *owners* nil) ; Retain all runtime handles, including failed/negative cases.
(defun env (o) (clamsara::workload-runtime-environment (owner-runtime o)))
(defun provider (o) (clamsara::workload-runtime-root-provider (owner-runtime o)))
(defun vm (o) (clamsara::workload-provider-vm (provider o)))
(defun plan (o) (clamsara::workload-runtime-plan (owner-runtime o)))
(defun client (o) (clamsara::workload-maclina-client (env o)))
(defun menv (o) (clamsara::workload-maclina-environment (env o)))
(defun cell-function (o name) (clostrum:fdefinition (client o) (menv o) name))
(defun (setf cell-function) (f o name)
  (setf (clostrum:fdefinition (client o) (menv o) name) f))

(defun with-owner (name action)
  (let ((o (make-owner :name name)))
    (push o *owners*)
    (handler-case
        (progn
          ;; Publish the actual runtime owner before any probe actions.
          (setf (owner-runtime o)
                (clamsara:make-workload-runtime :extent 16384
                   :max-object-bytes 8192 :root-capacity 1024)
                (owner-phase o) :ready)
          (funcall action o)
          o)
      (error (c)
        (setf (owner-condition o) c (owner-phase o) :failed-retained)
        (format t "~&LIST-NEXT-FAILED ~S ~S~%" name c)
        ;; No NIL evaluation, root erasure, restoration or close on failure.
        (error c)))))

(defun full-cycle (o)
  (let ((r (clamsara:make-cycle-result-record (plan o))))
    (clamsara:collect
      (clamsara::workload-runtime-configuration (owner-runtime o)) :all :explicit r)
    (assert (eq :complete (clamsara:cycle-result-status r)))
    r))

(defun release-success (o)
  ;; Reached only after every assertion for a positive case succeeded.
  (setf (owner-phase o) :consume-result)
  (clamsara:workload-eval (env o) nil)
  (assert (zerop (clamsara:cycle-result-count (full-cycle o) :objects-discovered)))
  (clamsara:close-workload-runtime (owner-runtime o))
  (assert (null (clamsara::workload-runtime-configuration (owner-runtime o))))
  (setf (owner-phase o) :complete))

(defun retained-p (o)
  (and (eq :published
           (clamsara::%configuration-state
             (clamsara::workload-runtime-configuration (owner-runtime o))))
       (clamsara::simulator-provider-token-active-p
         (clamsara::workload-runtime-root-token (owner-runtime o)))))

(defun graph (values &optional environment)
  "Ordered graph encoding across all values. Sharing must match, not just EQUAL."
  (let ((seen (make-hash-table :test (if environment #'eql #'eq))) (next 0))
    (labels ((walk (v)
               (let ((managed (and environment
                                   (clamsara:workload-reference-p environment v))))
                 (when (and environment (consp v))
                   (error "Host cons leaked as guest payload: ~S" v))
                 (cond
                   ((or managed (and (not environment) (consp v)))
                    (when managed
                      (assert (clamsara::%guest-cons-p environment v)))
                    (let ((key (if managed
                                   (clamsara:reference-address
                                     (clamsara:workload-model environment) v)
                                   v)))
                      (multiple-value-bind (id present) (gethash key seen)
                        (if present (list :ref id)
                            (let ((id (incf next)))
                              (setf (gethash key seen) id)
                              (list :node id
                                (walk (if managed
                                          (clamsara:workload-read-slot environment v :car)
                                          (car v)))
                                (walk (if managed
                                          (clamsara:workload-read-slot environment v :cdr)
                                          (cdr v)))))))))
                   ((or (symbolp v) (typep v 'fixnum) (characterp v)) v)
                   (t (error "Unexpected graph leaf ~S" v))))))
      (mapcar #'walk values))))

(defun prepare (a b)
  ;; Native oracle has no managed heap; same source order with a no-op hook.
  (declare (ignore a b)) nil)

(defun free-bytes (o)
  (let ((a (clamsara::%context-allocator (clamsara:workload-context (env o)))))
    (- (clamsara::%allocator-limit a) (clamsara::%allocator-cursor a))))

(defun install-movement-prepare (o)
  (setf (cell-function o 'prepare)
        (lambda (a b)
          ;; Read encodings only as numbers. Never keep detached guest references
          ;; across the following allocations. Caller VM locals own A and B.
          (let ((before
                  (loop for x in (list a b)
                        when (clamsara:workload-reference-p (env o) x)
                          collect (clamsara:reference-address
                                   (clamsara:workload-model (env o)) x))))
            (assert (>= (free-bytes o) 64))
            (assert (zerop (mod (free-bytes o) 32)))
            ;; Real allocations only. Neither a cursor nor a GC counter is set.
            ;; CONS is 32 bytes in this unchanged runtime geometry.
            (loop while (> (free-bytes o) 64)
                  do (clamsara::%cons* (env o) 0 nil))
            (assert (= 64 (free-bytes o)))
            (push (list :input-addresses before :free-bytes (free-bytes o))
                  (owner-evidence o)))
          nil)))

(defun case-form (kind)
  (ecase kind
    (:empty '(list))
    (:one '(list :one))
    (:many `(list ,@(loop for i below 31 collect i)))
    (:order '(let ((n 0))
               (list (incf n) (progn (incf n) (list (incf n) n))
                     (incf n) n)))
    (:identity '(let ((a (cons 101 nil)) (b (cons 202 nil)))
                  (let ((inner (list a b a)))
                    (values (list inner a inner (list) b) inner))))
    (:moving `(let ((a (cons 101 nil)) (b (cons 202 nil)))
                (prepare a b)
                (list ,@(loop for i below 31 collect (if (evenp i) 'a 'b)))))
    (:mapc-nested
     `(let ((a (cons 101 nil)) (b (cons 202 nil)) (out nil))
        (let ((rows (cons a (cons b nil))))
          (mapc (lambda (x)
                  (prepare x nil)
                  (setq out (list ,@(make-list 31 :initial-element 'x)))) rows)
          (values rows out))))))

(defun run-behavior (kind)
  "KIND: :EMPTY :ONE :MANY :ORDER :IDENTITY :MOVING :MAPC-NESTED. One owned case."
  (with-owner kind
    (lambda (o)
      (let* ((form (case-form kind))
             (expected (graph (multiple-value-list (eval form))))
             (moving (member kind '(:moving :mapc-nested))))
        (when moving (install-movement-prepare o))
        (setf (owner-phase o) :evaluate)
        (clamsara:workload-eval (env o) form)
        (assert (equal expected (graph (maclina.vm-cross::vm-values (vm o)) (env o))))
        (when moving
          (let ((r (clamsara::%plan-automatic-result (plan o))))
            (assert (eq :complete (clamsara:cycle-result-status r)))
            (assert (plusp (clamsara:cycle-result-count r :objects-moved)))
            (assert (plusp (clamsara:cycle-result-count r :bytes-moved)))
            (push (list :automatic-moved
                        (clamsara:cycle-result-count r :objects-moved))
                  (owner-evidence o)))
          ;; The latest PREPARE records the object used by the latest LIST.
          ;; Reacquire its new encoding from actual VM result roots.
          (let* ((roots (maclina.vm-cross::vm-values (vm o)))
                 (result-list (if (eq kind :moving) (first roots) (second roots)))
                 (arg (clamsara:workload-read-slot (env o) result-list :car))
                 (old (getf (find-if (lambda (x) (getf x :input-addresses))
                                    (owner-evidence o)) :input-addresses)))
            (assert (/= (first old)
                        (clamsara:reference-address
                          (clamsara:workload-model (env o)) arg)))))
        (setf (owner-phase o) :post-return-movement)
        ;; Result transfer must have reached the real VM source before this cycle.
        (full-cycle o)
        (assert (equal expected (graph (maclina.vm-cross::vm-values (vm o)) (env o))))
        (assert (zerop (clamsara::workload-provider-frame-count (provider o))))
        (assert (zerop (clamsara::workload-provider-native-cell-count (provider o))))
        (when moving (clostrum:fmakunbound (client o) (menv o) 'prepare))
        (release-success o)))))

;;; Pre-effect snapshots are taken at the LIST boundary, after argument
;;; evaluation. Comparing the whole caller before argument evaluation would
;;; wrongly forbid normal operand/value-register changes.
(defun physical-state (o)
  (let* ((p (provider o)) (v (vm o)))
    (list
      :frames (clamsara::workload-provider-frame-count p)
      :native-count (clamsara::workload-provider-native-cell-count p)
      :functions (coerce (clamsara::workload-provider-functions p) 'list)
      :saved (coerce (clamsara::workload-provider-saved-values p) 'list)
      :native (map 'list (lambda (c) (list (car c) (cdr c)))
                   (clamsara::workload-provider-native-cells p))
      :descriptors
      (map 'list (lambda (l)
                   (list (clamsara::workload-location-source-kind l)
                         (clamsara::workload-location-source l)
                         (clamsara::workload-location-source-index l)
                         (clamsara::workload-location-value l)))
           (clamsara::workload-provider-locations p))
      :registers (list (maclina.vm-cross::vm-stack-top v)
                       (maclina.vm-cross::vm-frame-pointer v)
                       (maclina.vm-cross::vm-pc v) (maclina.vm-cross::vm-args v)
                       (maclina.vm-cross::vm-arg-count v))
      :values (maclina.vm-cross::vm-values v)
      :stack (coerce (maclina.vm-cross::vm-stack v) 'list)
      :dynenv (maclina.vm-cross::vm-dynenv-stack v)
      :plan-state (clamsara::%plan-state (plan o))
      :heap
      (loop for s in (clamsara::%plan-spaces (plan o))
            when (typep s 'clamsara::semispace-space)
              collect
              (let ((a (clamsara::%space-allocator s))
                    (m (clamsara::%space-object-start-map s)))
                (list (clamsara::%semispace-role s)
                      (clamsara::%allocator-cursor a)
                      (clamsara::%allocator-limit a)
                      (multiple-value-bind (base limit stride) (clamsara:metadata-bounds m)
                        (loop for address from base below limit by stride
                              collect (clamsara:metadata-ref m address)))))))))

(defun same-identities (a b)
  (and (= (length a) (length b)) (every #'eql a b)))
(defun same-physical-state (a b)
  (and (every (lambda (k) (equal (getf a k) (getf b k)))
              '(:frames :native-count :registers :plan-state :heap))
       (eq (getf a :values) (getf b :values))
       (eq (getf a :dynenv) (getf b :dynenv))
       (same-identities (getf a :stack) (getf b :stack))
       (same-identities (getf a :functions) (getf b :functions))
       (same-identities (getf a :saved) (getf b :saved))
       (every #'same-identities (getf a :native) (getf b :native))
       (every #'same-identities (getf a :descriptors) (getf b :descriptors))))

(defun install-boundary-observer (o)
  (let ((original (cell-function o 'cl:list)))
    (setf (cell-function o 'cl:list)
          (lambda (&rest args)
            (declare (dynamic-extent args))
            (setf (owner-before o) (physical-state o))
            (handler-bind
                ((clamsara:workload-capability-error
                   (lambda (c)
                     (declare (ignore c))
                     ;; Observe before the primitive or caller unwinds.
                     (setf (owner-at-signal o) (physical-state o)))))
              (apply original args))))
    original))

(defun narrow-vector (o slot count)
  "White-box fixture: narrow actual physical storage at idle, never fake counts."
  (let ((p (provider o)))
    (assert (zerop (clamsara::workload-provider-frame-count p)))
    (assert (zerop (clamsara::workload-provider-native-cell-count p)))
    (let ((old (slot-value p slot)))
      (assert (<= 0 count (length old)))
      ;; New vector, same preallocated cons cells where applicable. No source
      ;; descriptor may refer to an active native extent here.
      (setf (slot-value p slot) (subseq old 0 count))
      old)))

(defun invoke-owned (o target)
  (let ((maclina.machine:*client* (client o))
        (maclina.vm-cross::*vm* (vm o))
        (clamsara:*workload-environment* (env o)))
    (funcall target)))

(defun run-capacity (n extra-cells resource boundary &key nested)
  "RESOURCE :ARENA/:FUNCTIONS/:SAVED. BOUNDARY :EXACT/:ONE-SHORT.
EXTRA-CELLS must be 1 or 2, chosen from separately reviewed implementation.
For N=0 use :ARENA :EXACT; zero arena storage must suffice.
Negative cases deliberately retain their published runtimes."
  (assert (member extra-cells '(1 2)))
  (assert (member boundary '(:exact :one-short)))
  (assert (or (plusp n) (and (not nested) (eq resource :arena) (eq boundary :exact))))
  (with-owner (list :capacity n extra-cells resource boundary nested)
    (lambda (o)
      (let* ((form (if nested
                       `(mapc (lambda (x) (list ,@(make-list n :initial-element 'x)))
                              (cons :row nil))
                       `(list ,@(loop for i below n collect i))))
             (expected (graph (multiple-value-list (eval form))))
             ;; Compile before limiting capacities; source compilation is not the
             ;; measured primitive. No guest payload literal is embedded here.
             (target (clamsara:workload-eval (env o) `(lambda () ,form)))
             (required (ecase resource
                         (:arena (if (zerop n) 0
                                     (+ (if nested 3 0) n extra-cells)))
                         ((:functions :saved) (if nested 4 2))))
             (bound (- required (if (eq boundary :one-short) 1 0)))
             (slot (ecase resource
                     (:arena 'clamsara::native-cells)
                     (:functions 'clamsara::functions)
                     (:saved 'clamsara::saved-values))))
        (let* ((backing (narrow-vector o slot bound))
               (original (install-boundary-observer o)))
          (setf (owner-phase o) :invoke)
          (if (eq boundary :exact)
              (progn
                (invoke-owned o target)
                (assert (owner-before o))
                (assert (null (owner-at-signal o)))
                (assert (equal expected
                               (graph (maclina.vm-cross::vm-values (vm o)) (env o))))
                (assert (zerop (clamsara::workload-provider-frame-count (provider o))))
                (assert (zerop (clamsara::workload-provider-native-cell-count (provider o))))
                ;; The measured call completed with the smaller actual vector.
                ;; Restore only after success; do not let unrelated EVAL setup
                ;; requirements become a false failure of the measured bound.
                (setf (cell-function o 'cl:list) original
                      (slot-value (provider o) slot) backing)
                (release-success o))
              (let ((condition
                      (handler-case (progn (invoke-owned o target) nil)
                        (clamsara:workload-capability-error (c) c))))
                (assert condition)
                (setf (owner-condition o) condition)
                (assert (eq (clamsara::workload-error-reason condition)
                            (if (eq resource :arena) :native-cell-capacity-exhausted
                                :vm-frame-capacity-exhausted)))
                (assert (and (owner-before o) (owner-at-signal o)))
                (assert (same-physical-state (owner-before o) (owner-at-signal o)))
                (assert (zerop (clamsara::workload-provider-frame-count (provider o))))
                (assert (zerop (clamsara::workload-provider-native-cell-count (provider o))))
                (assert (retained-p o))
                ;; Do NOT restore the probe definition/vector, erase roots,
                ;; evaluate NIL, collect, or close this expected failure.
                (setf (owner-phase o) :expected-rejection-retained))))))))

(defun run-host-payload-rejection ()
  "No whitelist widening: native-produced host cons must not become LIST payload."
  (with-owner :host-payload
    (lambda (o)
      (setf (cell-function o 'foreign-list) (lambda () (cons :host nil)))
      (let ((condition
              (handler-case
                  (progn (clamsara:workload-eval (env o) '(list (foreign-list))) nil)
                (error (c) c))))
        (assert condition)
        (setf (owner-condition o) condition)
        (assert (retained-p o))
        ;; Rejection class/phase still needs review: a late fatal barrier reject
        ;; is not equivalent to clean pre-entry admission.
        (setf (owner-phase o) :payload-rejected-retained)))))

;;; Separate diagnostic matrix. NOT included in LIST-only acceptance.
;;; Expected native results are obtained by EVAL, using GRAPH where lists escape.
;;; Do not label these passing merely because native LIST was repaired.
(defparameter *general-rest-diagnostics*
  '((funcall (lambda (&rest r) (car r)) 17 23)
    ((lambda (&rest r) r) 17 23)
    (flet ((f (&rest r) (cdr r))) (f 17 23))
    (labels ((f (&rest r) (if (null r) nil (car r)))) (f 17 23))
    (funcall (lambda (&optional (x 10 xp) &rest r) (values x xp r)) 17 23 29)
    (funcall (lambda (&rest r &key x &allow-other-keys) (values r x)) :x 17 :y 23)
    (funcall (funcall (lambda (&rest r) (lambda () (car r))) 17 23))
    (macrolet ((m (&rest r) `(list ,@r))) (m 17 23))))

;;; Suggested later invocations (not executed here):
;;; (run-behavior :moving), (run-behavior :mapc-nested), and all other CASE-FORM keys.
;;; After reviewing actual arena layout, for EACH extra-cells = implemented value:
;;; (run-capacity 0 extra-cells :arena :exact)
;;; (run-capacity 17 extra-cells :arena :exact)
;;; (run-capacity 17 extra-cells :arena :one-short)
;;; Repeat N=17 with :nested t and separately with :functions and :saved.
;;; Run negatives in separately owned processes; owners remain live by design.
