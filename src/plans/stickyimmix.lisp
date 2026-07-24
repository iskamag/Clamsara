;;;; plans/stickyimmix.lisp -- sticky mark bits on an immix (mark-region) space.

(in-package #:clamsara)

(defclass sticky-immix-space (immix-space) ()
  (:metaclass space-metaclass))

;; immix reclaim but does NOT clear the mark stratum on minor (sticky)
(defmethod space-reclaim ((s sticky-immix-space) vm &key cycle-kind)
  (let ((a (space-allocator s)))
    (when (and (ix-blocks a) (vm-stratum vm :mark))
      (dolist (b (ix-blocks a))
        (let ((live (immix-block-live-count a vm b)))
          (setf (immix-block-live b) live)
          (when (zerop live)
            (setf (immix-block-cursor b) (immix-block-base b)))))
      (setf (ix-current a) (first (ix-blocks a))))
    (when (eq cycle-kind :major) (immix-defrag s vm))
    (when (eq cycle-kind :major) (s-clear (vm-stratum vm :mark)))
    s))

(defclass sticky-immix-plan (plan) ()
  (:metaclass plan-metaclass))

(defmethod phase-prologue ((p sticky-immix-plan) k)
  (vm-stop-mutators (plan-vm p))
  (when (eq k :major) (s-clear (vm-stratum (plan-vm p) :mark))))

(defmethod phase-mark ((p sticky-immix-plan) k)
  (declare (ignore k)) (mark-roots p (plan-tracer p)))

(defmethod phase-reclaim ((p sticky-immix-plan) k)
  (map-spaces p (lambda (s ck) (space-reclaim s (plan-vm p) :cycle-kind ck))))

(defmethod phase-release ((p sticky-immix-plan) k)
  (declare (ignore k))
  (when (plan-stats p) (stats-event (plan-stats p) :gc-cycles 1)))

(defmethod plan-collect ((p sticky-immix-plan) &key cycle-kind)
  (let ((fn (gethash 'plan-collect (plan-function-table p))))
    (if fn (funcall fn p (or cycle-kind :minor))
        (plan-collect-phase p (or cycle-kind :minor)))))

(defmethod plan-handle-allocation-failure ((p sticky-immix-plan) size space)
  (plan-collect p :cycle-kind :minor)
  (let ((addr (alloc (space-allocator space) size)))
    (cond (addr (let ((os (vm-object-start (plan-vm p))))
                 (when os (s-set-bit os addr))) addr)
          (t (plan-collect p :cycle-kind :major)
             (let ((a2 (alloc (space-allocator space) size)))
               (if a2
                   (progn (let ((os (vm-object-start (plan-vm p))))
                            (when os (s-set-bit os a2))) a2)
                   (error 'heap-exhausted :requested-size size :space :default)))))))

(defun make-stickyimmix-plan (vm heap-size)
  (declare (ignore heap-size))
  (destructuring-bind (a) (partition-pages (vm-page-count vm) '(1))
    (let ((space (make-instance 'sticky-immix-space :vm vm
                                 :start-page (car a) :page-count (cdr a)
                                 :name :default :default-space t)))
      (let ((p (make-instance 'sticky-immix-plan :name :stickyimmix :vm vm
                             :spaces (list space) :sticky t
                             :constraints (make-instance 'plan-constraints))))
        (finalize-plan p) p))))
