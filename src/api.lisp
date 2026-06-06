(in-package #:clamsara)

;;; --- High-Level Clamsara API ---

(defvar *active-plan* nil
  "The currently active plan instance.")

(defvar *active-vm* nil
  "The currently active VM binding instance.")

(defun make-plan (type vm heap-size &rest initargs)
  "Create a plan of the given TYPE using the registered selectors.
Calls boot-gc after construction to populate the compiled function table."
  (let ((plan (apply #'plan-selector type vm heap-size initargs)))
    (boot-gc plan)
    plan))

(defun select-plan (plan-type vm heap-size)
  "Create a plan using the global selector registry."
  (make-plan plan-type vm heap-size))

(defun clamsara-gc ()
  "Trigger a GC cycle on the active plan."
  (unless *active-plan*
    (error 'no-active-plan :message "No active Clamsara plan."))
  (let* ((plan *active-plan*)
         (start (get-internal-run-time)))
    (plan-collect plan)
    (incf *gc-pause-time* (- (get-internal-run-time) start))
    (incf *gc-count*)))

(defun clamsara-register-root (addr)
  "Register ADDR as a GC root in the active plan."
  (unless *active-plan*
    (error 'no-active-plan))
  (register-root (vm-root-set (plan-vm *active-plan*)) addr))

(defun clamsara-allocate-object (n-slots &key (space :default) (type-tag +type-tag-object+))
  "Allocate an object with N-SLOTS reference slots."
  (unless *active-plan*
    (error 'no-active-plan))
  (let* ((plan *active-plan*)
         (vm (plan-vm plan))
         (total-words (1+ n-slots))
         (addr (plan-allocate plan total-words space)))
    (when addr
      (setf (vm-object-header vm addr) (make-object-header n-slots :type-tag type-tag)))
    addr))

(defun clamsara-allocate (size &key (space :default))
  "Allocate SIZE words and write a default header."
  (unless *active-plan*
    (error 'no-active-plan))
  (clamsara-allocate-object size :space space))

(defun clamsara-cons (car cdr)
  "Create a cons cell in the active plan's heap."
  (let ((plan *active-plan*))
    (unless plan (error 'no-active-plan))
    (let ((vm (plan-vm plan)))
      (let ((addr (plan-allocate plan 3 :default)))
        (when addr
          (setf (vm-object-header vm addr) (make-object-header 2 :type-tag +type-tag-cons+))
          (setf (vm-object-reference vm addr 0) car)
          (setf (vm-object-reference vm addr 1) cdr))
        addr))))

(defun clamsara-car (addr)
  (let ((vm (plan-vm *active-plan*)))
    (if (and (integerp addr) (not (zerop addr))
             (= (vm-object-type-tag vm addr) +type-tag-cons+))
        (vm-object-reference vm addr 0)
        (when (consp addr) (car addr)))))

(defun clamsara-cdr (addr)
  (let ((vm (plan-vm *active-plan*)))
    (if (and (integerp addr) (not (zerop addr))
             (= (vm-object-type-tag vm addr) +type-tag-cons+))
        (vm-object-reference vm addr 1)
        (when (consp addr) (cdr addr)))))

(defun clamsara-heap-usage ()
  "Return heap usage statistics."
  (unless *active-plan*
    (error 'no-active-plan))
  (vm-heap-usage (plan-vm *active-plan*)))

;;; --- WITH-CLAMSARA Macro ---

(defmacro with-active-plan ((plan) &body body)
  "Execute BODY with PLAN bound to *ACTIVE-PLAN*."
  `(let ((*active-plan* ,plan))
     ,@body))

(defmacro with-active-vm ((vm) &body body)
  "Execute BODY with VM bound to *ACTIVE-VM*."
  `(let ((*active-vm* ,vm))
     ,@body))

(defmacro with-active-gc ((vm plan) &body body)
  "Execute BODY with both VM and PLAN as active context."
  `(let ((*active-vm* ,vm)
         (*active-plan* ,plan))
     ,@body))

(defmacro with-clamsara ((&key (plan-type :semispace) (heap-size 65536)) &body body)
  "Execute BODY with an active Clamsara plan."
  (let ((vm-var (gensym "VM"))
        (plan-var (gensym "PLAN")))
    `(let* ((,vm-var (make-simulator-vm :heap-size ,heap-size))
            (,plan-var (select-plan ,plan-type ,vm-var ,heap-size))
            (*active-plan* ,plan-var)
            (*active-vm* ,vm-var))
       (unwind-protect
            (progn ,@body)
         (setf *active-plan* nil
               *active-vm* nil)))))
