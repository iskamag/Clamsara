(in-package #:clamsara)

;;; --- Maclina Allocation Redirect ---
;;; Redirects Maclina's cell allocation to the Clamsara heap.

(defclass clamsara-maclina-client (maclina.vm-cross:client)
  ((plan :initarg :plan :accessor maclina-client-plan))
  (:documentation "Custom Maclina client that redirects allocation to Clamsara."))

(defmethod maclina.machine:make-cell ((client clamsara-maclina-client) value)
  "Allocate a cell in the Clamsara heap. Returns raw address."
  (let* ((plan (maclina-client-plan client))
         (vm (plan-vm plan))
         (addr (plan-allocate plan 3 :default)))
    (when (null addr)
      (error 'heap-exhausted :plan plan :message "Clamsara cell allocation failed"))
    (setf (vm-object-header vm addr) (make-object-header 2 :type-tag +type-tag-object+))
    (setf (vm-object-reference vm addr 0) value)
    (setf (vm-object-reference vm addr 1) 0)
    addr))
