;;;; vm/binding.lisp -- the VM protocol and capability tiers (paper-v8
;;;; ch. vm-capabilities + ch. memory).
;;;;
;;;; The collector never touches hardware; it calls this protocol.  The
;;;; simulator implements every tier in software so any collector boots.
;;;; Capability tiers are mixins: T0 = base vm-binding, T1 = virtual-memory,
;;;; T2 = ring0.  Coloured-pointer and CAS128 are orthogonal mixins.

(in-package #:clamsara)

;; ---- VM coordination state ------------------------------------------------
;;
;; A real VM backs these fields with atomics and lets each mutator publish its
;; arrival at a safepoint.  The simulator has one execution stream, so the
;; state is an ordinary preallocated record: requesting a stop immediately
;; reaches the safepoint.  Keeping the record on the VM (rather than in a
;; collector or a temporary plist) makes the protocol allocation-free on all
;; collection paths and leaves a stable object for protocol tests.
(defstruct (coordination-state (:constructor %make-coordination-state))
  (requested nil :type boolean)
  (stopped nil :type boolean)
  (epoch 0 :type fixnum))

;; Explicit root regions are a simulator/backend hook.  They are not native
;; stack maps: a backend registers stable vectors and (optionally) the mapped
;; entries at boot, and collection only rewrites those entries.
(defstruct (root-region (:constructor %make-root-region))
  vector
  (start 0 :type fixnum)
  (end 0 :type fixnum)
  mapped-indices)

;; ---- capability mixins (markers + their state) --------------------------

(defclass vm-binding ()
  ((heap        :initarg :heap :reader vm-heap)
   (heap-size   :initarg :heap-size :reader vm-heap-size :initform 0)
   (roots       :initarg :roots :accessor vm-root-vector
                :initform (make-array 0 :fill-pointer 0))
   ;; Fixed-capacity descriptors are allocated with the VM, never by a
   ;; collection.  Registration fills an unused descriptor at boot.
   (root-regions :initarg :root-regions :accessor vm-root-regions
                 :initform #())
   (root-region-count :initarg :root-region-count
                      :accessor vm-root-region-count :initform 0)
   (root-region-capacity :initarg :root-region-capacity
                         :accessor vm-root-region-capacity :initform 0)
   (strata      :accessor vm-strata-table :initform (make-hash-table :test 'eq))
   (locations   :accessor vm-locations :initform (make-hash-table :test 'eq))
   ;; Dense simulator tables are the off-heap address-keyed tables of paper-v8.
   ;; They are allocated at boot and never grow through the host allocator.
   (fwd-table   :initarg :fwd-table :accessor vm-fwd-table :initform nil)
   (rc-table    :initarg :rc-table :accessor vm-rc-table :initform nil)
   (object-start :accessor vm-object-start :initform nil)
   (slot-maps   :accessor vm-slot-maps :initform nil)  ; per-type layout registry
   (stats       :accessor vm-stats :initform nil)
   ;; Persistence state is VM-owned so a checkpoint made through the plain
   ;; PLAN API can still accumulate a base image and subsequent deltas.  The
   ;; COW table is deliberately host-side metadata: it is only the simulator
   ;; implementation of the VM's protected-page/frozen-copy bookkeeping.
   (persistence-log :accessor vm-persistence-log :initform nil)
   (cow-pages   :accessor vm-cow-pages :initform nil) ; bit-vector, page -> armed
   (cow-images  :accessor vm-cow-images :initform nil) ; page -> frozen words
   ;; The simulator scheduler and packet pool are VM-owned immortal storage.
   ;; They are initialized once at VM creation and never grow on a collector
   ;; or mutator path.
   (scheduler :accessor vm-scheduler :initform nil)
   (work-packet-pool :accessor vm-work-packet-pool :initform nil)
   (work-packet-free-stack :accessor vm-work-packet-free-stack :initform nil)
   ;; Safepoint coordination is VM-owned and allocated with the VM.  Protocol
   ;; operations only mutate these three fields; they never lazily allocate.
   (coordination-state :initarg :coordination-state
                       :accessor vm-coordination-state
                       :initform (%make-coordination-state))
   (plan        :initarg :plan :accessor vm-plan :initform nil)))

(defclass virtual-memory-mixin ()           ; T1
  ((vpt        :accessor mmu-vpt :initform nil)       ; virt-page -> (phys . prot)
   (dirty      :accessor mmu-dirty :initform nil)     ; bit-vector
   ;; The simulator arms this table explicitly for checkpoint dirty tracking.
   ;; COW state is kept beside the table so a write fault can freeze a page
   ;; before the mutator store, then restore the previous handler afterwards.
   (mmu-armed  :accessor mmu-armed :initform nil)
   (cow-pages  :accessor mmu-cow-pages :initform nil)
   (cow-copied :accessor mmu-cow-copied :initform nil)
   (cow-previous-handler :accessor mmu-cow-previous-handler :initform nil)))

(defclass ring0-mixin ()                     ; T2
  ((handler    :accessor mmu-handler :initform nil)))

(defclass has-cas128-mixin () ())            ; marker
(defclass coloured-pointer-mixin ()          ; in-pointer colour
  ((mark-colour :accessor vm-mark-colour :initform +colour-marked0+)
   (good-colour :accessor vm-good-colour :initform +colour-remapped+)))

(defclass software-mmu () ()
  (:documentation "Marker: the VM implements T1/T2 in software."))

(defun vm-binding-p (x) (typep x 'vm-binding))

(defgeneric vm-page-count (vm)
  (:method ((vm vm-binding)) (ceiling (vm-heap-size vm) +page-words+)))

(defgeneric vm-tier (vm)
  (:documentation "Highest capability tier the VM provides: :t0 :t1 :t2.")
  (:method ((vm vm-binding)) :t0)
  (:method ((vm virtual-memory-mixin)) :t1)
  (:method ((vm ring0-mixin)) :t2))

(defgeneric vm-has-feature-p (vm feature)
  (:method ((vm vm-binding) (feature (eql :atomics))) t)
  (:method ((vm vm-binding) (feature (eql :t0))) t)
  (:method ((vm vm-binding) feature)
    (declare (ignore feature)) nil)
  (:method ((vm virtual-memory-mixin) (feature (eql :t1))) t)
  (:method ((vm virtual-memory-mixin) (feature (eql :virtual-memory))) t)
  (:method ((vm ring0-mixin) (feature (eql :t2))) t)
  (:method ((vm ring0-mixin) (feature (eql :ring0))) t)
  (:method ((vm has-cas128-mixin) (feature (eql :cas128))) t)
  (:method ((vm coloured-pointer-mixin) (feature (eql :coloured-pointers))) t))

(defgeneric vm-heap-base (vm)
  (:method ((vm vm-binding)) 0))
(defgeneric vm-min-alignment-words (vm)
  (:method ((vm vm-binding)) 1))

;; ---- T0 memory access + atomics ------------------------------------------

(defgeneric ref-u64 (vm address)
  (:method ((vm vm-binding) address) (aref (vm-heap vm) address)))
(defgeneric (setf ref-u64) (new-value vm address)
  (:method (new-value (vm vm-binding) address)
    (setf (aref (vm-heap vm) address) new-value)))

(declaim (inline ref-word))
(defun ref-word (vm address) (ref-u64 vm address))
(defun (setf ref-word) (new vm address) (setf (ref-u64 vm address) new))

(defgeneric cas (vm place expected new)
  (:documentation "Compare-and-swap PLACE. PLACE is an address or (heap . addr).")
  (:method ((vm vm-binding) place expected new)
    (let ((addr (if (consp place) (cdr place) place)))
      #+sbcl (eql expected (sb-ext:cas (aref (vm-heap vm) addr) expected new))
      #-sbcl (when (eql (aref (vm-heap vm) addr) expected)
               (setf (aref (vm-heap vm) addr) new) t))))

(defgeneric cas128 (vm place exp-lo exp-hi new-lo new-hi)
  (:method ((vm vm-binding) place exp-lo exp-hi new-lo new-hi)
    (declare (ignore place exp-lo exp-hi new-lo new-hi))
    (error 'clamsara-error :message "cas128 unsupported on this VM")))

(defgeneric atomic-incf (vm place delta)
  (:method ((vm vm-binding) place delta)
    (let ((addr (if (consp place) (cdr place) place)))
      #+sbcl (sb-ext:atomic-incf (aref (vm-heap vm) addr) delta)
      #-sbcl (prog1 (aref (vm-heap vm) addr)
               (incf (aref (vm-heap vm) addr) delta)))))

(defgeneric memory-fence (vm)
  (:method ((vm vm-binding))
    ;; single-threaded simulator: a fence is a no-op.  Mezzano backs this
    ;; with a real hardware fence behind the same protocol.
    nil))

;; ---- stratum registry (Axis 2 side-metadata wiring) ---------------------

(defgeneric vm-register-stratum (vm name stratum)
  (:method ((vm vm-binding) name stratum)
    (setf (gethash name (vm-strata-table vm)) stratum)
    stratum))
(defgeneric vm-stratum (vm name)
  (:method ((vm vm-binding) name)
    (gethash name (vm-strata-table vm))))

(defun vm-set-location (vm name location)
  "Declare where metadatum NAME physically lives (:side :in-header :in-pointer :off-heap)."
  (setf (gethash name (vm-locations vm)) location))
(defun vm-location (vm name)
  (or (gethash name (vm-locations vm)) :side))

;; ---- dense off-heap tables ----------------------------------------------

(declaim (inline fwd-get fwd-present-p fwd-set rc-get rc-set))
(defun fwd-get (vm address)
  (aref (vm-fwd-table vm) address))
(defun fwd-present-p (vm address)
  (not (zerop (fwd-get vm address))))
(defun fwd-set (vm address destination)
  (setf (aref (vm-fwd-table vm) address) destination))
(defun fwd-clear (vm)
  (fill (vm-fwd-table vm) 0)
  vm)
(defun fwd-count (vm)
  (count-if-not #'zerop (vm-fwd-table vm)))

(defun rc-get (vm address)
  (aref (vm-rc-table vm) address))
(defun rc-set (vm address value)
  (setf (aref (vm-rc-table vm) address) value))
(defun rc-clear (vm)
  (fill (vm-rc-table vm) 0)
  vm)

;; ---- roots ---------------------------------------------------------------

(defun vm-add-root (vm address)
  (unless (vector-push address (vm-root-vector vm))
    (error 'heap-exhausted :requested-size 1 :space :root-table))
  address)
(defun vm-remove-root (vm address)
  ;; roots may repeat; remove one occurrence
  (let ((v (vm-root-vector vm)))
    (dotimes (i (length v))
      (when (eql (aref v i) address)
        (setf (aref v i) (aref v (1- (length v))))
        (decf (fill-pointer v))
        (return)))))
(defun vm-remove-root-at-index (vm index)
  "Remove the root at INDEX via swap-remove.  Returns the removed address, or
NIL if INDEX is out of range.  Removing a root invalidates the index of the
root that was last in the vector (it moves into INDEX); callers must refresh
any indices they hold."
  (let ((v (vm-root-vector vm)))
    (when (and (<= 0 index) (< index (length v)))
      (prog1 (aref v index)
        (setf (aref v index) (aref v (1- (length v))))
        (decf (fill-pointer v))))))
(defun vm-clear-roots (vm)
  (setf (fill-pointer (vm-root-vector vm)) 0))
(defun vm-root-set (vm) (vm-root-vector vm))

;; ---- precise scanning: per-type slot maps (memory.tex §3) ----------------
;; A slot map names the reference-bearing slots of a layout.  An object's
;; type tag selects its layout (memory.tex §1); the header spare field holds
;; the layout id for tagged objects.  Every scan/heal site must route through
;; VM-REFERENCE-SLOTS; treating every payload slot as a reference is the
;; conservative fallback when no map is declared.

(defconstant +layout-id-bits+ 16)
(defconstant +layout-id-limit+ (ash 1 +layout-id-bits+))
(defconstant +slot-index-bits+ 24)
(defconstant +slot-index-limit+ (ash 1 +slot-index-bits+))

(defun %valid-layout-id-p (layout-id)
  (and (integerp layout-id)
       (<= 0 layout-id)
       (< layout-id +layout-id-limit+)))

(defun %valid-slot-index-p (slot)
  ;; Slot indices are payload offsets and must fit the header's 24-bit size
  ;; field.  Rejecting malformed indices at registration keeps all scan/heal
  ;; paths allocation-free and prevents a map from naming outside an object.
  (and (integerp slot)
       (<= 0 slot)
       (< slot +slot-index-limit+)))

(defun %slot-map-key (type-tag layout-id)
  "Return an allocation-free hash key for a TYPE-TAG/LAYOUT-ID pair.
  Both fields are validated before this helper is called, so the bit packing
  is injective and the result remains a fixnum on supported hosts."
  (logior (ash type-tag +layout-id-bits+) layout-id))

(defstruct (slot-map (:constructor %make-slot-map))
  (type-tag 0 :type fixnum)
  (ref-slots nil :type (or simple-vector null)))

(defun register-slot-map (vm type-tag layout-id ref-slots)
  "Declare that objects with type-tag TYPE-TAG and header spare LAYOUT-ID
  have reference slots REF-SLOTS (a vector of slot indices, ascending).
  The map's vector is copied so later mutations by the caller cannot change
  collector traversal.  Registration is the only operation that may allocate;
  lookup uses an integer key and a stable hash table.  Returns the layout id."
  (unless (and (integerp type-tag) (<= 0 type-tag) (< type-tag 256))
    (error 'clamsara-error
           :message (format nil "invalid slot-map type tag ~s (expected 0..255)"
                            type-tag)))
  (unless (%valid-layout-id-p layout-id)
    (error 'clamsara-error
           :message (format nil "invalid slot-map layout id ~s (expected 0..~d)"
                            layout-id (1- +layout-id-limit+))))
  (unless (or (null ref-slots) (vectorp ref-slots))
    (error 'clamsara-error
           :message "slot-map reference slots must be a vector or NIL"))
  (let ((slots (and ref-slots (make-array (length ref-slots))))
        (previous nil))
    (dotimes (i (length ref-slots))
      (let ((slot (aref ref-slots i)))
        (unless (%valid-slot-index-p slot)
          (error 'clamsara-error
                 :message
                 (format nil "invalid slot-map slot index ~s (expected 0..~d)"
                         slot (1- +slot-index-limit+))))
        ;; Maps are documented as ascending.  Enforce strict ordering: a
        ;; duplicate would otherwise cause duplicate visits during tracing.
        (when (and previous (<= slot previous))
          (error 'clamsara-error
                 :message "slot-map slot indices must be strictly ascending"))
        (setf (aref slots i) slot
              previous slot)))
    ;; The registry is intentionally created/resized by registration, never by
    ;; slot-map-for on a collector path.  Integer keys avoid consing a pair at
    ;; every lookup while still distinguishing tags that share a layout id.
    (unless (vm-slot-maps vm)
      (setf (vm-slot-maps vm) (make-hash-table :test #'eql)))
    (setf (gethash (%slot-map-key type-tag layout-id) (vm-slot-maps vm))
          (%make-slot-map :type-tag type-tag :ref-slots slots)))
  layout-id)

(defun slot-map-for (vm address)
  (let* ((maps (vm-slot-maps vm))
         (tag (vm-object-type-tag vm address))
         (layout-id (if (eql tag +tag-cons+)
                        0
                        (header-spare (vm-object-header vm address)))))
    (and maps
         (gethash (%slot-map-key tag layout-id) maps))))

(defun vm-reference-slots (vm address)
  "The reference-bearing slot indices of the object at ADDRESS, per its
  declared layout; NIL means conservative (every slot is a reference)."
  (let ((m (slot-map-for vm address)))
    (if m (slot-map-ref-slots m) nil)))

(defun register-root-region (vm vector start end mapped-indices-or-nil)
  "Register a stable VECTOR root region for the simulator/backend hook.
START and END are absolute vector bounds, with END exclusive.  A non-NIL
index vector names exactly the entries to rewrite; NIL scans every entry in
[START,END).  Registration copies the index vector and consumes one of the
VM's fixed-capacity boot-time descriptors."
  (unless (vectorp vector)
    (error 'clamsara-error :message "root region storage must be a vector"))
  (unless (and (integerp start) (integerp end)
               (<= 0 start) (<= start end) (<= end (length vector)))
    (error 'clamsara-error
           :message (format nil "invalid root region range [~s,~s) for vector length ~d"
                            start end (length vector))))
  (unless (or (null mapped-indices-or-nil)
              (vectorp mapped-indices-or-nil))
    (error 'clamsara-error
           :message "root region map must be a vector or NIL"))
  ;; Validate and copy before consuming a descriptor, so rejected input leaves
  ;; the VM registration state unchanged.
  (let ((mapped (and mapped-indices-or-nil
                     (make-array (length mapped-indices-or-nil)))))
    (when mapped
      (dotimes (i (length mapped-indices-or-nil))
        (let ((index (aref mapped-indices-or-nil i)))
          (unless (and (integerp index) (<= start index) (< index end))
            (error 'clamsara-error
                   :message (format nil
                                    "root region mapped index ~s outside [~s,~s)"
                                    index start end)))
          (setf (aref mapped i) index))))
    (let* ((regions (vm-root-regions vm))
           (count (vm-root-region-count vm)))
      (when (or (not (vectorp regions)) (>= count (length regions)))
        (error 'heap-exhausted :requested-size 1 :space :root-regions))
      (let ((descriptor (aref regions count)))
        ;; Descriptors are preallocated at simulator creation.  A malformed
        ;; backend VM gets a clear boot-time error rather than allocating one.
        (unless (root-region-p descriptor)
          (error 'clamsara-error :message "VM root-region descriptor storage is not preallocated"))
        (setf (root-region-vector descriptor) vector
              (root-region-start descriptor) start
              (root-region-end descriptor) end
              (root-region-mapped-indices descriptor) mapped
              (vm-root-region-count vm) (1+ count)))))
  vector)

(defgeneric vm-scan-roots (vm collector-state fn)
  (:documentation "Invoke FN as (FN COLLECTOR-STATE REF) on each root and
replace the root with its returned reference. VM backends extend this method
for stacks and registers. Passing state explicitly avoids allocating a
capturing closure during collection. Explicit root regions are a simulator /
backend hook, not native stack maps: mapped entries are rewritten, while NIL
maps conservatively scan the complete registered range.")
  (:method ((vm vm-binding) collector-state fn)
    (let ((roots (vm-root-vector vm)))
      ;; Preserve the original root-vector protocol and its conservative scan.
      (dotimes (i (length roots))
        (setf (aref roots i)
              (funcall fn collector-state (aref roots i))))
      ;; Descriptors and copied maps are VM-owned boot storage.  No host
      ;; allocation is needed while walking them during collection.
      (let ((regions (vm-root-regions vm)))
        (dotimes (r (vm-root-region-count vm))
          (let* ((descriptor (aref regions r))
                 (vector (root-region-vector descriptor))
                 (mapped (root-region-mapped-indices descriptor)))
            (if mapped
                (dotimes (i (length mapped))
                  (let ((index (aref mapped i)))
                    (setf (aref vector index)
                          (funcall fn collector-state (aref vector index)))))
                (loop for index from (root-region-start descriptor)
                      below (root-region-end descriptor)
                      do (setf (aref vector index)
                               (funcall fn collector-state (aref vector index)))))))))))

;; ---- coordination --------------------------------------------------------

;; VM-facing readers are deliberately tiny.  In addition to the descriptive
;; names, retain short aliases useful to backends and tests.  The record
;; accessors (COORDINATION-STATE-*) remain available when a caller wants to
;; inspect the VM-owned object itself.
(declaim (inline vm-coordination vm-coordination-requested
                 vm-coordination-stopped vm-coordination-epoch
                 vm-coordination-requested-p vm-coordination-stopped-p
                 vm-safepoint-requested-p vm-mutators-stopped-p
                 vm-stop-requested-p vm-stopped-p vm-safepoint-epoch))
(defun vm-coordination (vm) (vm-coordination-state vm))
(defun vm-coordination-requested (vm)
  (coordination-state-requested (vm-coordination-state vm)))
(defun vm-coordination-stopped (vm)
  (coordination-state-stopped (vm-coordination-state vm)))
(defun vm-coordination-epoch (vm)
  (coordination-state-epoch (vm-coordination-state vm)))
(defun vm-coordination-requested-p (vm) (vm-coordination-requested vm))
(defun vm-coordination-stopped-p (vm) (vm-coordination-stopped vm))
(defun vm-safepoint-requested-p (vm) (vm-coordination-requested vm))
(defun vm-mutators-stopped-p (vm) (vm-coordination-stopped vm))
(defun vm-stop-requested-p (vm) (vm-coordination-requested vm))
(defun vm-stopped-p (vm) (vm-coordination-stopped vm))
(defun vm-safepoint-epoch (vm) (vm-coordination-epoch vm))

(defgeneric vm-safepoint (vm &key reason)
  (:documentation "Publish this execution stream's arrival at a safepoint.
The simulator has one mutator stream, so an outstanding stop request is
acknowledged synchronously.  A parallel VM supplies an atomic implementation.")
  (:method ((vm vm-binding) &key reason)
    (declare (ignore reason))
    (let ((state (vm-coordination-state vm)))
      (when (coordination-state-requested state)
        (setf (coordination-state-stopped state) t)))
    vm))

(defgeneric vm-mutator-poll (vm)
  (:documentation "Poll the VM stop request at a mutator safepoint.
The simulator acknowledges synchronously; a concurrent backend may park the
calling context until VM-RESUME-MUTATORS." )
  (:method ((vm vm-binding))
    (when (vm-safepoint-requested-p vm)
      (vm-safepoint vm :reason :mutator-poll))
    vm))

(defgeneric vm-stop-mutators (vm)
  (:documentation "Request a mutator stop and synchronously acknowledge it in
 the single-threaded simulator.  Repeated requests in one epoch are idempotent." )
  (:method ((vm vm-binding))
    (let ((state (vm-coordination-state vm)))
      (unless (coordination-state-requested state)
        (setf (coordination-state-requested state) t)
        ;; EPOCH identifies this stop/resume interval.  Keep it a fixnum even
        ;; after a very long-running simulator session.
        (let ((epoch (coordination-state-epoch state)))
          (setf (coordination-state-epoch state)
                (if (= epoch most-positive-fixnum) 0 (1+ epoch))))))
    ;; There are no concurrent mutators in the simulator.  A real backend can
    ;; leave this as a request and have each worker call VM-SAFEPOINT instead.
    (vm-safepoint vm :reason :stop-mutators)))

(defgeneric vm-resume-mutators (vm)
  (:documentation "Clear the stop request and release simulator mutators.
The epoch is retained as the completed stop interval's token." )
  (:method ((vm vm-binding))
    (let ((state (vm-coordination-state vm)))
      (setf (coordination-state-requested state) nil
            (coordination-state-stopped state) nil))
    vm))
