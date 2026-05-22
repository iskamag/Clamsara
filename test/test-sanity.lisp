(in-package #:clamsara.tests)

(def-suite test-sanity :description "Sanity checker tests"
  :in clamsara-tests)

(in-suite test-sanity)

(test compute-live-set-basic
  "Compute-live-set finds reachable objects."
  (with-clamsara (:plan-type :marksweep :heap-size 65536)
    (let* ((plan *active-plan*)
           (vm (plan-vm plan))
           (root (allocate-object plan 2)))
      (setf (vm-object-reference vm root 0) root)
      (clamsara-register-root root)
      (let ((live (compute-live-set vm plan)))
        (is (gethash root live))))))

(test sanity-check-after-gc-marksweep
  "Sanity checker passes after MarkSweep GC."
  (with-clamsara (:plan-type :marksweep :heap-size 65536)
    (let* ((plan *active-plan*)
           (vm (plan-vm plan))
           (root (allocate-object plan 2))
           (child (allocate-object plan 2)))
      (setf (vm-object-reference vm root 0) child)
      (setf (vm-object-reference vm child 0) root)
      (clamsara-register-root root)
      (clamsara-gc)
      (multiple-value-bind (ok errors) (sanity-check-after-gc plan)
        (is-true ok)
        (is (null errors))))))

(test make-random-object-graph
  "Random object graph is created correctly."
  (with-clamsara (:plan-type :marksweep :heap-size 65536)
    (multiple-value-bind (objects roots) (make-random-object-graph *active-plan* 20 :max-slots 4)
      (is (not (null objects)))
      (is (not (null roots)))
      (is (> (length objects) 0)))))

(test sanity-stress-small
  "Sanity stress test with a few iterations."
  (with-clamsara (:plan-type :marksweep :heap-size 262144)
    (multiple-value-bind (objects roots) (make-random-object-graph *active-plan* 10 :max-slots 3)
      (declare (ignore roots))
      (dotimes (i 5)
        (setf objects (random-mutator-step *active-plan* objects :max-slots 3)))
      (clamsara-gc)
      (multiple-value-bind (ok errors) (sanity-check-after-gc *active-plan*)
        (is-true ok)
        (is (null errors))))))
