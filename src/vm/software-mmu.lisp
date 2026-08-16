;;;; vm/software-mmu.lisp -- software implementation of T1 (virtual memory)
;;;; and T2 (ring-0) so hardware-bound collectors are simulatable.
;;;;
;;;; The heap is one physical (unsigned-byte 64) array; the MMU is an optional
;;;; overlay.  When armed, ref-u64 routes through the page table so protection
;;;; faults and page remapping are observable.  Most collectors (T0) never arm
;;;; it and use direct access.  Coloured-pointer correctness uses the software
;;;; load-value barrier (object-model) + the off-heap forwarding table, NOT
;;;; multi-mapping; the MMU is exercised by the fault-driven (T2) path.

(in-package #:clamsara)

(defparameter *mmu-trace* nil)

(defun mmu-init (vm)
  (unless (mmu-vpt vm)
    (let ((pages (vm-page-count vm)))
      (setf (mmu-vpt vm) (make-array pages :initial-element nil)
            (mmu-dirty vm) (make-array pages :element-type 'bit :initial-element 0))
      (dotimes (p pages)
        (setf (aref (mmu-vpt vm) p) (cons p :read-write))))))

(defun mmu-ensure (vm)
  (unless (mmu-vpt vm) (mmu-init vm)))

(defun mmu-arm (vm &key (clear-dirty t))
  "Enable software-MMU accesses and page dirty-bit tracking for VM.

Arming is explicit rather than a simulator-wide default: normal collector
traffic remains T0 direct access, while a checkpoint can fence the VM and then
observe every mutator write through the same MMU path.  CLEAR-DIRTY is false
when the caller has just captured a collector-owned dirty set."
  (mmu-ensure vm)
  (when clear-dirty (fill (mmu-dirty vm) 0))
  (setf (mmu-armed vm) t)
  vm)

(defun mmu-disarm (vm)
  "Disable software-MMU routing (the page table and dirty bits are retained)."
  (setf (mmu-armed vm) nil)
  vm)

(declaim (inline mmu-access-violates-p))
(defun mmu-access-violates-p (prot access-kind)
  (ecase access-kind
    (:read  (member prot '(:none :write)))
    (:write (not (eq prot :read-write)))))

(declaim (inline mmu-translate))
(defun mmu-translate (vm virt-addr entry)
  (declare (ignore vm))
  (let ((phys-page (car entry)))
    (+ (ash phys-page +log-page-words+) (logand virt-addr (1- +page-words+)))))

(defun mmu-ref (vm virt-addr access-kind)
  (mmu-ensure vm)
  (let* ((vp (address-page virt-addr))
         (entry (aref (mmu-vpt vm) vp)))
    (when (mmu-access-violates-p (cdr entry) access-kind)
      (if (mmu-handler vm)
          (funcall (mmu-handler vm) virt-addr access-kind)
          (error 'clamsara-error
                 :message (format nil "software page fault @ ~a (~a)" virt-addr access-kind)))
      (setf entry (aref (mmu-vpt vm) vp)))
    (when (eq access-kind :write) (setf (sbit (mmu-dirty vm) vp) 1))
    (aref (vm-heap vm) (mmu-translate vm virt-addr entry))))

(defun (setf mmu-ref) (new vm virt-addr access-kind)
  (mmu-ensure vm)
  (let* ((vp (address-page virt-addr))
         (entry (aref (mmu-vpt vm) vp)))
    (when (mmu-access-violates-p (cdr entry) access-kind)
      (if (mmu-handler vm)
          (funcall (mmu-handler vm) virt-addr access-kind)
          (error 'clamsara-error
                 :message (format nil "software page fault (write) @ ~a" virt-addr)))
      (setf entry (aref (mmu-vpt vm) vp)))
    (setf (sbit (mmu-dirty vm) vp) 1)
    (setf (aref (vm-heap vm) (mmu-translate vm virt-addr entry)) new)))

;; ---- override memory access when the MMU is armed -----------------------

(defmethod ref-u64 :around ((vm virtual-memory-mixin) address)
  (if (mmu-armed vm)
      (mmu-ref vm address :read)
      (call-next-method)))

(defmethod (setf ref-u64) :around (new-value (vm virtual-memory-mixin) address)
  (if (mmu-armed vm)
      (setf (mmu-ref vm address :write) new-value)
      (call-next-method)))

;; ---- T1 protocol (userspace virtual memory) -----------------------------

(defgeneric vm-mprotect (vm page-index count protection)
  (:method ((vm virtual-memory-mixin) page-index count protection)
    (mmu-ensure vm)
    (loop for p from page-index below (+ page-index count)
          do (setf (cdr (aref (mmu-vpt vm) p)) protection))))

(defgeneric vm-map-alias (vm phys-page virt-page count)
  (:method ((vm virtual-memory-mixin) phys-page virt-page count)
    (mmu-ensure vm)
    (loop for k below count
          for entry = (aref (mmu-vpt vm) (+ virt-page k))
          do (setf (car entry) (+ phys-page k)
                   (cdr entry) :read-write))
    virt-page))

(defgeneric vm-unmap (vm virt-page count)
  (:method ((vm virtual-memory-mixin) virt-page count)
    (mmu-ensure vm)
    (loop for k below count
          for entry = (aref (mmu-vpt vm) (+ virt-page k))
          do (setf (car entry) 0 (cdr entry) :none))))

(defgeneric vm-page-dirty-p (vm page-index)
  (:method ((vm virtual-memory-mixin) page-index)
    (mmu-ensure vm)
    (eql 1 (sbit (mmu-dirty vm) page-index))))

(defgeneric vm-clear-page-dirty (vm page-index)
  (:method ((vm virtual-memory-mixin) page-index)
    (mmu-ensure vm)
    (setf (sbit (mmu-dirty vm) page-index) 0)))

;; ---- T2 protocol (ring-0) ------------------------------------------------

(defgeneric vm-install-fault-handler (vm handler-fn)
  (:method ((vm ring0-mixin) handler-fn)
    (setf (mmu-handler vm) handler-fn)))

(defgeneric vm-remap (vm virt-page phys-page count)
  (:method ((vm ring0-mixin) virt-page phys-page count)
    (mmu-ensure vm)
    (loop for k below count
          do (setf (car (aref (mmu-vpt vm) (+ virt-page k))) (+ phys-page k)))))

(defgeneric vm-flush-tlb (vm &optional page-index count)
  (:method ((vm ring0-mixin) &optional page-index count)
    (declare (ignore page-index count))
    nil)) ; software TLB is always consistent

;; ---- coloured-pointer accessors (in-pointer metadata) ------------------

(defgeneric ref-colour (vm reference)
  (:method ((vm coloured-pointer-mixin) reference)
    (ash (logand reference +colour-mask+) (- +colour-pos+))))
(defgeneric ref-set-colour (vm reference colour)
  (:method ((vm coloured-pointer-mixin) reference colour)
    (logior (ash (ldb (byte +colour-bits+ 0) colour) +colour-pos+)
            (logand reference (lognot +colour-mask+)))))
(defgeneric ref-good-colour-p (vm reference)
  (:method ((vm coloured-pointer-mixin) reference)
    (eql (ref-colour vm reference) (vm-good-colour vm))))
(defgeneric ref-strip (vm reference)
  (:method ((vm coloured-pointer-mixin) reference)
    (logand reference (lognot +colour-mask+))))
