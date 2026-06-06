(in-package #:clamsara)

;;; --- Simulator VM ---
;;; The primary test backend. Uses *HEAP* for storage and side metadata for GC state.

(defclass simulator-vm (vm-binding)
  ((stack :accessor simulator-stack
    :initform (make-array 1024 :initial-element 0))
   (roots :accessor simulator-roots
    :initform (make-array 256 :adjustable t :initial-element 0 :fill-pointer 0)))
  (:documentation "Simulator VM binding."))

(defun make-simulator-vm (&key (heap-size 65536))
  "Create a simulator VM with a heap of HEAP-SIZE words."
  (let* ((vm (make-instance 'simulator-vm)))
    (ensure-heap heap-size)
    (ensure-page-table heap-size)
    (ensure-metadata heap-size)
    (setf (vm-card-table vm) (ensure-card-table heap-size)
          (vm-root-set vm) (make-root-set))
    (setf (slot-value vm 'heap-size) heap-size)
    vm))

(defmethod vm-scan-roots ((vm simulator-vm) collector-state visitor-fn)
  "Scan all registered roots (static, thread, and simulated stack)."
  (declare (ignore collector-state))
  ;; Static roots
  (let ((rs (vm-root-set vm)))
    (dolist (root (rs-static-roots rs))
      (when (and root (not (zerop root)))
        (funcall visitor-fn root)))
    ;; Thread roots
    (maphash (lambda (thread-id trs)
               (declare (ignore thread-id))
               (dolist (root (trs-roots trs))
                 (when (and root (not (zerop root)))
                   (funcall visitor-fn root))))
             (rs-thread-roots rs)))
  ;; Simulated stack roots
  (when *simulated-stack*
    (scan-simulated-stack vm (vm-root-set vm))))

;;; --- Simulated Stack ---

(defstruct stack-frame
  "Fake stack frame for simulation testing."
  (function nil :type (or null symbol))
  (pc nil :type (or null fixnum))
  (slots nil :type list))

(defvar *simulated-stack* nil
  "Simulated call stack for testing stack scanning.")

(defvar *simulated-thread-id* :simulated-thread
  "Thread ID used for simulated stack frame roots.")

(defun push-stack-frame (function pc slots)
  (push (make-stack-frame :function function :pc pc :slots slots)
        *simulated-stack*))

(defun pop-stack-frame ()
  (pop *simulated-stack*))

(defun clear-simulated-stack ()
  (setf *simulated-stack* nil))

(defun scan-simulated-stack (vm root-set)
  "Scan all stack frames for reference-type slots and register them as
thread roots. Clears previous stack roots first to avoid accumulation."
  (declare (ignore vm))
  ;; Clear previous stack roots to avoid accumulation across GC cycles
  (remhash *simulated-thread-id* (rs-thread-roots root-set))
  (dolist (frame *simulated-stack*)
    (dolist (slot (stack-frame-slots frame))
      (when (and slot (not (zerop slot)) (typep slot 'fixnum))
        (register-thread-root root-set *simulated-thread-id* slot)))))

(defmethod vm-update-roots-forwarded ((vm simulator-vm))
  (update-root-set-forwarded vm (vm-root-set vm))
  ;; Also update stack frame slots so the simulated stack doesn't hold
  ;; stale pre-move addresses after copying GC
  (dolist (frame *simulated-stack*)
    (let ((slots (stack-frame-slots frame)))
      (setf (stack-frame-slots frame)
            (loop for slot in slots
                  collect (if (and slot (not (zerop slot))
                                   (vm-valid-reference-p vm slot)
                                   (vm-object-is-forwarded-p vm slot))
                              (vm-object-forwarding-pointer vm slot)
                              slot))))))
