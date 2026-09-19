;;;; compile.lisp -- compile-to-functions and boot (paper-v8 ch. compilation).
;;;;
;;;; The compiler turns the MOP-composed collector into plain functions at
;;;; boot. Method functions, around-method continuations, and plan wrappers
;;;; are all resolved while CLOS is available; collection invokes only the
;;;; resulting function objects. The simulator uses SBCL's fast effective
;;;; method calls for the same boot-resolved inner VM/space/allocator
;;;; protocols. A target backend still needs its own low-level emitter or
;;;; foreign method compiler.

(in-package #:clamsara)

;;;; Inner protocol assembler ------------------------------------------------
;;;
;;; The phase assembler below is only useful if the component protocols it
;;; calls have the same property.  A generic function call is not a
;;; compilation boundary: it can construct an effective method and a
;;; next-method continuation on the first collection. The boot assembler
;;; therefore captures the complete standard method combination for each
;;; concrete VM/space/allocator instance. SBCL exposes that combination as a
;;; fast-method-call graph; compiling an invocation of that graph preserves
;;; before/after/around and CALL-NEXT-METHOD semantics without making a MOP
;;; argument list at collection time.

(defstruct (vm-collection-ops (:constructor %make-vm-collection-ops))
  address-cons page-physical ref-u64 set-ref-u64 memory-fence stratum
  scan-roots safepoint stop-mutators resume-mutators
  object-header set-object-header object-total-words object-reference-count
  object-type-tag object-reference set-object-reference object-start-p
  object-has-children object-copy object-marked set-object-marked
  object-logged set-object-logged object-public set-object-public
  object-age set-object-age object-rc set-object-rc object-forwarded
  object-forwarding-pointer set-object-forwarding-pointer object-young
  object-old)

#+sbcl
(defun %effective-method-fast-call (generic-function methods)
  "Return SBCL's direct fast-call graph for an effective method.

GET-EFFECTIVE-METHOD-FUNCTION is the public MOP-shaped bridge and may return
either a METHOD-CALL or an already assembled FAST-METHOD-CALL. The former's
funcallable wrapper retains the same fast function used by the latter; make a
constant FAST-METHOD-CALL around it so the compiler can emit direct calls.
This is a representation conversion only: CLOS has already selected and
combined the methods, and no class or method is named here."
  (let ((effective-method
          (sb-pcl::get-effective-method-function generic-function methods)))
    (cond
      ((sb-pcl::fast-method-call-p effective-method)
       effective-method)
      ((sb-pcl::method-call-p effective-method)
       (let ((fast-function
               (sb-pcl::%method-function-fast-function
                (sb-pcl::method-call-function effective-method))))
         (if (sb-pcl::fast-method-call-p fast-function)
             fast-function
             (sb-pcl::make-fast-method-call
              :function fast-function
              :pv nil
              :next-method-call nil))))
      (t
       (error "SBCL returned an unsupported effective method call ~S"
              effective-method)))))

#+sbcl
(defun %compile-effective-emitter (gf sample lambda-list call-args)
  "Compile an ordinary fixed-arity function for GF's boot-time EMF.

SAMPLE is used only while CLOS is available to select the applicable methods.
CALL-ARGS is a form list containing the real function arguments and any
boot-captured constants. SBCL's effective-method compiler expands the
standard method combination (including before/after/around and
CALL-NEXT-METHOD) into a direct fast-method-call graph; no MOP argument-list
convention is entered by the resulting function."
  (let* ((generic-function (fdefinition gf))
         (methods (compute-applicable-methods generic-function sample))
         (fast-call (%effective-method-fast-call generic-function methods)))
    (compile nil
             `(lambda ,lambda-list
                (sb-pcl::invoke-fast-method-call
                 ,fast-call nil ,@call-args)))))

#-sbcl
(defun %compile-effective-emitter (gf sample lambda-list call-args)
  (declare (ignore gf sample lambda-list call-args))
  nil)

(defun %quoted-boot-object (object)
  (list 'quote object))

#+sbcl
(defun %build-vm-collection-ops (vm plan)
  (%make-vm-collection-ops
   :address-cons
   (%compile-effective-emitter 'vm-address-cons-p (list vm 0) '(address)
                               (list (%quoted-boot-object vm) 'address))
   :page-physical
   (%compile-effective-emitter 'vm-page-physical (list vm 0) '(page)
                               (list (%quoted-boot-object vm) 'page))
   :ref-u64
   (%compile-effective-emitter 'ref-u64 (list vm 0) '(address)
                               (list (%quoted-boot-object vm) 'address))
   :set-ref-u64
   (%compile-effective-emitter '(setf ref-u64) (list nil vm 0)
                               '(new-value address)
                               (list 'new-value (%quoted-boot-object vm)
                                     'address))
   :memory-fence
   (%compile-effective-emitter 'memory-fence (list vm) '()
                               (list (%quoted-boot-object vm)))
   :stratum
   (%compile-effective-emitter 'vm-stratum (list vm nil) '(name)
                               (list (%quoted-boot-object vm) 'name))
   :scan-roots
   (%compile-effective-emitter 'vm-scan-roots (list vm plan #'identity)
                               '(collector-state fn)
                               (list (%quoted-boot-object vm)
                                     'collector-state 'fn))
   :safepoint
   (%compile-effective-emitter 'vm-safepoint (list vm :reason nil) '(reason)
                               (list (%quoted-boot-object vm) :reason 'reason))
   :stop-mutators
   (%compile-effective-emitter 'vm-stop-mutators (list vm) '()
                               (list (%quoted-boot-object vm)))
   :resume-mutators
   (%compile-effective-emitter 'vm-resume-mutators (list vm) '()
                               (list (%quoted-boot-object vm)))
   :object-header
   (%compile-effective-emitter 'vm-object-header (list vm 0) '(address)
                               (list (%quoted-boot-object vm) 'address))
   :set-object-header
   (%compile-effective-emitter '(setf vm-object-header) (list nil vm 0)
                               '(new-value address)
                               (list 'new-value (%quoted-boot-object vm)
                                     'address))
   :object-total-words
   (%compile-effective-emitter 'vm-object-total-words (list vm 0) '(address)
                               (list (%quoted-boot-object vm) 'address))
   :object-reference-count
   (%compile-effective-emitter 'vm-object-reference-count (list vm 0)
                               '(address)
                               (list (%quoted-boot-object vm) 'address))
   :object-type-tag
   (%compile-effective-emitter 'vm-object-type-tag (list vm 0) '(address)
                               (list (%quoted-boot-object vm) 'address))
   :object-reference
   (%compile-effective-emitter 'vm-object-reference (list vm 0 0)
                               '(address slot)
                               (list (%quoted-boot-object vm) 'address 'slot))
   :set-object-reference
   (%compile-effective-emitter '(setf vm-object-reference) (list nil vm 0 0)
                               '(new-value address slot)
                               (list 'new-value (%quoted-boot-object vm)
                                     'address 'slot))
   :object-start-p
   (%compile-effective-emitter 'vm-object-start-p (list vm 0) '(address)
                               (list (%quoted-boot-object vm) 'address))
   :object-has-children
   (%compile-effective-emitter 'vm-object-has-children-p (list vm 0)
                               '(address)
                               (list (%quoted-boot-object vm) 'address))
   :object-copy
   (%compile-effective-emitter 'vm-object-copy (list vm 0 0) '(source destination)
                               (list (%quoted-boot-object vm) 'source 'destination))
   :object-marked
   (%compile-effective-emitter 'vm-object-is-marked-p (list vm 0) '(address)
                               (list (%quoted-boot-object vm) 'address))
   :set-object-marked
   (%compile-effective-emitter '(setf vm-object-is-marked-p) (list nil vm 0)
                               '(new-value address)
                               (list 'new-value (%quoted-boot-object vm)
                                     'address))
   :object-logged
   (%compile-effective-emitter 'vm-object-is-logged-p (list vm 0) '(address)
                               (list (%quoted-boot-object vm) 'address))
   :set-object-logged
   (%compile-effective-emitter '(setf vm-object-is-logged-p) (list nil vm 0)
                               '(new-value address)
                               (list 'new-value (%quoted-boot-object vm)
                                     'address))
   :object-public
   (%compile-effective-emitter 'vm-object-is-public-p (list vm 0) '(address)
                               (list (%quoted-boot-object vm) 'address))
   :set-object-public
   (%compile-effective-emitter '(setf vm-object-is-public-p) (list nil vm 0)
                               '(new-value address)
                               (list 'new-value (%quoted-boot-object vm)
                                     'address))
   :object-age
   (%compile-effective-emitter 'vm-object-age (list vm 0) '(address)
                               (list (%quoted-boot-object vm) 'address))
   :set-object-age
   (%compile-effective-emitter '(setf vm-object-age) (list nil vm 0)
                               '(new-value address)
                               (list 'new-value (%quoted-boot-object vm)
                                     'address))
   :object-rc
   (%compile-effective-emitter 'vm-object-rc (list vm 0) '(address)
                               (list (%quoted-boot-object vm) 'address))
   :set-object-rc
   (%compile-effective-emitter '(setf vm-object-rc) (list nil vm 0)
                               '(new-value address)
                               (list 'new-value (%quoted-boot-object vm)
                                     'address))
   :object-forwarded
   (%compile-effective-emitter 'vm-object-is-forwarded-p (list vm 0)
                               '(address)
                               (list (%quoted-boot-object vm) 'address))
   :object-forwarding-pointer
   (%compile-effective-emitter 'vm-object-forwarding-pointer (list vm 0)
                               '(address)
                               (list (%quoted-boot-object vm) 'address))
   :set-object-forwarding-pointer
   (%compile-effective-emitter '(setf vm-object-forwarding-pointer)
                               (list nil vm 0) '(new-value address)
                               (list 'new-value (%quoted-boot-object vm)
                                     'address))
   :object-young
   (%compile-effective-emitter 'vm-object-young-p (list vm 0) '(reference)
                               (list (%quoted-boot-object vm) 'reference))
   :object-old
   (%compile-effective-emitter 'vm-object-old-p (list vm 0) '(reference)
                               (list (%quoted-boot-object vm) 'reference))))

#+sbcl
(defun %install-space-collection-ops (space)
  (let* ((allocator (space-allocator space))
         (space-constant (%quoted-boot-object space))
         (vm 'vm)
         (ref 'ref)
         (tracer 'tracer)
         (trace-kind 'trace-kind)
         (cycle-kind 'cycle-kind))
    (setf (slot-value space 'collection-trace)
          (%compile-effective-emitter
           'space-trace-object (list space nil 0 nil nil)
           '(vm ref tracer trace-kind)
           (list space-constant vm ref tracer trace-kind))
          (slot-value space 'collection-prepare)
          (%compile-effective-emitter
           'space-prepare (list space nil nil) '(vm cycle-kind)
           (list space-constant vm cycle-kind))
          (slot-value space 'collection-reclaim)
          (%compile-effective-emitter
           'space-reclaim (list space nil nil) '(vm cycle-kind)
           (list space-constant vm cycle-kind))
          (slot-value space 'collection-release)
          (%compile-effective-emitter
           'space-release (list space nil nil) '(vm cycle-kind)
           (list space-constant vm cycle-kind))
          (slot-value space 'collection-contains)
          (%compile-effective-emitter
           'space-contains-p (list space 0) '(address)
           (list space-constant 'address))
          (slot-value space 'collection-occupancy)
          (%compile-effective-emitter
           'space-occupancy (list space) '()
           (list space-constant))
          (slot-value space 'collection-alloc)
          (and allocator
               (%compile-effective-emitter
                'alloc (list allocator 0) '(size)
                (list (%quoted-boot-object allocator) 'size)))
          (slot-value space 'collection-free)
          (and allocator
               (%compile-effective-emitter
                'free (list allocator 0 0) '(address size)
                (list (%quoted-boot-object allocator) 'address 'size)))
          (slot-value space 'collection-reset)
          (and allocator
               (%compile-effective-emitter
                'allocator-reset (list allocator) '()
                (list (%quoted-boot-object allocator)))))
    space))

#-sbcl
(defun %build-vm-collection-ops (vm plan) (declare (ignore vm plan)) nil)
#-sbcl
(defun %install-space-collection-ops (space) space)

(defun resolve-collection-protocols (plan)
  "Assemble all inner CLOS protocols for PLAN during boot.
The operation table is installed only after every method function and fixed
argument list has been captured, so a partially assembled table cannot be
observed by a collector."
  (let* ((vm (plan-vm plan))
         (ops (%build-vm-collection-ops vm plan)))
    (setf (slot-value vm 'collection-ops) ops)
    (dolist (space (plan-spaces plan))
      (%install-space-collection-ops space))
    (let ((space (default-space plan)))
      (setf (plan-allocation-failure-function plan)
            (and space
                 (%compile-effective-emitter
                  'plan-handle-allocation-failure
                  (list plan 1 space) '(size space)
                  (list (%quoted-boot-object plan) 'size 'space)))))
    plan))

(defun plan-direct-handle-allocation-failure (plan size space)
  "Invoke the construction-bound allocation-failure method combination."
  (let ((function (slot-value plan 'allocation-failure-function)))
    (if function
        (funcall function size space)
        (plan-handle-allocation-failure plan size space))))

;; Fixed-operation entry points used by collection code.  Before boot they
;; retain the interpreted CLOS path, which keeps the normal phase machine a
;; useful diagnostic; after boot every branch below calls a captured method
;; function and never the generic dispatcher.
(defun %vm-ops (vm) (slot-value vm 'collection-ops))
(defun vm-direct-address-cons-p (vm address)
  (let ((ops (%vm-ops vm)))
    (if ops (funcall (vm-collection-ops-address-cons ops) address)
        (vm-address-cons-p vm address))))
(defun vm-direct-page-physical (vm page)
  (let ((ops (%vm-ops vm)))
    (if ops (funcall (vm-collection-ops-page-physical ops) page)
        (vm-page-physical vm page))))
(defun vm-direct-ref-u64 (vm address)
  (let ((ops (%vm-ops vm)))
    (if ops (funcall (vm-collection-ops-ref-u64 ops) address)
        (ref-u64 vm address))))
(defun vm-direct-set-ref-u64 (vm address value)
  (let ((ops (%vm-ops vm)))
    (if ops (funcall (vm-collection-ops-set-ref-u64 ops) value address)
        (setf (ref-u64 vm address) value))))
(defun vm-direct-memory-fence (vm)
  (let ((ops (%vm-ops vm)))
    (if ops (funcall (vm-collection-ops-memory-fence ops))
        (memory-fence vm))))
(defun vm-direct-stratum (vm name)
  (let ((ops (%vm-ops vm)))
    (if ops (funcall (vm-collection-ops-stratum ops) name)
        (vm-stratum vm name))))
(defun vm-direct-scan-roots (vm state fn)
  (let ((ops (%vm-ops vm)))
    (if ops (funcall (vm-collection-ops-scan-roots ops) state fn)
        (vm-scan-roots vm state fn))))
(defun vm-direct-safepoint (vm reason)
  (let ((ops (%vm-ops vm)))
    (if ops (funcall (vm-collection-ops-safepoint ops) reason)
        (vm-safepoint vm :reason reason))))
(defun vm-direct-stop-mutators (vm)
  (let ((ops (%vm-ops vm)))
    (if ops (funcall (vm-collection-ops-stop-mutators ops))
        (vm-stop-mutators vm))))
(defun vm-direct-resume-mutators (vm)
  (let ((ops (%vm-ops vm)))
    (if ops (funcall (vm-collection-ops-resume-mutators ops))
        (vm-resume-mutators vm))))

(defun vm-direct-object-header (vm address)
  (let ((ops (%vm-ops vm)))
    (if ops (funcall (vm-collection-ops-object-header ops) address)
        (vm-object-header vm address))))
(defun vm-direct-set-object-header (vm address value)
  (let ((ops (%vm-ops vm)))
    (if ops (funcall (vm-collection-ops-set-object-header ops) value address)
        (setf (vm-object-header vm address) value))))
(defun vm-direct-object-total-words (vm address)
  (let ((ops (%vm-ops vm)))
    (if ops (funcall (vm-collection-ops-object-total-words ops) address)
        (vm-object-total-words vm address))))
(defun vm-direct-object-reference-count (vm address)
  (let ((ops (%vm-ops vm)))
    (if ops (funcall (vm-collection-ops-object-reference-count ops) address)
        (vm-object-reference-count vm address))))
(defun vm-direct-object-type-tag (vm address)
  (let ((ops (%vm-ops vm)))
    (if ops (funcall (vm-collection-ops-object-type-tag ops) address)
        (vm-object-type-tag vm address))))
(defun vm-direct-object-reference (vm address slot)
  (let ((ops (%vm-ops vm)))
    (if ops (funcall (vm-collection-ops-object-reference ops) address slot)
        (vm-object-reference vm address slot))))
(defun vm-direct-set-object-reference (vm address slot value)
  (let ((ops (%vm-ops vm)))
    (if ops (funcall (vm-collection-ops-set-object-reference ops)
                     value address slot)
        (setf (vm-object-reference vm address slot) value))))
(defun vm-direct-object-start-p (vm address)
  (let ((ops (%vm-ops vm)))
    (if ops (funcall (vm-collection-ops-object-start-p ops) address)
        (vm-object-start-p vm address))))
(defun vm-direct-object-has-children-p (vm address)
  (let ((ops (%vm-ops vm)))
    (if ops (funcall (vm-collection-ops-object-has-children ops) address)
        (vm-object-has-children-p vm address))))
(defun vm-direct-object-copy (vm source destination)
  (let ((ops (%vm-ops vm)))
    (if ops (funcall (vm-collection-ops-object-copy ops) source destination)
        (vm-object-copy vm source destination))))
(defun vm-direct-object-marked-p (vm address)
  (let ((ops (%vm-ops vm)))
    (if ops (funcall (vm-collection-ops-object-marked ops) address)
        (vm-object-is-marked-p vm address))))
(defun vm-direct-set-object-marked-p (vm address value)
  (let ((ops (%vm-ops vm)))
    (if ops (funcall (vm-collection-ops-set-object-marked ops) value address)
        (setf (vm-object-is-marked-p vm address) value))))
(defun vm-direct-object-logged-p (vm address)
  (let ((ops (%vm-ops vm)))
    (if ops (funcall (vm-collection-ops-object-logged ops) address)
        (vm-object-is-logged-p vm address))))
(defun vm-direct-set-object-logged-p (vm address value)
  (let ((ops (%vm-ops vm)))
    (if ops (funcall (vm-collection-ops-set-object-logged ops) value address)
        (setf (vm-object-is-logged-p vm address) value))))
(defun vm-direct-object-public-p (vm address)
  (let ((ops (%vm-ops vm)))
    (if ops (funcall (vm-collection-ops-object-public ops) address)
        (vm-object-is-public-p vm address))))
(defun vm-direct-set-object-public-p (vm address value)
  (let ((ops (%vm-ops vm)))
    (if ops (funcall (vm-collection-ops-set-object-public ops) value address)
        (setf (vm-object-is-public-p vm address) value))))
(defun vm-direct-object-age (vm address)
  (let ((ops (%vm-ops vm)))
    (if ops (funcall (vm-collection-ops-object-age ops) address)
        (vm-object-age vm address))))
(defun vm-direct-set-object-age (vm address value)
  (let ((ops (%vm-ops vm)))
    (if ops (funcall (vm-collection-ops-set-object-age ops) value address)
        (setf (vm-object-age vm address) value))))
(defun vm-direct-object-rc (vm address)
  (let ((ops (%vm-ops vm)))
    (if ops (funcall (vm-collection-ops-object-rc ops) address)
        (vm-object-rc vm address))))
(defun vm-direct-set-object-rc (vm address value)
  (let ((ops (%vm-ops vm)))
    (if ops (funcall (vm-collection-ops-set-object-rc ops) value address)
        (setf (vm-object-rc vm address) value))))
(defun vm-direct-object-forwarded-p (vm address)
  (let ((ops (%vm-ops vm)))
    (if ops (funcall (vm-collection-ops-object-forwarded ops) address)
        (vm-object-is-forwarded-p vm address))))
(defun vm-direct-object-forwarding-pointer (vm address)
  (let ((ops (%vm-ops vm)))
    (if ops (funcall (vm-collection-ops-object-forwarding-pointer ops) address)
        (vm-object-forwarding-pointer vm address))))
(defun vm-direct-set-object-forwarding-pointer (vm address value)
  (let ((ops (%vm-ops vm)))
    (if ops (funcall (vm-collection-ops-set-object-forwarding-pointer ops)
                     value address)
        (setf (vm-object-forwarding-pointer vm address) value))))
(defun vm-direct-object-young-p (vm reference)
  (let ((ops (%vm-ops vm)))
    (if ops (funcall (vm-collection-ops-object-young ops) reference)
        (vm-object-young-p vm reference))))
(defun vm-direct-object-old-p (vm reference)
  (let ((ops (%vm-ops vm)))
    (if ops (funcall (vm-collection-ops-object-old ops) reference)
        (vm-object-old-p vm reference))))

(defun space-direct-trace-object (space vm ref tracer trace-kind)
  (let ((fn (slot-value space 'collection-trace)))
    (if fn (funcall fn vm ref tracer trace-kind)
        (space-trace-object space vm ref tracer trace-kind))))
(defun space-direct-prepare (space vm cycle-kind)
  (let ((fn (slot-value space 'collection-prepare)))
    (if fn (funcall fn vm cycle-kind)
        (space-prepare space vm cycle-kind))))
(defun space-direct-reclaim (space vm cycle-kind)
  (let ((fn (slot-value space 'collection-reclaim)))
    (if fn (funcall fn vm cycle-kind)
        (space-reclaim space vm cycle-kind))))
(defun space-direct-release (space vm cycle-kind)
  (let ((fn (slot-value space 'collection-release)))
    (if fn (funcall fn vm cycle-kind)
        (space-release space vm cycle-kind))))
(defun space-direct-contains-p (space address)
  (let ((fn (slot-value space 'collection-contains)))
    (if fn (funcall fn address) (space-contains-p space address))))
(defun space-direct-occupancy (space)
  "Call the construction-bound occupancy sample without collection-time CLOS
method lookup.  The generic fallback exists only for an unbooted test space."
  (let ((fn (slot-value space 'collection-occupancy)))
    (if fn (funcall fn) (space-occupancy space))))
(defun space-direct-alloc (space size)
  (let ((fn (slot-value space 'collection-alloc)))
    (if fn (funcall fn size)
        (alloc (space-allocator space) size))))
(defun space-direct-free (space address size)
  (let ((fn (slot-value space 'collection-free)))
    (if fn (funcall fn address size)
        (free (space-allocator space) address size))))
(defun space-direct-reset (space)
  (let ((fn (slot-value space 'collection-reset)))
    (if fn (funcall fn)
        (allocator-reset (space-allocator space)))))

(defgeneric compile-to-functions (component)
  (:method-combination append)
  (:method append ((c t)) (list))
  (:documentation "Return an alist of (name . lambda-form) for the component."))

(defgeneric boot-gc (plan)
  (:method ((p plan))
    (finalize-plan p)
    ;; CLOS is still available here.  Resolve the VM, space, and allocator
    ;; protocols before assembling the phase machine; all subsequent warm-up
    ;; collections exercise the same direct inner calls used by the mutator.
    (resolve-collection-protocols p)
    (let ((table (plan-function-table p)))
      (loop for (name . form) in (compile-to-functions p)
            do (setf (gethash name table) (compile nil form))))
    ;; SBCL (and other CLOS implementations) may lazily construct effective
    ;; method functions on first dispatch.  That is boot work, not collection
    ;; work. Exercise every cycle shape over a tiny live graph before the
    ;; mutator can allocate, then collect that graph and retain only the
    ;; resolved code/cache state.
    (let ((cycle-kinds (boot-cycle-kinds p)))
      (when cycle-kinds
        (let ((parent (allocate-object p 1))
              (child (allocate-object p 0)))
          (vm-set-reference (plan-vm p) parent 0 child)
          (vm-add-root (plan-vm p) parent)
          (dolist (cycle-kind cycle-kinds)
            (plan-collect p :cycle-kind cycle-kind))
          (vm-clear-roots (plan-vm p))
          (plan-collect p :cycle-kind
                        (if (member :major cycle-kinds) :major
                            (car (last cycle-kinds))))
          ;; End boot on a live traversal, so every object-model and trace
          ;; dispatch needed by the first mutator-triggered collection is hot.
          ;; BOOT-RESET-STATE discards these simulated objects without running
          ;; another empty collection that would leave a misleading cache state.
          (let ((parent (allocate-object p 1))
                (child (allocate-object p 0)))
            (vm-set-reference (plan-vm p) parent 0 child)
            (vm-add-root (plan-vm p) parent)
            (dolist (cycle-kind cycle-kinds)
              (plan-collect p :cycle-kind cycle-kind))
            (vm-clear-roots (plan-vm p))))))
    (boot-reset-state p)
    (boot-warm-runtime-dispatch p)
    ;; The final dispatch warm-up can itself write through an armed simulator
    ;; MMU after BOOT-RESET-STATE.  Do not expose those boot writes as the
    ;; first mutator/checkpoint dirty set.
    (let ((vm (plan-vm p)))
      (when (and (typep vm 'virtual-memory-mixin) (mmu-dirty vm))
        (fill (mmu-dirty vm) 0)))
    p))

(defgeneric boot-cycle-kinds (plan)
  (:documentation "Cycle shapes to resolve while the simulator is booting.")
  (:method ((p plan)) (declare (ignore p)) '(:full)))

(defgeneric boot-reset-state (plan)
  (:documentation "Remove observable bookkeeping produced by boot warm-up.")
  (:method ((p plan))
    (let ((vm (plan-vm p)))
      (s-clear (vm-object-start vm))
      (maphash (lambda (name stratum)
                 (declare (ignore name))
                 (s-clear stratum))
               (vm-strata-table vm))
      (fwd-clear vm)
      (rc-clear vm)
      ;; Space storage and counters reset through the declarative plan;
      ;; no collector is special-cased here.
      (dolist (space (plan-spaces p))
        (reset-space-state space)
        (boot-reset-allocator-state (space-allocator space)))
      (when (plan-barrier p)
        (setf (fill-pointer (barrier-satb-buffer (plan-barrier p))) 0
              (fill-pointer (barrier-rc-buffer (plan-barrier p))) 0))
      ;; A boot-time map may have armed the simulator MMU.  Its dirty bits are
      ;; execution metadata, not part of the post-boot heap image.
      (when (and (typep vm 'virtual-memory-mixin) (mmu-dirty vm))
        (fill (mmu-dirty vm) 0))
      (when (plan-publication p)
        (setf (fill-pointer (publication-work (plan-publication p))) 0)))
    ;; Retain the boot-sized dense counter vector and clear every warmed event.
    (when (plan-stats p)
      (stats-reset (plan-stats p)))
    p))

(defun boot-warm-runtime-dispatch (plan)
  "Resolve dispatch that SBCL can evict while BOOT-RESET-STATE clears the heap.
This is boot work for accessors that remain ordinary simulator calls, such as
metadata and barrier helpers. The inner VM/space/allocator protocol itself is
already emitted as fast effective-method calls by RESOLVE-COLLECTION-PROTOCOLS."
  ;; Resolve the fixed-slot reader used by direct allocation retry while host
  ;; dispatch work is still legal.
  (slot-value plan 'allocation-failure-function)
  (let* ((vm (plan-vm plan))
         (space (default-space plan))
         (address (and space (space-base-address space))))
    (when (and address (< (1+ address) (vm-heap-size vm)))
      (vm-object-reference vm address 0)))
  ;; Barrier accessors are on the mutator fast path.  Resolve them before
  ;; returning from boot so the first RC/publication store cannot construct a
  ;; CLOS effective method or allocate host storage.
  (let ((barrier (plan-barrier plan)))
    (when barrier
      (barrier-plan barrier)
      (barrier-rules barrier)
      (barrier-rc-buffer barrier)
      (barrier-satb-buffer barrier)
      (dolist (rule (barrier-rules barrier))
        (barrier-rule-name rule)
        (barrier-rule-metadatum rule)
        (barrier-rule-trigger rule)
        (barrier-rule-transfer rule))))
  ;; Every stratum registered on the VM resolves its slot accessors on the
  ;; collection path (s-get/s-set read stratum-cells, stratum-log-gran,
  ;; stratum-storage, ...).  Warm them all so no effective method is
  ;; constructed inside a measured collection.
  (let ((vm (plan-vm plan)))
    (maphash (lambda (name stratum)
               (declare (ignore name))
               (%warm-stratum stratum))
             (vm-strata-table vm)))
  ;; Publication's RC write barrier tests this side-stratum accessor.  Warm it
  ;; after the stratum cell dispatch above so its s-test-bit path is cached too.
  (let* ((vm (plan-vm plan))
         (space (default-space plan))
         (address (and space (space-base-address space))))
    (when (and address (< (1+ address) (vm-heap-size vm)))
      (vm-object-is-public-p vm address)))
  ;; Hierarchy accessors used on the collection path must resolve at boot:
  ;; superblock-space slot accessors, the escape stratum, the hierarchical
  ;; allocator's vector operations, and the full release/search path.  The
  ;; warm-up goes through T-typed helper parameters so SBCL cannot inline the
  ;; accessors as static slot reads: the real CLOS dispatch cache is what the
  ;; collection path uses, and that is what must be hot.
  (dolist (space (plan-spaces plan))
    ;; Exercise the actual direct entry points, not only the old generic warm
    ;; calls above.  In particular, SPACE-PREPARE reaches the stratum storage
    ;; readers that a first post-boot collection would otherwise initialize.
    (space-direct-contains-p space (space-base-address space))
    (space-direct-prepare space (plan-vm plan) :full)
    (when (typep space 'superblock-space)
      (%warm-superblock space (plan-vm plan))))
  ;; Resolve the complete VM operation vector through its production entry
  ;; points as well.  This includes the unarmed T0 read/write branch; armed
  ;; software-MMU reads are selected explicitly by VM-DIRECT-REF-U64.
  (let* ((vm (plan-vm plan))
         (space (default-space plan))
         (address (and space (space-base-address space))))
    (when address
      (vm-direct-ref-u64 vm address)
      (vm-direct-set-ref-u64 vm address (vm-direct-ref-u64 vm address))
      (vm-direct-object-header vm address)
      (vm-direct-object-total-words vm address)
      (vm-direct-object-reference-count vm address)
      (vm-direct-object-type-tag vm address)
      (vm-direct-object-reference vm address 0)
      (vm-direct-object-start-p vm address)
      (vm-direct-object-marked-p vm address)
      (vm-direct-object-logged-p vm address)
      (vm-direct-object-public-p vm address)
      (vm-direct-object-age vm address)
      (vm-direct-object-rc vm address)
      (vm-direct-object-forwarded-p vm address)
      (vm-direct-object-forwarding-pointer vm address)
      (vm-direct-object-young-p vm address)
      (vm-direct-object-old-p vm address)))
  plan)

(defun %warm-stratum (stratum)
  "Resolve every stratum slot accessor through the generic dispatch path."
  (stratum-name stratum)
  (stratum-granularity stratum)
  (stratum-cell-type stratum)
  (stratum-default stratum)
  (stratum-storage stratum)
  (stratum-heap-words stratum)
  (stratum-log-gran stratum)
  (stratum-cells stratum)
  (stratum-active stratum)
  (stratum-concurrent-p stratum)
  (s-get stratum 0)
  (s-set stratum 0 (s-get stratum 0))
  stratum)

(defun %warm-superblock (space vm)
  "Resolve every superblock-space / hierarchical-allocator accessor through
  the generic dispatch path and exercise the whole release path once.
  NOTINLINE forces real CLOS dispatch so the dispatch cache (not a static
  slot read) is what gets warmed."
  (declare (notinline sb-escape sb-refcounts sb-pinned sb-mb-matrices
                      sb-block-matrices sb-mb-root-bits sb-reached-mbs
                      sb-block-words sb-blocks-per-metablock
                      sb-mbs-per-superblock sb-count sb-block-count sb-mb-count
                      space-allocator))
  (sb-escape space)
  (sb-refcounts space)
  (sb-pinned space)
  (sb-mb-matrices space)
  (sb-block-matrices space)
  (sb-mb-root-bits space)
  (sb-reached-mbs space)
  (sb-block-words space)
  (sb-blocks-per-metablock space)
  (sb-mbs-per-superblock space)
  (sb-count space)
  (sb-block-count space)
  (sb-mb-count space)
  (setf (sb-escape-value space vm 0) 0)
  (sb-index space 0)
  (sb-block-index space 0)
  (sb-mb-index space 0)
  (sb-local-block space 0)
  (sb-local-mb space 0)
  (sb-block-base space 0)
  ;; RC/publication barriers classify mature source addresses through these
  ;; side-stratum accessors; warm the mature base after stratum dispatch so a
  ;; first publication store remains allocation-free.
  (space-contains-p space (space-base-address space))
  (vm-object-is-public-p vm (space-base-address space))
  ;; The mutator write path finally stores through this object-reference
  ;; setter; resolve it for mature addresses during boot too.
  (setf (vm-object-reference vm (space-base-address space) 0) 0)
  (let ((a (space-allocator space)))
    (when (typep a 'hierarchical-allocator)
      (%warm-hierarchical-allocator a vm space)))
  space)

(defun %warm-hierarchical-allocator (a vm space)
  "Exercise the release path on a scratch block so every effective method
  inside it is resolved before mutators run."
  (declare (ignore space))
  (let ((scratch (hierarchical-acquire-block a)))
    (when scratch
      (setf (aref (hierarchical-allocator-cursors a) scratch)
            (hierarchical-block-base a scratch)
            (hierarchical-allocator-current a) scratch)
      (eql (hierarchical-allocator-current a) scratch)
      (hierarchical-free-block a vm scratch)))
  a)

(defun boot-reset-allocator-state (allocator)
  "Restore an allocator to empty using only storage allocated at boot."
  (typecase allocator
    (bump-allocator
     (setf (slot-value allocator 'cursor)
           (slot-value allocator 'start)))
    (free-list-allocator
     (let ((start (slot-value allocator 'start))
           (limit (slot-value allocator 'limit)))
       (setf (slot-value allocator 'run-count) 1
             (aref (slot-value allocator 'run-starts) 0) start
             (aref (slot-value allocator 'run-lengths) 0)
             (- limit start))))
    (immix-allocator
     (let ((blocks (slot-value allocator 'blocks)))
       (dotimes (index (length blocks))
         (let ((block (aref blocks index)))
           (setf (immix-block-cursor block) (immix-block-base block)
                 (immix-block-live block) 0))))
     (setf (slot-value allocator 'block-count) 0
           (slot-value allocator 'current) nil
           (slot-value allocator 'next-base)
           (slot-value allocator 'start))
     (when (slot-value allocator 'span-root)
       (fill (slot-value allocator 'span-root) -1))
     (when (slot-value allocator 'block-live)
       (fill (slot-value allocator 'block-live) 0)))
    (hierarchical-allocator
     (fill (hierarchical-allocator-cursors allocator) -1)
     (when (hierarchical-allocator-span-root allocator)
       (fill (hierarchical-allocator-span-root allocator) -1))
     (setf (fill-pointer (hierarchical-allocator-free-blocks allocator)) 0
           (hierarchical-allocator-next-fresh allocator) 0
           (hierarchical-allocator-current allocator) nil)))
  allocator)

#+sbcl
(defun selected-phase-method-function (plan cycle-kind phase)
  "Resolve the most-specific GC-PHASE method qualified PHASE for PLAN.
The returned function uses SBCL's (arguments next-methods) MOP calling
convention."
  (let ((method
          (find-if
           (lambda (candidate)
             (equal (sb-mop:method-qualifiers candidate) (list phase)))
           (compute-applicable-methods
            (fdefinition 'gc-phase) (list plan cycle-kind)))))
    (unless method
      (error "No ~a gc-phase method for ~S" phase (type-of plan)))
    (sb-mop:method-function method)))

#+sbcl
(defun %applicable-method-functions (gf plan cycle-kind qualifier)
  (mapcar #'sb-mop:method-function
          (remove-if-not
           (lambda (method)
             (equal (sb-mop:method-qualifiers method) (list qualifier)))
           (compute-applicable-methods gf (list plan cycle-kind)))))

#+sbcl
(defun %plan-collect-custom-around-method-functions (plan cycle-kind)
  "Return PLAN-COLLECT-PHASE around methods except the framework timing arm.

The framework arm is emitted as an ordinary boot-built continuation below.
That avoids entering a CLOS method function merely to update GC timing on the
target.  User-defined around methods remain in the explicit boot chain and
retain their normal call-next-method semantics."
  (let ((gf (fdefinition 'plan-collect-phase)))
    (mapcar #'sb-mop:method-function
            (remove-if
             (lambda (method)
               (let ((specializers (sb-mop:method-specializers method)))
                 (eq (first specializers) (find-class 'plan))))
             (remove-if-not
              (lambda (method)
                (equal (sb-mop:method-qualifiers method) '(:around)))
              (compute-applicable-methods gf (list plan cycle-kind)))))))

#+sbcl
(defun %compose-boot-method-functions (around-functions primary-function)
  "Compose an already-resolved around chain around PRIMARY-FUNCTION.

The continuation functions and their one-element next-method lists are
created here, while CLOS/host allocation is legal.  A collection call only
invokes those stable objects; it does not construct a continuation or a
generic-function argument list."
  (let ((next primary-function))
    (dolist (method-function (reverse around-functions) next)
      (let* ((next-function next)
             (next-methods (list next-function)))
        (setf next
              (lambda (arguments ignored-next-methods)
                (declare (ignore ignored-next-methods))
                (funcall method-function arguments next-methods)))))))

#+sbcl
(defun %compiled-gc-phase-entry (plan cycle-kind phase-order)
  "Build one static effective GC-PHASE invoker for CYCLE-KIND.

This is the method-combination boundary: the selected phase methods and all
applicable :around methods are resolved now.  It is intentionally separate
from the inner VM/space protocols, whose target-specific direct emitters are a
different compilation unit."
  (let* ((gf (fdefinition 'gc-phase))
         (around (%applicable-method-functions gf plan cycle-kind :around))
         (phase-functions
           (mapcar (lambda (phase)
                     (selected-phase-method-function plan cycle-kind phase))
                   phase-order))
         (primary
           (let ((functions phase-functions))
             (lambda (arguments ignored-next-methods)
               (declare (ignore ignored-next-methods))
               (dolist (method-function functions)
                 (funcall method-function arguments nil)))))
         (effective (%compose-boot-method-functions around primary))
         ;; This argument list is boot-owned and immutable after this point.
         ;; It is the equivalent of the method-combination call's arguments
         ;; without a collection-time (list plan cycle-kind).
         (arguments (list plan cycle-kind)))
    (lambda (ignored-plan ignored-cycle-kind)
      (declare (ignore ignored-plan ignored-cycle-kind))
      (funcall effective arguments nil))))

#+sbcl
(defun %compiled-plan-wrapper-entry (plan cycle-kind machine-entry)
  "Compose plan-collect-phase :around methods around MACHINE-ENTRY.

The default around method supplies GC timing.  Keeping it in this boot-built
chain means a custom plan wrapper has the same semantics in interpreted and
compiled execution without dispatching through PLAN-COLLECT-PHASE at runtime."
  (let* ((around (%plan-collect-custom-around-method-functions
                  plan cycle-kind))
         (arguments (list plan cycle-kind))
         (timed-machine
           ;; This is the source default PLAN-COLLECT-PHASE :AROUND method,
           ;; expressed as a plain continuation.  Its implementation is
           ;; stable and known, so retaining its behavior need not retain a
           ;; runtime CLOS call.
           (lambda (ignored-arguments ignored-next-methods)
             (declare (ignore ignored-arguments ignored-next-methods))
             (let ((started (get-internal-run-time)))
               (funcall machine-entry nil nil)
               (let ((statistics (slot-value plan 'stats)))
                 (when statistics
                   (stats-event statistics :gc-time
                              (- (get-internal-run-time) started)))))))
         (effective
           (%compose-boot-method-functions
            around
            timed-machine)))
    (lambda (ignored-plan ignored-cycle-kind)
      (declare (ignore ignored-plan ignored-cycle-kind))
      (funcall effective arguments nil))))

#+sbcl
(defun direct-phase-forms (plan cycle-kind
                           &optional (phase-order +gc-phase-order+))
  "Compatibility diagnostic: return boot-resolved direct phase forms.
The production emitter uses %COMPILED-GC-PHASE-ENTRY so :around methods are
preserved too."
  (let ((arguments (list plan cycle-kind)))
    (loop for phase in phase-order
          for method-function = (selected-phase-method-function plan cycle-kind phase)
          collect `(funcall ,method-function ',arguments nil))))

(defun compiled-plan-collect-form (plan)
  #+sbcl
  (let* ((minor-machine
           (%compiled-gc-phase-entry plan :minor +gc-collection-phase-order+))
         (major-machine
           (%compiled-gc-phase-entry plan :major +gc-collection-phase-order+))
         (full-machine
           (%compiled-gc-phase-entry plan :full +gc-collection-phase-order+))
         (minor (%compiled-plan-wrapper-entry plan :minor minor-machine))
         (major (%compiled-plan-wrapper-entry plan :major major-machine))
         (full (%compiled-plan-wrapper-entry plan :full full-machine))
        ;; persistence.tex §4: a checkpoint is a SNAPSHOT, not a collection.
        ;; The compiled arm runs only the checkpoint phase (plus the
        ;; stop/resume safepoint), never prologue/mark/reclaim/compact.
        (checkpoint-machine (%compiled-gc-phase-entry plan :checkpoint
                                                       '(:checkpoint)))
        (checkpoint (%compiled-plan-wrapper-entry
                     plan :checkpoint checkpoint-machine)))
    `(lambda (ignored-plan cycle-kind)
       (declare (ignore ignored-plan))
       (ecase cycle-kind
           (:minor
            (unwind-protect
                 (funcall ',minor nil nil)
              ;; The normal epilogue resumes the VM, but this idempotent
              ;; cleanup also covers a phase/backend error.
              (vm-direct-resume-mutators (plan-vm ',plan))
              (publication-reopen-after-abort
               (slot-value ',plan 'publication) (slot-value ',plan 'vm))))
           (:major
            (unwind-protect
                 (funcall ',major nil nil)
              (vm-direct-resume-mutators (plan-vm ',plan))
              (publication-reopen-after-abort
               (slot-value ',plan 'publication) (slot-value ',plan 'vm))))
           (:full
            (unwind-protect
                 (funcall ',full nil nil)
              (vm-direct-resume-mutators (plan-vm ',plan))
              (publication-reopen-after-abort
               (slot-value ',plan 'publication) (slot-value ',plan 'vm))))
           (:checkpoint
            (vm-direct-stop-mutators (plan-vm ',plan))
            (unwind-protect
                 (funcall ',checkpoint nil nil)
              (vm-direct-resume-mutators (plan-vm ',plan))
              (publication-reopen-after-abort
               (slot-value ',plan 'publication) (slot-value ',plan 'vm))))
         )))
  #-sbcl
  `(lambda (runtime-plan cycle-kind)
     (plan-collect-phase runtime-plan cycle-kind)))

(defmethod compile-to-functions append ((p plan))
  "Emit a plan-specific collector with phase selection resolved at boot."
  (list (cons 'plan-collect (compiled-plan-collect-form p))))

;; ---- construction -------------------------------------------------------

(defun make-plan (&rest args &key name vm spaces barrier publication constraints
                  &allow-other-keys)
  "Construct a generic plan instance and finalize it."
  (declare (ignore args))
  (let ((p (make-instance 'plan :name name :vm vm :spaces spaces
                           :barrier barrier :publication publication
                           :constraints (or constraints (make-instance 'plan-constraints)))))
    (finalize-plan p)
    p))

(defmacro defplan (name &body args)
  "Define a parameter holding a configured plan."
  `(defparameter ,name (make-plan ,@args)))

;; ---- axis resolution helpers (used by future per-fragment emitters) ------

(defun resolve-metadata-location (plan datum)
  "Where DATUM physically lives for this plan (Axis 2)."
  (vm-location (plan-vm plan) datum))

(defun resolve-barrier-sequence (plan)
  "The fused list of barrier rules (Axis 5), in application order."
  (when (plan-barrier plan) (barrier-rules (plan-barrier plan))))
