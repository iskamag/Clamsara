;;;; vm/binding.lisp -- the VM protocol and capability tiers (paper-v8
;;;; ch. vm-capabilities + ch. memory).
;;;;
;;;; The collector never touches hardware; it calls this protocol.  The
;;;; simulator implements every tier in software so any collector boots.
;;;; Capability tiers are mixins: T0 = base vm-binding, T1 = virtual-memory,
;;;; T2 = ring0.  Coloured-pointer and CAS128 are orthogonal mixins.

(in-package #:clamsara)

;; ---- capability mixins (markers + their state) --------------------------

(defclass vm-binding ()
  ((heap        :initarg :heap :reader vm-heap)
   (heap-size   :initarg :heap-size :reader vm-heap-size :initform 0)
   (roots       :initarg :roots :accessor vm-root-vector
                :initform (make-array 0 :fill-pointer 0))
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

(defstruct (slot-map (:constructor %make-slot-map))
  (type-tag 0 :type fixnum)
  (ref-slots nil :type (or simple-vector null)))

(defun register-slot-map (vm type-tag layout-id ref-slots)
  "Declare that objects with type-tag TYPE-TAG and header spare LAYOUT-ID
  have reference slots REF-SLOTS (a vector of slot indices, ascending).
  Returns the layout id."
  (unless (vm-slot-maps vm)
    (setf (vm-slot-maps vm) (make-array 64 :initial-element nil)))
  (setf (aref (vm-slot-maps vm) layout-id)
        (%make-slot-map :type-tag type-tag :ref-slots ref-slots))
  layout-id)

(defun slot-map-for (vm address)
  (let* ((maps (vm-slot-maps vm))
         (tag (vm-object-type-tag vm address))
         (layout-id (if (eql tag +tag-cons+)
                        0
                        (header-spare (vm-object-header vm address)))))
    (and maps (< layout-id (length maps))
         (let ((m (aref maps layout-id)))
           (and m (eql (slot-map-type-tag m) tag) m)))))

(defun vm-reference-slots (vm address)
  "The reference-bearing slot indices of the object at ADDRESS, per its
  declared layout; NIL means conservative (every slot is a reference)."
  (let ((m (slot-map-for vm address)))
    (if m (slot-map-ref-slots m) nil)))

(defgeneric vm-scan-roots (vm collector-state fn)
  (:documentation "Invoke FN as (FN COLLECTOR-STATE REF) on each root and
replace the root with its returned reference. VM backends extend this method
for stacks and registers. Passing state explicitly avoids allocating a
capturing closure during collection.")
  (:method ((vm vm-binding) collector-state fn)
    (let ((roots (vm-root-vector vm)))
      (dotimes (i (length roots))
        (setf (aref roots i)
              (funcall fn collector-state (aref roots i)))))))

;; ---- coordination (no-ops on the single-threaded simulator) -------------

(defgeneric vm-safepoint (vm &key reason)
  (:method ((vm vm-binding) &key reason) (declare (ignore reason))))
(defgeneric vm-stop-mutators (vm)
  (:method ((vm vm-binding))))
(defgeneric vm-resume-mutators (vm)
  (:method ((vm vm-binding))))
