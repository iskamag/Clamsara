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
    (case status
      (:stored effective)
      (:retry (error 'workload-error :operation 'root-provider-store
                     :reason :retry))
      (otherwise (error 'workload-error :operation 'root-provider-store
                        :reason status)))))

(defun workload-root-load (root-set index)
  (let* ((environment (workload-root-set-environment root-set))
         (location (aref (workload-root-set-locations root-set) index)))
    (root-provider-load (workload-root-client environment)
                        (workload-root-token environment) location)))

(defun workload-root-clear (root-set index)
  (%root-store root-set index nil))

(defun workload-root-place (root-set index value)
  (%root-store root-set index value))

(defmacro with-workload-root ((root-set index value) &body body)
  "Keep VALUE in one already-registered physical root through BODY.
The slot is cleared even when BODY exits nonlocally.  A RETRY is surfaced;
this helper never stores directly through a host vector."
  (let ((set (gensym "ROOT-SET"))
        (slot (gensym "SLOT"))
        (item (gensym "VALUE")))
    `(let* ((,set ,root-set) (,slot ,index) (,item ,value))
       (%root-store ,set ,slot ,item)
       (unwind-protect (progn ,@body)
         (%root-store ,set ,slot nil)))))

(defmacro with-workload-roots ((root-set bindings) &body body)
  "Reserve a fixed set of physical roots for BINDINGS.
BINDINGS is ((index value) ...).  The implementation is deliberately
unrolled at macro expansion so entering/leaving the roots creates no helper
list and has a deterministic cleanup order."
  (let ((set-var (gensym "ROOT-SET")))
    (labels ((expand (remaining)
               (if (null remaining)
                   `(progn ,@body)
                   `(%with-workload-root-values
                      ,set-var ,(caar remaining) ,(cadar remaining)
                      (lambda () ,(expand (cdr remaining)))))))
      `(let ((,set-var ,root-set))
         ,(expand bindings)))))

(defun %with-workload-root-values (root-set index value function)
  (%root-store root-set index value)
  (unwind-protect (funcall function)
    (%root-store root-set index nil)))

(export '(workload-root-set make-workload-root-set workload-root-load
          workload-root-clear workload-root-place with-workload-root
          with-workload-roots))


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

(defclass workload-root-provider ()
  ((locations :initarg :locations :reader workload-provider-locations)
   (capacity :initarg :capacity :reader workload-provider-capacity)
   (temporary-capacity :initarg :temporary-capacity :reader workload-provider-temporary-capacity)
   (vm :initform nil :accessor workload-provider-vm)
   (client :initform nil :accessor workload-provider-client)
   (environment :initform nil :accessor workload-provider-environment)))

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
                                 :locations (make-array capacity))))
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


(defun %provider-activate-closure (provider cursor closure)
  (if (typep closure 'maclina.machine:closure)
      (let ((environment (maclina.machine:environment closure)))
        (dotimes (index (length environment) cursor)
          (setf cursor (%provider-activate provider cursor :closure
                                            closure index))))
      cursor))

(defun %provider-refresh (provider)
  "Retarget tokens to active vm-cross roots without allocating.

This hosted path uses fixed token storage.  The interpreter must provision a
capacity covering its stack, values, dynamic cells and closure environments;
exhaustion is reported as a capability failure rather than dropping roots."
  (%provider-clear-locations provider)
  (let ((cursor (workload-provider-temporary-capacity provider))
        (vm (workload-provider-vm provider))
        (client (workload-provider-client provider)))
    (when vm
      (dotimes (index (maclina.vm-cross::vm-stack-top vm))
        (setf cursor (%provider-activate provider cursor :stack vm index))
        (setf cursor
              (%provider-activate-closure
               provider cursor
               (svref (maclina.vm-cross::vm-stack vm) index))))
      ;; VM-VALUES is a host list.  Each cons cell is a stable physical source
      ;; for this protected snapshot; no location is retained after release.
      (loop for value-cell = (maclina.vm-cross::vm-values vm)
              then (cdr value-cell)
            while (consp value-cell)
            do (setf cursor (%provider-activate
                             provider cursor :values value-cell))
               (setf cursor (%provider-activate-closure
                             provider cursor (car value-cell))))
      ;; Dynamic special-binding/progv cells are host conses holding managed
      ;; values.  They are active roots for the current bytecode extent.
      (dolist (dynenv (maclina.vm-cross::vm-dynenv-stack vm))
        (typecase dynenv
          (maclina.vm-cross::sbind-dynenv
           (setf cursor
                 (%provider-activate provider cursor :cell
                                     (maclina.vm-cross::sbind-dynenv-cell
                                      dynenv))))
          (maclina.vm-cross::progv-dynenv
           (dolist (pair (maclina.vm-cross::progv-dynenv-mapping dynenv))
             (setf cursor (%provider-activate provider cursor :cell (cdr pair)))))
          (maclina.vm-cross::protection-dynenv
           (setf cursor
                 (%provider-activate-closure
                  provider cursor
                  (maclina.vm-cross::protection-dynenv-cleanup dynenv)))))))
    ;; Symbol/property values are host hash-table payloads but are managed
    ;; references.  Retarget a fixed location directly to each hash entry.
    (when client
      (maphash (lambda (key value)
                 (declare (ignore value))
                 (setf cursor (%provider-activate
                               provider cursor :property
                               (workload-client-properties client) key)))
               (workload-client-properties client)))
    ;; Registered global cells are maintained in a fixed client vector by the
    ;; adapter.  They are covered even when their value is NIL.
    (when client
      (dotimes (index (workload-client-global-cell-count client))
        (setf cursor (%provider-activate
                      provider cursor :cell
                      (aref (workload-client-global-cells client) index)))))
    cursor))

(defmethod map-provider-roots
    ((provider workload-root-provider) function)
  (%provider-refresh provider)
  (dotimes (index (workload-provider-capacity provider))
    (funcall function (workload-provider-location provider index)))
  (values))

(export '(workload-root-set make-workload-root-set workload-root-load
          workload-root-place workload-root-clear with-workload-root
          with-workload-roots
          workload-root-location workload-root-provider
          make-workload-root-provider workload-provider-location
          workload-provider-bind-maclina workload-provider-bind-vm
          workload-provider-locations workload-provider-capacity
          workload-provider-temporary-capacity
          workload-provider-temporary-locations))
