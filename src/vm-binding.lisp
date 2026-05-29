(in-package #:clamsara)

;;; --- VM Binding Layer ---
;;; The VM binding is the sole interface between the GC framework and the
;;; target runtime. All object access, address math, metadata queries, root
;;; scanning, thread control, and resource acquisition go through this protocol.

(defclass vm-binding ()
  ((heap-base :initarg :heap-base :reader vm-heap-base
    :initform 0)
   (heap-size :initarg :heap-size :reader vm-heap-size
    :initform 0)
   (card-table :initarg :card-table :accessor vm-card-table
    :initform nil)
   (root-set :initarg :root-set :accessor vm-root-set
    :initform nil)
   (barrier :initarg :barrier :initform nil
    :accessor vm-barrier)
   (stat-gc-count :initform 0 :accessor vm-stat-gc-count :type fixnum))
  (:documentation "Abstract VM binding. Plans interact with the VM through
this interface, never directly with the heap."))

(defgeneric vm-forwarding-placement (vm)
  (:documentation "Return the metadata spec placement for forwarding.
   Default: :in-header for STW VMs, :separate-region for concurrent VMs.")
  (:method ((vm vm-binding)) :separate-region))

;;; --- Object Model ---

(defgeneric vm-object-header (vm obj-address)
  (:documentation "Return the header word of the object at OBJ-ADDRESS."))

(defgeneric (setf vm-object-header) (new-val vm obj-address)
  (:documentation "Set the header word of the object at OBJ-ADDRESS."))

(defgeneric vm-object-reference (vm obj-address slot-index)
  (:documentation "Return the reference in SLOT-INDEX of the object at OBJ-ADDRESS."))

(defgeneric (setf vm-object-reference) (new-val vm obj-address slot-index)
  (:documentation "Set the reference in SLOT-INDEX of the object at OBJ-ADDRESS."))

(defgeneric vm-object-reference-count (vm obj-address)
  (:documentation "Number of reference slots in the object at OBJ-ADDRESS."))

(defgeneric vm-object-total-words (vm obj-address)
  (:documentation "Total words occupied by the object (header + slots)."))

(defgeneric vm-object-type-tag (vm obj-address)
  (:documentation "Return the type tag of the object at OBJ-ADDRESS."))

(defgeneric vm-object-start-p (vm obj-address)
  (:documentation "Return T if OBJ-ADDRESS points to an object start."))

(defgeneric vm-object-copy (vm src-address dst-address)
  (:documentation "Copy the object from SRC-ADDRESS to DST-ADDRESS. Returns DST-ADDRESS."))

(defgeneric vm-compute-header (vm size type-tag &rest flags)
  (:documentation "Compute an object header for the given VM object model."))

;;; --- Metadata Protocol ---

(defgeneric vm-object-is-marked-p (vm obj-address)
  (:documentation "Return T if the object is marked."))

(defgeneric (setf vm-object-is-marked-p) (new-val vm obj-address)
  (:documentation "Set or clear the mark on the object."))

(defgeneric vm-object-is-forwarded-p (vm obj-address)
  (:documentation "Return T if the object has been forwarded."))

(defgeneric vm-object-forwarding-pointer (vm obj-address)
  (:documentation "Return the forwarding address, or NIL if not forwarded."))

(defgeneric (setf vm-object-forwarding-pointer) (new-addr vm obj-address)
  (:documentation "Set the forwarding pointer for the object."))

(defgeneric vm-object-is-pinned-p (vm obj-address)
  (:documentation "Return T if the object is pinned (non-movable)."))

(defgeneric vm-object-is-logged-p (vm obj-address)
  (:documentation "Return T if the object is logged (has young referents)."))

(defgeneric (setf vm-object-is-logged-p) (new-val vm obj-address)
  (:documentation "Set or clear the log bit on the object."))

(defgeneric vm-object-generation (vm obj-address)
  (:documentation "Return the generation number (0 = nursery) for OBJ-ADDRESS."))

(defgeneric (setf vm-object-generation) (generation vm obj-address)
  (:documentation "Set the generation number. Used for in-place promotion."))

(defgeneric vm-object-has-children-p (vm obj-address)
  (:documentation "Return T if the object has reference slots."))

(defgeneric vm-object-age (vm obj-address)
  (:documentation "Return the survivor count (age within generation)."))

(defgeneric (setf vm-object-age) (age vm obj-address))

;;; --- Address Protocol ---

(defgeneric vm-address-index (vm addr)
  (:documentation "Extract the word index portion of ADDR."))

(defgeneric vm-address-in-space-p (vm addr space)
  (:documentation "Return T if ADDR falls within SPACE."))

(defgeneric vm-address-generation (vm addr)
  (:documentation "Return the generation of the object at ADDR, or NIL if unknown."))

(defgeneric vm-address-young-p (vm addr)
  (:documentation "True if ADDR points to a nursery object."))

(defgeneric vm-address-old-p (vm addr)
  (:documentation "True if ADDR points to a mature object."))

(defgeneric vm-find-space-for-address (vm addr)
  (:documentation "Return the space that contains ADDR, or NIL."))

;;; --- Scanning Protocol ---

(defgeneric vm-scan-roots (vm collector-state visitor-fn)
  (:documentation "Call VISITOR-FN once for each root address."))

(defgeneric vm-scan-object-references (vm obj-address visitor-fn)
  (:documentation "Call VISITOR-FN once for each reference slot in the object at OBJ-ADDRESS."))

(defgeneric vm-update-roots-forwarded (vm)
  (:documentation "Update all root slots that contain forwarded addresses to point to the forwarded destination."))

;;; --- Thread Control Protocol ---

(defgeneric vm-stop-mutators (vm)
  (:documentation "Stop all mutator threads before collection."))

(defgeneric vm-resume-mutators (vm)
  (:documentation "Resume all mutator threads after collection."))

(defgeneric vm-block-for-gc (vm)
  (:documentation "Block the current mutator thread for GC."))

;;; --- Collection Lifecycle ---

(defgeneric vm-post-gc-cleanup (vm)
  (:documentation "Post-GC cleanup: clear metadata, release resources."))

(defgeneric vm-clear-all-forwarding (vm)
  (:documentation "Clear all forwarding pointers."))

(defgeneric vm-clear-all-mark-bits (vm)
  (:documentation "Clear all mark bits."))

(defgeneric vm-clear-all-log-bits (vm)
  (:documentation "Clear all log/remembered-set bits."))

;;; --- Heap Statistics ---

(defgeneric vm-heap-usage (vm)
  (:documentation "Return a plist of heap statistics."))

(defgeneric vm-valid-reference-p (vm addr)
  (:documentation "Return T if ADDR looks like a valid reference to a heap object."))

;;; --- Object Reference Store (with barrier) ---

(defgeneric vm-object-reference-store (vm source-addr slot new-value &key barrier-p)
  (:documentation "Store NEW-VALUE into SLOT of SOURCE-ADDR, optionally invoking barriers."))

;;; --- Default method implementations ---

(defmethod vm-object-header ((vm vm-binding) obj-address)
  (object-header obj-address))

(defmethod (setf vm-object-header) (new-val (vm vm-binding) obj-address)
  (setf (object-header obj-address) new-val))

(defmethod (setf vm-object-header) :after (new-val (vm vm-binding) obj-address)
  (declare (ignore new-val vm))
  (mark-object-start obj-address))

(defmethod vm-object-reference ((vm vm-binding) obj-address slot-index)
  (object-reference obj-address slot-index))

(defmethod (setf vm-object-reference) (new-val (vm vm-binding) obj-address slot-index)
  (setf (object-reference obj-address slot-index) new-val))

(defmethod vm-object-reference-count ((vm vm-binding) obj-address)
  (object-reference-count obj-address))

(defmethod vm-object-total-words ((vm vm-binding) obj-address)
  (object-total-words obj-address))

(defmethod vm-object-type-tag ((vm vm-binding) obj-address)
  (object-type-tag obj-address))

(defmethod vm-object-start-p ((vm vm-binding) obj-address)
  (object-start-p obj-address))

(defmethod vm-object-is-marked-p ((vm vm-binding) obj-address)
  (object-marked-p obj-address))

(defmethod (setf vm-object-is-marked-p) (new-val (vm vm-binding) obj-address)
  (if new-val (mark-object obj-address) (unmark-object obj-address))
  new-val)

(defmethod vm-object-is-forwarded-p ((vm vm-binding) obj-address)
  (object-forwarded-p obj-address))

(defmethod vm-object-forwarding-pointer ((vm vm-binding) obj-address)
  (object-forwarding-address obj-address))

(defmethod (setf vm-object-forwarding-pointer) (new-addr (vm vm-binding) obj-address)
  (set-object-forwarding obj-address new-addr))

(defmethod vm-object-is-pinned-p ((vm vm-binding) obj-address)
  (object-pinned-p obj-address))

(defmethod vm-object-is-logged-p ((vm vm-binding) obj-address)
  (object-logged-p obj-address))

(defmethod (setf vm-object-is-logged-p) (new-val (vm vm-binding) obj-address)
  (if new-val (log-object obj-address) (unlog-object obj-address))
  new-val)

(defmethod vm-object-generation ((vm vm-binding) obj-address)
  (ldb (byte 8 +generation-shift+) (aref *metadata-words* obj-address)))

(defmethod (setf vm-object-generation) (generation (vm vm-binding) obj-address)
  (let* ((word (aref *metadata-words* obj-address))
         (mask (ash #xFF +generation-shift+))
         (cleared (logandc2 word mask))
         (set (logior cleared (ash generation +generation-shift+))))
    (setf (aref *metadata-words* obj-address) set)))

(defmethod vm-object-age ((vm vm-binding) obj-address)
  (object-age obj-address))

(defmethod (setf vm-object-age) (age (vm vm-binding) obj-address)
  (setf (object-age obj-address) age))

(defmethod vm-object-has-children-p ((vm vm-binding) obj-address)
  (> (vm-object-reference-count vm obj-address) 0))

(defmethod vm-object-copy ((vm vm-binding) src-address dst-address)
  "Copy the object from SRC-ADDRESS to DST-ADDRESS. In the simulator,
delegates to the global heap-ref functions; a target VM would override
this with its own memory-access primitives."
  (let ((n-words (vm-object-total-words vm src-address)))
    (loop for i from 0 below n-words
          do (setf (heap-ref (+ (address-index dst-address) i))
                   (heap-ref (+ (address-index src-address) i))))
    (mark-object-start dst-address)
    dst-address))

(defmethod vm-compute-header ((vm vm-binding) size type-tag &rest flags)
  (declare (ignore vm))
  (apply #'make-object-header size :type-tag type-tag :flags flags))

(defmethod vm-address-index ((vm vm-binding) addr)
  (declare (ignore vm))
  (address-index addr))

(defmethod vm-address-in-space-p ((vm vm-binding) addr space)
  (declare (ignore vm))
  (space-contains-p space addr))

(defmethod vm-address-generation ((vm vm-binding) addr)
  (declare (ignore vm))
  (vm-object-generation vm addr))

(defmethod vm-address-young-p ((vm vm-binding) addr)
  (declare (ignore vm))
  (zerop (vm-object-generation vm addr)))

(defmethod vm-address-old-p ((vm vm-binding) addr)
  (declare (ignore vm))
  (not (zerop (vm-object-generation vm addr))))

(defmethod vm-find-space-for-address ((vm vm-binding) addr)
  (let ((plan *active-plan*))
    (when plan
      (find-if (lambda (s) (space-contains-p s addr))
               (plan-spaces plan)))))

(defmethod vm-scan-object-references ((vm vm-binding) obj-address visitor-fn)
  (let ((n-refs (vm-object-reference-count vm obj-address)))
    (loop for i from 0 below n-refs
          for ref = (vm-object-reference vm obj-address i)
          when (vm-valid-reference-p vm ref)
            do (funcall visitor-fn ref i))))

(defmethod vm-stop-mutators ((vm vm-binding))
  (incf (vm-stat-gc-count vm))
  nil)

(defmethod vm-resume-mutators ((vm vm-binding))
  nil)

(defmethod vm-block-for-gc ((vm vm-binding))
  nil)

(defmethod vm-post-gc-cleanup ((vm vm-binding))
  (vm-clear-all-forwarding vm)
  (vm-clear-all-log-bits vm))

(defmethod vm-clear-all-forwarding ((vm vm-binding))
  (declare (ignore vm))
  (clear-all-forwarding))

(defmethod vm-clear-all-mark-bits ((vm vm-binding))
  (declare (ignore vm))
  (clear-all-mark-bits))

(defmethod vm-clear-all-log-bits ((vm vm-binding))
  (declare (ignore vm))
  (clear-all-log-bits))

(defmethod vm-heap-usage ((vm vm-binding))
  (let ((live 0))
    (when *metadata-words*
      (loop for i from 0 below (length *metadata-words*)
            when (object-start-p i)
              do (incf live)))
    (list :total-words *heap-size* :live-objects live)))

(defmethod vm-valid-reference-p ((vm vm-binding) addr)
  (and (integerp addr)
       (not (zerop addr))
       (>= addr 0)
       (< addr *heap-size*)
       (vm-object-start-p vm addr)))

(defmethod vm-object-reference-store ((vm vm-binding) source-addr slot new-value &key (barrier-p t))
  (setf (vm-object-reference vm source-addr slot) new-value)
  (when barrier-p
    (let ((barrier (vm-barrier vm)))
      (when barrier
        (barrier-note-write barrier source-addr slot new-value))))
  new-value)
