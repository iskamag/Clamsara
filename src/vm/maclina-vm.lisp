(in-package #:clamsara)

;;; --- Maclina VM Binding ---
;;; Bridges Clamsara plans to Maclina's interpreter.
;;; Like simulator-vm, uses the global *HEAP*, *METADATA-WORDS*, and
;;; *PAGE-TABLE* for storage. Root scanning is Maclina-specific.

(defclass maclina-vm (vm-binding)
  ()
  (:documentation "Maclina VM binding. Shares the global heap with simulator-vm
but provides Maclina-specific root scanning (stack, dynenv, closures)."))

(defun make-maclina-vm (&key (heap-size 65536))
  "Create a maclina-vm with a heap of HEAP-SIZE words."
  (let* ((vm (make-instance 'maclina-vm)))
    (ensure-heap heap-size)
    (ensure-page-table heap-size)
    (ensure-metadata heap-size)
    (setf (vm-card-table vm) (ensure-card-table heap-size)
          (vm-root-set vm) (make-root-set))
    (setf (slot-value vm 'heap-size) heap-size)
    vm))

(defmethod vm-scan-roots ((vm maclina-vm) collector-state visitor-fn)
  "Scan all Maclina roots: static, stack, dynamic environment, and closures."
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
  (update-root-set-forwarded vm (vm-root-set vm))
  ;; Update Maclina stack entries that hold forwarded addresses
  (update-maclina-stack-forwarded vm))
