;;;; compile.lisp -- compile-to-functions and boot (paper-v8 ch. compilation).
;;;;
;;;; The compiler turns the MOP-composed collector into plain functions at
;;;; boot. On SBCL the outer phase methods are resolved to method-functions;
;;;; component operations inside those methods still use the VM/space generic
;;;; protocols. Completely splicing those inner fragments remains a paper-v8
;;;; requirement.

(in-package #:clamsara)

(defgeneric compile-to-functions (component)
  (:method-combination append)
  (:method append ((c t)) (list))
  (:documentation "Return an alist of (name . lambda-form) for the component."))

(defgeneric boot-gc (plan)
  (:method ((p plan))
    (finalize-plan p)
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
      (dolist (space (plan-spaces p))
        (boot-reset-allocator-state (space-allocator space)))
      (when (plan-barrier p)
        (setf (fill-pointer (barrier-satb-buffer (plan-barrier p))) 0
              (fill-pointer (barrier-rc-buffer (plan-barrier p))) 0))
      (when (plan-publication p)
        (setf (fill-pointer (publication-work (plan-publication p))) 0)))
    ;; Keep the hash entries established by warm-up so the first real event
    ;; increment cannot grow the table on the collection path.
    (when (plan-stats p)
      (maphash (lambda (name value)
                 (declare (ignore value))
                 (setf (gethash name (stats-events (plan-stats p))) 0))
               (stats-events (plan-stats p))))
    p))

(defun boot-warm-runtime-dispatch (plan)
  "Resolve dispatch that SBCL can evict while BOOT-RESET-STATE clears the heap.
This is boot work, not a substitute for compiling the remaining inner VM
protocol. In particular, a fresh SBCL otherwise allocates an effective method
on the first live VM-OBJECT-REFERENCE after boot."
  (let* ((vm (plan-vm plan))
         (space (default-space plan))
         (address (and space (space-base-address space))))
    (when (and address (< (1+ address) (vm-heap-size vm)))
      (vm-object-reference vm address 0)))
  plan)

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
           (slot-value allocator 'start)))
    (hierarchical-allocator
     (setf (slot-value allocator 'cursor)
           (slot-value allocator 'start))))
  allocator)

#+sbcl
(defun selected-primary-method-function (generic-function arguments)
  "Resolve one phase method at boot. The returned function uses SBCL's
(arguments next-methods) MOP calling convention."
  (let ((method
          (find-if
           (lambda (candidate)
             (null (sb-mop:method-qualifiers candidate)))
           (compute-applicable-methods generic-function arguments))))
    (unless method
      (error "No primary method for ~S with ~S"
             generic-function arguments))
    (sb-mop:method-function method)))

#+sbcl
(defun direct-phase-forms (plan cycle-kind)
  "Resolve the ordered phase generics and prebuild their argument lists."
  (loop for name in '(phase-prologue phase-mark phase-reclaim phase-compact
                      phase-checkpoint phase-release phase-epilogue)
        for arguments = (list plan cycle-kind)
        for method-function =
          (selected-primary-method-function (fdefinition name) arguments)
        collect `(funcall ,method-function ',arguments nil)))

(defun compiled-plan-collect-form (plan)
  #+sbcl
  (let ((minor (direct-phase-forms plan :minor))
        (major (direct-phase-forms plan :major))
        (full (direct-phase-forms plan :full)))
    `(lambda (ignored-plan cycle-kind)
       (declare (ignore ignored-plan))
       (let ((started (get-internal-run-time)))
         (ecase cycle-kind
           (:minor ,@minor)
           (:major ,@major)
           (:full ,@full))
         (let ((statistics (slot-value ',plan 'stats)))
           (when statistics
             (incf (gethash :gc-time (slot-value statistics 'events) 0)
                   (- (get-internal-run-time) started)))))))
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

;; ---- space layout helpers (used by the plan constructors) ---------------

(defun partition-pages (total-pages fractions)
  "FRACTIONS is a list of ratios summing to <= 1.  Return (start . count) pairs,
page 0 reserved for the null sentinel; the last fraction absorbs slack."
  (let* ((usable (max 0 (1- total-pages)))
         (n (length fractions))
         (counts (loop for f in (if (zerop n) fractions (butlast fractions))
                       collect (floor (* usable f))))
         (sum (reduce #'+ counts :initial-value 0))
         (counts (if (zerop n) counts
                    (append counts (list (max 0 (- usable sum)))))))
    (let ((start 1) result)
      (dolist (c counts) (push (cons start c) result) (incf start c))
      (nreverse result))))

(declaim (inline make-space))
(defun make-space (class vm start-page page-count &rest initargs)
  (apply #'make-instance class :vm vm :start-page start-page :page-count page-count
         :default-space t initargs))
