;;;; src/workload/roots.lisp -- temporary/source root discipline.
;;;;
;;;; The collector may move a value while ALLOCATE-OBJECT or a barrier slow path
;;;; runs.  The interpreter therefore reserves physical provider slots before
;;;; entering those operations and reloads the effective values afterwards.
;;;; This helper does not make locations or register providers at runtime.

(in-package #:clamsara)

(defstruct (workload-root-set
            (:constructor %make-workload-root-set
                (environment locations capacity)))
  environment
  locations
  capacity)

(defun make-workload-root-set (environment locations)
  "Wrap preallocated ROOT LOCATIONS from ENVIRONMENT's registered provider.
LOCATIONS is a simple vector of opaque physical tokens.  No location is
created by this function."
  (%require-open environment 'make-workload-root-set)
  (unless (and (vectorp locations) (plusp (length locations)))
    (error 'workload-capability-error :operation 'make-workload-root-set
           :reason :invalid-locations))
  (%make-workload-root-set environment locations (length locations)))

(defun %root-store (root-set index value)
  (unless (< -1 index (workload-root-set-capacity root-set))
    (error 'workload-capability-error :operation 'root-provider-store
           :reason (list :index-out-of-range index)))
  (let* ((environment (workload-root-set-environment root-set))
         (effective nil)
         (status nil)
         (location (aref (workload-root-set-locations root-set) index)))
    (multiple-value-setq (effective status)
      (root-provider-store
       (workload-root-client environment)
       (workload-context environment)
       (workload-root-token environment)
       location value))
    (%store-outcome 'root-provider-store effective status)))

(defun workload-root-load (root-set index)
  (let* ((environment (workload-root-set-environment root-set))
         (location (aref (workload-root-set-locations root-set) index)))
    (root-provider-load (workload-root-client environment)
                        (workload-root-token environment) location)))

(defun workload-root-clear (root-set index)
  (%root-store root-set index nil))

(defun workload-root-place (root-set index value)
  (%root-store root-set index value))


;;; ---- fixed Maclina execution/root provider -------------------------------
;;;
;;; A vm-cross frame is host storage, but managed references can reside in its
;;; stack, value list, global Clostrum cells, and closure environments.  The
;;; provider below provisions physical tokens once and retargets their
;;; source/index descriptors only while the root snapshot is protected.  The
;;; token identity never changes and its host-root hooks update the actual
;;; source slot after movement.

(defclass workload-root-location ()
  ((provider :initarg :provider :reader workload-location-provider)
   (index :initarg :index :reader workload-location-index)
   (source-kind :initform :inactive :accessor workload-location-source-kind)
   (source :initform nil :accessor workload-location-source)
   (source-index :initform 0 :accessor workload-location-source-index)
   (value :initform nil :accessor workload-location-value)))

(defstruct (workload-root-walk (:constructor %make-workload-root-walk (queue seen)))
  queue seen (count 0))

(defun %new-workload-root-walk (capacity)
  (%make-workload-root-walk
   (make-array capacity :initial-element nil)
   (make-hash-table :test #'eq :size (* 2 capacity) :rehash-threshold 1.0)))

(defun %clear-workload-root-walk (walk)
  (fill (workload-root-walk-queue walk) nil)
  (clrhash (workload-root-walk-seen walk))
  (setf (workload-root-walk-count walk) 0))

(defun %make-workload-native-cells (capacity)
  ;; These are interpreter control sources, never boxed guest list payload.
  (let ((cells (make-array capacity)))
    (dotimes (i capacity cells) (setf (aref cells i) (cons nil nil)))))

(defclass workload-root-provider ()
  ((locations :initarg :locations :reader workload-provider-locations)
   (capacity :initarg :capacity :reader workload-provider-capacity)
   (temporary-capacity :initarg :temporary-capacity :reader workload-provider-temporary-capacity)
   (vm :initform nil :accessor workload-provider-vm)
   (client :initform nil :accessor workload-provider-client)
   (environment :initform nil :accessor workload-provider-environment)
   (functions :initarg :functions :reader workload-provider-functions)
   (saved-values :initarg :saved-values :reader workload-provider-saved-values)
   (frame-count :initform 0 :accessor workload-provider-frame-count)
   (control-walk :initarg :control-walk :reader workload-provider-control-walk)
   (census-walk :initarg :census-walk :reader workload-provider-census-walk)
   (native-cells :initarg :native-cells :reader workload-provider-native-cells)
   (native-cell-count :initform 0 :accessor workload-provider-native-cell-count)))

(defun make-workload-root-provider (capacity &key (temporary-capacity 16))
  "Provision CAPACITY immutable location tokens for a Maclina provider.
The first TEMPORARY-CAPACITY tokens are reserved for allocation/barrier
arguments; collector refresh never retargets or clears those tokens."
  (unless (and (integerp capacity) (plusp capacity)
               (integerp temporary-capacity) (<= 0 temporary-capacity capacity))
    (error 'workload-capability-error :operation 'make-workload-root-provider
           :reason (list :invalid-capacity capacity temporary-capacity)))
  (let ((provider (make-instance 'workload-root-provider
                                 :capacity capacity
                                 :temporary-capacity temporary-capacity
                                 :locations (make-array capacity)
                                 :functions (make-array capacity :initial-element nil)
                                 :saved-values (make-array capacity :initial-element nil)
                                 :control-walk (%new-workload-root-walk capacity)
                                 :census-walk (%new-workload-root-walk capacity)
                                 :native-cells (%make-workload-native-cells capacity))))
    (dotimes (index capacity provider)
      (setf (aref (workload-provider-locations provider) index)
            (make-instance 'workload-root-location
                           :provider provider :index index))
      (when (< index temporary-capacity)
        (setf (workload-location-source-kind
               (aref (workload-provider-locations provider) index)) :temp)))))

(defun workload-provider-temporary-locations (provider)
  "Return the setup-time vector of reserved temporary root tokens."
  (subseq (workload-provider-locations provider) 0
          (workload-provider-temporary-capacity provider)))

(defun workload-provider-location (provider index)
  (unless (< -1 index (workload-provider-capacity provider))
    (error 'workload-capability-error :operation 'workload-provider-location
           :reason (list :index-out-of-range index)))
  (aref (workload-provider-locations provider) index))

(defun workload-provider-bind-maclina (provider client runtime)
  "Attach the provider before registering it with ROOT-CLIENT."
  (setf (workload-provider-client provider) client
        (workload-provider-environment provider) runtime)
  provider)

(defun workload-provider-bind-vm (provider vm)
  (setf (workload-provider-vm provider) vm)
  provider)

(defun %location-read (location)
  (case (workload-location-source-kind location)
    (:inactive nil)
    (:temp (workload-location-value location))
    (:stack (svref (maclina.vm-cross::vm-stack
                    (workload-location-source location))
                   (workload-location-source-index location)))
    (:values (car (workload-location-source location)))
    (:cell (car (workload-location-source location)))
    (:lexical-cell (maclina.vm-cross::cell-value
                    (workload-location-source location)))
    (:literal (aref (maclina.machine:literals (workload-location-source location))
                    (workload-location-source-index location)))
    (:property (gethash (workload-location-source-index location)
                        (workload-location-source location)))
    (:closure
     (aref (maclina.machine:environment
            (workload-location-source location))
           (workload-location-source-index location)))
    (otherwise
     (error 'workload-capability-error :operation 'host-root-value
            :reason (list :unknown-source
                          (workload-location-source-kind location))))))

(defun %location-write (location value)
  (case (workload-location-source-kind location)
    (:inactive
     (unless (null value)
       (error 'workload-capability-error :operation 'host-root-value
              :reason :inactive-root)))
    (:temp (setf (workload-location-value location) value))
    (:stack (setf (svref (maclina.vm-cross::vm-stack
                           (workload-location-source location))
                          (workload-location-source-index location)) value))
    (:values (setf (car (workload-location-source location)) value))
    (:cell (setf (car (workload-location-source location)) value))
    (:lexical-cell (setf (maclina.vm-cross::cell-value
                          (workload-location-source location)) value))
    (:literal (setf (aref (maclina.machine:literals
                           (workload-location-source location))
                          (workload-location-source-index location)) value))
    (:property
     (setf (gethash (workload-location-source-index location)
                    (workload-location-source location)) value))
    (:closure
     (setf (aref (maclina.machine:environment
                  (workload-location-source location))
                 (workload-location-source-index location)) value))
    (otherwise
     (error 'workload-capability-error :operation 'host-root-value
            :reason (list :unknown-source
                          (workload-location-source-kind location))))))

;; HOST-ROOT-VALUE is the parent-owned host root integration generic.  These
;; methods intentionally do not expose a raw simulator store; root-provider-
;; store still routes through the configured runtime barrier before invoking
;; this committed host operation.
(defmethod clamsara::host-root-value ((location workload-root-location))
  (%location-read location))

(defmethod (setf clamsara::host-root-value)
    (value (location workload-root-location))
  (%location-write location value)
  value)

(defmethod clamsara::host-root-kind ((location workload-root-location))
  :exact)

(defun %provider-clear-locations (provider)
  (dotimes (index (workload-provider-capacity provider))
    (let ((location (workload-provider-location provider index)))
      (if (< index (workload-provider-temporary-capacity provider))
          (setf (workload-location-source-kind location) :temp
                (workload-location-source location) nil
                (workload-location-source-index location) 0)
          (setf (workload-location-source-kind location) :inactive
                (workload-location-source location) nil
                (workload-location-source-index location) 0
                (workload-location-value location) nil)))))

(defun %provider-activate (provider cursor kind source &optional (source-index 0))
  (when (>= cursor (workload-provider-capacity provider))
    (error 'workload-capability-error :operation 'map-provider-roots
           :reason :root-provider-capacity-exhausted))
  (let ((location (workload-provider-location provider cursor)))
    (setf (workload-location-source-kind location) kind
          (workload-location-source location) source
          (workload-location-source-index location) source-index)
    (1+ cursor)))


(defun %provider-enqueue-control (walk cursor value)
  ;; Queue only known interpreter control objects. Never traverse arbitrary
  ;; host containers as if they were an admitted guest representation.
  (when (and (or (typep value 'maclina.machine:closure)
                 (typep value 'maclina.machine:function)
                 (typep value 'maclina.machine:module)
                 (typep value 'maclina.vm-cross::cell))
             (not (gethash value (workload-root-walk-seen walk))))
    (let ((count (workload-root-walk-count walk)))
      (when (= count (length (workload-root-walk-queue walk)))
        (error 'workload-capability-error :operation 'map-provider-roots
               :reason :control-root-capacity-exhausted))
      (setf (gethash value (workload-root-walk-seen walk)) t
            (aref (workload-root-walk-queue walk) count) value
            (workload-root-walk-count walk) (1+ count))))
  cursor)

(defun %provider-drain-control-roots (provider walk cursor activate)
  (loop for index from 0
        while (< index (workload-root-walk-count walk))
        for object = (aref (workload-root-walk-queue walk) index)
        do (etypecase object
             (maclina.machine:function
              (%provider-enqueue-control walk cursor (maclina.machine:module object)))
             (maclina.machine:module
              (let ((literals (maclina.machine:literals object))
                    (environment (workload-client-workload
                                  (workload-provider-client provider))))
                (dotimes (i (length literals))
                  (let ((value (aref literals i)))
                    ;; A literal slot itself is writable, unlike a detached
                    ;; copy of its current value. Host syntax is not traversed.
                    (when (workload-reference-p environment value)
                      (setf cursor (funcall activate provider cursor :literal object i)))
                    (%provider-enqueue-control walk cursor value)))))
             (maclina.machine:closure
              (%provider-enqueue-control walk cursor (maclina.machine:template object))
              (let ((environment (maclina.machine:environment object)))
                (dotimes (i (length environment))
                  (setf cursor (funcall activate provider cursor :closure object i))
                  (%provider-enqueue-control walk cursor (aref environment i)))))
             (maclina.vm-cross::cell
              (setf cursor (funcall activate provider cursor :lexical-cell object))
              (%provider-enqueue-control walk cursor
                                          (maclina.vm-cross::cell-value object)))))
  cursor)

(defun %provider-walk-root-sources (provider walk activate
                                    &key extra-function entry-local-start entry-end)
  "Enumerate the same physical sources for snapshot installation and census.
ACTIVATE may install a descriptor only in the protected snapshot path. The
census uses separate bounded control scratch and never changes descriptors."
  (%clear-workload-root-walk walk)
  (let ((cursor (workload-provider-temporary-capacity provider))
        (vm (workload-provider-vm provider))
        (client (workload-provider-client provider)))
    (when vm
      (dotimes (index (maclina.vm-cross::vm-stack-top vm))
        (setf cursor (funcall activate provider cursor :stack vm index))
        (setf cursor
              (%provider-enqueue-control walk cursor
               (svref (maclina.vm-cross::vm-stack vm) index))))
      ;; VM-VALUES is a host list.  Each cons cell is a stable physical source
      ;; for this protected snapshot; no location is retained after release.
      (loop for value-cell = (maclina.vm-cross::vm-values vm)
              then (cdr value-cell)
            while (consp value-cell)
            do (setf cursor (funcall activate provider cursor :values value-cell))
               (setf cursor (%provider-enqueue-control walk cursor (car value-cell))))
      ;; Dynamic special-binding/progv cells are host conses holding managed
      ;; values.  They are active roots for the current bytecode extent.
      (dolist (dynenv (maclina.vm-cross::vm-dynenv-stack vm))
        (typecase dynenv
          (maclina.vm-cross::sbind-dynenv
           (let ((cell (maclina.vm-cross::sbind-dynenv-cell dynenv)))
             (setf cursor (funcall activate provider cursor :cell cell))
             (%provider-enqueue-control walk cursor (car cell))))
          (maclina.vm-cross::progv-dynenv
           (dolist (pair (maclina.vm-cross::progv-dynenv-mapping dynenv))
             (setf cursor (funcall activate provider cursor :cell (cdr pair)))
             (%provider-enqueue-control walk cursor (cadr pair))))
          (maclina.vm-cross::protection-dynenv
           (setf cursor
                 (%provider-enqueue-control walk cursor
                  (maclina.vm-cross::protection-dynenv-cleanup dynenv)))))))
    ;; Active callees can have left the operand stack. Saved cleanup values
    ;; outlive changes to VM-VALUES and must update the original host conses.
    (dotimes (frame (workload-provider-frame-count provider))
      (%provider-enqueue-control walk cursor (aref (workload-provider-functions provider) frame))
      (loop for cell on (aref (workload-provider-saved-values provider) frame)
            do (setf cursor (funcall activate provider cursor :values cell))
               (%provider-enqueue-control walk cursor (car cell))))
    ;; Symbol/property values are host hash-table payloads but are managed
    ;; references.  Retarget a fixed location directly to each hash entry.
    (when client
      (maphash (lambda (key value)
                 (setf cursor (funcall activate provider cursor :property
                               (workload-client-properties client) key))
                 (%provider-enqueue-control walk cursor value))
               (workload-client-properties client)))
    ;; Registered global cells are maintained in a fixed client vector by the
    ;; adapter.  They are covered even when their value is NIL.
    (when client
      (dotimes (index (workload-client-global-cell-count client))
        (setf cursor (funcall activate provider cursor :cell
                      (aref (workload-client-global-cells client) index)))
        (%provider-enqueue-control walk cursor (car (aref (workload-client-global-cells client) index)))))
    ;; Follow the current environment's declared code owners. Rebinding or
    ;; FMAKUNBOUND naturally releases the previous definition; no history of
    ;; every compiled function is promoted into a permanent root registry.
    (let ((environment (workload-provider-environment provider)))
      (when environment
        (maphash
         (lambda (name entry)
           (declare (ignore name))
           (%provider-enqueue-control walk cursor (car (clostrum-basic::cell entry)))
           (%provider-enqueue-control walk cursor
                                       (clostrum-basic::compiler-macro-function entry))
           (%provider-enqueue-control walk cursor
                                       (clostrum-basic::setf-expander entry)))
         (clostrum-basic::functions environment))
        (maphash
         (lambda (name entry)
           (declare (ignore name))
           (when (slot-boundp entry 'clostrum-basic::symbol-macro-expander)
             (%provider-enqueue-control walk cursor
                                         (clostrum-basic::symbol-macro-expander entry))))
         (clostrum-basic::variables environment))
        (maphash
         (lambda (name entry)
           (declare (ignore name))
           (%provider-enqueue-control walk cursor (clostrum-basic::type-expander entry)))
         (clostrum-basic::types environment))))
    ;; A proposed callback owns its known code/capture graph before publication.
    (%provider-enqueue-control walk cursor extra-function)
    ;; VM locals are not initialized by BYTECODE-CALL. Census their actual
    ;; existing control values, not fabricated NILs. Argument words come from
    ;; managed cons payload, not arbitrary host control containers.
    (when entry-local-start
      (loop for i from entry-local-start below entry-end do
        (%provider-enqueue-control walk cursor
          (svref (maclina.vm-cross::vm-stack vm) i))))
    (%provider-drain-control-roots provider walk cursor activate)))

(defun %provider-refresh (provider)
  "Retarget only inside the protected provider snapshot."
  (%provider-clear-locations provider)
  (%provider-walk-root-sources provider (workload-provider-control-walk provider)
                              #'%provider-activate))

(defun %provider-count-location (provider cursor kind source &optional index)
  (declare (ignore kind source index))
  (when (or (>= cursor (workload-provider-capacity provider))
            (>= cursor (length (workload-provider-locations provider))))
    (%mapc-capability-reject :root-provider-capacity-exhausted))
  (1+ cursor))

(defun %provider-root-demand (provider &key extra-function entry-local-start entry-end)
  "Count current sources plus known proposed control owners, without retargeting."
  (let ((walk (workload-provider-census-walk provider)))
    (unwind-protect
         (let ((roots (%provider-walk-root-sources
                       provider walk #'%provider-count-location
                       :extra-function extra-function
                       :entry-local-start entry-local-start :entry-end entry-end)))
           (values roots (workload-root-walk-count walk)))
      (%clear-workload-root-walk walk))))

(defmethod map-provider-roots
    ((provider workload-root-provider) function)
  (%provider-refresh provider)
  (dotimes (index (workload-provider-capacity provider))
    (funcall function (workload-provider-location provider index)))
  (values))

(export '(workload-root-set make-workload-root-set workload-root-load
          workload-root-place workload-root-clear
          workload-root-location workload-root-provider
          make-workload-root-provider workload-provider-location
          workload-provider-bind-maclina workload-provider-bind-vm
          workload-provider-locations workload-provider-capacity
          workload-provider-temporary-capacity
          workload-provider-temporary-locations))
