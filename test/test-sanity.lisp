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
  (dolist (plan-type '(:semispace :marksweep :immix))
    (with-clamsara (:plan-type plan-type :heap-size 1048576)
      (multiple-value-bind (objects roots) (make-random-object-graph *active-plan* 8 :max-slots 2)
        (declare (ignore roots))
        (let ((done nil))
          (dotimes (i 5)
            (unless done
              (handler-case
                  (setf objects (random-mutator-step *active-plan* objects :max-slots 2))
                (heap-exhausted ()
                  (setf objects nil done t)))))
          (when objects
            (is (not (null objects)))
            (let ((addr (allocate-object *active-plan* 2)))
              (clamsara-register-root addr)
              (clamsara-gc)
              (multiple-value-bind (ok errors) (sanity-check-after-gc *active-plan*)
                (declare (ignore errors))
                (is-true ok)))))))))

(test sanity-stress-small
  "Small sanity stress: mutate, GC, verify."
  (dolist (plan-type '(:marksweep :semispace :immix))
    (with-clamsara (:plan-type plan-type :heap-size 1048576)
      (let* ((plan *active-plan*)
             (objects nil)
             (exhausted nil))
        (multiple-value-bind (objs roots) (make-random-object-graph plan 15 :max-slots 2)
          (declare (ignore roots))
          (setf objects objs))
        (dotimes (i 3)
          (unless exhausted
            (handler-case
                (setf objects (random-mutator-step plan objects :max-slots 2))
              (heap-exhausted ()
                (setf objects nil exhausted t)))))
        (when objects
          (clamsara-gc)
          (multiple-value-bind (ok errors) (sanity-check-after-gc plan)
            (declare (ignore errors))
            (is-true ok)))
        (is (not (null objects)))))))
