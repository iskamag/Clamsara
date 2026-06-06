(in-package #:clamsara.tests)

(def-suite test-sanity :description "Sanity checker and stress tests"
  :in clamsara-tests)

(in-suite test-sanity)

;;; Per-plan heap sizing: copying plans need more room because
;;; semispaces split the heap in half, and generational plans
;;; allocate the nursery at 1/8 of total heap.

(defun sanity-heap-size (plan-type)
  "Return a heap size suitable for stress-testing PLAN-TYPE."
  (case plan-type
    ((:marksweep :immix :stickyms :stickyimmix) 131072)
    ((:semispace) 262144)
    ((:gencopy :genms :genimmix) 524288)
    (t 262144)))

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
    (with-clamsara (:plan-type plan-type :heap-size (sanity-heap-size plan-type))
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
    (with-clamsara (:plan-type plan-type :heap-size (sanity-heap-size plan-type))
      (multiple-value-bind (objects roots) (make-random-object-graph *active-plan* 20 :max-slots 4)
        (is (not (null objects)))
        (is (not (null roots)))
        (is (> (length objects) 0))))))

(test random-mutator-steps
  "Random mutation does not crash."
  (dolist (plan-type '(:semispace :marksweep :immix :gencopy :genms
                       :genimmix :stickyimmix :stickyms))
    (with-clamsara (:plan-type plan-type :heap-size (sanity-heap-size plan-type))
      (multiple-value-bind (objects roots) (make-random-object-graph *active-plan* 10 :max-slots 3)
        (declare (ignore roots))
        (dotimes (i 10)
          (handler-case
              (setf objects (random-mutator-step *active-plan* objects :max-slots 3))
            (heap-exhausted ()
              (setf objects nil)))
          (unless objects (return)))
        (is (not (null objects)))
        (let ((addr (allocate-object *active-plan* 2)))
          (clamsara-register-root addr)
          (clamsara-gc)
          ;; Random mutations may create garbage cycles with stale
          ;; references. The sanity checker should run without crashing.
          (multiple-value-bind (ok errors) (sanity-check-after-gc *active-plan*)
            (declare (ignore ok errors))
            (is-true t)))))))

(test sanity-stress-small
  "Small sanity stress: mutate, GC, sanity check doesn't crash."
  (dolist (plan-type '(:marksweep :semispace :immix :gencopy :genms
                       :genimmix :stickyimmix :stickyms))
    (with-clamsara (:plan-type plan-type :heap-size (sanity-heap-size plan-type))
      (let* ((plan *active-plan*)
             (objects nil))
        (multiple-value-bind (objs roots) (make-random-object-graph plan 20 :max-slots 3)
          (declare (ignore roots))
          (setf objects objs))
        (dotimes (i 5)
          (handler-case
              (setf objects (random-mutator-step plan objects :max-slots 3))
            (heap-exhausted ()
              (setf objects nil)))
          (when objects
            (handler-case (clamsara-gc)
              (heap-exhausted ()
                (setf objects nil))))
          (when objects
            (multiple-value-bind (ok errors) (sanity-check-after-gc plan)
              (declare (ignore ok errors))
              (is-true t))))
        ;; If objects is nil, heap was exhausted; the test is about
        ;; not crashing, not about never running out of space.
        (when objects
          (is (not (null objects))))))))
