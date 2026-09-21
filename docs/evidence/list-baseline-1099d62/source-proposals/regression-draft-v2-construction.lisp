;;;; SOURCE-ONLY V2 DRAFT. Not executed or read by a Lisp in this review.
;;;; V1 fault injection is preserved separately. Preferred N+2 layout is a
;;;; proposal, not approved implementation. No LIST performance claim.
;;;; Load only after parent review. No load-time run, dependency patch or fixture edit.
(defpackage #:clamsara.list-next.draft.v2
  (:use #:cl)
  (:export #:*owners* #:run-behavior #:run-capacity #:run-host-payload-rejection
           #:*general-rest-diagnostics*))
(in-package #:clamsara.list-next.draft.v2)

(defstruct owner name runtime provider construction-spec construction-vectors
  (phase :created) condition expected-condition before at-signal evidence
  (allocations 0) (stores 0) (rooted-p nil) owner-graph)
(defvar *owners* nil) ; Retain every owner, including partial construction failure.
(defvar *constructing-owner* nil)
(defvar *effect-owner* nil)
(defvar *native-owned-input* nil)
(defun env (o) (clamsara::workload-runtime-environment (owner-runtime o)))
(defun provider (o) (clamsara::workload-runtime-root-provider (owner-runtime o)))
(defun vm (o) (clamsara::workload-provider-vm (provider o)))
(defun plan (o) (clamsara::workload-runtime-plan (owner-runtime o)))
(defun client (o) (clamsara::workload-maclina-client (env o)))
(defun menv (o) (clamsara::workload-maclina-environment (env o)))
(defun cell-function (o name) (clostrum:fdefinition (client o) (menv o) name))
(defun (setf cell-function) (f o name)
  (setf (clostrum:fdefinition (client o) (menv o) name) f))

(defun with-unique-method (generic qualifiers classes definition thunk)
  ;; Same ownership discipline as the accepted MAPC test seam. The NEW package
  ;; and flags isolate this fixture; assert absence rather than overwrite even
  ;; if another test has installed the same method specializers.
  (assert (null (find-method generic qualifiers (mapcar #'find-class classes) nil)))
  (let ((method (eval definition)))
    ;; Removing only this test method does not erase guest/runtime owners.
    (unwind-protect (funcall thunk) (remove-method generic method))))

(defun with-fixture-methods (thunk)
  (labels ((install (specs)
             (if (null specs) (funcall thunk)
                 (destructuring-bind (name qualifiers classes definition) (car specs)
                   (with-unique-method (fdefinition name) qualifiers classes definition
                     (lambda () (install (cdr specs))))))))
    (install
     '((initialize-instance (:after) (clamsara::workload-root-provider)
        (defmethod initialize-instance :after
            ((p clamsara::workload-root-provider) &key &allow-other-keys)
          (when *constructing-owner*
            (let* ((o *constructing-owner*) (spec (owner-construction-spec o))
                   (tokens (clamsara::workload-provider-locations p))
                   (capacity (clamsara::workload-provider-capacity p)))
              (setf (owner-provider o) p) ; keep partial provider on setup failure
              (assert (= capacity (length tokens)))
              (assert (zerop (clamsara::workload-provider-frame-count p)))
              (assert (zerop (clamsara::workload-provider-native-cell-count p)))
              ;; Before MAKE-WORKLOAD-ROOT-PROVIDER fills tokens and before
              ;; REGISTER-ROOT-PROVIDER: real arrays, never live vector resizing.
              ;; GETF returns 0 truthfully, so a zero-cell fixture is supported.
              (when (getf spec :cells)
                (setf (slot-value p 'clamsara::native-cells)
                      (clamsara::%make-workload-native-cells (getf spec :cells))))
              (when (getf spec :functions)
                (setf (slot-value p 'clamsara::functions)
                      (make-array (getf spec :functions) :initial-element nil)))
              (when (getf spec :saved)
                (setf (slot-value p 'clamsara::saved-values)
                      (make-array (getf spec :saved) :initial-element nil)))
              (assert (eq tokens (clamsara::workload-provider-locations p)))
              (assert (= capacity (clamsara::workload-provider-capacity p)))
              (setf (owner-construction-vectors o)
                    (list tokens (clamsara::workload-provider-native-cells p)
                          (clamsara::workload-provider-functions p)
                          (clamsara::workload-provider-saved-values p)))))))
       (clamsara:allocate-object (:before)
        (clamsara::sequential-execution-context t t t t)
        (defmethod clamsara:allocate-object :before
            ((context clamsara::sequential-execution-context) kind bytes alignment descriptor)
          (declare (ignore kind bytes alignment descriptor))
          (when (and *effect-owner*
                     (eq context (clamsara:workload-context (env *effect-owner*))))
            (incf (owner-allocations *effect-owner*)))))
       (clamsara:barrier-store (:before)
        (clamsara::composed-barrier clamsara::sequential-execution-context t t)
        (defmethod clamsara:barrier-store :before
            ((barrier clamsara::composed-barrier)
             (context clamsara::sequential-execution-context) location new)
          (declare (ignore barrier location new))
          (when (and *effect-owner*
                     (eq context (clamsara:workload-context (env *effect-owner*))))
            (incf (owner-stores *effect-owner*)))))))))

(defun check-construction (o)
  (let ((p (provider o)) (spec (owner-construction-spec o)))
    (assert (eq p (owner-provider o)))
    (assert (every #'eq (owner-construction-vectors o)
                   (list (clamsara::workload-provider-locations p)
                         (clamsara::workload-provider-native-cells p)
                         (clamsara::workload-provider-functions p)
                         (clamsara::workload-provider-saved-values p))))
    (assert (= 1024 (length (clamsara::workload-provider-locations p))))
    (dolist (row (list (list :cells (clamsara::workload-provider-native-cells p))
                      (list :functions (clamsara::workload-provider-functions p))
                      (list :saved (clamsara::workload-provider-saved-values p))))
      (when (getf spec (first row))
        (assert (= (getf spec (first row)) (length (second row))))))))

(defun with-owner (name action &optional construction-spec)
  (with-fixture-methods
    (lambda ()
      (let ((o (make-owner :name name :construction-spec construction-spec)))
        (push o *owners*)
        (handler-case
            (progn
              ;; Publish the actual runtime owner before any probe actions.
              ;; The constructor seam retains a partial provider even if setup
              ;; cannot fit. Setup failure is failed/unreached, never a pass.
              (let ((*constructing-owner* o))
                (setf (owner-runtime o)
                      (clamsara:make-workload-runtime :extent 16384
                         :max-object-bytes 8192 :root-capacity 1024)))
              (check-construction o)
              (setf (owner-phase o) :ready)
              (funcall action o)
              o)
          (error (c)
            (setf (owner-condition o) c (owner-phase o) :failed-retained)
            (format t "~&LIST-NEXT-FAILED ~S ~S~%" name c)
            ;; No NIL evaluation, root erasure, restoration or close on failure.
            (error c)))))))

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

(defun native-owner-graph ()
  (let ((a (cons 101 nil)) (b (cons 202 nil))) (list a b a)))
(defun owned-input ()
  ;; Native oracle only. Managed definition reads a registered physical root.
  (assert *native-owned-input*) *native-owned-input*)
(defun root-load (o index) (clamsara:workload-temporary-root-load (env o) index))
(defun owner-input-graph (o) (graph (list (root-load o 15)) (env o)))
(defun check-owner-graph (o)
  (assert (owner-rooted-p o))
  (assert (equal (owner-owner-graph o) (owner-input-graph o))))
(defun seed-owner-graph (o)
  (assert (null (root-load o 14)))
  (assert (null (root-load o 15)))
  (let ((value
          (clamsara:workload-eval (env o)
            '(let ((a (cons 101 nil)) (b (cons 202 nil)))
               (cons a (cons b (cons a nil)))))))
    (clamsara::%store-temporary-root (env o) 15 value))
  (setf (owner-rooted-p o) t
        (owner-owner-graph o) (owner-input-graph o))
  (assert (equal (graph (list (native-owner-graph))) (owner-owner-graph o)))
  (clamsara:workload-eval (env o) nil) ; consume result only after explicit root handoff
  (setf (cell-function o 'owned-input) (lambda () (root-load o 15))))
(defun finish-capacity-success (o original-list)
  ;; Called only after positive proof or proved refusal + nonempty recovery.
  (check-owner-graph o)
  (check-construction o)
  (setf (cell-function o 'cl:list) original-list)
  (clostrum:fmakunbound (client o) (menv o) 'owned-input)
  ;; Release only this case's application slots, not arbitrary provider roots.
  (clamsara:workload-temporary-root-clear (env o) 14)
  (clamsara:workload-temporary-root-clear (env o) 15)
  (setf (owner-rooted-p o) nil)
  (release-success o))

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
      :construction (list (clamsara::workload-provider-locations p)
                          (clamsara::workload-provider-native-cells p)
                          (clamsara::workload-provider-functions p)
                          (clamsara::workload-provider-saved-values p))
      :tokens (coerce (clamsara::workload-provider-locations p) 'list)
      :allocations (owner-allocations o) :stores (owner-stores o)
      :owner-graph (when (owner-rooted-p o) (owner-input-graph o))
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
              '(:frames :native-count :registers :plan-state :heap
                :allocations :stores :owner-graph))
       (same-identities (getf a :construction) (getf b :construction))
       (same-identities (getf a :tokens) (getf b :tokens))
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
            (let ((*effect-owner* o))
              (setf (owner-before o) (physical-state o)
                    (owner-at-signal o) nil)
              (handler-bind
                  ((clamsara:workload-capability-error
                     (lambda (c)
                       (declare (ignore c))
                       ;; Observe original sources before any NLX cleanup.
                       (setf (owner-at-signal o) (physical-state o)))))
                (apply original args)))))
    original))

(defun invoke-owned (o target)
  (let ((maclina.machine:*client* (client o))
        (maclina.vm-cross::*vm* (vm o))
        (clamsara:*workload-environment* (env o)))
    (funcall target)))

(defun census-clean-p (o)
  (let ((walk (clamsara::workload-provider-census-walk (provider o))))
    (and (zerop (clamsara::workload-root-walk-count walk))
         (zerop (hash-table-count (clamsara::workload-root-walk-seen walk)))
         (every #'null (clamsara::workload-root-walk-queue walk)))))

(defun smaller-nonempty-recovery (o)
  ;; The same construction stays physically bounded. Native direct entry drops
  ;; the rejected guest caller's frame demand; N=1 drops the larger arena row.
  ;; This is deliberately NONEMPTY. It is not a fake counter or empty fast path.
  (setf (owner-phase o) :smaller-nonempty-recovery)
  (check-owner-graph o)
  (check-construction o)
  (let ((allocations (owner-allocations o))
        (expected
          (let ((s (native-owner-graph))) (graph (list (list s) s)))))
    ;; The primitive return is transferred immediately into case-owned root14.
    ;; Host control wrappers do not keep a detached copy across guest allocation.
    (clamsara::%store-temporary-root
      (env o) 14
      (let ((maclina.machine:*client* (client o))
            (maclina.vm-cross::*vm* (vm o))
            (clamsara:*workload-environment* (env o)))
        (funcall (cell-function o 'cl:list) (root-load o 15))))
    (assert (> (owner-allocations o) allocations))
    (assert (equal expected (graph (list (root-load o 14) (root-load o 15)) (env o))))
    (assert (zerop (clamsara::workload-provider-frame-count (provider o))))
    (assert (zerop (clamsara::workload-provider-native-cell-count (provider o))))
    (setf (owner-phase o) :recovery-movement)
    (let ((r (full-cycle o)))
      (assert (>= (clamsara:cycle-result-count r :objects-moved) 6)))
    ;; Both result and its input are reloaded from corrected physical sources.
    (assert (equal expected (graph (list (root-load o 14) (root-load o 15)) (env o))))
    (check-owner-graph o)
    (check-construction o)))

(defun run-capacity (n resource boundary &key nested)
  "SOURCE DRAFT for proposed N+2 LIST only; not an approved implementation.
RESOURCE :ARENA/:FUNCTIONS/:SAVED; BOUNDARY :EXACT/:ONE-SHORT.
N=0 requires :ARENA :EXACT without NESTED. Negative arena cases require N>=2
so a smaller N=1 nonempty recovery can really fit the unchanged construction."
  (assert (member boundary '(:exact :one-short)))
  (assert (or (plusp n) (and (not nested) (eq resource :arena) (eq boundary :exact))))
  (when (and (eq resource :arena) (eq boundary :one-short)) (assert (>= n 2)))
  (let* ((required (ecase resource
                     (:arena (if (zerop n) 0 (+ (if nested 3 0) n 2)))
                     ((:functions :saved) (if nested 4 2))))
         (bound (- required (if (eq boundary :one-short) 1 0)))
         (spec (list (ecase resource
                       (:arena :cells) (:functions :functions) (:saved :saved)) bound)))
    (with-owner (list :capacity-n+2 n resource boundary nested)
      (lambda (o)
        (seed-owner-graph o)
        (let* ((form (if nested
                         `(mapc (lambda (x) (list ,@(make-list n :initial-element 'x)))
                                (cons (owned-input) nil))
                         (if (zerop n) '(list)
                             `(let ((a (owned-input)))
                                (list ,@(make-list n :initial-element 'a))))))
               (expected
                 (let ((*native-owned-input* (native-owner-graph)))
                   (graph (append (multiple-value-list (eval form))
                                  (list *native-owned-input*)))))
               ;; Compile in the already bounded construction. Setup failure is
               ;; unreached/failed, never permission to resize a live vector.
               (target (clamsara:workload-eval (env o) `(lambda () ,form)))
               (original (install-boundary-observer o)))
          (check-owner-graph o)
          (setf (owner-phase o) :invoke)
          (if (eq boundary :exact)
              (progn
                (invoke-owned o target)
                (assert (owner-before o))
                (assert (null (owner-at-signal o)))
                (assert (equal expected
                               (graph (append (maclina.vm-cross::vm-values (vm o))
                                              (list (root-load o 15))) (env o))))
                (assert (zerop (clamsara::workload-provider-frame-count (provider o))))
                (assert (zerop (clamsara::workload-provider-native-cell-count (provider o))))
                (full-cycle o)
                (assert (equal expected
                               (graph (append (maclina.vm-cross::vm-values (vm o))
                                              (list (root-load o 15))) (env o))))
                (finish-capacity-success o original))
              (let ((condition
                      (handler-case (progn (invoke-owned o target) nil)
                        (clamsara:workload-capability-error (c) c))))
                (assert condition)
                (setf (owner-expected-condition o) condition)
                (assert (eq (clamsara::workload-error-reason condition)
                            (if (eq resource :arena) :native-cell-capacity-exhausted
                                :vm-frame-capacity-exhausted)))
                (assert (and (owner-before o) (owner-at-signal o)))
                ;; Actual allocation/store call observations, physical source
                ;; identities/contents, real heap maps/cursors, and owner graph.
                (assert (same-physical-state (owner-before o) (owner-at-signal o)))
                ;; Observe cleanup as well: no attempted allocate/store call may
                ;; appear after the signal and before the caller regains control.
                (assert (= (getf (owner-before o) :allocations) (owner-allocations o)))
                (assert (= (getf (owner-before o) :stores) (owner-stores o)))
                (push (list :proved-rejection (owner-before o) (owner-at-signal o))
                      (owner-evidence o))
                (assert (census-clean-p o))
                (assert (zerop (clamsara::workload-provider-frame-count (provider o))))
                (assert (zerop (clamsara::workload-provider-native-cell-count (provider o))))
                (assert (retained-p o))
                (check-owner-graph o)
                (check-construction o)
                (setf (owner-phase o) :rejection-proved)
                ;; An expected condition is NOT yet a successful test.
                ;; No capacity restoration, root erasure, or empty-only retry.
                (smaller-nonempty-recovery o)
                (finish-capacity-success o original)))))
      spec)))

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
;;; (run-behavior :moving), (run-behavior :mapc-nested), and all CASE-FORM keys.
;;; After separate review of the proposed N+2 implementation:
;;; (run-capacity 0 :arena :exact)
;;; (run-capacity 17 :arena :exact)
;;; (run-capacity 17 :arena :one-short)
;;; Repeat N=17 with :nested t, separately with :functions and :saved.
;;; Expected refusals pass ONLY after nonempty recovery, real movement,
;;; owner-graph checks, case-owned release, zero-discovery collection and close.
;;; Unexpected failures retain owners; only fixture-owned additive methods
;;; are removed when unwinding. No general REST gate or LIST performance claim.
