;;;; Optional Maclina adapter.
;;;;
;;;; Maclina remains a host interpreter/compiler; its own bytecode, lexical
;;;; cells, and compiler data are host objects.  The overridden allocation and
;;;; mutation subset below makes evaluated Lisp construct its cons graph in the
;;;; Clamsara simulator heap, which is the workload seam required by paper-v8.

(in-package #:clamsara-maclina)

(defclass maclina-vm (clamsara:simulator-vm) ())

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
  (defconstant +maclina-max-integer+ #.(1- (ash 1 58))))

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
    (t
     (error "Invalid word in the Maclina simulated heap: ~S" value))))

(defun %temporary-root (vm value)
  (when (%maclina-reference-p vm value)
    (clamsara:vm-add-root vm value)
    (1- (length (clamsara::vm-root-vector vm)))))

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
                (new-car (if car-index
                             (%make-maclina-reference
                              vm
                              (aref (clamsara::vm-root-vector vm) car-index))
                             car))
                (new-cdr (if cdr-index
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
  (let* ((plan (maclina-client-plan client))
         (vm (clamsara:plan-vm plan))
         (barrier (clamsara:plan-barrier plan)))
    (unless (%simulated-cons-p vm object)
      (error 'type-error :datum object :expected-type 'cons))
    (let ((address (%reference-address vm object))
          (encoded (%encode-heap-value vm value)))
      (when barrier
        (setf encoded
              (clamsara:barrier-note-write
               vm barrier address slot encoded)))
      (clamsara:vm-set-reference
       vm address slot encoded))
    object))

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

(defun install-clamsara-maclina-overrides (client environment)
  (let* ((plan (maclina-client-plan client))
         (vm (clamsara:plan-vm plan)))
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
            (clostrum:fdefinition client environment 'cl:list) #'make-list*)))
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
