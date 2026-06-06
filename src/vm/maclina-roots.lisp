(in-package #:clamsara-vm)

;;; --- Maclina Root Scanner ---

(defun scan-maclina-stack-roots (vm visitor-fn)
  "Scan the Maclina *vm* stack for roots."
  (let* ((maclina-vm maclina.vm-cross::*vm*)
         (stack (when maclina-vm (maclina.vm-cross::vm-stack maclina-vm))))
    (when stack
      (loop for i from 0 below (length stack)
            for val = (aref stack i)
            when (vm-valid-reference-p vm val)
              do (funcall visitor-fn val)))))

(defun scan-maclina-dynenv-roots (vm visitor-fn)
  "Scan the Maclina dynamic environment stack for roots."
  (let* ((maclina-vm maclina.vm-cross::*vm*)
         (dynenv-stack (when maclina-vm
                         (maclina.vm-cross::vm-dynenv-stack maclina-vm))))
    (dolist (entry dynenv-stack)
      (scan-dynenv-entry vm entry visitor-fn))))

(defun scan-dynenv-entry (vm entry visitor-fn)
  "Scan a single dynamic environment entry for references."
  (when entry
    (typecase entry
      (cons
       (let ((tag (car entry))
             (data (cdr entry)))
         (when (vm-valid-reference-p vm tag)
           (funcall visitor-fn tag))
         ;; CDR of cons-based dynenv entries may hold heap references
         (when (and (consp data) (vm-valid-reference-p vm (car data)))
           (funcall visitor-fn (car data)))))
      (t nil))))

(defun scan-maclina-closure-roots (vm visitor-fn)
  "Scan all closure environments for references."
  (let* ((maclina-vm maclina.vm-cross::*vm*)
         (stack (when maclina-vm (maclina.vm-cross::vm-stack maclina-vm)))
         (closure-class (find-class 'maclina.vm-cross::closure nil)))
    (when stack
      (loop for i from 0 below (length stack)
            for val = (aref stack i)
            when (and closure-class
                      (typep val closure-class))
              do (let ((env (maclina.vm-cross::environment val)))
                   (when (simple-vector-p env)
                     (loop for j from 0 below (length env)
                           for env-val = (aref env j)
                           when (vm-valid-reference-p vm env-val)
                             do (funcall visitor-fn env-val))))))))

(defun update-maclina-stack-forwarded (vm)
  "Update Maclina interpreter stack entries that hold forwarded addresses.
Walks the Maclina VM stack and replaces any forwarded object references
with their new addresses, following forwarding chains."
  (let* ((maclina-vm maclina.vm-cross::*vm*)
         (stack (when maclina-vm (maclina.vm-cross::vm-stack maclina-vm))))
    (when stack
      (loop for i from 0 below (length stack)
            for val = (aref stack i)
            when (and val (not (zerop val))
                      (vm-valid-reference-p vm val)
                      (vm-object-is-forwarded-p vm val))
              do (setf (aref stack i)
                       (vm-object-forwarding-pointer vm val))))))
