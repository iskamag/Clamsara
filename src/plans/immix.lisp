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
  (let ((spaces (make-plan-spaces vm
                   '((immix-space 1 :default :default-space t)))))
    (let ((p (make-instance 'immix-plan :name :immix :vm vm
                            :spaces spaces
                            :constraints (make-instance 'plan-constraints))))
      (finalize-plan p))))
