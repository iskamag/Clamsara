;;;; Optional Maclina adapter.
;;;;
;;;; Maclina remains a host compiler; its bytecode, lexical cells, and compiler
;;;; data are host objects, but the interpreter that RUNS that bytecode is the
;;;; client's own allocation-free execution substrate below (Maclina's
;;;; documented COMPUTE-INSTANCE-FUNCTION seam): boot-preallocated stacks,
;;;; frames, dynamic environments, and multiple-value areas, with immutable
;;;; direct-entry closures for host entry.  Measured Maclina execution
;;;; therefore allocates no host objects; the only residual per-call cost is
;;;; documented open CLOS dispatch on non-hot seams.  The overridden allocation
;;;; and mutation subset makes evaluated Lisp construct its cons, struct, and
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

(defconstant +maclina-global-cell-capacity+ 4096
  "Fixed registry size for global variable cells; see the substrate section.")

(defclass clamsara-maclina-client (maclina.vm-cross:client)
  ((plan :initarg :plan :reader maclina-client-plan)
   ;; Boot-preallocated registry of global variable cells.  Every cell cons
   ;; holding a special variable value is a GC root; see vm-scan-roots.
   (global-cells :initform (make-array +maclina-global-cell-capacity+)
                 :reader maclina-client-global-cells)
   (global-cell-count :initform 0
                      :accessor maclina-client-global-cell-count)))

(defvar *clamsara-maclina-client* nil)
(defvar *clamsara-maclina-environment* nil)

;;;; ---- Clamsara client execution substrate -------------------------------
;;;;
;;;; The upstream maclina.vm-cross driver allocates host objects on every
;;;; interpreted frame: a fresh CATCH tag cons, a fresh entry dynenv, a
;;;; heap-allocated dynenv-stack cons per dynamic binding, an argument list
;;;; per call (GATHER), and a multiple-value list per full call.  Those are
;;;; plain functions, not client methods, so a client cannot declaim them
;;;; away.  This substrate re-runs the same bytecode with the same linking
;;;; and compiler through Maclina's documented client seam
;;;; (COMPUTE-INSTANCE-FUNCTION), replacing each measured allocation with
;;;; boot-preallocated storage:
;;;;
;;;;   * stacks, frames, dynamic-environment stack, multiple-value area,
;;;;     and all dynenv/frame-tag pools are allocated once at setup;
;;;;   * host->Maclina entry uses immutable direct-entry closures whose
;;;;     template data is captured at function creation and whose &REST
;;;;     argument list is declared DYNAMIC-EXTENT;
;;;;   * VM->VM calls bind arguments in place on the preallocated stack
;;;;     (no marshalling list, no APPLY);
;;;;   * fixed small arities call host callees through FUNCALL directly;
;;;;   * frame identity and dynamic environments are unique fixnum ids
;;;;     into pooled storage, so captures that outlive their extent are
;;;;     detected by id comparison instead of object recycling.
;;;;
;;;; Remaining open CLOS dispatch is limited to documented seams: closure
;;;; creation, environment cell access, and the FDESIGNATOR opcode.

