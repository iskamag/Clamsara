;;;; plans/stickyms.lisp -- sticky mark bits on a mark-sweep space.
;;;; The mark stratum is sticky: it persists across minor cycles (survivors
;;;; keep their mark), so a minor collection only reclaims newly-dead (unmarked)
;;;; objects.  A major cycle clears all marks and reclaims everything unreachable.

(in-package #:clamsara)

(defclass sticky-mark-sweep-space (mark-sweep-space) ()
  (:metaclass space-metaclass))

;; like mark-sweep reclaim but does NOT clear the mark stratum (sticky)
(defmethod space-reclaim ((s sticky-mark-sweep-space) vm &key cycle-kind)
  (declare (ignore cycle-kind))
  (let ((a (space-allocator s))
        (os (vm-object-start vm))
        (mark (vm-stratum vm :mark))
        (start (space-base-address s))
        (end (space-end-address s)))
    (when (and a os mark)
      (s-for-set-cells os (cons start end)
        (lambda (addr)
          (unless (s-test-bit mark addr)
            (free a addr (vm-object-total-words vm addr))))))
    s))
(defclass sticky-ms-plan (plan) ()
  (:metaclass plan-metaclass))

(defmethod phase-prologue ((p sticky-ms-plan) k)
  (vm-stop-mutators (plan-vm p))
  (when (eq k :major) (s-clear (vm-stratum (plan-vm p) :mark))))

(defmethod phase-mark ((p sticky-ms-plan) k)
  (declare (ignore k)) (mark-roots p (plan-tracer p)))

(defmethod phase-reclaim ((p sticky-ms-plan) k)
  (map-spaces p (lambda (s ck) (space-reclaim s (plan-vm p) :cycle-kind ck))))

(defmethod phase-release ((p sticky-ms-plan) k)
  (declare (ignore k))
  (when (plan-stats p) (stats-event (plan-stats p) :gc-cycles 1)))

(defmethod plan-collect ((p sticky-ms-plan) &key cycle-kind)
  (let ((fn (gethash 'plan-collect (plan-function-table p))))
    (if fn (funcall fn p (or cycle-kind :minor))
        (plan-collect-phase p (or cycle-kind :minor)))))

(defmethod plan-handle-allocation-failure ((p sticky-ms-plan) size space)
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

(defun make-stickyms-plan (vm heap-size)
  (declare (ignore heap-size))
  (destructuring-bind (a) (partition-pages (vm-page-count vm) '(1))
    (let ((space (make-instance 'sticky-mark-sweep-space :vm vm
                                 :start-page (car a) :page-count (cdr a)
                                 :name :default :default-space t)))
      (let ((p (make-instance 'sticky-ms-plan :name :stickyms :vm vm
                             :spaces (list space) :sticky t
                             :constraints (make-instance 'plan-constraints))))
        (finalize-plan p) p))))
