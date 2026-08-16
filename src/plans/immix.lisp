;;;; plans/immix.lisp -- mark-region / trace / opportunistic / global / STW.
;;;; Block-granular recycling on :full; opportunistic compaction on :major.

(in-package #:clamsara)

(defclass immix-plan (plan) ()
  (:metaclass plan-metaclass))

(defmethod boot-cycle-kinds ((p immix-plan))
  (declare (ignore p))
  '(:full :major))

(defmethod plan-handle-allocation-failure ((p immix-plan) size space)
  ;; a full collect recycles dead blocks; if that doesn't free enough, a
  ;; :major defrags (opportunistic compaction) -- the anti-fragmentation path.
  (plan-collect p :cycle-kind :full)
  (or (plan-allocate-in p size space)
      (plan-retry-after p size space :major)))

(defun make-immix-plan (vm heap-size)
  (declare (ignore heap-size))
  (destructuring-bind (a) (partition-pages (vm-page-count vm) '(1))
    (let ((space (make-instance 'immix-space :vm vm :start-page (car a)
                                 :page-count (cdr a) :name :default :default-space t)))
      (let ((p (make-instance 'immix-plan :name :immix :vm vm :spaces (list space)
                             :constraints (make-instance 'plan-constraints))))
        (add-los-space p 1/16)
        (finalize-plan p) p))))
