(in-package #:clamsara)

;;; --- Maclina VM Binding ---
;;; Bridges Clamsara plans to Maclina's interpreter.
;;;
;;; NOTE: The maclina-vm class is an integration stub. The current
;;; with-clamsara-maclina entry point creates a simulator-vm instead,
;;; so maclina-vm is not yet exercised. To activate, the maclina-env
;;; setup must use make-maclina-vm in place of make-simulator-vm, and
;;; the root scanning, stack updating, and allocation paths must be
;;; validated against Maclina's internal VM structures.

(defclass maclina-vm (vm-binding)
  ((plan :initarg :plan :accessor maclina-vm-plan)
   (client :initarg :client :accessor maclina-vm-client)
   (heap :initarg :heap :accessor vm-heap))
  (:documentation "Maclina VM binding for Clamsara."))

(defun make-maclina-vm (&key plan client heap-size)
  "Create a maclina-vm with a heap of HEAP-SIZE words."
  (let* ((size (or heap-size 65536))
         (vm (make-instance 'maclina-vm
                            :plan plan
                            :client client
                            :heap *heap*)))
    (setf (slot-value vm 'heap-size) size)
    (setf (vm-card-table vm) (ensure-card-table size))
    (setf (vm-root-set vm) (make-root-set))
    vm))

(defmethod vm-scan-roots ((vm maclina-vm) collector-state visitor-fn)
  "Scan Maclina VM roots."
  (declare (ignore collector-state))
  ;; Static roots
  (let ((rs (vm-root-set vm)))
    (dolist (root (rs-static-roots rs))
      (when (and root (not (zerop root)))
        (funcall visitor-fn root))))
  ;; Maclina stack roots
  (scan-maclina-stack-roots vm visitor-fn)
  ;; Maclina dynenv roots
  (scan-maclina-dynenv-roots vm visitor-fn)
  ;; Maclina closure roots
  (scan-maclina-closure-roots vm visitor-fn))

(defmethod vm-update-roots-forwarded ((vm maclina-vm))
  (update-root-set-forwarded vm (vm-root-set vm)))
