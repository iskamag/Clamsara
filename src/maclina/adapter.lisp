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

(defun %allocate-struct (client slot-count values)
  "Allocate a +TAG-STRUCT+ object and initialize VALUES atomically enough for
our mutator model.  Every tagged input is rooted before allocation, because
PLAN-ALLOCATE may run a moving collection."
  (let* ((plan (maclina-client-plan client))
         (vm (clamsara:plan-vm plan))
         (root-base (length (clamsara::vm-root-vector vm)))
         (indices (mapcar (lambda (value) (%temporary-root vm value)) values)))
    (unwind-protect
         (let ((address
                 (clamsara::allocate-object
                  plan slot-count :type-tag clamsara:+tag-struct+)))
           (loop for value in values
                 for index in indices
                 for slot from 0
                 for current = (if (not (null index))
                                  (%make-maclina-reference
                                   vm (aref (clamsara::vm-root-vector vm) index))
                                  value)
                 do (clamsara:vm-set-reference
                     vm address slot (%encode-heap-value vm current)))
           (%make-maclina-reference vm address))
      (setf (fill-pointer (clamsara::vm-root-vector vm)) root-base))))

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
      (let* ((plan (maclina-client-plan client))
             (vm (clamsara:plan-vm plan))
             ;; A constructor is exposed as a macro so :slot names are quoted
             ;; before Maclina compiles the call.  Its hidden function remains a
             ;; normal Clostrum function closure.
             (constructor-function (gensym (format nil "%MAKE-~A-" name))))
        (setf (clostrum:fdefinition client environment constructor-function)
              (lambda (&rest arguments)
                (let ((values (make-list (length slots))))
                  (loop for (key value) on arguments by #'cddr
                        do (let ((index
                                   (position key slots :test #'string-equal
                                                    :key #'symbol-name)))
                             (if index
                                 (setf (nth index values) value)
                                 (error "Unknown or malformed ~A constructor key: ~S"
                                        constructor key))))
                  (%allocate-struct client (length slots) values))))
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
          (setf (clostrum:fdefinition client environment copier)
                (lambda (object)
                  (%allocate-struct
                   client (length slots)
                   (loop for index below (length slots)
                         collect (%struct-ref client object index))))))
        ;; Keep a type cell for TYPEP/TYPE-OF users that only need the name.
        ;; The fixed object representation is identified by +TAG-STRUCT+.
        (values name constructor predicate copier)))))

(defun %install-make-array-macro (client environment)
  ;; The host alias installed by EXTRINSICL has the useful element-type
  ;; resolution logic, but Maclina currently treats unquoted keyword names as
  ;; lexical variables.  Keep the alias under a private function name and
  ;; quote only keyword *names* in the public macro expansion.
  (let ((function-name (gensym "%MAKE-ARRAY-"))
        (function (clostrum:fdefinition client environment 'cl:make-array)))
    (setf (clostrum:fdefinition client environment function-name) function)
    (setf (clostrum:macro-function client environment 'cl:make-array)
          (lambda (form macro-environment)
            (declare (ignore macro-environment))
            `(funcall (function ,function-name)
                      ,@(cons (second form)
                              (%quote-maclina-keywords (cddr form))))))))

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
            (clostrum:fdefinition client environment 'cl:list) #'make-list*)
      ;; Fixed simple DEFSTRUCT support.  These are ordinary host closures,
      ;; but all payload words they manipulate live in the simulated heap.
      (setf (clostrum:fdefinition client environment '%make-struct-raw)
            (lambda (slot-count &rest values)
              (%allocate-struct client slot-count values))
            (clostrum:fdefinition client environment '%struct-ref)
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