(defconstant +boot-dynenv-depth+ 1024
  "Boot-time dynamic-environment depth.  Exhaustion signals before mutation;
the execution path never grows this collector-client arena on the host.")

(defconstant +boot-frame-depth+ 1024
  "Boot-time frame-tag pool depth.  Exhaustion is explicit; no fallback cons
is permitted in an allocation-free entry.")

(defconstant +boot-values-capacity+ 64
  "Boot-time multiple-value area.  Wider multiple values grow by doubling.")

(defconstant +de-kind-entry+ 0)
(defconstant +de-kind-catch+ 1)
(defconstant +de-kind-sbind+ 2)
(defconstant +de-kind-progv+ 3)
(defconstant +de-kind-protection+ 4)

(defstruct (maclina-dynenv
            (:constructor %make-maclina-dynenv ()))
  ;; One pooled record per dynamic-environment slot.  Fields are unused
  ;; unless the record's kind matches; they are re-written at every push.
  (kind +de-kind-entry+ :type fixnum)
  (entry-tag nil)                       ; +DE-KIND-ENTRY+: owning frame tag
  (catch-tag nil)                       ; +DE-KIND-CATCH+: language tag
  (catch-dest-tag nil)                  ; frame tag to throw to
  (catch-dest 0 :type fixnum)           ; resume ip
  (sbind-global-cell nil)               ; +DE-KIND-SBIND+
  (sbind-cell nil)                      ; (value . old) binding cell
  (progv-mapping nil)                   ; +DE-KIND-PROGV+: alist
  (protect-cleanup nil))                ; +DE-KIND-PROTECTION+: thunk

(defstruct (maclina-machine
            (:constructor %make-maclina-machine
                (stack-size dynenv-depth values-capacity client)))
  (stack (make-array stack-size) :type simple-vector)
  (stack-top 0 :type (and unsigned-byte fixnum))
  (frame-pointer 0 :type (and unsigned-byte fixnum))
  (args 0 :type (and unsigned-byte fixnum))
  (arg-count 0 :type (and unsigned-byte fixnum))
  (pc 0 :type (and unsigned-byte fixnum))
  (depth 0 :type (and unsigned-byte fixnum))
  (next-dynenv-id 0 :type (and unsigned-byte fixnum))
  ;; dynamic-environment stack of unique ids; data lives in the pool
  (dynenv-stack (make-array dynenv-depth) :type simple-vector)
  (dynenv-top 0 :type (and unsigned-byte fixnum))
  (dynenv-pool (make-array dynenv-depth)
               :type simple-vector)     ; pooled maclina-dynenv records
  (sbind-cell-pool (make-array dynenv-depth)
                   :type simple-vector) ; pooled (value . old) cells
  (frame-tags (make-array +boot-frame-depth+)
              :type simple-vector)      ; unique frame tag objects
  (values (make-array values-capacity) :type simple-vector)
  (values-count 0 :type (and unsigned-byte fixnum))
  (values-save (make-array values-capacity) :type simple-vector)
  (values-save-count 0 :type (and unsigned-byte fixnum))
  (client nil))

(defvar *clamsara-maclina-machine* nil)
(declaim (type (or null maclina-machine) *clamsara-maclina-machine*))

(defun %initialize-execution-machine (stack-size client)
  "Boot-preallocate every execution structure the interpreter will reuse.
Nothing here is per-call work; it is setup, like compiling the substrate."
  (let* ((dynenv-depth +boot-dynenv-depth+)
         (machine
           (%make-maclina-machine stack-size dynenv-depth
                                  +boot-values-capacity+ client)))
    ;; Fill the boot pools: unique frame-tag objects and pooled dynenv
    ;; records, one per slot, allocated once and mutated in place forever.
    (dotimes (i +boot-frame-depth+)
      (setf (aref (maclina-machine-frame-tags machine) i) (cons nil nil)))
    (dotimes (i dynenv-depth)
      (setf (aref (maclina-machine-dynenv-pool machine) i)
            (%make-maclina-dynenv)
            (aref (maclina-machine-sbind-cell-pool machine) i)
            (cons nil nil)))
    (setf *clamsara-maclina-machine* machine)
    (values)))

(defun %grow-values (m minimum)
  "Report exhaustion of the boot-owned multiple-value area.
The historical name remains private so all capacity checks have one target;
it never grows storage during execution."
  (declare (ignore m))
  (error 'clamsara:heap-exhausted
         :requested-size minimum :space :maclina-values-area))

(defun %store-values (m list)
  "Copy LIST into the machine's multiple-value area; return the area.
The caller re-binds its local vector after every store because growth
replaces the vector."
  (let* ((n (length list))
         (vec (maclina-machine-values m)))
    (when (> n (length vec))
      (setf vec (%grow-values m n)))
    (let ((i 0))
      (dolist (v list)
        (setf (aref vec i) v)
        (incf i)))
    (setf (maclina-machine-values-count m) n)
    vec))

(defmacro %receive-all (machine call-form)
  "Evaluate CALL-FORM and store all its values without constructing a list."
  (let* ((m (gensym "MACHINE"))
         (vec (gensym "VALUES"))
         (receiver (gensym "RECEIVER"))
         (overflow (gensym "OVERFLOW"))
         (values (loop repeat 64
                       collect (gensym "VALUE")))
         (present (loop repeat 64
                        collect (gensym "PRESENT"))))
    `(let* ((,m ,machine)
            (,vec (maclina-machine-values ,m)))
       (flet ((,receiver
                  (&optional
                   ,@(loop for value in values
                           for supplied in present
                           collect `(,value nil ,supplied))
                   &rest ,overflow)
                ;; With at most the boot limit, the empty &REST tail is NIL.
                ;; The receiver closure and any overflow list have dynamic
                ;; extent, so successful calls do not enter the host heap.
                (declare (dynamic-extent ,overflow))
                (when ,overflow
                  (%grow-values ,m (1+ +maclina-multiple-values-limit+)))
                ,@(loop for value in values
                        for supplied in present
                        for i from 0
                        collect `(when ,supplied
                                   (setf (aref ,vec ,i) ,value)))
                (setf (maclina-machine-values-count ,m)
                      (cond
                        ,@(loop for supplied in (reverse present)
                                for n downfrom 64
                                collect `(,supplied ,n))
                        (t 0)))
                ,vec))
         (declare (dynamic-extent #',receiver))
         (multiple-value-call #',receiver ,call-form)))))

(defmacro %values-from-vector (vector count)
  "Return COUNT values from VECTOR without an intermediate sequence."
  `(case ,count
     ,@(loop for n from 0 to 64
             collect `(,n (values
                            ,@(loop for i below n
                                    collect `(aref ,vector ,i)))))
     (t (%grow-values nil ,count))))

(defun %return-frame-values (m)
  "Deliver the machine's preallocated value area as multiple values."
  (let ((count (maclina-machine-values-count m))
        (vec (maclina-machine-values m)))
    (%values-from-vector vec count)))


(defun %save-values (m)
  (let ((count (maclina-machine-values-count m))
        (vec (maclina-machine-values m))
        (save (maclina-machine-values-save m)))
    (when (> count (length save))
      (error 'clamsara:heap-exhausted
             :requested-size count :space :maclina-values-save-area))
    (dotimes (i count)
      (setf (aref save i) (aref vec i)))
    (setf (maclina-machine-values-save-count m) count)))

(defun %restore-values (m)
  (let ((count (maclina-machine-values-save-count m))
        (save (maclina-machine-values-save m))
        (vec (maclina-machine-values m)))
    (when (> count (length vec))
      (setf vec (%grow-values m count)))
    (dotimes (i count)
      (setf (aref vec i) (aref save i)))
    (setf (maclina-machine-values-count m) count)))

;; ---- dynamic environment --------------------------------------------------

(declaim (inline %de-push %de-pop))
(defun %de-push (m kind)
  "Claim the next dynamic-environment slot; return its pooled record.
The record's id is pushed, never the record: captures that outlive the
extent are detected by id, so pool recycling cannot alias an old exit."
  (let ((top (maclina-machine-dynenv-top m))
        (depth (length (maclina-machine-dynenv-stack m)))
        (de nil))
    (when (= top depth)
      (%grow-dynenv-stack m))
    (setf de (aref (maclina-machine-dynenv-pool m) top))
    (setf (maclina-dynenv-kind de) kind)
    (setf (aref (maclina-machine-dynenv-stack m) top)
          (maclina-machine-next-dynenv-id m))
    (incf (maclina-machine-next-dynenv-id m))
    (setf (maclina-machine-dynenv-top m) (1+ top))
    de))

(defun %de-pop (m)
  (let ((top (1- (maclina-machine-dynenv-top m))))
    (setf (maclina-machine-dynenv-top m) top)
    (aref (maclina-machine-dynenv-pool m) top)))

(defun %de-position (m dynenv-id)
  "Slot of DYNENV-ID on the de-stack, or NIL when out of extent."
  (let ((stack (maclina-machine-dynenv-stack m)))
    (loop for i below (maclina-machine-dynenv-top m)
          when (= (aref stack i) dynenv-id)
            return i)))

(defun %grow-dynenv-stack (m)
  "Report exhaustion of the boot-owned dynamic-environment arena.
Execution must never turn depth pressure into hidden host allocation."
  (error 'clamsara:heap-exhausted
         :requested-size (1+ (maclina-machine-dynenv-top m))
         :space :maclina-dynamic-environments))

(defun %frame-tag (m depth)
  "A unique object identifying the frame at nesting DEPTH.
Active frames occupy distinct depths, so pool slots never alias; the tag
object never escapes the substrate."
  (if (< depth +boot-frame-depth+)
      (aref (maclina-machine-frame-tags m) depth)
      (error 'clamsara:heap-exhausted
             :requested-size (1+ depth) :space :maclina-frame-tags)))

(defun %symbol-cell (m global-cell)
  "Innermost binding cell for GLOBAL-CELL, or GLOBAL-CELL itself."
  (let* ((top (maclina-machine-dynenv-top m))
         (pool (maclina-machine-dynenv-pool m)))
    (loop for i from (1- top) downto 0
          for de = (aref pool i)
          do (cond ((= (maclina-dynenv-kind de) +de-kind-sbind+)
                    (when (eq global-cell (maclina-dynenv-sbind-global-cell de))
                      (return (maclina-dynenv-sbind-cell de))))
                   ((= (maclina-dynenv-kind de) +de-kind-progv+)
                    (let ((pair (assoc global-cell
                                       (maclina-dynenv-progv-mapping de))))
                      (when pair
                        (return (cdr pair))))))
          finally (return global-cell))))

(defun %symbol-value (m symbol global-cell)
  (let* ((cell (%symbol-cell m global-cell))
         (value (car cell)))
    (if (eq value (cdr cell))
        (error 'maclina.vm-cross::unbound-variable :name symbol)
        value)))

(defun (setf %symbol-value) (new m symbol global-cell)
  (declare (ignore symbol))
  (let ((cell (%symbol-cell m global-cell)))
    (setf (car cell) new)))

(defun %boundp (m symbol global-cell)
  (declare (ignore symbol))
  (let ((cell (%symbol-cell m global-cell)))
    (not (eq (car cell) (cdr cell)))))

(defun %progv-push (m env varnames values)
  (let* ((client (maclina-machine-client m))
         (global-cells
           (loop for symbol in varnames
                 collect (clostrum:ensure-variable-cell client env symbol)))
         (mapping
           (loop for global-cell in global-cells
                 for value = (if (null values) maclina.vm-shared::*unbound*
                                 (pop values))
                 for cell = (cons value maclina.vm-shared::*unbound*)
                 collect (cons global-cell cell)))
         (de (%de-push m +de-kind-progv+)))
    (setf (maclina-dynenv-progv-mapping de) mapping)))

;; ---- non-local exits ------------------------------------------------------

(defun %unwind-to (m rtag new-ip new-top)
  "Pop dynamic environments down to NEW-TOP, running protection cleanups,
then throw RTAG/NEW-IP to the destination frame."
  (loop until (= (maclina-machine-dynenv-top m) new-top)
        do (let ((de (%de-pop m)))
             (when (= (maclina-dynenv-kind de) +de-kind-protection+)
               ;; Preserve the multiple-value area across the cleanup.
               (%save-values m)
               (funcall (maclina-dynenv-protect-cleanup de))
               (%restore-values m))))
  (throw rtag new-ip))

(defun %exit-to (m dynenv-id new-ip)
  (let ((position (%de-position m dynenv-id)))
    (if (null position)
        (error 'maclina.vm-cross::out-of-extent-unwind)
        (let* ((de (aref (maclina-machine-dynenv-pool m) position))
               (rtag (maclina-dynenv-entry-tag de)))
          ;; Preserve the ENTRY record itself.  The target's ENTRY-CLOSE
          ;; consumes it after control resumes; only younger environments
          ;; unwind here (the upstream list tail starts at ENTRY).
          (%unwind-to m rtag new-ip (1+ position))))))

(defun %throw-to (m tag)
  (let* ((top (maclina-machine-dynenv-top m))
         (pool (maclina-machine-dynenv-pool m))
         (position
           (loop for i from (1- top) downto 0
                 for de = (aref pool i)
                 when (and (= (maclina-dynenv-kind de) +de-kind-catch+)
                           (eq (maclina-dynenv-catch-tag de) tag))
                   return i)))
    (if (null position)
        (error 'maclina.vm-cross::no-catch-tag :tag tag)
        (let* ((de (aref pool position))
               (rtag (maclina-dynenv-catch-dest-tag de))
               (dest (maclina-dynenv-catch-dest de)))
          (%unwind-to m rtag dest position)))))

;; ---- frame execution ------------------------------------------------------

(defun %invoke-bytecode (module entry-pc frame-size closure-env args)
  "Host entry: copy dynamic-extent ARGS to the root-visible machine stack and
run one bytecode frame."
  (let ((m *clamsara-maclina-machine*))
    (unless m
      (error "No active Clamsara/Maclina execution machine"))
    (let* ((stack (maclina-machine-stack m))
           (base (maclina-machine-stack-top m))
           (old-args (maclina-machine-args m))
           (old-arg-count (maclina-machine-arg-count m))
           (n 0))
      (declare (fixnum n))
      (dolist (arg args)
        (setf (aref stack (+ base n)) arg)
        (incf n))
      (unwind-protect
           (progn
             (setf (maclina-machine-args m) base
                   (maclina-machine-arg-count m) n)
             (%run-frame m module closure-env entry-pc frame-size base))
        (setf (maclina-machine-args m) old-args
              (maclina-machine-arg-count m) old-arg-count
              (maclina-machine-stack-top m) base)))))

(defun %run-frame (m module closure-env entry-pc frame-size return-sp)
  "Run one bytecode frame and restore it to RETURN-SP on every exit."
  ;; RETURN-SP differs for host entry (the argument base) and VM calls (the
  ;; callee slot below the arguments).  It cannot be reconstructed from the
  ;; mutable current ARG-COUNT after nested calls.
  (let* ((old-fp (maclina-machine-frame-pointer m))
         (old-pc (maclina-machine-pc m))
         (old-de-top (maclina-machine-dynenv-top m))
         (old-depth (maclina-machine-depth m))
         (new-fp (+ (maclina-machine-args m)
                    (maclina-machine-arg-count m))))
    (setf (maclina-machine-frame-pointer m) new-fp
          (maclina-machine-pc m) entry-pc
          ;; Locals occupy [FP,FP+FRAME-SIZE); temporaries begin after them.
          (maclina-machine-stack-top m) (+ new-fp frame-size)
          (maclina-machine-depth m) (1+ old-depth))
    (unwind-protect
         (let ((tag (%frame-tag m old-depth)))
           (%run-bytecode-loop m module closure-env frame-size tag))
      (setf (maclina-machine-stack-top m) return-sp
            (maclina-machine-frame-pointer m) old-fp
            (maclina-machine-pc m) old-pc
            (maclina-machine-dynenv-top m) old-de-top
            (maclina-machine-depth m) old-depth))
    (%return-frame-values m)))

(defun %run-bytecode-loop (m module closure-env frame-size tag)
  ;; Opcode-for-opcode port of maclina.vm-cross::vm, with every measured
  ;; allocation replaced by preallocated storage (see the substrate header).
  (declare (optimize (speed 3) (safety 1) (debug 0)))
  (let* ((bytecode (maclina.machine:bytecode module))
         (constants (maclina.machine:literals module))
         (stack (maclina-machine-stack m))
         (vvec (maclina-machine-values m))
         (ip (maclina-machine-pc m))
         (sp (maclina-machine-stack-top m))
         (bp (maclina-machine-frame-pointer m))
         (timeout maclina.vm-cross::*timeout*))
    (declare (type (simple-array (unsigned-byte 8) (*)) bytecode)
             (type (simple-array t (*)) constants stack vvec)
             (type (and unsigned-byte fixnum) ip sp bp))
    (labels ((stack (index) (svref stack index))
             ((setf stack) (object index) (setf (svref stack index) object))
             (local (index) (svref stack (+ bp index)))
             ((setf local) (object index)
               (setf (svref stack (+ bp index)) object))
             (spush (object) (prog1 (setf (stack sp) object) (incf sp)))
             (spop () (stack (decf sp)))
             (bind (nvars base)
               (loop repeat nvars
                     for bsp downfrom (+ base nvars -1)
                     do (setf (local bsp) (spop))))
             (code () (aref bytecode ip))
             (next-code () (aref bytecode (incf ip)))
             (next-code-signed ()
               (logior (aref bytecode (+ ip 1))
                       (- (mask-field (byte 1 7) (aref bytecode (+ ip 1))))))
             (next-long ()
               (logior (next-code) (ash (next-code) 8)))
             (next-code-signed-16 ()
               (let ((v (+ (aref bytecode (+ ip 1))
                           (ash (aref bytecode (+ ip 2)) 8))))
                 (logior v (- (mask-field (byte 1 15) v)))))
             (next-code-signed-24 ()
               (let ((v (+ (aref bytecode (+ ip 1))
                           (ash (aref bytecode (+ ip 2)) 8)
                           (ash (aref bytecode (+ ip 3)) 16))))
                 (logior v (- (mask-field (byte 1 23) v)))))
             (constant (index) (aref constants index))
             (closure (index) (aref closure-env index))
             (gather (n)
               (let ((result nil))
                 (loop repeat n do (push (spop) result))
                 result))
             (save-sp-and-call (nargs)
               ;; Stack shape is CALLEE ARG0 ... ARG(N-1), with SP one past
               ;; the last argument.  Preserve the caller's argument window;
               ;; nested frame teardown and non-local exit must restore it.
               (let* ((callee-index (- sp nargs 1))
                      (args-base (1+ callee-index))
                      (callee (stack callee-index))
                      (caller-args (maclina-machine-args m))
                      (caller-arg-count (maclina-machine-arg-count m))
                      (call-top sp))
                 (declare (type function callee))
                 (setf sp callee-index)
                 (unwind-protect
                      (progn
                        (setf (maclina-machine-args m) args-base
                              (maclina-machine-arg-count m) nargs
                              ;; Host callees may collect.  Keep their argument
                              ;; references visible until the call returns.
                              (maclina-machine-stack-top m) call-top)
                        (if (typep callee
                                   '(or maclina.machine:function
                                     maclina.machine:closure))
                            (let* ((template
                                     (if (typep callee 'maclina.machine:closure)
                                         (maclina.machine:template callee)
                                         callee))
                                   (env
                                     (if (typep callee 'maclina.machine:closure)
                                         (maclina.machine:environment callee)
                                         #()))
                                   (submodule (maclina.machine:module template))
                                   (sub-entry (maclina.machine:entry-pc template))
                                   (sub-frame
                                     (maclina.machine:locals-frame-size template)))
                              (%run-frame m submodule env sub-entry sub-frame
                                          callee-index))
                            (case nargs
                              ((0) (funcall callee))
                              ((1) (funcall callee (stack args-base)))
                              ((2) (funcall callee
                                            (stack args-base)
                                            (stack (+ args-base 1))))
                              ((3) (funcall callee
                                            (stack args-base)
                                            (stack (+ args-base 1))
                                            (stack (+ args-base 2))))
                              ((4) (funcall callee
                                            (stack args-base)
                                            (stack (+ args-base 1))
                                            (stack (+ args-base 2))
                                            (stack (+ args-base 3))))
                              ((5) (funcall callee
                                            (stack args-base)
                                            (stack (+ args-base 1))
                                            (stack (+ args-base 2))
                                            (stack (+ args-base 3))
                                            (stack (+ args-base 4))))
                              ((6) (funcall callee
                                            (stack args-base)
                                            (stack (+ args-base 1))
                                            (stack (+ args-base 2))
                                            (stack (+ args-base 3))
                                            (stack (+ args-base 4))
                                            (stack (+ args-base 5))))
                              ((7) (funcall callee
                                            (stack args-base)
                                            (stack (+ args-base 1))
                                            (stack (+ args-base 2))
                                            (stack (+ args-base 3))
                                            (stack (+ args-base 4))
                                            (stack (+ args-base 5))
                                            (stack (+ args-base 6))))
                              ((8) (funcall callee
                                            (stack args-base)
                                            (stack (+ args-base 1))
                                            (stack (+ args-base 2))
                                            (stack (+ args-base 3))
                                            (stack (+ args-base 4))
                                            (stack (+ args-base 5))
                                            (stack (+ args-base 6))
                                            (stack (+ args-base 7))))
                              (t
                               (let ((arglist nil))
                                 (declare (dynamic-extent arglist))
                                 (do ((i (1- nargs) (1- i)))
                                     ((< i 0))
                                   (push (stack (+ args-base i)) arglist))
                                 (apply callee arglist))))))
                   (setf (maclina-machine-args m) caller-args
                         (maclina-machine-arg-count m) caller-arg-count
                         (maclina-machine-stack-top m) sp))))
             (call (nargs) (save-sp-and-call nargs)))
      (declare (inline stack (setf stack) local (setf local) spush spop bind
                       code next-code next-long constant closure call
                       next-code-signed next-code-signed-16
                       next-code-signed-24))
      (prog ((end (length bytecode))
             (trace maclina.vm-cross::*trace*))
       loop
         (when (>= ip end)
           (error "Invalid bytecode: Reached end"))
         (when timeout
           (when (> (incf maclina.vm-cross::*odometer*) timeout)
             (error 'maclina.vm-cross::timeout :timeout timeout)))
         (when trace
           (maclina.vm-cross::instruction-trace
            bytecode constants stack ip bp sp frame-size))
         (setf ip
               (catch tag
                 (case (code)
                   ((#.maclina.machine:ref)
                    (spush (local (next-code))) (incf ip))
                   ((#.maclina.machine:const)
                    (spush (constant (next-code))) (incf ip))
                   ((#.maclina.machine:closure)
                    (spush (closure (next-code))) (incf ip))
                   ((#.maclina.machine:call)
                    (setf vvec (%receive-all m (call (next-code))))
                    (incf ip))
                   ((#.maclina.machine:call-receive-one)
                    (spush (call (next-code)))
                    (incf ip))
                   ((#.maclina.machine:call-receive-fixed)
                    (let ((nargs (next-code)) (mvals (next-code)))
                      (case mvals
                        ((0) (call nargs))
                        (t
                         (setf vvec (%receive-all m (call nargs)))
                         (let ((n (min mvals
                                       (maclina-machine-values-count m))))
                           (dotimes (i n)
                             (spush (aref vvec i)))))))
                    (incf ip))
                   ((#.maclina.machine:bind) (bind (next-code) (next-code)) (incf ip))
                   ((#.maclina.machine:set)
                    (setf (local (next-code)) (spop))
                    (incf ip))
                   ((#.maclina.machine:make-cell)
                    (spush (maclina.vm-cross::make-cell (spop))) (incf ip))
                   ((#.maclina.machine:cell-ref)
                    (spush (maclina.vm-cross::cell-value (spop))) (incf ip))
                   ((#.maclina.machine:cell-set)
                    (setf (maclina.vm-cross::cell-value (spop)) (spop))
                    (incf ip))
                   ((#.maclina.machine:make-closure)
                    (spush (let ((template (constant (next-code))))
                             (maclina.machine:make-closure
                              (maclina-machine-client m)
                              template
                              (coerce (gather
                                       (maclina.machine:environment-size
                                        template))
                                      'simple-vector))))
                    (incf ip))
                   ((#.maclina.machine:make-uninitialized-closure)
                    (spush (let ((template (constant (next-code))))
                             (maclina.machine:make-closure
                              (maclina-machine-client m) template)))
                    (incf ip))
                   ((#.maclina.machine:initialize-closure)
                    (let ((env (maclina.machine:environment
                                (local (next-code)))))
                      (declare (type simple-vector env))
                      (loop for i from (1- (length env)) downto 0 do
                        (setf (aref env i) (spop))))
                    (incf ip))
                   ((#.maclina.machine:return)
                    (assert (eql sp (+ bp frame-size)))
                    (return))
                   ((#.maclina.machine:jump-8) (incf ip (next-code-signed)))
                   ((#.maclina.machine:jump-16) (incf ip (next-code-signed-16)))
                   ((#.maclina.machine:jump-24) (incf ip (next-code-signed-24)))
                   ((#.maclina.machine:jump-if-8)
                    (incf ip (if (spop) (next-code-signed) 2)))
                   ((#.maclina.machine:jump-if-16)
                    (incf ip (if (spop) (next-code-signed-16) 3)))
                   ((#.maclina.machine:jump-if-24)
                    (incf ip (if (spop) (next-code-signed-24) 4)))
                   ((#.maclina.machine:check-arg-count-<=)
                    (maclina.vm-shared:check-arg-count-<= (maclina-machine-arg-count m)
                                           (next-code))
                    (incf ip))
                   ((#.maclina.machine:check-arg-count->=)
                    (maclina.vm-shared:check-arg-count->= (maclina-machine-arg-count m)
                                           (next-code))
                    (incf ip))
                   ((#.maclina.machine:check-arg-count-=)
                    (maclina.vm-shared:check-arg-count-= (maclina-machine-arg-count m)
                                          (next-code))
                    (incf ip))
                   ((#.maclina.machine:jump-if-supplied-8)
                    (let ((arg (spop)))
                      (incf ip
                            (cond ((typep arg 'maclina.vm-shared:unbound-marker)
                                   2)
                                  (t (spush arg) (next-code-signed))))))
                   ((#.maclina.machine:jump-if-supplied-16)
                    (let ((arg (spop)))
                      (incf ip
                            (cond ((typep arg 'maclina.vm-shared:unbound-marker)
                                   3)
                                  (t (spush arg) (next-code-signed-16))))))
                   ((#.maclina.machine:bind-required-args)
                    (maclina.vm-shared:bind-required-args
                     (next-code) stack bp (maclina-machine-args m))
                    (incf ip))
                   ((#.maclina.machine:bind-optional-args)
                    (setf sp
                          (maclina.vm-shared:bind-optional-args
                           (next-code) (next-code) stack sp
                           (maclina-machine-args m)
                           (maclina-machine-arg-count m)))
                    (incf ip))
                   ((#.maclina.machine:listify-rest-args)
                    (spush
                     (maclina.vm-shared:listify-rest-args
                      (next-code) stack (maclina-machine-args m)
                      (maclina-machine-arg-count m)))
                    (incf ip))
                   ((#.maclina.machine:parse-key-args)
                    (let ((nfixed (next-code)) (key-count-info (next-code))
                          (key-literal-start (next-code)))
                      (setf sp
                            (maclina.vm-shared:parse-key-args
                             nfixed
                             (ash key-count-info -1)
                             (logbitp 0 key-count-info)
                             key-literal-start stack sp
                             (maclina-machine-arg-count m)
                             (maclina-machine-args m) constants)))
                    (incf ip))
                   ((#.maclina.machine:save-sp)
                    (setf (local (next-code)) sp)
                    (incf ip))
                   ((#.maclina.machine:restore-sp)
                    (setf sp (local (next-code)))
                    (incf ip))
                   ((#.maclina.machine:entry)
                    (let ((de (%de-push m +de-kind-entry+)))
                      (setf (maclina-dynenv-entry-tag de) tag)
                      (setf (local (next-code))
                            (aref (maclina-machine-dynenv-stack m)
                                  (1- (maclina-machine-dynenv-top m))))
                      (incf ip)))
                   ((#.maclina.machine:catch-8)
                    (let* ((target (+ ip (next-code-signed)))
                           (dest-tag tag)
                           (catch-tag (spop))
                           (de (%de-push m +de-kind-catch+)))
                      (setf (maclina-dynenv-catch-tag de) catch-tag
                            (maclina-dynenv-catch-dest-tag de) dest-tag
                            (maclina-dynenv-catch-dest de) target)
                      (incf ip 2)))
                   ((#.maclina.machine:catch-16)
                    (let* ((target (+ ip (next-code-signed-16)))
                           (dest-tag tag)
                           (catch-tag (spop))
                           (de (%de-push m +de-kind-catch+)))
                      (setf (maclina-dynenv-catch-tag de) catch-tag
                            (maclina-dynenv-catch-dest-tag de) dest-tag
                            (maclina-dynenv-catch-dest de) target)
                      (incf ip 3)))
                   ((#.maclina.machine:throw) (%throw-to m (spop)))
                   ((#.maclina.machine:catch-close)
                    (%de-pop m)
                    (incf ip))
                   ((#.maclina.machine:exit-8)
                    (incf ip (next-code-signed))
                    (%exit-to m (spop) ip))
                   ((#.maclina.machine:exit-16)
                    (incf ip (next-code-signed-16))
                    (%exit-to m (spop) ip))
                   ((#.maclina.machine:exit-24)
                    (incf ip (next-code-signed-24))
                    (%exit-to m (spop) ip))
                   ((#.maclina.machine:entry-close)
                    (%de-pop m)
                    (incf ip))
                   ((#.maclina.machine:special-bind)
                    (let ((value (spop))
                          (de (%de-push m +de-kind-sbind+))
                          (cell (aref (maclina-machine-sbind-cell-pool m)
                                      (1- (maclina-machine-dynenv-top m)))))
                      (setf (car cell) value
                            (cdr cell) maclina.vm-shared::*unbound*
                            (maclina-dynenv-sbind-global-cell de)
                            (cdr (constant (next-code)))
                            (maclina-dynenv-sbind-cell de) cell))
                    (incf ip))
                   ((#.maclina.machine:symbol-value)
                    (let ((vcell (constant (next-code))))
                      (spush (%symbol-value m (car vcell) (cdr vcell))))
                    (incf ip))
                   ((#.maclina.machine:symbol-value-set)
                    (let ((vcell (constant (next-code))))
                      (setf (%symbol-value m (car vcell) (cdr vcell))
                            (spop)))
                    (incf ip))
                   ((#.maclina.machine:progv)
                    (let* ((env (constant (next-code)))
                           (values (spop)) (varnames (spop)))
                      (%progv-push m env varnames values))
                    (incf ip))
                   ((#.maclina.machine:unbind)
                    (%de-pop m)
                    (incf ip))
                   ((#.maclina.machine:push-values)
                    (let ((n (maclina-machine-values-count m)))
                      (dotimes (i n) (spush (aref vvec i)))
                      (spush n))
                    (incf ip))
                   ((#.maclina.machine:append-values)
                    (let ((n (spop)))
                      (declare (type (and unsigned-byte fixnum) n))
                      (let ((count (maclina-machine-values-count m)))
                        (dotimes (i count) (spush (aref vvec i)))
                        (spush (+ n count))))
                    (incf ip))
                   ((#.maclina.machine:pop-values)
                    (let ((n (spop)))
                      (declare (type (and unsigned-byte fixnum) n))
                      (when (> n (length vvec))
                        (setf vvec (%grow-values m n)))
                      (decf sp n)
                      (dotimes (i n)
                        (setf (aref vvec i) (stack (+ sp i))))
                      (setf (maclina-machine-values-count m) n))
                    (incf ip))
                   ((#.maclina.machine:mv-call)
                    (setf vvec (%receive-all m (call (spop))))
                    (incf ip))
                   ((#.maclina.machine:mv-call-receive-one)
                    (spush (call (spop)))
                    (incf ip))
                   ((#.maclina.machine:mv-call-receive-fixed)
                    (let ((mvals (next-code)))
                      (case mvals
                        ((0) (call (spop)))
                        (t
                         (setf vvec (%receive-all m (call (spop))))
                         (let ((n (min mvals
                                       (maclina-machine-values-count m))))
                           (dotimes (i n)
                             (spush (aref vvec i)))))))
                    (incf ip))
                   ((#.maclina.machine:fdefinition
                     #.maclina.machine:called-fdefinition)
                    (spush (car (constant (next-code)))) (incf ip))
                   ((#.maclina.machine:nil) (spush nil) (incf ip))
                   ((#.maclina.machine:eq) (spush (eq (spop) (spop))) (incf ip))
                   ((#.maclina.machine:pop)
                    (let ((v (spop)))
                      (setf (aref vvec 0) v
                            (maclina-machine-values-count m) 1))
                    (incf ip))
                   ((#.maclina.machine:push)
                    (spush (if (zerop (maclina-machine-values-count m))
                               nil
                               (aref vvec 0)))
                    (incf ip))
                   ((#.maclina.machine:dup)
                    (let ((v (spop))) (spush v) (spush v)) (incf ip))
                   ((#.maclina.machine:fdesignator)
                    (let ((desig (spop)))
                      (spush
                       (etypecase desig
                         (function (incf ip) desig)
                         (symbol
                          (clostrum:fdefinition
                           (maclina-machine-client m) (constant (next-code))
                           desig)))))
                    (incf ip))
                   ((#.maclina.machine:protect)
                    (let* ((template (constant (next-code)))
                           (envsize (maclina.machine:environment-size template))
                           (cleanup-thunk
                             (maclina.machine:make-closure
                              (maclina-machine-client m) template
                              (coerce (gather envsize) 'simple-vector)))
                           (de (%de-push m +de-kind-protection+)))
                      (setf (maclina-dynenv-protect-cleanup de) cleanup-thunk))
                    (incf ip))
                   ((#.maclina.machine:cleanup)
                    (let ((de (%de-pop m)))
                      (%save-values m)
                      (setf (maclina-machine-stack-top m) sp)
                      (funcall (maclina-dynenv-protect-cleanup de))
                      (%restore-values m))
                    (incf ip))
                   ((#.maclina.machine:encell)
                    (let ((index (next-code)))
                      (setf (local index)
                            (maclina.vm-cross::make-cell (local index))))
                    (incf ip))
                   ((#.maclina.machine:long)
                    (case (next-code)
                      (#.maclina.machine:ref (spush (local (next-long))) (incf ip))
                      (#.maclina.machine:const (spush (constant (next-long))) (incf ip))
                      (#.maclina.machine:closure (spush (closure (next-long))) (incf ip))
                      (#.maclina.machine:call
                       (setf vvec (%receive-all m (call (next-long))))
                       (incf ip))
                      (#.maclina.machine:call-receive-one
                       (spush (call (next-long))) (incf ip))
                      (#.maclina.machine:call-receive-fixed
                       (let ((nargs (next-long)) (mvals (next-long)))
                         (case mvals
                           ((0) (call nargs))
                           (t
                            (setf vvec (%receive-all m (call nargs)))
                            (let ((n (min mvals
                                          (maclina-machine-values-count m))))
                              (dotimes (i n)
                                (spush (aref vvec i)))))))
                       (incf ip))
                      (#.maclina.machine:bind (bind (next-long) (next-long)) (incf ip))
                      (#.maclina.machine:set
                       (setf (local (next-long)) (spop))
                       (incf ip))
                      (#.maclina.machine:make-closure
                       (spush (let ((template (constant (next-long))))
                                (maclina.machine:make-closure
                                 (maclina-machine-client m)
                                 template
                                 (coerce (gather
                                          (maclina.machine:environment-size
                                           template))
                                         'simple-vector))))
                       (incf ip))
                      (#.maclina.machine:make-uninitialized-closure
                       (spush (let ((template (constant (next-long))))
                                (maclina.machine:make-closure
                                 (maclina-machine-client m) template)))
                       (incf ip))
                      (#.maclina.machine:initialize-closure
                       (let ((env (maclina.machine:environment
                                   (local (next-long)))))
                         (declare (type simple-vector env))
                         (loop for i from (1- (length env)) downto 0 do
                           (setf (aref env i) (spop))))
                       (incf ip))
                      (#.maclina.machine:bind-required-args
                       (maclina.vm-shared:bind-required-args
                        (next-long) stack bp (maclina-machine-args m))
                       (incf ip))
                      (#.maclina.machine:bind-optional-args
                       (setf sp
                             (maclina.vm-shared:bind-optional-args
                              (next-long) (next-long) stack sp
                              (maclina-machine-args m)
                              (maclina-machine-arg-count m)))
                       (incf ip))
                      (#.maclina.machine:listify-rest-args
                       (spush
                        (maclina.vm-shared:listify-rest-args
                         (next-long) stack (maclina-machine-args m)
                         (maclina-machine-arg-count m)))
                       (incf ip))
                      (#.maclina.machine:parse-key-args
                       (let ((nfixed (next-long)) (key-count-info (next-long))
                             (key-literal-start (next-long)))
                         (setf sp
                               (maclina.vm-shared:parse-key-args
                                nfixed
                                (ash key-count-info -1)
                                (logbitp 0 key-count-info)
                                key-literal-start stack sp
                                (maclina-machine-arg-count m)
                                (maclina-machine-args m) constants)))
                       (incf ip))
                      (#.maclina.machine:check-arg-count-<=
                       (maclina.vm-shared:check-arg-count-<= (maclina-machine-arg-count m)
                                              (next-long))
                       (incf ip))
                      (#.maclina.machine:check-arg-count->=
                       (maclina.vm-shared:check-arg-count->= (maclina-machine-arg-count m)
                                              (next-long))
                       (incf ip))
                      (#.maclina.machine:check-arg-count-=
                       (maclina.vm-shared:check-arg-count-= (maclina-machine-arg-count m)
                                             (next-long))
                       (incf ip))
                      ((#.maclina.machine:fdefinition
                        #.maclina.machine:called-fdefinition)
                       (spush (car (constant (next-long)))) (incf ip))
                      (otherwise
                       (error 'maclina.machine:unknown-long-opcode
                              :opcode (code)))))
                   (otherwise
                    (error 'maclina.machine:unknown-opcode :opcode (code))))
                 (go loop)))
         (go loop)))))

;; Immutable direct-entry closures: template data captured at creation; the
;; &REST argument list is dynamic-extent and walked onto the preallocated
;; stack inside the same frame, so host entry allocates nothing for the
;; common arities (and never for zero arguments).
(defmethod maclina.machine:compute-instance-function
    ((client clamsara-maclina-client) (fun maclina.machine:function))
  (declare (ignore client))
  (let ((module (maclina.machine:module fun))
        (entry-pc (maclina.machine:entry-pc fun))
        (frame-size (maclina.machine:locals-frame-size fun)))
    (lambda (&rest args)
      (declare (dynamic-extent args))
      (%invoke-bytecode module entry-pc frame-size #() args))))

(defmethod maclina.machine:compute-instance-function
    ((client clamsara-maclina-client) (closure maclina.machine:closure))
  (declare (ignore client))
  (let* ((template (maclina.machine:template closure))
         (module (maclina.machine:module template))
         (entry-pc (maclina.machine:entry-pc template))
         (frame-size (maclina.machine:locals-frame-size template))
         (closure-env (maclina.machine:environment closure)))
    (lambda (&rest args)
      (declare (dynamic-extent args))
      (%invoke-bytecode module entry-pc frame-size closure-env args))))

;; Special variable protocol over the client-owned de-stack.  The upstream
;; vm-cross methods read maclina.vm-cross::*vm*, which this substrate does
;; not drive.
(defmethod maclina.machine:symbol-value
    ((client clamsara-maclina-client) env symbol)
  (let ((cell (clostrum:ensure-variable-cell client env symbol)))
    (%symbol-value *clamsara-maclina-machine* symbol cell)))
(defmethod (setf maclina.machine:symbol-value)
    (new (client clamsara-maclina-client) env symbol)
  (let ((cell (clostrum:ensure-variable-cell client env symbol)))
    (setf (%symbol-value *clamsara-maclina-machine* symbol cell) new)))
(defmethod maclina.machine:boundp
    ((client clamsara-maclina-client) env symbol)
  (%boundp *clamsara-maclina-machine* symbol
           (clostrum:ensure-variable-cell client env symbol)))
(defmethod maclina.machine:makunbound
    ((client clamsara-maclina-client) env symbol)
  (let* ((m *clamsara-maclina-machine*)
         (cell (%symbol-cell m
                             (clostrum:ensure-variable-cell client env symbol))))
    (setf (car cell) (cdr cell)))
  symbol)
(defmethod maclina.machine:call-with-progv
    ((client clamsara-maclina-client) env symbols values thunk)
  (%progv-push *clamsara-maclina-machine* env symbols values)
  (unwind-protect (funcall thunk)
    (%de-pop *clamsara-maclina-machine*)))


;; ---- global variable cells as registered roots ----------------------------
;;
;; A Maclina special variable's value lives in its Clostrum cell cons.  The
;; interpreter dereferences those cells at SYMBOL-VALUE, so a cell holding a
;; simulated reference must be a GC root.  Every cell is registered once when
;; created (or when discovered right after EXTRINSICL:INSTALL-CL) in a
;; boot-preallocated vector; capacity exhaustion is an explicit error, never
;; a silent root loss.

(defun %register-global-cell (client cell)
  (let ((cells (maclina-client-global-cells client))
        (count (maclina-client-global-cell-count client)))
    (when (>= count (length cells))
      (error "Clamsara/Maclina global variable cell registry exhausted ~
              (~d cells); raise +maclina-global-cell-capacity+"
             count))
    (setf (aref cells count) cell)
    (setf (maclina-client-global-cell-count client) (1+ count))
    cell))

(defmethod clostrum-basic:make-variable-cell
    ((client clamsara-maclina-client) environment name)
  (declare (ignore environment name))
  (%register-global-cell client (call-next-method)))

(defun %enumerate-initial-global-cells (client environment)
  "Register the cells EXTRINSICL:INSTALL-CL created before the client's
make-variable-cell method was in effect."
  (let ((table (clostrum-basic::variables environment)))
    (loop for name being each hash-key of table
          for entry = (gethash name table)
          when (and entry (slot-boundp entry 'clostrum-basic::cell))
            do (%register-global-cell client (clostrum-basic::cell entry))))
  (values))

;; ---- v11 root-location protocol over registered cells ----------------------
;;
;; Location encoding reuses the vm-binding shape (vector id in the high bits,
;; cell index in the low 40); registry cells use an id far above any region
;; count.  A location is enumerable iff its cell currently holds a tagged
;; reference, so language integers and NIL are never presented as roots.
;; Non-cell locations fall through to the simulator methods.

(defconstant +maclina-cell-vector-id+ (ash 1 20))

(defun %maclina-cell-location-p (location)
  (and (typep location 'fixnum)
       (= (ash location -40) +maclina-cell-vector-id+)))

(defun %maclina-cell-location (index)
  (logior (ash +maclina-cell-vector-id+ 40) index))

(defun %maclina-cell-for-location (location what)
  (unless (%maclina-cell-location-p location)
    (error 'clamsara:clamsara-error
           :message (format nil "~a: location ~s is not a Maclina cell" what location)))
  (let* ((index (logand location (1- (ash 1 40))))
         (client *clamsara-maclina-client*))
    (unless (and client (< -1 index (maclina-client-global-cell-count client)))
      (error 'clamsara:clamsara-error
             :message (format nil "~a: Maclina cell location ~s is unregistered" what location)))
    (aref (maclina-client-global-cells client) index)))

(defmethod clamsara-protocol.roots:map-root-locations ((vm maclina-vm) function)
  ;; Legacy locations first (root vector and regions), then registry cells.
  (call-next-method)
  (let ((client *clamsara-maclina-client*))
    (when client
      (let ((cells (maclina-client-global-cells client)))
        (dotimes (i (maclina-client-global-cell-count client))
          (when (%maclina-reference-p vm (car (aref cells i)))
            (funcall function (%maclina-cell-location i)))))))
  vm)

(defmethod clamsara-protocol.roots:load-root ((vm maclina-vm) root-location)
  (if (%maclina-cell-location-p root-location)
      (car (%maclina-cell-for-location root-location "load-root"))
      (call-next-method)))

(defmethod clamsara-protocol.roots:store-root ((vm maclina-vm) root-location reference)
  (if (%maclina-cell-location-p root-location)
      (let ((cell (%maclina-cell-for-location root-location "store-root")))
        (unless (%maclina-reference-p vm reference)
          (error 'clamsara:clamsara-error
                 :message "store-root: value is not a simulated reference"))
        (setf (car cell) reference)
        reference)
      (call-next-method)))

(defmethod clamsara-protocol.roots:root-location-kind ((vm maclina-vm) root-location)
  (if (%maclina-cell-location-p root-location)
      :maclina-global-cell
      (call-next-method)))

;; Extrinsicl's default PROCESS-TYPE-SPECIFIER method names its second and
;; third parameters in reverse order and consequently passes TYPE as the
;; environment to RESOLVE-TYPE.  Keep the upstream checkout untouched and
;; repair the seam for this client specialization.
(defmethod extrinsicl::process-type-specifier
    ((client clamsara-maclina-client) environment type-specifier)
  (extrinsicl::resolve-type client environment type-specifier))

;; ---- ANSI proclamation shorthand -------------------------------------------
;;
;; (PROCLAIM '(FIXNUM X Y)) is shorthand for (PROCLAIM '(TYPE FIXNUM X Y)).
;; Canonicalize before the installed PROCLAIM sees it so STAK-style type
;; proclamations are accepted.

(defun %canonicalize-proclamation (declaration)
  (if (and (consp declaration)
           (symbolp (first declaration))
           (not (member (first declaration)
                        '(cl:type cl:ftype cl:special cl:inline cl:notinline
                          cl:optimize cl:declaration))))
      (cons 'cl:type declaration)
      declaration))

(defun %install-canonicalizing-proclaim (client environment)
  (let ((proclaim-fn (clostrum:fdefinition client environment 'cl:proclaim)))
    (setf (clostrum:fdefinition client environment 'cl:proclaim)
          (lambda (declaration)
            (funcall proclaim-fn
                     (%canonicalize-proclamation declaration))))
    (values)))

;; ---- setup-time compilation for benchmark runners ---------------------------
;;
;; READ-FROM-STRING, compilation, linking, and any setup must happen once,
;; outside a measured window.  These entries read and compile once and return
;; the bound direct-entry function; each later call runs that entry with no
;; reader, compiler, or linker work.  Calling the result reproduces
;; CLAMSARA-MACLINA-EVAL-STRING's semantics for the form: EVAL itself
;; compiles (LAMBDA () form) and funcalls it.

(defun clamsara-maclina-compile-form (form)
  "Compile FORM once as a zero-argument Maclina function; return the entry.
Every later call of the returned function evaluates FORM through Maclina,
identically to CLAMSARA-MACLINA-EVAL of FORM."
  (unless (and *clamsara-maclina-client*
               *clamsara-maclina-environment*)
    (error "No active Clamsara/Maclina environment"))
  (funcall (clostrum:fdefinition
            *clamsara-maclina-client*
            *clamsara-maclina-environment*
            'cl:compile)
           nil
           `(lambda () ,form)))

(defun clamsara-maclina-compile-string (string)
  "Read STRING once and compile it as a zero-argument Maclina function.
Setup-time: reading, compiling, and linking happen here.  Each later call of
the returned function is a direct Maclina entry with no read/compile work."
  (clamsara-maclina-compile-form (read-from-string string)))


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
  "Extend the explicit root vector with the client execution machine's live
state: the preallocated VM stack up to its top, the multiple-value area, the
active dynamic-environment records (special-binding cells, progv mappings,
catch tags, cleanup thunks), and every registered global variable cell.
Maclina does not expose stack maps, so the stack scan is conservative; the
machine's own structures are scanned exactly."
  (call-next-method)
  (let ((machine *clamsara-maclina-machine*))
    (when machine
      (let* ((stack (maclina-machine-stack machine))
             (top (maclina-machine-stack-top machine)))
        (%map-vector-roots vm collector-state fn stack 0 top)
        (loop for i below top
              do (%map-closure-roots
                  vm collector-state fn (aref stack i)))
        (let ((vvec (maclina-machine-values machine)))
          (%map-vector-roots
           vm collector-state fn vvec 0 (maclina-machine-values-count machine)))
        (let ((pool (maclina-machine-dynenv-pool machine)))
          (loop for i below (maclina-machine-dynenv-top machine)
                for de = (aref pool i)
                for kind = (maclina-dynenv-kind de)
                do (cond ((= kind +de-kind-catch+)
                          (setf (maclina-dynenv-catch-tag de)
                                (%map-root vm collector-state fn
                                           (maclina-dynenv-catch-tag de))))
                         ((= kind +de-kind-sbind+)
                          (%map-list-roots
                           vm collector-state fn
                           (maclina-dynenv-sbind-cell de)))
                         ((= kind +de-kind-progv+)
                          (loop for pair in (maclina-dynenv-progv-mapping de)
                                do (%map-list-roots
                                    vm collector-state fn (cdr pair))))
                         ((= kind +de-kind-protection+)
                          (%map-closure-roots
                           vm collector-state fn
                           (maclina-dynenv-protect-cleanup de)))))))))
  (let ((client *clamsara-maclina-client*))
    (when client
      (let ((cells (maclina-client-global-cells client)))
        (loop for i below (maclina-client-global-cell-count client)
              for cell = (aref cells i)
              do (setf (car cell)
                       (%map-root vm collector-state fn (car cell)))))))
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
The eight arguments cover the supported simple DEFSTRUCT subset.  Values and
root indices stay in fixed lexical slots; no host argument, value, or pin
vector is manufactured per simulated object."
  (when (> slot-count 8)
    (error "Simple simulated DEFSTRUCT supports at most eight slots"))
  (let* ((plan (maclina-client-plan client))
         (vm (clamsara:plan-vm plan))
         (root-base (length (clamsara::vm-root-vector vm)))
         ;; Capture each pin decision before ALLOCATE-OBJECT can collect.  A
         ;; post-GC stale original is never re-tested; its root slot is the
         ;; authority.  LET* preserves argument order without a host vector.
         (p0 (and (> slot-count 0) (%maclina-reference-p vm v0)
                  (%pin-root vm v0)))
         (p1 (and (> slot-count 1) (%maclina-reference-p vm v1)
                  (%pin-root vm v1)))
         (p2 (and (> slot-count 2) (%maclina-reference-p vm v2)
                  (%pin-root vm v2)))
         (p3 (and (> slot-count 3) (%maclina-reference-p vm v3)
                  (%pin-root vm v3)))
         (p4 (and (> slot-count 4) (%maclina-reference-p vm v4)
                  (%pin-root vm v4)))
         (p5 (and (> slot-count 5) (%maclina-reference-p vm v5)
                  (%pin-root vm v5)))
         (p6 (and (> slot-count 6) (%maclina-reference-p vm v6)
                  (%pin-root vm v6)))
         (p7 (and (> slot-count 7) (%maclina-reference-p vm v7)
                  (%pin-root vm v7))))
    (unwind-protect
         (let ((address
                 (clamsara::allocate-object
                  plan slot-count :type-tag clamsara:+tag-struct+)))
           (dotimes (slot slot-count)
             (let ((value (case slot
                            (0 v0) (1 v1) (2 v2) (3 v3)
                            (4 v4) (5 v5) (6 v6) (7 v7)))
                   (root-index (case slot
                                 (0 p0) (1 p1) (2 p2) (3 p3)
                                 (4 p4) (5 p5) (6 p6) (7 p7))))
               (clamsara:vm-set-reference
                vm address slot
                (%encode-heap-value
                 vm (if root-index
                        (%make-maclina-reference
                         vm (aref (clamsara::vm-root-vector vm) root-index))
                        value)))))
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
               ;; FUNCALL/APPLY fallback and the callee of last resort.
               ;; The &REST list is the caller's own host argument sequence --
               ;; an indefinite-arity function cannot refuse one -- but it is
               ;; walked by recursion, never copied by REVERSE, and declared
               ;; DYNAMIC-EXTENT so hosts that honour the declaration do not
               ;; heap-allocate it.  Direct source calls never reach this
               ;; cell: the compiler macro below expands them to nested CONS.
               (declare (dynamic-extent values))
               (labels ((build (rest)
                          (if (null rest)
                              nil
                              (cons* (car rest) (build (cdr rest))))))
                 (build values))))
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
      ;; Source-language LIST is expanded at COMPILE time into nested
      ;; simulated CONS (keywords quoted per Maclina's keyword-argument
      ;; quirk, like the DEFSTRUCT constructor macro), so a direct call
      ;; never builds a host argument list.  This is a compiler macro, not
      ;; a macro: clostrum-basic keeps one operator cell per name, so a
      ;; macro would replace the function definition and break
      ;; (FUNCALL #'LIST ...) -- the compiler macro is exactly the ANSI
      ;; seam that optimizes direct calls while FDEFINITION stays the
      ;; correct FUNCALL/APPLY fallback above.  Returning the original form
      ;; would leave the ordinary function call in place.
      (setf (clostrum:compiler-macro-function client environment 'cl:list)
            (lambda (form &optional macro-environment)
              (declare (ignore macro-environment))
              (labels ((expand (args)
                         (if (null args)
                             nil
                             `(cl:cons ,(if (keywordp (first args))
                                            `(quote ,(first args))
                                            (first args))
                                       ,(expand (rest args))))))
                (expand (rest form)))))
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
    ;; INSTALL-CL used the native client, so register those existing cells.
    (%enumerate-initial-global-cells client environment)
    ;; INSTALL-CL also closed SYMBOL-VALUE and its setter over that native
    ;; client.  Reinstall only the environment accessors over the Maclina
    ;; client.  Otherwise DEFPARAMETER/SETQ reaches EXTRINSICL with a
    ;; TRUCLER-NATIVE:CLIENT and cannot access simulated value cells.
    (extrinsicl::install-environment-accessors client environment)
    ;; Rebind PROCLAIM to the Maclina client as well.  INSTALL-CL captured the
    ;; temporary native client in its closure.
    (extrinsicl::install-proclaim client environment)
    (extrinsicl.maclina:install-eval client environment)
    (setf maclina.machine:*client* client)
    ;; Boot-preallocate the execution substrate: stack, dynamic-environment
    ;; stack, pools, and multiple-value area are setup, not per-call work.
    (%initialize-execution-machine stack-size client)
    (%install-canonicalizing-proclaim client environment)
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
