(in-package #:clamsara)

;;; --- Maclina Root Scanner ---

(defun scan-maclina-stack-roots (vm visitor-fn)
  "Scan the Maclina *vm* stack for roots."
  (declare (ignore vm))
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
      ;; handle cons-based dynenv entries
      (cons
       (let ((tag (car entry)))
         (when (vm-valid-reference-p vm tag)
           (funcall visitor-fn tag))))
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
