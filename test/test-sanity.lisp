(in-package #:clamsara.tests)

(def-suite test-sanity :description "Sanity checker and stress tests"
  :in clamsara-tests)

(in-suite test-sanity)

(test compute-live-set-finds-reachable
  "Compute-live-set finds all reachable objects."
  (with-clamsara (:plan-type :marksweep :heap-size 65536)
    (let* ((plan *active-plan*)
           (vm (plan-vm plan))
           (root (allocate-fill plan 2 0 0)))
      (setf (vm-object-reference vm root 0) root)
      (clamsara-register-root root)
      (let ((live (compute-live-set vm plan)))
        (is (gethash root live))))))

(test sanity-check-passes-after-gc
  "Sanity checker passes after GC for all plan types."
  (dolist (plan-type '(:semispace :marksweep :immix :gencopy :genms
                       :genimmix :stickyimmix :stickyms))
    (with-clamsara (:plan-type plan-type :heap-size 131072)
      (let* ((plan *active-plan*)
             (vm (plan-vm plan))
             (root (allocate-fill plan 2 0 0))
             (child (allocate-fill plan 2 0 0)))
        (setf (vm-object-reference vm root 0) child)
        (setf (vm-object-reference vm child 0) root)
        (clamsara-register-root root)
        (clamsara-gc)
        (multiple-value-bind (result errors) (sanity-check-after-gc plan)
          (is-true result)
          (is (null errors)))))))

(test random-object-graph-creation
  "Random object graph generator creates non-empty graphs."
  (dolist (plan-type '(:semispace :marksweep :immix))
    (with-clamsara (:plan-type plan-type :heap-size 65536)
      (multiple-value-bind (objects roots) (make-random-object-graph *active-plan* 20 :max-slots 4)
        (is (not (null objects)))
        (is (not (null roots)))
        (is (> (length objects) 0))))))

(test random-mutator-steps
  "Random mutation does not crash."
  (dolist (plan-type '(:semispace :marksweep :immix :gencopy))
    (with-clamsara (:plan-type plan-type :heap-size 131072)
      (multiple-value-bind (objects roots) (make-random-object-graph *active-plan* 10 :max-slots 3)
        (declare (ignore roots))
        (dotimes (i 10)
          (setf objects (random-mutator-step *active-plan* objects :max-slots 3))
          (is (not (null objects)))))
      (let ((addr (allocate-object *active-plan* 2)))
        (clamsara-register-root addr)
        (clamsara-gc)
        (multiple-value-bind (ok errors) (sanity-check-after-gc *active-plan*)
          (is-true ok)
          (is (null errors)))))))

(test sanity-stress-small
  "Small sanity stress: mutate, GC, verify."
  (dolist (plan-type '(:marksweep :semispace :immix :gencopy))
    (with-clamsara (:plan-type plan-type :heap-size 262144)
      (let* ((plan *active-plan*)
             (objects nil))
        ;; Build graph
        (multiple-value-bind (objs roots) (make-random-object-graph plan 30 :max-slots 3)
          (declare (ignore roots))
          (setf objects objs))
        ;; Mutate + GC + verify, repeat
        (dotimes (i 5)
          (setf objects (random-mutator-step plan objects :max-slots 3))
          (clamsara-gc)
          (multiple-value-bind (ok errors) (sanity-check-after-gc plan)
            (is-true ok)
            (is (null errors))))
        (is (not (null objects)))))))
