;;;; plans/stickyimmix.lisp -- sticky mark bits on an immix (mark-region) space.

(in-package #:clamsara)

(defclass sticky-immix-space (immix-space) ()
  (:metaclass space-metaclass))

;; immix reclaim but does NOT clear the mark stratum on minor (sticky)
(defmethod space-reclaim ((s sticky-immix-space) vm &key cycle-kind)
  (let ((a (space-allocator s)))
    (when (and (plusp (ix-block-count a)) (vm-stratum vm :mark))
      (do-immix-blocks (b a)
        (let ((live (immix-block-live-count a vm b)))
          (setf (immix-block-live b) live)
          (immix-forget-dead-objects a vm b)
          (when (zerop live)
            (vm-clear-metadata-range vm
                                     (immix-block-base b)
                                     (+ (immix-block-base b)
                                        (ix-block-words a)))
            (setf (immix-block-cursor b) (immix-block-base b)))))
      (setf (ix-current a) (ix-first-block a)))
    (when (eq cycle-kind :major) (immix-defrag s vm))
    (when (eq cycle-kind :major) (s-clear (vm-stratum vm :mark)))
    s))

(defclass sticky-immix-plan (plan) ()
  (:metaclass plan-metaclass))

(defmethod boot-cycle-kinds ((p sticky-immix-plan))
  (declare (ignore p))
  '(:minor :major))

(defmethod plan-install-strata ((p sticky-immix-plan) vm)
  (call-next-method)
  (vm-register-stratum vm :log
    (make-stratum :log (vm-min-alignment-words vm)
                  :bit (vm-heap-size vm))))

(defmethod gc-phase :prologue ((p sticky-immix-plan) k)
  (vm-stop-mutators (plan-vm p))
  (when (eq k :major) (s-clear (vm-stratum (plan-vm p) :mark))))

(defmethod gc-phase :mark ((p sticky-immix-plan) k)
  (mark-roots p (plan-tracer p))
  (if (eq k :minor)
      (sticky-rescan-dirty p)
      (s-clear (vm-stratum (plan-vm p) :log))))

(defmethod gc-phase :reclaim ((p sticky-immix-plan) k)
  (reclaim-spaces p k))

(defmethod gc-phase :release ((p sticky-immix-plan) k)
  (declare (ignore k))
  (when (plan-stats p) (stats-event (plan-stats p) :gc-cycles 1)))

(defmethod plan-handle-allocation-failure ((p sticky-immix-plan) size space)
  (plan-collect p :cycle-kind :minor)
  (or (plan-allocate-in p size space)
      (plan-retry-after p size space :major)))

(defun make-stickyimmix-plan (vm heap-size)
  (declare (ignore heap-size))
  (destructuring-bind (a) (partition-pages (vm-page-count vm) '(1))
    (let ((space (make-instance 'sticky-immix-space :vm vm
                                 :start-page (car a) :page-count (cdr a)
                                 :name :default :default-space t)))
      (let* ((barrier
               (make-instance 'barrier
                              :rules (list (sticky-dirty-barrier-rule))))
             (p (make-instance 'sticky-immix-plan
                             :name :stickyimmix :vm vm
                             :spaces (list space) :sticky t
                             :barrier barrier
                             :constraints (make-instance 'plan-constraints))))
        (setf (barrier-plan barrier) p)
        (add-los-space p 1/16)
        (finalize-plan p) p))))
