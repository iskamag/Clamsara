;;;; Optional Maclina adapter.
;;;;
;;;; Maclina remains a host interpreter/compiler; its own bytecode, lexical
;;;; cells, and compiler data are host objects.  The overridden allocation and
;;;; mutation subset below makes evaluated Lisp construct its cons, struct, and
;;;; one-dimensional array graphs in the Clamsara simulator heap, which is the
;;;; workload seam required by paper-v8.

(in-package #:clamsara-maclina)

(defclass maclina-vm (clamsara:simulator-vm) ()
  (:metaclass clamsara:vm-metaclass))

(eval-when (:compile-toplevel :load-toplevel :execute)
  ;; Heap references use colour 1 while they are visible to Maclina.  The
  ;; collector strips the colour before dereferencing them.  Heap slots contain
  ;; bare addresses, so the collector's object graph remains backend-native.
  (defconstant +maclina-reference-tag-bit+ 60)
  (defconstant +maclina-reference-tag+ #.(ash 1 60))
  ;; Immediate integers use bit 59 plus a 59-bit two's-complement payload.
  ;; This keeps them disjoint from NIL, raw heap addresses, and references,
  ;; while remaining positive host fixnums on 64-bit SBCL.
  (defconstant +maclina-integer-tag-bit+ 59)
  (defconstant +maclina-integer-tag+ #.(ash 1 59))
  (defconstant +maclina-integer-payload-bits+ 59)
  (defconstant +maclina-integer-payload-mask+ #.(1- (ash 1 59)))
  (defconstant +maclina-min-integer+ #.(- (ash 1 58)))
  (defconstant +maclina-max-integer+ #.(1- (ash 1 58)))
  ;; Header spare values are the array element encoding/layout.  Zero is
  ;; deliberately left conservative: a general array may contain references
  ;; in every slot.  Numeric layouts are registered with the VM as having no
  ;; reference slots, so an integer/float bit pattern can never be mistaken
  ;; for a heap pointer by the collector.
  (defconstant +maclina-array-generic-code+ 0)
  (defconstant +maclina-array-single-float-code+ 1)
  (defconstant +maclina-array-integer-code+ 2)
  ;; Single-floats are stored as their IEEE-754 payload in simulated words.
  ;; SBCL is already a Maclina prerequisite, so use its allocation-free bit
  ;; conversion primitives rather than boxing an array/vector on the host.
  (defconstant +maclina-float-tag-bit+ 58)
  (defconstant +maclina-float-tag+ #.(ash 1 58))
  (defconstant +maclina-float-payload-mask+ #.(1- (ash 1 32))))

(defun make-maclina-vm (&key (heap-size 65536) plan)
  (when (>= heap-size +maclina-integer-tag+)
    (error "Maclina heap must fit below its immediate-integer tag"))
  (clamsara::%make-simulator-vm 'maclina-vm heap-size plan))

(defclass clamsara-maclina-client (maclina.vm-cross:client)
  ((plan :initarg :plan :reader maclina-client-plan)))

(defvar *clamsara-maclina-client* nil)
(defvar *clamsara-maclina-environment* nil)

(declaim (inline %maclina-reference-p %reference-address
                 %make-maclina-reference %maclina-integer-p))
(defun %maclina-reference-p (vm value)
  (and (integerp value)
       (logbitp +maclina-reference-tag-bit+ value)
       (not (logbitp (1+ +maclina-reference-tag-bit+) value))
       (clamsara:vm-reference-p vm value)))

(defun %reference-address (vm value)
  (clamsara:ref-strip vm value))

(defun %make-maclina-reference (vm value)
  (let ((address (%reference-address vm value)))
    (unless (clamsara:vm-reference-p vm address)
      (error "Not a live simulated-heap reference: ~S" value))
    (logior +maclina-reference-tag+ address)))

(defun %maclina-integer-p (value)
  (and (integerp value)
       (<= +maclina-min-integer+ value +maclina-max-integer+)))

(defun %map-root (vm collector-state fn value)
  ;; Do not conservatively reinterpret ordinary Maclina integers as heap
  ;; addresses.  Only explicitly tagged language-level references are roots.
  (if (%maclina-reference-p vm value)
      (%make-maclina-reference
       vm (funcall fn collector-state value))
      value))

(defun %map-vector-roots (vm collector-state fn vector start end)
  (loop for i from start below end
        do (setf (aref vector i)
                 (%map-root vm collector-state fn (aref vector i)))))

(defun %map-list-roots (vm collector-state fn list)
  (loop for cell on list
        do (setf (car cell)
                 (%map-root vm collector-state fn (car cell)))))

(defun %map-closure-roots (vm collector-state fn value)
  (when (typep value 'maclina.machine:closure)
    (let ((environment (maclina.machine:environment value)))
      (%map-vector-roots
       vm collector-state fn environment 0 (length environment)))))

(defmethod clamsara:vm-scan-roots ((vm maclina-vm) collector-state fn)
  "Extend the explicit root vector with Maclina's live stack and value area.
The scan is conservative because Maclina does not currently expose stack maps."
  (call-next-method)
  (when (and (boundp 'maclina.vm-cross::*vm*)
             maclina.vm-cross::*vm*)
    (let* ((machine maclina.vm-cross::*vm*)
           (stack (maclina.vm-cross::vm-stack machine))
           (top (maclina.vm-cross::vm-stack-top machine)))
      (%map-vector-roots vm collector-state fn stack 0 top)
      (loop for i below top
            do (%map-closure-roots
                vm collector-state fn (aref stack i)))
      (%map-list-roots
       vm collector-state fn (maclina.vm-cross::vm-values machine))))
  collector-state)

(defun %simulated-cons-p (vm value)
  (and (%maclina-reference-p vm value)
       (= (clamsara:vm-object-type-tag
           vm (%reference-address vm value))
          clamsara:+tag-cons+)))

(defun %encode-heap-value (vm value)
  "Encode the deliberately small Maclina heap-value subset.
NIL is zero, simulated references become bare heap addresses, and signed
immediate integers use a disjoint tagged representation.  Other host objects
are rejected instead of smuggling host pointers into the simulated heap."
  (cond ((null value) 0)
        ((%maclina-reference-p vm value)
         (%reference-address vm value))
        ((typep value 'single-float)
         (logior +maclina-float-tag+
                 (sb-kernel:single-float-bits value)))
        ((%maclina-integer-p value)
         (logior +maclina-integer-tag+
                 (logand value +maclina-integer-payload-mask+)))
        (t
         (error 'type-error
                :datum value
                :expected-type
                `(or null
                     (integer ,+maclina-min-integer+
                              ,+maclina-max-integer+))))))

(defun %decode-heap-value (vm value)
  (cond
    ((zerop value) nil)
    ((clamsara:vm-reference-p vm value)
     (%make-maclina-reference vm value))
    ((logbitp +maclina-integer-tag-bit+ value)
     (let ((payload (logand value +maclina-integer-payload-mask+)))
       (if (logbitp (1- +maclina-integer-payload-bits+) payload)
           (- payload (ash 1 +maclina-integer-payload-bits+))
           payload)))
    ((logbitp +maclina-float-tag-bit+ value)
     (sb-kernel:make-single-float
      (logand value +maclina-float-payload-mask+)))
    (t
     (error "Invalid word in the Maclina simulated heap: ~S" value))))

(defun %temporary-root (vm value)
  (when (%maclina-reference-p vm value)
    (clamsara:vm-add-root vm value)
    (1- (length (clamsara::vm-root-vector vm)))))

(defun %pin-root (vm value)
  "Push VALUE into the VM root vector and return its slot index.
VM-ADD-ROOT returns the pushed address, not an index; callers keeping the
index for a post-GC re-read must compute it from the fill pointer here."
  (clamsara:vm-add-root vm value)
  (1- (length (clamsara::vm-root-vector vm))))

(defun %allocate-cons (client car cdr)
  ;; CAR and CDR are host-call arguments while PLAN-ALLOCATE may trigger a GC.
  ;; Pin them in the VM root vector, then read back their possibly forwarded
  ;; values before initializing the new object.
  (let* ((plan (maclina-client-plan client))
         (vm (clamsara:plan-vm plan))
         (root-base (length (clamsara::vm-root-vector vm)))
         (car-index (%temporary-root vm car))
         (cdr-index (%temporary-root vm cdr)))
    (unwind-protect
         (let* ((address (clamsara::allocate-object
                          plan 2 :type-tag clamsara:+tag-cons+))
                (new-car (if (not (null car-index))
                             (%make-maclina-reference
                              vm
                              (aref (clamsara::vm-root-vector vm) car-index))
                             car))
                (new-cdr (if (not (null cdr-index))
                             (%make-maclina-reference
                              vm
                              (aref (clamsara::vm-root-vector vm) cdr-index))
                             cdr)))
           (clamsara:vm-set-reference
            vm address 0 (%encode-heap-value vm new-car))
           (clamsara:vm-set-reference
            vm address 1 (%encode-heap-value vm new-cdr))
           (%make-maclina-reference vm address))
      (setf (fill-pointer (clamsara::vm-root-vector vm)) root-base))))

(defun %write-cons-slot (client object slot value)
  "Store a cons slot through the active mutator barrier.
Both the container and value are temporary roots because a future barrier
implementation may perform a moving transfer while handling the write."
  (let* ((plan (maclina-client-plan client))
         (vm (clamsara:plan-vm plan))
         (barrier (clamsara:plan-barrier plan))
         (root-base (length (clamsara::vm-root-vector vm)))
         (object-index (%temporary-root vm object))
         (value-index (%temporary-root vm value)))
    (unwind-protect
         (progn
           (unless (%simulated-cons-p vm object)
             (error 'type-error :datum object :expected-type 'cons))
           (let* ((address (%reference-address
                            vm (if (not (null object-index))
                                   (%make-maclina-reference
                                    vm (aref (clamsara::vm-root-vector vm)
                                             object-index))
                                   object)))
                  (encoded (%encode-heap-value vm value)))
             (when barrier
               (setf encoded
                     (clamsara:barrier-note-write
                      vm barrier address slot encoded)))
             ;; Re-read roots after the barrier in case it moved either input.
             (when (not (null object-index))
               (setf address
                     (%reference-address
                      vm (%make-maclina-reference
                          vm (aref (clamsara::vm-root-vector vm)
                                   object-index)))))
             (when (not (null value-index))
               (let ((current
                       (aref (clamsara::vm-root-vector vm) value-index)))
                 (unless (eql current value)
                   (setf encoded (%encode-heap-value
                                  vm (%make-maclina-reference vm current))))))
             (clamsara:vm-set-reference vm address slot encoded)
             (if (not (null object-index))
                 (%make-maclina-reference
                  vm (aref (clamsara::vm-root-vector vm) object-index))
                 object)))
      (setf (fill-pointer (clamsara::vm-root-vector vm)) root-base))))

(defun %simulated-list-length (vm object)
  "Number of simulated conses from OBJECT before NIL (or an atom).
The bound is the heap's word count: no chain can be longer than that, so
this is also the cycle guard.  Iterative: length of a long list must not
cons host frames or build host lists."
  ;; %read-cons-slot wants PLAN for its read barrier; here the caller's
  ;; environment may have none, so look it up through the client.
  (let* ((client *clamsara-maclina-client*)
         (plan (and client (maclina-client-plan client)))
         (count 0))
    (declare (type fixnum count))
    (loop for cell = object
            then (%decode-heap-value
                  vm (%read-cons-slot vm plan
                                      (%reference-address vm cell) 1))
          while (and (%maclina-reference-p vm cell)
                     (< count (clamsara:vm-heap-size vm)))
          do (incf count)
          finally (return count))))

(defun %read-cons-slot (vm plan object slot)
  "Read a simulated cons slot through PLAN's fused read barrier.

Maclina's CAR/CDR overrides are mutator reads just like CLAMSARA-READ.  In
particular, the heap stores bare addresses, so checking pointer colour in the
caller cannot replace the barrier: an old bare address must first consult the
forwarding table and be written back to the slot."
  (let* ((address (%reference-address vm object))
         (raw (clamsara:vm-object-reference vm address slot))
         (barrier (clamsara:plan-barrier plan)))
    (if barrier
        (let* ((slot-address
                 ;; BARRIER-NOTE-READ writes a healed value through the raw
                 ;; VM slot address.  Headered objects keep slot 0 at ADDRESS
                 ;; + 1; using ADDRESS itself would overwrite the header and
                 ;; make the tagged cons look like an ordinary host value on
                 ;; the next CAR/CDR call.  Keep this in lockstep with
                 ;; CLAMSARA-READ's object-model-aware address calculation.
                 (if (clamsara::vm-address-cons-p vm address)
                     (+ address slot)
                     (+ address 1 slot)))
               (healed
                 (clamsara:barrier-note-read
                  vm barrier slot-address raw)))
          ;; A read transfer is allowed to return a healed value without
          ;; knowing the object model.  Mirror CLAMSARA-READ's writeback here
          ;; so every Maclina load has the same self-healing semantics.
          (setf (clamsara:vm-object-reference vm address slot) healed)
          healed)
        raw)))


(defun %simulated-struct-p (vm value)
  (and (%maclina-reference-p vm value)
       (= (clamsara:vm-object-type-tag
           vm (%reference-address vm value))
          clamsara:+tag-struct+)))

(defun %read-struct-slot (vm plan object slot)
  "Read a STRUCT slot through PLAN's fused read barrier and heal the slot."
  (let* ((root-base (length (clamsara::vm-root-vector vm)))
         (object-index (%temporary-root vm object)))
    (unwind-protect
         (progn
           (unless (%simulated-struct-p vm object)
             (error 'type-error :datum object :expected-type 'structure-object))
           (let* ((address (%reference-address
                            vm (%make-maclina-reference
                                vm (aref (clamsara::vm-root-vector vm)
                                         object-index))))
                  (raw (clamsara:vm-object-reference vm address slot))
                  (barrier (clamsara:plan-barrier plan))
                  (healed (if barrier
                              (clamsara:barrier-note-read
                               vm barrier (+ address 1 slot) raw)
                              raw)))
             ;; Keep the logical object-model slot in sync with the raw slot.
             (setf (clamsara:vm-object-reference vm address slot) healed)
             healed))
      (setf (fill-pointer (clamsara::vm-root-vector vm)) root-base))))

(defun %struct-ref (client object slot)
  (let* ((plan (maclina-client-plan client))
         (vm (clamsara:plan-vm plan)))
    (%decode-heap-value
     vm (%read-struct-slot vm plan object slot))))

(defun %struct-set (client value object slot)
  "Store VALUE in a simulated struct slot, applying the active write barrier.
Temporary roots keep both inputs live if a barrier transfer allocates."
  (let* ((plan (maclina-client-plan client))
         (vm (clamsara:plan-vm plan))
         (barrier (clamsara:plan-barrier plan))
         (root-base (length (clamsara::vm-root-vector vm)))
         (object-index (%temporary-root vm object))
         (value-index (%temporary-root vm value)))
    (unwind-protect
         (progn
           (unless (%simulated-struct-p vm object)
             (error 'type-error :datum object :expected-type 'structure-object))
           (let* ((address
                    (%reference-address
                     vm (%make-maclina-reference
                         vm (aref (clamsara::vm-root-vector vm)
                                  object-index))))
                  (encoded (%encode-heap-value vm value)))
             (when barrier
               (setf encoded
                     (clamsara:barrier-note-write
                      vm barrier address slot encoded)))
             ;; A future barrier may relocate either root while processing the
             ;; write; use the post-barrier addresses for the final store.
             (setf address
                   (%reference-address
                    vm (%make-maclina-reference
                        vm (aref (clamsara::vm-root-vector vm)
                                 object-index))))
             (when (not (null value-index))
               (let ((current
                       (aref (clamsara::vm-root-vector vm) value-index)))
                 (unless (eql current value)
                   (setf encoded (%encode-heap-value
                                  vm (%make-maclina-reference vm current))))))
             (clamsara:vm-set-reference vm address slot encoded)
             value))
      (setf (fill-pointer (clamsara::vm-root-vector vm)) root-base))))

(defun %allocate-struct-fixed (client slot-count v0 v1 v2 v3 v4 v5 v6 v7)
  "Allocation-free fixed-arity struct allocation for generated constructors.
The eight arguments cover the supported simple DEFSTRUCT subset; unlike an
&REST helper this path creates no host argument/list sequence."
  (when (> slot-count 8)
    (error "Simple simulated DEFSTRUCT supports at most eight slots"))
  (let* ((plan (maclina-client-plan client))
         (vm (clamsara:plan-vm plan))
         (root-base (length (clamsara::vm-root-vector vm)))
         (pinned (make-array 8 :initial-element nil))
         (values (vector v0 v1 v2 v3 v4 v5 v6 v7)))
    ;; Pin every reference argument BEFORE any allocation-triggered
    ;; collection.  The pin decision is captured here: after a GC the original
    ;; value is a stale from-space address, so the store phase must not
    ;; re-test its liveness.  The root slot it was pinned into is the healed
    ;; authority.
    (dotimes (i slot-count)
      (let ((v (aref values i)))
        (when (%maclina-reference-p vm v)
          (setf (aref pinned i) (%pin-root vm v)))))
    (unwind-protect
         (let ((address
                 (clamsara::allocate-object
                  plan slot-count :type-tag clamsara:+tag-struct+)))
           (dotimes (slot slot-count)
             (let ((root-index (aref pinned slot)))
               (clamsara:vm-set-reference
                vm address slot
                (%encode-heap-value
                 vm (if root-index
                        (%make-maclina-reference
                         vm (aref (clamsara::vm-root-vector vm) root-index))
                        (aref values slot))))))
           (%make-maclina-reference vm address))
      (setf (fill-pointer (clamsara::vm-root-vector vm)) root-base))))

(defun %allocate-struct (client slot-count values)
  "Allocate a +TAG-STRUCT+ object and initialize VALUES without constructing
  an auxiliary index list.  VALUES is the caller's argument sequence; all tagged
  inputs are pinned in the preallocated VM root vector before allocation."
  (let* ((plan (maclina-client-plan client))
         (vm (clamsara:plan-vm plan))
         (root-base (length (clamsara::vm-root-vector vm)))
         (pinned (make-list (length values) :initial-element nil)))
    ;; Capture the pin decision before GC can move the arguments: a pin's
    ;; index (not a later liveness re-test of the stale original) is what the
    ;; store phase must consult.
    (loop for value in values
          for cell on pinned
          when (%maclina-reference-p vm value)
            do (setf (car cell) (%pin-root vm value)))
    (unwind-protect
         (let ((address
                 (clamsara::allocate-object
                  plan slot-count :type-tag clamsara:+tag-struct+)))
           (loop for value in values
                 for cell on pinned
                 for slot from 0
                 do (let ((root-index (car cell)))
                      (clamsara:vm-set-reference
                       vm address slot
                       (%encode-heap-value
                        vm (if root-index
                               (%make-maclina-reference
                                vm (aref (clamsara::vm-root-vector vm)
                                         root-index))
                               value)))))
           (%make-maclina-reference vm address))
      (setf (fill-pointer (clamsara::vm-root-vector vm)) root-base))))

(defun %simulated-array-p (vm value)
  (and (%maclina-reference-p vm value)
       (= (clamsara:vm-object-type-tag
           vm (%reference-address vm value))
          clamsara:+tag-array+)))

(defun %array-element-code (vm object)
  (clamsara::header-spare
   (clamsara:vm-object-header vm (%reference-address vm object))))

(defun %array-length (vm object)
  (clamsara::header-size
   (clamsara:vm-object-header vm (%reference-address vm object))))

(defun %array-index (vm object index)
  (unless (and (integerp index)
               (<= 0 index)
               (< index (%array-length vm object)))
    (error 'type-error :datum index :expected-type 'fixnum))
  index)

(defun %read-array-slot (vm plan object index)
  (let* ((root-base (length (clamsara::vm-root-vector vm)))
         (object-index (%temporary-root vm object)))
    (unwind-protect
         (let* ((address
                  (%reference-address
                   vm (%make-maclina-reference
                       vm (aref (clamsara::vm-root-vector vm) object-index))))
                (raw (clamsara:vm-object-reference vm address index))
                (barrier (clamsara:plan-barrier plan))
                (healed (if barrier
                            (clamsara:barrier-note-read
                             vm barrier (+ address 1 index) raw)
                            raw)))
           (setf (clamsara:vm-object-reference vm address index) healed)
           healed)
      (setf (fill-pointer (clamsara::vm-root-vector vm)) root-base))))

(defun %write-array-slot (client object index value)
  (let* ((plan (maclina-client-plan client))
         (vm (clamsara:plan-vm plan))
         (barrier (clamsara:plan-barrier plan))
         (root-base (length (clamsara::vm-root-vector vm)))
         (object-index (%temporary-root vm object))
         (value-index (%temporary-root vm value)))
    (unwind-protect
         (progn
           (unless (%simulated-array-p vm object)
             (error 'type-error :datum object :expected-type 'array))
           (%array-index vm object index)
           (let ((code (%array-element-code vm object)))
             (when (and (= code +maclina-array-single-float-code+)
                        (not (typep value 'single-float)))
               (error 'type-error :datum value :expected-type 'single-float))
             (when (and (= code +maclina-array-integer-code+)
                        (not (integerp value)))
               (error 'type-error :datum value :expected-type 'integer)))
           (let* ((address (%reference-address
                            vm (%make-maclina-reference
                                vm (aref (clamsara::vm-root-vector vm)
                                         object-index))))
                  (encoded (%encode-heap-value vm value)))
             (when barrier
               (setf encoded
                     (clamsara:barrier-note-write
                      vm barrier address index encoded)))
             (setf address
                   (%reference-address
                    vm (%make-maclina-reference
                        vm (aref (clamsara::vm-root-vector vm)
                                 object-index))))
             (when (not (null value-index))
               (let ((current (aref (clamsara::vm-root-vector vm) value-index)))
                 (unless (eql current value)
                   (setf encoded (%encode-heap-value
                                  vm (%make-maclina-reference vm current))))))
             (clamsara:vm-set-reference vm address index encoded)
             value))
      (setf (fill-pointer (clamsara::vm-root-vector vm)) root-base))))

(defun %make-simulated-array (client dimensions &key element-type initial-element initial-element-p)
  (let* ((plan (maclina-client-plan client))
         (vm (clamsara:plan-vm plan))
         (length (cond ((integerp dimensions) dimensions)
                       ;; Accept the one-element list spelling used by
                       ;; ordinary MAKE-ARRAY callers without allocating a
                       ;; host backing vector.
                       ((and (consp dimensions)
                             (null (cdr dimensions))
                             (integerp (car dimensions)))
                        (car dimensions))
                       (t (error "Only one-dimensional simulated arrays are supported"))))
         (code (cond ((or (null element-type) (eql element-type t))
                      +maclina-array-generic-code+)
                     ((or (eql element-type 'single-float)
                          (equal element-type '(single-float)))
                      +maclina-array-single-float-code+)
                     ((or (eql element-type 'integer)
                          (equal element-type '(integer)))
                      +maclina-array-integer-code+)
                     (t (error "Unsupported simulated array element type: ~S"
                               element-type)))))
    (unless (and (integerp length) (<= 0 length))
      (error 'type-error :datum length :expected-type '(integer 0)))
    (when (and (= code +maclina-array-single-float-code+)
               (not initial-element-p))
      (setf initial-element 0.0s0))
    (when (and (= code +maclina-array-single-float-code+)
               (not (typep initial-element 'single-float)))
      (error 'type-error :datum initial-element :expected-type 'single-float))
    ;; Numeric arrays contain no references.  Registering an empty slot map is
    ;; a boot/setup operation; collection then scans no numeric payload words.
    (let* ((root-base (length (clamsara::vm-root-vector vm)))
           (initial-index (%temporary-root vm initial-element)))
      (unwind-protect
           (let* ((address
                    (clamsara::allocate-object
                     plan length :type-tag clamsara:+tag-array+
                     :layout-id code))
                  (initial
                    (if (not (null initial-index))
                        (%make-maclina-reference
                         vm (aref (clamsara::vm-root-vector vm) initial-index))
                        initial-element)))
             (dotimes (index length)
               (clamsara:vm-set-reference
                vm address index (%encode-heap-value vm initial)))
             (%make-maclina-reference vm address))
        (setf (fill-pointer (clamsara::vm-root-vector vm)) root-base)))))

(defun %array-ref (client object index)
  (let* ((plan (maclina-client-plan client))
         (vm (clamsara:plan-vm plan)))
    (if (%simulated-array-p vm object)
        (%decode-heap-value
         vm (%read-array-slot vm plan object (%array-index vm object index)))
        (cl:aref object index))))

(defun %array-set (client value object index)
  (let* ((plan (maclina-client-plan client))
         (vm (clamsara:plan-vm plan)))
    (if (%simulated-array-p vm object)
        (%write-array-slot client object (%array-index vm object index) value)
        (setf (cl:aref object index) value))))

(defun %parse-simple-defstruct (name-and-options slot-specs)
  "Parse the fixed simple DEFSTRUCT subset used by the Boehm benchmark."
  (let* ((name (if (consp name-and-options)
                   (first name-and-options)
                   name-and-options))
         (options (if (consp name-and-options)
                      (rest name-and-options)
                      nil))
         (constructor (intern (format nil "MAKE-~A" name)
                              (symbol-package name)))
         (predicate (intern (format nil "~A-P" name)
                            (symbol-package name)))
         (copier (intern (format nil "COPY-~A" name)
                         (symbol-package name)))
         (conc-name (format nil "~A-" name)))
    (dolist (option options)
      (when (consp option)
        (case (first option)
          (:constructor
           (setf constructor (or (second option) nil)))
          (:predicate
           (setf predicate (or (second option) nil)))
          (:copier
           (setf copier (or (second option) nil)))
          (:conc-name
           (setf conc-name (or (second option) nil)))
          ;; The benchmark does not use these options.  Rejecting them keeps
          ;; accidental non-simple layouts from silently corrupting the heap.
          ((:type :named :include :initial-offset)
           (error "Unsupported simple DEFSTRUCT option: ~S" option)))))
    (let ((slots
            (loop for spec in slot-specs
                  unless (and (consp spec) (keywordp (first spec)))
                  collect (if (consp spec) (first spec) spec))))
      (values name constructor predicate copier conc-name slots))))

(defun %quote-maclina-keywords (arguments)
  "Quote keyword argument names for Maclina's keyword-variable quirk."
  (loop for argument in arguments
        collect (if (keywordp argument) `(quote ,argument) argument)))


(defun %install-maclina-defmacro (client environment form)
  "Install an ANSI-style macro in the Maclina environment.
The macro expander itself runs at definition/expansion time on the host, while
its returned forms are compiled and executed by Maclina.  This phase split
supports quasiquote, UNQUOTE, &BODY, and nested source-language macros without
benchmark-specific pattern matching."
  (destructuring-bind (defmacro name lambda-list &body body) form
    (declare (ignore defmacro))
    (let ((expander
            (eval `(lambda (form environment)
                     (declare (ignore environment))
                     (destructuring-bind ,lambda-list (cdr form)
                       ,@body)))))
      (setf (clostrum:macro-function client environment name) expander)
      nil)))

(defun %install-simple-defstruct (client environment form)
  (destructuring-bind (defstruct name-and-options &rest slot-specs) form
    (declare (ignore defstruct))
    (multiple-value-bind (name constructor predicate copier conc-name slots)
        (%parse-simple-defstruct name-and-options slot-specs)
      (when (> (length slots) 8)
        (error "Simple simulated DEFSTRUCT supports at most eight slots"))
      (let* ((plan (maclina-client-plan client))
             (vm (clamsara:plan-vm plan))
             ;; A constructor is exposed as a macro so :slot names are quoted
             ;; before Maclina compiles the call.  Its hidden function remains a
             ;; normal Clostrum function closure.
             (constructor-function (gensym (format nil "%MAKE-~A-" name))))
        ;; Generate a fixed keyword lambda at DEFSTRUCT installation time.
        ;; Runtime constructor calls therefore use keyword registers directly,
        ;; not an &REST list or MAKE-LIST temporary.
        (setf (clostrum:fdefinition client environment constructor-function)
              (eval `(lambda (&key ,@slots)
                       (%allocate-struct-fixed
                        ,client ,(length slots)
                        ,@(append slots
                                  (make-list (- 8 (length slots))))))))
        (setf (clostrum:macro-function client environment constructor)
              (lambda (call-form macro-environment)
                (declare (ignore macro-environment))
                `(funcall (function ,constructor-function)
                          ,@(%quote-maclina-keywords (rest call-form)))))
        (when predicate
          (setf (clostrum:fdefinition client environment predicate)
                (lambda (object) (%simulated-struct-p vm object))))
        (loop for slot in slots
              for index from 0
              for accessor = (and conc-name
                                  (intern (format nil "~A~A" conc-name slot)
                                          (symbol-package name)))
              when accessor do
                (let ((slot-index index))
                  (setf (clostrum:fdefinition client environment accessor)
                        (lambda (object)
                          (%struct-ref client object slot-index)))
                  (setf (clostrum:fdefinition client environment
                                               `(setf ,accessor))
                        (lambda (value object)
                          (%struct-set client value object slot-index)))))
        (when copier
          ;; Generate a fixed-arity copier too; LOOP/COLLECT would otherwise
          ;; put the copied payload in a transient host list.
          (setf (clostrum:fdefinition client environment copier)
                (eval `(lambda (object)
                         (%allocate-struct-fixed
                          ,client ,(length slots)
                          ,@(loop for index below (length slots)
                                  collect `(%struct-ref ,client object ,index))
                          ,@(make-list (- 8 (length slots))))))))
        ;; Keep a type cell for TYPEP/TYPE-OF users that only need the name.
        ;; The fixed object representation is identified by +TAG-STRUCT+.
        (values name constructor predicate copier)))))

(defun %install-make-array-macro (client environment)
  ;; Simulated arrays are headered +TAG-ARRAY+ objects.  The macro only quotes
  ;; keyword names for Maclina; the runtime helper never calls host MAKE-ARRAY.
  (let ((function-name (gensym "%MAKE-SIMULATED-ARRAY-")))
    (setf (clostrum:fdefinition client environment function-name)
          (lambda (dimensions &key element-type (initial-element nil initial-element-p))
            (%make-simulated-array
             client dimensions
             :element-type element-type
             :initial-element initial-element
             :initial-element-p initial-element-p)))
    (setf (clostrum:macro-function client environment 'cl:make-array)
          (lambda (form macro-environment)
            (declare (ignore macro-environment))
            `(funcall (function ,function-name)
                      ,@(cons (second form)
                              (%quote-maclina-keywords (cddr form))))))))

(defun install-clamsara-maclina-overrides (client environment)
  (let* ((plan (maclina-client-plan client))
         (vm (clamsara:plan-vm plan)))
    ;; Numeric array payloads contain no references; register those layouts at
    ;; setup time so collection never allocates or conservatively scans them.
    (clamsara:register-slot-map
     vm clamsara:+tag-array+ +maclina-array-single-float-code+ #())
    (clamsara:register-slot-map
     vm clamsara:+tag-array+ +maclina-array-integer-code+ #())
    (labels ((cons* (car cdr) (%allocate-cons client car cdr))
             (car* (object)
               (if (%simulated-cons-p vm object)
                   (%decode-heap-value vm (%read-cons-slot vm plan object 0))
                   (cl:car object)))
             (cdr* (object)
               (if (%simulated-cons-p vm object)
                   (%decode-heap-value vm (%read-cons-slot vm plan object 1))
                   (cl:cdr object)))
             (consp* (object)
               (or (%simulated-cons-p vm object) (cl:consp object)))
             (rplaca* (object value)
               (%write-cons-slot client object 0 value))
             (rplacd* (object value)
               (%write-cons-slot client object 1 value))
             (make-list* (&rest values)
               (let ((result nil))
                 (dolist (value (reverse values) result)
                   (setf result (%allocate-cons client value result))))))
      (setf (clostrum:fdefinition client environment 'cl:cons) #'cons*
            (clostrum:fdefinition client environment 'cl:car) #'car*
            (clostrum:fdefinition client environment 'cl:cdr) #'cdr*
            (clostrum:fdefinition client environment 'cl:consp) #'consp*
            (clostrum:fdefinition client environment 'cl:rplaca) #'rplaca*
            (clostrum:fdefinition client environment 'cl:rplacd) #'rplacd*
            (clostrum:fdefinition client environment 'cl:list) #'make-list*
            (clostrum:fdefinition client environment 'cl:aref)
            (lambda (object index) (%array-ref client object index))
            (clostrum:fdefinition client environment '(setf cl:aref))
            (lambda (value object index) (%array-set client value object index))
            (clostrum:fdefinition client environment 'cl:length)
            (lambda (object)
              (cond
                ((%simulated-array-p vm object) (%array-length vm object))
                ;; A simulated cons chain must be walked in the simulated
                ;; heap: its cells are tagged references, not host conses.
                ((%simulated-cons-p vm object)
                 (%simulated-list-length vm object))
                (t (cl:length object))))
            (clostrum:fdefinition client environment 'cl:arrayp)
            (lambda (object)
              (or (%simulated-array-p vm object) (cl:arrayp object)))
            (clostrum:fdefinition client environment 'cl:array-element-type)
            (lambda (object)
              (if (%simulated-array-p vm object)
                  (case (%array-element-code vm object)
                    (#.+maclina-array-single-float-code+ 'single-float)
                    (#.+maclina-array-integer-code+ 'integer)
                    (otherwise t))
                  (cl:array-element-type object))))
      ;; Fixed simple DEFSTRUCT support.  These are ordinary host closures,
      ;; but all payload words they manipulate live in the simulated heap.
      (setf (clostrum:fdefinition client environment '%struct-ref)
            (lambda (object slot)
              (%struct-ref client object slot))
            (clostrum:fdefinition client environment '%struct-set)
            (lambda (value object slot)
              (%struct-set client value object slot)))
      (setf (clostrum:macro-function client environment 'cl:defstruct)
            (lambda (form macro-environment)
              (declare (ignore macro-environment))
              (%install-simple-defstruct client environment form)
              nil))
      (setf (clostrum:macro-function client environment 'cl:defmacro)
            (lambda (form macro-environment)
              (declare (ignore macro-environment))
              (%install-maclina-defmacro client environment form)))
      ;; ASSERT is omitted from EXTRINSICL's common macro table, but the
      ;; benchmark uses its one-argument form for the final liveness checks.
      (setf (clostrum:macro-function client environment 'cl:assert)
            (lambda (form macro-environment)
              (declare (ignore macro-environment))
              `(if ,(second form) t (error "Assertion failed: ~S" ',(second form)))))
      (%install-make-array-macro client environment)))
  environment)

(defun setup-clamsara-maclina-environment (plan &key (stack-size 65536))
  (let* ((client (make-instance 'clamsara-maclina-client :plan plan))
         (environment
           (make-instance 'clostrum-basic:run-time-environment)))
    ;; Extrinsicl installs the CL subset using native definitions. Maclina
    ;; supplies EVAL/COMPILE, after which we replace the heap-facing functions.
    (extrinsicl:install-cl (make-instance 'trucler-native:client) environment)
    (extrinsicl.maclina:install-eval client environment)
    (setf maclina.machine:*client* client)
    (maclina.vm-cross:initialize-vm stack-size client)
    (install-clamsara-maclina-overrides client environment)
    (setf *clamsara-maclina-client* client
          *clamsara-maclina-environment* environment)
    (values client environment)))

(defun clamsara-maclina-eval (form)
  (unless (and *clamsara-maclina-client*
               *clamsara-maclina-environment*)
    (error "No active Clamsara/Maclina environment"))
  (funcall (clostrum:fdefinition
            *clamsara-maclina-client*
            *clamsara-maclina-environment*
            'cl:eval)
           form))

(defun clamsara-maclina-eval-string (string)
  (clamsara-maclina-eval (read-from-string string)))

(defun load-maclina-source-file (pathname)
  "Evaluate every top-level form of PATHNAME through Maclina, preserving
source semantics.  Used by the test suite and the benchmark harness so the
fixture source resolves in Maclina's package exactly as for an interactive
source load."
  (let ((*package* (find-package '#:clamsara-maclina)))
    (with-open-file (stream pathname)
      (loop for form = (read stream nil :eof)
            until (eq form :eof)
              do (clamsara-maclina-eval form))))
  t)

(defmacro with-clamsara-maclina
    ((&key (plan-type :marksweep) (heap-size 65536) (stack-size 65536))
     &body body)
  `(let* ((vm (make-maclina-vm :heap-size ,heap-size))
          (plan (clamsara::make-collector ,plan-type vm ,heap-size)))
     (clamsara:boot-gc plan)
     (let ((clamsara:*clamsara-vm* vm)
           (clamsara:*clamsara-plan* plan)
           (*clamsara-maclina-client* nil)
           (*clamsara-maclina-environment* nil))
       (setup-clamsara-maclina-environment plan :stack-size ,stack-size)
       ,@body)))
