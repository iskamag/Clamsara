(in-package #:clamsara)

;;; --- Copy Semantics ---
;;; Describes why an object is being copied.

(defvar *copy-semantics*
  '(:default :promote-to-mature :mature :none)
  "Valid copy semantics.")

(defclass copy-config ()
  ((copy-selector :initarg :copy-selector :reader copy-config-selector)
   (space-mapping :initarg :space-mapping :reader copy-config-space-mapping))
  (:documentation "Per-plan copy semantics configuration."))

(defun make-copy-config (&key copy-selector space-mapping)
  (make-instance 'copy-config :copy-selector copy-selector :space-mapping space-mapping))
