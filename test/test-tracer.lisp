(in-package #:clamsara.tests)

(def-suite test-tracer :description "Tracer tests"
  :in clamsara-tests)

(in-suite test-tracer)

(test tracer-enqueue-dequeue
  "Tracer enqueue and dequeue work correctly."
  (with-clamsara (:plan-type :marksweep :heap-size 65536)
    (let* ((plan *active-plan*)
           (vm (plan-vm plan))
           (tracer (make-tracer vm (lambda (r) r) :queue-size 128)))
      (is (tracer-empty-p tracer))
      (tracer-enqueue tracer 1)
      (tracer-enqueue tracer 2)
      (tracer-enqueue tracer 3)
      (is (not (tracer-empty-p tracer)))
      (is (= 1 (tracer-dequeue tracer)))
      (is (= 2 (tracer-dequeue tracer)))
      (is (= 3 (tracer-dequeue tracer)))
      (is (tracer-empty-p tracer)))))

(test tracer-process-roots
  "Tracer processes roots correctly."
  (with-clamsara (:plan-type :marksweep :heap-size 65536)
    (let* ((plan *active-plan*)
           (vm (plan-vm plan))
           (root (allocate-object plan 2)))
      (setf (vm-object-reference vm root 0) root)
      (clamsara-register-root root)
      (let ((tracer (make-tracer vm
                     (lambda (r)
                       (unless (vm-object-is-marked-p vm r)
                         (setf (vm-object-is-marked-p vm r) t)
                         r))
                     :queue-size 128)))
        (vm-scan-roots vm plan
          (lambda (r)
            (when (and r (not (zerop r)))
              (tracer-enqueue tracer r))))
        (tracer-process-queue tracer)
        (is (vm-object-is-marked-p vm root))
        (is (> (tracer-visit-count tracer) 0))))))
