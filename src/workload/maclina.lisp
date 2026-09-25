;;;; src/workload/maclina.lisp -- Maclina interpreter over v14.
;;;;
;;;; Maclina remains the compiler/bytecode engine.  Guest CONS, ARRAY and
;;;; STRUCT payloads are allocated only through the v14 context; the host CL
;;;; objects used by Maclina for code, environments and closures are not
;;;; silently treated as managed references.  The Maclina/Trucler generic
;;;; extensions, including the compiler-private macro seam, are a documented
;;;; integration boundary of this adapter.

(in-package #:clamsara)

(defclass workload-maclina-client (maclina.vm-cross:client)
  ((workload :initarg :workload :reader workload-client-workload)
   (global-cells :initform (make-array 4096 :initial-element nil)
                 :reader workload-client-global-cells)
   (global-cell-count :initform 0 :accessor workload-client-global-cell-count)
   (properties :initform (make-hash-table :test #'equal)
               :reader workload-client-properties)
   ;; Compiler-control functions, not guest payload or a guest heap registry.
   (source-operators :initform (make-hash-table :test #'eq)
                     :reader workload-client-source-operators)
   (cleanup-templates :initform (make-hash-table :test #'eq)
                      :reader workload-client-cleanup-templates)))

(defvar *workload-environment* nil)
(defvar *workload-read-depth* 0)

(defvar *workload-source-execution-p* nil)

(defmethod maclina.compile::compile-combination :around
    ((description trucler:macro-description) form environment context)
  (declare (ignore description form environment context))
  ;; Maclina invokes macro bodies through the VM. Its source forms are host
  ;; syntax objects, not guest heap objects. Bind this distinction only while
  ;; the compiler expands a macro; ordinary workload execution never sets it.
  ;; This extends a generic without replacing its existing methods/functions.
  (if (typep maclina.machine:*client* 'workload-maclina-client)
      (let ((*workload-source-execution-p* t)) (call-next-method))
      (call-next-method)))

(defmethod maclina.machine:compute-instance-function :around
    ((client workload-maclina-client) (function maclina.machine:function))
  (let ((entry (call-next-method)))
    (lambda (&rest arguments)
      (declare (dynamic-extent arguments))
      (let ((source-entry
              (and *workload-source-execution-p*
                   (gethash function (workload-client-source-operators client)))))
        ;; Keep the original Maclina function object and closure environment
        ;; visible. Do not hide them behind a replacement fdefinition closure.
        (%call-with-workload-function client function
                                      (or source-entry entry) arguments)))))

(defun %workload-cxr-name-p (name)
  (and (symbolp name) (eq (symbol-package name) (find-package :common-lisp))
       (let* ((text (symbol-name name)) (length (length text)))
         (and (<= 4 length 6) (char= #\C (char text 0))
              (char= #\R (char text (1- length)))
              (loop for i from 1 below (1- length)
                    always (find (char text i) "AD"))))))

(defun %workload-install-data-function (client runtime name function)
  (let ((source-entry
          (and (or (%workload-cxr-name-p name)
                   (member name '(cl:cons cl:car cl:cdr cl:consp cl:atom
                              cl:rplaca cl:rplacd cl:list cl:length
                              cl:mapcar cl:mapc cl:member cl:assoc cl:append
                              cl:nconc cl:reverse cl:subst cl:copy-tree cl:equal
                              cl:aref (setf cl:aref) cl:make-array cl:arrayp
                              cl:vectorp cl:array-element-type)
                           :test #'equal))
               (fdefinition name))))
    (setf (clostrum:fdefinition client runtime name)
          (cond
            ((typep function 'maclina.machine:function)
             (when source-entry
               (setf (gethash function (workload-client-source-operators client))
                     source-entry))
             function)
            (source-entry
             (lambda (&rest arguments)
               (declare (dynamic-extent arguments))
               (apply (if *workload-source-execution-p* source-entry function)
                      arguments)))
            (t function)))))


(defmethod trucler:describe-variable
    ((client workload-maclina-client) (environment clostrum:environment) name)
  ;; Keywords are self-evaluating constants, not unknown special variables.
  ;; Describe them directly: no mutable global cell or host-environment fallback.
  (if (keywordp name)
      (make-instance 'trucler:constant-variable-description
                     :name name :value name)
      (call-next-method)))

(defun %register-global-cell (client cell)
  (let* ((cells (workload-client-global-cells client))
         (count (workload-client-global-cell-count client)))
    (when (>= count (length cells))
      (error 'workload-capability-error :operation 'global-root-provider
             :reason :capacity-exhausted))
    (setf (aref cells count) cell
          (workload-client-global-cell-count client) (1+ count))
    cell))

(defmethod clostrum-basic:make-variable-cell
    ((client workload-maclina-client) environment name)
  (declare (ignore environment name))
  (%register-global-cell client (call-next-method)))

(defun %register-existing-global-cells (client runtime)
  (let ((table (clostrum-basic::variables runtime)))
    (loop for name being each hash-key of table
          for entry = (gethash name table)
          when (and entry (slot-boundp entry 'clostrum-basic::cell))
            do (%register-global-cell client (clostrum-basic::cell entry))))
  client)

(defun %guest-ref-p (environment value)
  (and (not (null value))
       (valid-reference-p (workload-model environment) value)))

(defun %description-p (environment value kind-name)
  (and (%guest-ref-p environment value)
       (eq (object-kind (workload-model environment) value)
           (workload-kind-description (%workload-kind environment kind-name)))))

(defun %guest-cons-p (environment value)
  (%description-p environment value :cons))

(defun %guest-array-kind-name (environment value)
  (loop for name in '(:array :array-single-float :array-integer)
        for kind = (getf (workload-kinds environment) name)
        when (and kind (%guest-ref-p environment value)
                  (eq (object-kind (workload-model environment) value)
                      (workload-kind-description kind)))
          do (return name)))

(defun %guest-array-p (environment value)
  (not (null (%guest-array-kind-name environment value))))

(defun %guest-array-numeric-p (environment value)
  (let ((name (%guest-array-kind-name environment value)))
    (member name '(:array-single-float :array-integer))))

(defun %assert-numeric-array-element (environment array value)
  "Reject values with no guest-resident numeric representation.

The indexed numeric payload is a raw word plane.  Fixnums and single-floats
are the only numeric values admitted by the workload bridge; boxed integers,
ratios, double-floats, and other host numeric objects must not masquerade as
guest values."
  (let ((kind (%guest-array-kind-name environment array)))
    (cond ((eq kind :array-integer)
           (unless (typep value 'fixnum)
             (error 'workload-capability-error
                    :operation 'numeric-array-store
                    :reason (list :unsupported-boxed-numeric value))))
          ((eq kind :array-single-float)
           (unless (typep value 'single-float)
             (error 'workload-capability-error
                    :operation 'numeric-array-store
                    :reason (list :unsupported-numeric-type
                                  (type-of value)))))
          (t (error 'workload-capability-error
                    :operation 'numeric-array-store
                    :reason (list :not-numeric-array kind)))))
  value)

(defun %guest-struct-p (environment value &optional name)
  (and (%description-p environment value :struct)
       (or (null name)
           (eq name (workload-read-slot environment value :slot0)))))

(defun %guest-car (environment value)
  (cond ((null value) nil)
        ((%guest-cons-p environment value)
         (workload-read-slot environment value :car))
        (t (error 'type-error :datum value :expected-type 'cons))))

(defun %guest-cdr (environment value)
  (cond ((null value) nil)
        ((%guest-cons-p environment value)
         (workload-read-slot environment value :cdr))
        (t (error 'type-error :datum value :expected-type 'cons))))

(defun %temporary-root-location (environment index)
  (let ((locations (workload-root-locations environment)))
    (unless (< -1 index (length locations))
      (error 'workload-capability-error :operation 'temporary-root
             :reason (list :index index :capacity (length locations))))
    (aref locations index)))

(defun %store-temporary-root (environment index value)
  (multiple-value-bind (effective status)
      (root-provider-store (workload-root-client environment)
                           (workload-context environment)
                           (workload-root-token environment)
                           (%temporary-root-location environment index)
                           value)
    (case status
      (:stored effective)
      (:retry (error 'workload-error :operation 'root-provider-store
                     :reason :retry))
      (otherwise (error 'workload-error :operation 'root-provider-store
                        :reason status)))))

(defun %allocate-guest (environment kind-name count values &optional initializer)
  "Allocate one object while VALUES occupy caller-provided root slots.
INITIALIZER runs before those slots are cleared, so it can reload moved
arguments and initialize the new object without retaining stale encodings."
  (declare (type list values))
  (let ((environment (%require-open environment 'allocate-object)))
    (loop for value in values
          for index from 0
          do (%store-temporary-root environment index value))
    (unwind-protect
         (multiple-value-bind (kind bytes alignment descriptor)
             (%workload-kind-allocation environment kind-name count)
           (multiple-value-bind (reference status reason)
               (allocate-object (workload-context environment)
                                kind bytes alignment descriptor)
             (case status
               (:allocated
                (if initializer
                    (funcall initializer reference)
                    reference))
               (:failed (error 'workload-allocation-error
                              :operation 'allocate-object :reason reason))
               (otherwise
                (error 'workload-allocation-error :operation 'allocate-object
                       :reason (or reason status))))))
      (loop for index from 0 below (length values)
            do (%store-temporary-root environment index nil)))))

(defun %cons* (environment car cdr)
  (%allocate-guest
   environment :cons 2 (list car cdr)
   (lambda (object)
     ;; INITIALIZER runs while allocation argument roots remain live.
     (workload-write-slot environment object :car
                           (workload-temporary-root-load environment 0))
     (workload-write-slot environment object :cdr
                           (workload-temporary-root-load environment 1))
     object)))

(defun %list* (environment values)
  (if (null values)
      nil
      (%cons* environment (first values)
               (%list* environment (rest values)))))

;;; ---------------------------------------------------------------------------
;;; Guest &rest bridge.
;;;
;;; Maclina's VM builds a rest list with MACLINA.VM-SHARED:LISTIFY-REST-ARGS,
;;; which uses a host LOOP/COLLECT and therefore yields a HOST list.  Guest
;;; CAR/CDR require managed CONS cells, so any guest lambda with &REST (and the
;;; adapter's own guest APPEND/NCONC/MAPCAR/LIST forms) breaks.
;;;
;;; Candidate fix: override that one VM helper at this workload boundary.  The
;;; VM calls it by symbol (`maclina.vm-shared:listify-rest-args`) and SBCL does
;;; not inline the call in the compiled VM, so the override is live.  The
;;; bridge copies the raw argument words into one fixed native-cell extent and
;;; PUBLISHES that extent before the first allocation, so a moving collection
;;; corrects both the pending inputs and the accumulated tail.  It never
;;; traverses a host container as guest storage.

(defvar *rest-bridge-active-p* nil)
(defvar *rest-bridge-original* nil)

(defun %workload-rest-bridge-environment ()
  "The open workload environment whose VM is executing, or NIL."
  (let ((environment (and (boundp '*workload-environment*)
                          *workload-environment*)))
    (when (and environment
               (not (workload-closed-p environment))
               (workload-provider-vm (workload-root-provider environment)))
      environment)))

(defun %managed-rest-list-from-words (environment stack argsi nfixed nargs)
  "Build a managed CONS chain from the VM argument words
STACK[ARGSI+NFIXED .. ARGSI+NARGS), preserving their order.

The argument words are copied into a contiguous native-cell extent that is
published (native-cell-count advanced) before the first allocation; the
accumulated tail lives in slot zero of that extent.  On success the result is
written to STACK[ARGSI] -- the slot the VM's argument-completion prologue
re-pushes -- and the extent is released.  On any exit the extent is cleared."
  (declare (type (simple-array t (*)) stack))
  (let* ((provider (workload-root-provider environment))
         (cells (workload-provider-native-cells provider))
         (capacity (length cells))
         (length (- nargs nfixed))
         (result-slot argsi)          ; prologue re-pushes STACK[ARGSI]
         (start (+ argsi (if (zerop length) 0 1)))
         (end (+ start length)))
    (unless (and (integerp length) (not (minusp length))
                 (<= 0 result-slot) (< result-slot capacity)
                 (<= start end capacity)
                 (<= end (workload-provider-capacity provider)))
      (error 'workload-capability-error :operation 'rest-list-bridge
             :reason (list :native-cell-capacity length)))
    (let ((saved (workload-provider-native-cell-count provider))
          (result nil)
          (settled nil))
      (unwind-protect
           (progn
             ;; Copy every argument word into its own cell.  Slots in the extent
             ;; are disjoint from the two temporaries %CONS* borrows.
             (dotimes (i length)
               (setf (car (aref cells (+ start i)))
                     (svref stack (+ argsi nfixed i))
                     (cdr (aref cells (+ start i))) nil))
             ;; Publish the whole extent before any allocation.
             (setf (workload-provider-native-cell-count provider) end)
             ;; Build right to left.  Each %CONS* can move the pending inputs
             ;; and the accumulated tail; both are in the published extent.
             (loop for i downfrom (1- length) to 0
                   do (setf result
                            (%cons* environment
                                    (car (aref cells (+ start i)))
                                    result)))
             ;; Publish into the completion slot; the prologue overwrites it
             ;; with the same value, so this is idempotent.
             (setf (svref stack result-slot) result
                   settled t)
             result)
        (setf (workload-provider-native-cell-count provider) saved)
        (dotimes (i length)
          (setf (car (aref cells (+ start i))) nil
                (cdr (aref cells (+ start i))) nil)))
      (unless settled (setf (svref stack result-slot) nil))
      result)))

(defun %install-rest-bridge ()
  "Install the managed &REST bridge over the VM's host-list builder."
  (unless *rest-bridge-active-p*
    (let ((original (fdefinition 'maclina.vm-shared:listify-rest-args)))
      (setf *rest-bridge-original* original)
      (setf (fdefinition 'maclina.vm-shared:listify-rest-args)
            (lambda (nfixed stack argsi nargs)
              (let ((environment (%workload-rest-bridge-environment)))
                (if (and environment
                         (typep (maclina.vm-cross::vm-client maclina.vm-cross::*vm*)
                                'workload-maclina-client))
                    (%managed-rest-list-from-words
                     environment stack argsi nfixed nargs)
                    ;; A non-workload VM keeps the dependency's own behavior.
                    (funcall original nfixed stack argsi nargs)))))
      (setf *rest-bridge-active-p* t)))
  t)

(defun %uninstall-rest-bridge ()
  (when *rest-bridge-active-p*
    (let ((current (fdefinition 'maclina.vm-shared:listify-rest-args))
          (original *rest-bridge-original*))
      (declare (ignore current))
      (when original
        (setf (fdefinition 'maclina.vm-shared:listify-rest-args) original))
      (setf *rest-bridge-active-p* nil))))

(defun %proper-guest-list-p (environment value)
  (loop for cursor = value then (%guest-cdr environment cursor)
        while (%guest-cons-p environment cursor)
        finally (return (null cursor))))

(defun %guest-list->host (environment value)
  "Copy a proper guest list to a host list for compiler/ANSI services.
This is an explicit boundary conversion, never an implicit host fallback for
CAR/CDR or storage."
  (if (null value)
      nil
      (progn
        (unless (%proper-guest-list-p environment value)
          (error 'type-error :datum value :expected-type 'list))
        (loop for cursor = value then (%guest-cdr environment cursor)
              while (%guest-cons-p environment cursor)
              collect (%guest-car environment cursor)))))

(defun %host-list->guest (environment values)
  "Copy transient host REST values into managed CONS cells.

The VM's argument-list bridge supplies a host list.  Keep every element in a
registered slot before the first allocation, and retain the growing result in
another slot; the host list itself is never used as guest storage.  On
success slot one holds the result until the caller transfers it to its own
registered VM/root slot."
  (let ((count (length values))
        (completed nil))
    (unless (<= (+ count 2) (length (workload-root-locations environment)))
      (error 'workload-capability-error :operation 'rest-list-bridge
             :reason (list :root-capacity count)))
    (unwind-protect
         (progn
           (loop for value in values
                 for index from 2
                 do (%store-temporary-root environment index value))
           (%store-temporary-root environment 0 nil)
           (%store-temporary-root environment 1 nil)
           (loop for index from (1- count) downto 0
                 do (%allocate-guest
                     environment :cons 2 nil
                     (lambda (object)
                       ;; Save the old result before slot one becomes the new
                       ;; cell.  Slot zero is owned by WORKLOAD-WRITE-SLOT,
                       ;; so write CDR first, then CAR.
                       (%store-temporary-root
                        environment 0
                        (workload-temporary-root-load environment 1))
                       (%store-temporary-root environment 1 object)
                       (workload-write-slot
                        environment object :cdr
                        (workload-temporary-root-load environment 0))
                       (workload-write-slot
                        environment object :car
                        (workload-temporary-root-load environment (+ 2 index))))))
           (setf completed t)
           (workload-temporary-root-load environment 1))
      ;; A failed bridge must not leave a partially-built list hidden in a
      ;; reserved root.  On success the caller owns the transfer/clear step.
      (unless completed
        (%store-temporary-root environment 1 nil))
      (%store-temporary-root environment 0 nil)
      (loop for index from 2 below (+ 2 count)
            do (%store-temporary-root environment index nil)))))

(defun %guest-atom-p (environment value)
  (not (%guest-cons-p environment value)))

(defun %guest-length (environment value)
  (cond ((null value) 0)
        ((%guest-array-p environment value)
         (let* ((bytes (object-size (workload-model environment) value))
                (payload (- bytes (workload-array-header-bytes environment))))
           (unless (and (plusp (workload-word-bytes environment))
                        (>= payload 0)
                        (zerop (mod payload (workload-word-bytes environment))))
             (error 'workload-capability-error :operation 'array-length
                    :reason :nonintegral-representation-size))
           (/ payload (workload-word-bytes environment))))
        ((%guest-cons-p environment value)
         (loop for cursor = value then (%guest-cdr environment cursor)
               while (%guest-cons-p environment cursor)
               count 1))
        (t (error 'type-error :datum value :expected-type 'sequence))))

(defun %with-array-element-location (environment object index function)
  "Borrow an exact raw array element location from the simulator model.
Numeric elements are not references and therefore must not be sent through
BARRIER-READ/STORE."
  (let* ((package (find-package '#:clamsara))
         (name (and package
                     (find-symbol "%CALL-WITH-SIMULATOR-ARRAY-ELEMENT"
                                  package)))
         (resolver (and name (fboundp name) (symbol-function name))))
    (unless resolver
      (error 'workload-capability-error :operation 'array-element-location
             :reason :missing-model-resolver))
    (multiple-value-bind (result status reason)
        (funcall resolver (workload-model environment) object index function)
      (case status
        ((:present :complete) result)
        (:stale (error 'workload-error :operation 'array-element-location
                       :reason :stale))
        (:retry (error 'workload-error :operation 'array-element-location
                       :reason :retry))
        (otherwise
         (if (null status) result
             (error 'workload-capability-error
                    :operation 'array-element-location
                    :reason (or reason status))))))))

(defun %guest-array-ref (environment array index)
  (unless (%guest-array-p environment array)
    (error 'type-error :datum array :expected-type 'array))
  (unless (and (integerp index) (<= 0 index)
               (< index (%guest-length environment array)))
    (error 'type-error :datum index :expected-type '(integer 0)))
  (if (%guest-array-numeric-p environment array)
      (%with-array-element-location environment array index
                                     (lambda (location)
                                       (%assert-numeric-array-element
                                        environment array
                                        (load-reference
                                         (workload-model environment)
                                         location))))
      (workload-read-slot environment array index)))

(defun %guest-array-set (environment value array index)
  (unless (%guest-array-p environment array)
    (error 'type-error :datum array :expected-type 'array))
  (unless (and (integerp index) (<= 0 index)
               (< index (%guest-length environment array)))
    (error 'type-error :datum index :expected-type '(integer 0)))
  (if (%guest-array-numeric-p environment array)
      (%with-array-element-location
       environment array index
       (lambda (location)
         (%assert-numeric-array-element environment array value)
         (store-reference-raw (workload-model environment) location value)))
      (workload-write-slot environment array index value)))


(defun %array-dimension (environment dimensions)
  (cond ((integerp dimensions) dimensions)
        ((%guest-cons-p environment dimensions)
         (let ((host (%guest-list->host environment dimensions)))
           (unless (and (= (length host) 1) (integerp (first host)))
             (error 'workload-capability-error :operation 'make-array
                    :reason :only-one-dimensional-arrays))
           (first host)))
        (t (error 'type-error :datum dimensions :expected-type '(or integer list)))))

(defun %array-kind-for-element-type (environment element-type)
  (declare (ignore environment))
  (cond ((or (null element-type) (eq element-type t)) :array)
        ((or (eq element-type 'single-float)
             (equal element-type '(single-float)))
         :array-single-float)
        ((or (eq element-type 'integer)
             (equal element-type '(integer)))
         :array-integer)
        (t (error 'workload-capability-error :operation 'make-array
                  :reason (list :unsupported-element-type element-type)))))

(defun %make-array* (environment dimensions &rest options)
  (declare (dynamic-extent options))
  (let ((length (%array-dimension environment dimensions))
        (element-type nil)
        (initial-element nil)
        (initial-element-p nil)
        (initial-contents nil)
        (initial-contents-p nil))
    (loop for tail on options by #'cddr
          for key = (first tail)
          for value = (second tail)
          do (case key
               (:element-type (setf element-type value))
               (:initial-element
                (setf initial-element value initial-element-p t))
               (:initial-contents
                (setf initial-contents value initial-contents-p t))
               (:adjustable (unless (null value)
                              (error 'workload-capability-error
                                     :operation 'make-array
                                     :reason :adjustable-not-supported)))
               (:fill-pointer (when value
                                (error 'workload-capability-error
                                       :operation 'make-array
                                       :reason :fill-pointer-not-supported)))
               (otherwise
                (error 'workload-capability-error :operation 'make-array
                       :reason (list :unsupported-option key)))))
    (unless (and (integerp length) (<= 0 length))
      (error 'type-error :datum length :expected-type '(integer 0)))
    (when (and initial-contents-p initial-element-p)
      (error 'workload-capability-error :operation 'make-array
             :reason :both-initializers))
    ;; ANSI typed numeric arrays have a representable zero initializer when
    ;; INITIAL-ELEMENT is omitted.  Do not put NIL into a numeric payload.
    (unless (or initial-element-p initial-contents-p)
      (setf initial-element
            (cond ((or (eq element-type 'single-float)
                       (equal element-type '(single-float))) 0.0s0)
                  ((or (eq element-type 'integer)
                       (equal element-type '(integer))) 0)
                  (t nil))
            initial-element-p t))
    (let* ((kind-name (%array-kind-for-element-type environment element-type))
           (kind (getf (workload-kinds environment) kind-name)))
      (unless kind
        (error 'workload-capability-error :operation 'make-array
               :reason (list :unsupported-array-kind kind-name)))
      (%allocate-guest
       environment kind-name length nil
       (lambda (object)
         ;; Keep the newly allocated array rooted while initialization stores run.
         (%store-temporary-root environment 1 object)
         (unwind-protect
              (progn
                (when initial-contents-p
                  (%store-temporary-root environment 2 initial-contents)
                  (unwind-protect
                       (progn
                         (dotimes (index length)
                           (let ((cursor (workload-temporary-root-load
                                          environment 2)))
                             (unless (%guest-cons-p environment cursor)
                               (error 'workload-capability-error
                                      :operation 'make-array
                                      :reason :too-few-initial-contents))
                             (%guest-array-set
                              environment (%guest-car environment cursor)
                              (workload-temporary-root-load environment 1)
                              index)
                             (%store-temporary-root
                              environment 2 (%guest-cdr environment cursor))))
                         (when (%guest-cons-p
                                environment
                                (workload-temporary-root-load environment 2))
                           (error 'workload-capability-error
                                  :operation 'make-array
                                  :reason :too-many-initial-contents)))
                    (workload-temporary-root-clear environment 2)))
                (unless initial-contents-p
                  (dotimes (index length)
                    (%guest-array-set
                     environment
                     (if initial-element-p initial-element nil)
                     (workload-temporary-root-load environment 1)
                     index)))
                (workload-temporary-root-load environment 1))
           (workload-temporary-root-clear environment 1)))))))

(defun %property-key (symbol indicator)
  (cons symbol indicator))

(defun %property-value (client symbol indicator &optional default)
  (multiple-value-bind (value present)
      (gethash (%property-key symbol indicator)
               (workload-client-properties client))
    (if present value default)))

(defun %set-property-value (client value symbol indicator)
  (setf (gethash (%property-key symbol indicator)
                 (workload-client-properties client)) value)
  value)

(defun %lookup-fdefinition (client environment designator)
  (if (symbolp designator)
      (clostrum:fdefinition client environment designator)
      designator))

(defun %struct-slot-identity (index)
  ;; Slot zero is the managed structure type tag; seven words remain for data.
  (svref #(:slot0 :slot1 :slot2 :slot3 :slot4 :slot5 :slot6 :slot7) index))

(defun %parse-simple-struct (form)
  (let* ((name-and-options (second form))
         (name (if (consp name-and-options)
                   (first name-and-options) name-and-options))
         (slots (cddr form)))
    (unless (and (symbolp name) name (not (eq name t)) (not (keywordp name)))
      (error 'workload-capability-error :operation 'defstruct
             :reason :invalid-name))
    ;; Reject unimplemented options/defaults rather than silently discarding
    ;; their semantics. The currently admitted shape uses bare slot names.
    (when (and (consp name-and-options) (cdr name-and-options))
      (error 'workload-capability-error :operation 'defstruct
             :reason :unsupported-structure-options))
    (unless (every #'symbolp slots)
      (error 'workload-capability-error :operation 'defstruct
             :reason :unsupported-slot-specification))
    (unless (= (length slots)
               (length (remove-duplicates slots :key #'symbol-name :test #'string=)))
      (error 'workload-capability-error :operation 'defstruct
             :reason :duplicate-slot-name))
    (when (> (length slots) 7)
      (error 'workload-capability-error :operation 'defstruct
             :reason :structure-slot-capacity))
    (values name slots)))

(defun %struct-accessor-name (name slot)
  (intern (format nil "~A-~A" name slot)
          (or (symbol-package name) *package*)))

(defun %install-struct (client runtime form)
  (let ((environment (workload-client-workload client)))
    (multiple-value-bind (name slots) (%parse-simple-struct form)
      (let ((constructor (intern (format nil "MAKE-~A" name)
                                 (or (symbol-package name) *package*)))
            (predicate (intern (format nil "~A-P" name)
                               (or (symbol-package name) *package*)))
            (keywords (mapcar (lambda (slot)
                                (intern (symbol-name slot) (find-package "KEYWORD")))
                              slots)))
        (setf (clostrum:fdefinition client runtime predicate)
              (lambda (value) (%guest-struct-p environment value name)))
        (setf (clostrum:fdefinition client runtime constructor)
              (lambda (&rest arguments)
                (declare (dynamic-extent arguments))
                (unless (evenp (length arguments)) (error 'program-error))
                (unless (getf arguments :allow-other-keys)
                  (loop for (key value) on arguments by #'cddr
                        do (unless (or (eq key :allow-other-keys)
                                       (member key keywords :test #'eq))
                             (error 'program-error))))
                ;; GETF implements the leftmost-keyword rule. Use the shared
                ;; allocation path so object, values, and store scratch never
                ;; alias temporary roots, including across collection.
                (workload-allocate
                 environment :struct (1+ (length slots))
                 (cons (list :slot0 name)
                       (loop for keyword in keywords
                             for index from 1
                             collect (list (%struct-slot-identity index)
                                           (getf arguments keyword)))))))
        (loop for slot in slots
              for index from 1
              for accessor = (%struct-accessor-name name slot)
              do (let ((identity (%struct-slot-identity index)))
                   (setf (clostrum:fdefinition client runtime accessor)
                         (lambda (object)
                           (unless (%guest-struct-p environment object name)
                             (error 'type-error :datum object :expected-type name))
                           (workload-read-slot environment object identity)))
                   (setf (clostrum:fdefinition client runtime `(setf ,accessor))
                         (lambda (value object)
                           (unless (%guest-struct-p environment object name)
                             (error 'type-error :datum object :expected-type name))
                           (workload-write-slot environment object identity value))))))))
  nil)

(defun %literal-expression (value)
  "Lower a quoted host list to source-level CONS calls.
The source bytes remain untouched; this is the interpreter's quote semantics,
ensuring every literal list is a managed object graph rather than a hidden
host graph."
  (cond ((consp value)
         `(cl:cons ,(%literal-expression (car value))
                    ,(%literal-expression (cdr value))))
        ((or (symbolp value) (characterp value) (numberp value)
             (stringp value) (null value))
         `(quote ,value))
        (t (error 'workload-capability-error :operation 'quote
                  :reason (list :unsupported-literal value)))))

(defun %rewrite-quoted (form)
  (if (consp form)
      (if (and (eq (first form) 'quote) (= (length form) 2)
               (consp (second form)))
          (%literal-expression (second form))
          (loop for item in form collect (%rewrite-quoted item)))
      form))

(defun %normalize-proclamation (environment value)
  ;; DECLAIM/PROCLAIM syntax is compiler-owned host syntax.  A quoted guest
  ;; declaration is converted at the boundary, but VM-CROSS may already hand
  ;; us an ordinary host list from its macro expansion.
  (let ((host (if (%guest-cons-p environment value)
                  (%guest-list->host environment value)
                  value)))
    (if (and (consp host) (symbolp (first host))
             (not (member (first host)
                          '(cl:type cl:ftype cl:special cl:inline cl:notinline
                            cl:optimize cl:declaration))))
        (cons 'cl:type host)
        host)))

(defun %install-workload-cxr-functions (client runtime)
  (let ((environment (workload-client-workload client)))
    (loop for width from 2 to 4 do
      (dotimes (bits (ash 1 width))
        (let* ((path (coerce (loop for i below width
                                   collect (if (logbitp i bits) #\D #\A))
                            'string))
               (name (find-symbol (format nil "C~AR" path) :common-lisp)))
          (assert (%workload-cxr-name-p name))
          (%workload-install-data-function
           client runtime name
           (lambda (object)
             ;; The rightmost operation is innermost. These reads do not
             ;; allocate guest storage or unwrap a managed list into a host list.
             (loop for i downfrom (1- (length path)) to 0
                   do (setf object (if (char= (char path i) #\A)
                                       (%guest-car environment object)
                                       (%guest-cdr environment object))))
             object))
          ;; The environment's general SETF expander calls these definitions.
          ;; Syntax mutation remains host-only inside compiler source execution.
          (%workload-install-data-function
           client runtime (list 'setf name)
           (lambda (value object)
             (loop for i downfrom (1- (length path)) above 0
                   do (setf object
                            (if *workload-source-execution-p*
                                (if (char= (char path i) #\A) (car object) (cdr object))
                                (if (char= (char path i) #\A)
                                    (%guest-car environment object)
                                    (%guest-cdr environment object)))))
             (if *workload-source-execution-p*
                 (if (char= (char path 0) #\A)
                     (rplaca object value) (rplacd object value))
                 (progn
                   (unless (%guest-cons-p environment object)
                     (error 'type-error :datum object :expected-type 'cons))
                   (workload-write-slot environment object
                                        (if (char= (char path 0) #\A) :car :cdr)
                                        value)))
             value)))))))

(defun %install-workload-functions (client runtime)
  (let ((environment (workload-client-workload client)))
  (labels ((cons* (car cdr) (%cons* environment car cdr))
           (car* (value) (%guest-car environment value))
           (cdr* (value) (%guest-cdr environment value))
           (consp* (value) (%guest-cons-p environment value))
           (atom* (value) (%guest-atom-p environment value))
           (rplaca* (object value)
             (workload-write-slot environment object :car value)
             object)
           (rplacd* (object value)
             (workload-write-slot environment object :cdr value)
             object)
           (list-fn (&rest values)
             (declare (dynamic-extent values))
             (%list* environment values))
           (length* (value) (%guest-length environment value))
           (mapcar* (function list)
             (let ((result nil))
               (loop for cursor = list then (%guest-cdr environment cursor)
                     while (%guest-cons-p environment cursor)
                     do (setf result
                              (%cons* environment
                                      (funcall function
                                               (%guest-car environment cursor))
                                      result)))
               (let ((forward nil))
                 (loop for cursor = result
                       while (%guest-cons-p environment cursor)
                       do (push (%guest-car environment cursor) forward)
                          (setf cursor (%guest-cdr environment cursor)))
                 (%list* environment forward))))
           (mapc* (function &rest lists)
             (declare (dynamic-extent lists))
             (%workload-mapc environment function lists))
           (member* (item list &key (test (lambda (a b) (%guest-eql environment a b)))
                              (test-not nil test-not-p) key)
             (loop for cursor = list then (%guest-cdr environment cursor)
                   while (%guest-cons-p environment cursor)
                   for candidate = (%guest-car environment cursor)
                   when (funcall (if test-not-p
                                     (lambda (a b) (not (funcall test-not a b)))
                                     test)
                                 item (if key (funcall key candidate) candidate))
                     do (return cursor)))
           (assoc* (item alist &key (test (lambda (a b) (%guest-eql environment a b))) key)
             (loop for cursor = alist then (%guest-cdr environment cursor)
                   while (%guest-cons-p environment cursor)
                   for pair = (%guest-car environment cursor)
                   when (and (%guest-cons-p environment pair)
                             (funcall test item
                                      (if key (funcall key (%guest-car environment pair))
                                          (%guest-car environment pair))))
                     do (return pair)))
           (append* (&rest lists)
             (declare (dynamic-extent lists))
             (labels ((copy (list tail)
                        (if (%guest-cons-p environment list)
                            (%cons* environment (%guest-car environment list)
                                    (copy (%guest-cdr environment list) tail))
                            tail)))
               (reduce (lambda (left right) (copy left right))
                       lists :from-end t :initial-value nil)))
           (copy-tree* (value)
             (if (%guest-cons-p environment value)
                 (%cons* environment
                         (copy-tree* (%guest-car environment value))
                         (copy-tree* (%guest-cdr environment value)))
                 value))
           (nconc* (&rest lists)
             (declare (dynamic-extent lists))
             (let ((head nil) (tail nil))
               (dolist (list lists head)
                 (unless (null list)
                   (if (null head) (setf head list)
                       (workload-write-slot environment tail :cdr list))
                   (setf tail list)
                   (loop while (%guest-cons-p environment
                                               (%guest-cdr environment tail))
                         do (setf tail (%guest-cdr environment tail)))))))
           (reverse* (list)
             (let ((result nil))
               (loop for cursor = list then (%guest-cdr environment cursor)
                     while (%guest-cons-p environment cursor)
                     do (setf result
                              (%cons* environment
                                      (%guest-car environment cursor) result)))
               result))
           (subst* (new old tree &key (test (lambda (a b) (%guest-eql environment a b))))
             (if (funcall test old tree)
                 new
                 (if (%guest-cons-p environment tree)
                     (%cons* environment
                             (subst* new old (%guest-car environment tree)
                                     :test test)
                             (subst* new old (%guest-cdr environment tree)
                                     :test test))
                     tree)))
           (equal* (left right)
             (cond ((and (%guest-cons-p environment left)
                         (%guest-cons-p environment right))
                    (and (equal* (%guest-car environment left)
                                 (%guest-car environment right))
                         (equal* (%guest-cdr environment left)
                                 (%guest-cdr environment right))))
                   ((or (%guest-cons-p environment left)
                        (%guest-cons-p environment right)) nil)
                   ((or (%guest-bignum-p environment left)
                        (%guest-bignum-p environment right))
                    (%guest-eql environment left right))
                   (t (equal left right)))))
    (flet ((fset (name function)
             (%workload-install-data-function client runtime name function)))
      (fset 'cl:cons #'cons*) (fset 'cl:car #'car*) (fset 'cl:cdr #'cdr*)
      (fset 'cl:consp #'consp*) (fset 'cl:atom #'atom*)
      (%install-workload-cxr-functions client runtime)
      (fset 'cl:rplaca #'rplaca*) (fset 'cl:rplacd #'rplacd*)
      (fset 'cl:list #'list-fn) (fset 'cl:length #'length*)
      (fset 'cl:mapcar #'mapcar*) (fset 'cl:mapc #'mapc*)
      (fset 'cl:member #'member*) (fset 'cl:assoc #'assoc*)
      (fset 'cl:append #'append*) (fset 'cl:nconc #'nconc*)
      (fset 'cl:reverse #'reverse*) (fset 'cl:subst #'subst*)
      (fset 'cl:copy-tree #'copy-tree*)
      (fset 'cl:equal #'equal*)
      ;; Install TIME as a guest macro.  The wrapped form runs once and
      ;; MULTIPLE-VALUE-PROG1 preserves every value; timing/reporting happens
      ;; only after the values have been captured.
      (setf (clostrum:macro-function client runtime 'cl:time)
            (lambda (form macro-environment)
              (declare (ignore macro-environment))
              (unless (= (length form) 2)
                (error 'program-error))
              (let ((started (gensym "TIME-START-")))
                `(let ((,started (get-internal-real-time)))
                   (multiple-value-prog1
                       ,(second form)
                     (format t "~&; elapsed ~,3F seconds~%"
                             (/ (- (get-internal-real-time) ,started)
                                (float internal-time-units-per-second))))))))
      (fset 'cl:aref (lambda (array index)
                      (%guest-array-ref environment array index)))
      (fset '(setf cl:aref)
            (lambda (value array index)
              (%guest-array-set environment value array index)))
      (fset 'cl:make-array
            (lambda (dimensions &rest options)
              (declare (dynamic-extent options))
              (apply #'%make-array* environment dimensions options)))
      (fset 'cl:arrayp (lambda (value) (%guest-array-p environment value)))
      (fset 'cl:vectorp (lambda (value) (%guest-array-p environment value)))
      (fset 'cl:array-element-type
            (lambda (value)
              (let ((kind-name (%guest-array-kind-name environment value)))
                (unless kind-name
                  (error 'type-error :datum value :expected-type 'array))
                (or (workload-kind-element-type
                     (%workload-kind environment kind-name))
                    (case kind-name
                      (:array-single-float 'single-float)
                      (:array-integer 'integer)
                      (otherwise t))))))
      (fset 'cl:get
            (lambda (symbol indicator &optional default)
              (%property-value client symbol indicator default)))
      (fset '(setf cl:get)
            (lambda (value symbol indicator)
              (%set-property-value client value symbol indicator)))
      (fset 'cl:proclaim
            (let ((original (clostrum:fdefinition client runtime 'cl:proclaim)))
              (lambda (declaration)
                (funcall original (%normalize-proclamation environment declaration)))))
      (setf (clostrum:macro-function client runtime 'cl:defstruct)
            (lambda (form macro-environment)
              (declare (ignore macro-environment))
              (%install-struct client runtime form)))
      ;; Allocation-capable sequence operations run as guest functions.
      ;; Their recursion and argument values therefore live in VM frames and
      ;; the provider's normal frame/value root scan, not in unregistered host
      ;; locals held across CONS allocations.
      (labels ((install-guest (name form)
                 (fset name (workload-eval environment form))))
        (install-guest
         'cl:list
         `(lambda (&rest values)
            (labels ((build (tail)
                       (if (null tail) nil
                           (cons (car tail) (build (cdr tail))))))
              (build values))))
        (install-guest
         'cl:mapcar
         `(lambda (function list)
            (if (null list) nil
                (cons (funcall function (car list))
                      (mapcar function (cdr list))))))
        (install-guest
         'cl:append
         `(lambda (&rest lists)
            (labels ((copy (list tail)
                       (if (null list) tail
                           (cons (car list)
                                 (copy (cdr list) tail))))
                     (join (rest)
                       (if (null rest) nil
                           (copy (car rest) (join (cdr rest))))))
              (join lists))))
        (install-guest
         'cl:reverse
         `(lambda (list)
            (labels ((step (tail result)
                       (if (null tail) result
                           (step (cdr tail) (cons (car tail) result)))))
              (step list nil))))
        (install-guest
         'cl:copy-tree
         `(lambda (tree)
            (if (consp tree)
                (cons (copy-tree (car tree))
                      (copy-tree (cdr tree)))
                tree)))
        (install-guest
         'cl:subst
         `(lambda (new old tree)
            (if (eql old tree) new
                (if (consp tree)
                    (cons (subst new old (car tree))
                          (subst new old (cdr tree)))
                    tree))))
        (install-guest
         'cl:nconc
         `(lambda (&rest lists)
            (labels ((last-cell (list)
                       (if (consp (cdr list))
                           (last-cell (cdr list))
                           list))
                     (join (head rest)
                       (if (null rest) head
                           (if (null head)
                               (join (car rest) (cdr rest))
                               (progn
                                 (rplacd (last-cell head) (car rest))
                                 (join head (cdr rest)))))))
              (join nil lists)))))
      ;; Source ASSERT is absent from some Extrinsicl installations.
      (setf (clostrum:macro-function client runtime 'cl:assert)
            (lambda (form macro-environment)
              (declare (ignore macro-environment))
              `(if ,(second form) t
                   (error "Assertion failed: ~S" ',(second form))))))
  environment)))

(defun setup-workload-maclina (environment)
  "Install Maclina and the strict managed-value primitive set.
Compilation and source loading occur only after setup; callers should perform
all benchmark warmup before collecting evidence."
  (%require-open environment 'setup-workload-maclina)
  (let* ((client (make-instance 'workload-maclina-client :workload environment))
         (runtime (make-instance 'clostrum-basic:run-time-environment)))
    (extrinsicl:install-cl (make-instance 'trucler-native:client) runtime)
    ;; INSTALL-CL creates initial cells before our specialized cell method is
    ;; active; register them explicitly in the fixed client vector.
    (%register-existing-global-cells client runtime)
    (extrinsicl::install-environment-accessors client runtime)
    (extrinsicl::install-proclaim client runtime)
    (extrinsicl.maclina:install-eval client runtime)
    (%install-workload-reader-macros client runtime)
    (setf maclina.machine:*client* client
          (workload-maclina-client environment) client
          (workload-maclina-environment environment) runtime)
    ;; VM state and root-provider source descriptors are provisioned before
    ;; the first source form executes.  The provider/token themselves were
    ;; registered by MAKE-WORKLOAD-ENVIRONMENT's caller.
    ;; Install the managed &REST bridge before any guest source executes.
    (%install-rest-bridge)
    (maclina.vm-cross:initialize-vm (workload-stack-size environment) client)
    (workload-provider-bind-maclina
     (workload-root-provider environment) client runtime)
    (workload-provider-bind-vm
     (workload-root-provider environment) maclina.vm-cross::*vm*)
    (%install-workload-functions client runtime)
    (%install-workload-numbers client runtime)
    environment))

(defun workload-eval (environment form)
  "Evaluate FORM through Maclina.  Source literal lists are lowered into
managed CONS graphs by the interpreter boundary."
  (%require-open environment 'workload-eval)
  (let ((client (workload-maclina-client environment))
        (runtime (workload-maclina-environment environment)))
    (unless (and client runtime)
      (error 'workload-capability-error :operation 'workload-eval
             :reason :maclina-not-installed))
    (let ((*workload-environment* environment))
      (funcall (clostrum:fdefinition client runtime 'cl:eval)
               (%rewrite-quoted form)))))

(defun workload-load (environment pathname)
  "Read PATHNAME once per top-level form and evaluate it without editing the
source bytes.  Reader/compiler work is setup, not collection evidence."
  (%require-open environment 'workload-load)
  (with-open-file (stream pathname)
    (let ((*package* (find-package '#:clamsara)))
      (loop for form = (read stream nil :eof)
            until (eq form :eof)
            do (workload-eval environment form))))
  t)

(export '(workload-maclina-client setup-workload-maclina workload-eval
          workload-load *workload-environment*))
