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
        (when (typep space 'superblock-space)
          (fill (sb-refcounts space) 0)
          (fill (sb-pinned space) 0)
          (dotimes (i (length (sb-mb-matrices space)))
            (let ((m (aref (sb-mb-matrices space) i)))
              (when m (matrix-clear-all m))))
          (dotimes (i (length (sb-block-matrices space)))
            (let ((m (aref (sb-block-matrices space) i)))
              (when m (matrix-clear-all m))))
          (dotimes (i (length (sb-mb-root-bits space)))
            (fill (aref (sb-mb-root-bits space) i) 0)
            (fill (aref (sb-reached-mbs space) i) 0)))
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
    (when (typep space 'superblock-space)
      (%warm-superblock space (plan-vm plan))))
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
  ;; RC barriers classify source/target addresses through SPACE-CONTAINS-P;
  ;; resolve that effective method during boot rather than on the first
  ;; mutator store (which must remain allocation-free).
  (space-contains-p space (space-base-address space))
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
(defun direct-phase-forms (plan cycle-kind
                           &optional (phase-order +gc-phase-order+))
  "Resolve PHASE-ORDER methods and prebuild their argument lists.
The resolution is identical to the combination's dispatch, so compiled and
interpreted collectors cannot diverge.  Checkpoint is deliberately excluded
from ordinary collection phase lists: it is a fence, not a GC sub-phase."
  (let ((arguments (list plan cycle-kind)))
    (loop for phase in phase-order
          for method-function = (selected-phase-method-function plan cycle-kind phase)
          collect `(funcall ,method-function ',arguments nil))))

(defun compiled-plan-collect-form (plan)
  #+sbcl
  (let ((minor (direct-phase-forms plan :minor +gc-collection-phase-order+))
        (major (direct-phase-forms plan :major +gc-collection-phase-order+))
        (full (direct-phase-forms plan :full +gc-collection-phase-order+))
        ;; persistence.tex §4: a checkpoint is a SNAPSHOT, not a collection.
        ;; The compiled arm runs only the checkpoint phase (plus the
        ;; stop/resume safepoint), never prologue/mark/reclaim/compact.
        (checkpoint-form (first (direct-phase-forms plan :checkpoint
                                                     '(:checkpoint)))))
    `(lambda (ignored-plan cycle-kind)
       (declare (ignore ignored-plan))
       (let ((started (get-internal-run-time)))
         (ecase cycle-kind
           (:minor ,@minor)
           (:major ,@major)
           (:full ,@full)
           (:checkpoint
            (vm-stop-mutators (plan-vm ',plan))
            ,checkpoint-form
            (vm-resume-mutators (plan-vm ',plan))))
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
