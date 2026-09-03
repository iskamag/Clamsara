;;;; test/test-stats.lisp -- exact v11 event semantics and hot accounting.

(in-package #:clamsara)

#+sbcl
(sb-alien:define-alien-variable
    ("bytes_allocated" %stats-test-bytes-allocated)
    sb-alien:unsigned-long)

(declaim (inline %exercise-stats-hot-body))
(defun %exercise-stats-hot-body (events repetitions)
  (declare (type (simple-array fixnum (*)) events)
           (type fixnum repetitions)
           (optimize (speed 3) (safety 0)))
  (dotimes (i repetitions)
    (%stats-vector-add events 11 1)
    (%stats-vector-set events 21 i))
  events)

#+sbcl
(deftest stats-first-and-repeated-hot-bodies-do-not-allocate ()
  ;; STATS-PREPARE is construction.  Both windows below contain only the
  ;; authored direct event/gauge bodies; snapshotting and CLOS/configuration
  ;; work remain outside.  No warm-up call is substituted for the first body.
  (let* ((statistics (stats-prepare (make-stats)))
         ;; CLOS record access is the explicit outer boundary.  The measured
         ;; body below receives the already bound dense counter arena.
         (events (stats-events statistics)))
    (sb-vm::close-thread-alloc-region)
    (let ((before %stats-test-bytes-allocated))
      (%exercise-stats-hot-body events 1)
      (sb-vm::close-thread-alloc-region)
      (let ((first (- %stats-test-bytes-allocated before)))
        (setf before %stats-test-bytes-allocated)
        (%exercise-stats-hot-body events 100)
        (sb-vm::close-thread-alloc-region)
        (let ((repeated (- %stats-test-bytes-allocated before)))
          (if (and (zerop first) (zerop repeated))
              (values t "ok: first and 100 repeated event/gauge writes allocated 0 host bytes")
              (values nil
                      (format nil "stats hot bodies allocated first=~D repeated=~D bytes"
                              first repeated))))))))

(deftest stats-vocabulary-is-prewarmed ()
  (let* ((statistics (stats-prepare (make-stats)))
         (storage (stats-events statistics))
         (bad
           (or (/= (length storage) (length +stats-event-names+))
               (loop for name in +stats-event-names+
                     for index from 0
                     thereis (/= (%stats-index name) index)))))
    (if bad
        (values nil "dense stats vocabulary/index layout is inconsistent")
        (values t "ok"))))

(deftest stats-gauges-replace-and-merge-without-summing ()
  (let ((left (stats-prepare (make-stats)))
        (right (stats-prepare (make-stats))))
    (stats-event left :barrier-events 2)
    (stats-sample left :retained-bytes-sample 80)
    (stats-event right :barrier-events 3)
    (stats-sample right :retained-bytes-sample 56)
    (stats-merge left right)
    (if (and (= (stats-get left :barrier-events) 5)
             (= (stats-get left :retained-bytes-sample) 56))
        (values t "ok")
        (values nil
                (format nil "merge yielded event=~D retained=~D"
                        (stats-get left :barrier-events)
                        (stats-get left :retained-bytes-sample))))))

(deftest collection-records-roots-references-safepoints-and-retained-bytes ()
  (let* ((vm (make-simulator-vm 8192))
         (plan (make-collector :semispace vm 8192)))
    (boot-gc plan)
    (let* ((child (allocate-object plan 1))
           (parent (allocate-object plan 1)))
      (vm-set-reference vm parent 0 child)
      (vm-add-root vm parent)
      (stats-reset (plan-stats plan))
      (plan-collect plan :cycle-kind :full)
      (let ((statistics (plan-stats plan)))
        (if (and (= (stats-get statistics :gc-cycles) 1)
                 (plusp (stats-get statistics :root-locations-scanned))
                 (plusp (stats-get statistics :ref-locations-scanned))
                 (plusp (stats-get statistics :safepoint-requests))
                 (plusp (stats-get statistics :safepoint-arrivals))
                 (plusp (stats-get statistics :retained-bytes-sample))
                 (zerop (stats-get statistics :collection-aborts)))
            (values t "ok")
            (values nil (format nil "incomplete collection counters: ~S"
                                (stats-snapshot statistics))))))))

(deftest fused-barrier-events-are-distinct-from-rule-transfers ()
  (let* ((vm (make-simulator-vm 16384))
         (plan (make-collector :gencopy vm 16384)))
    (boot-gc plan)
    (let ((source (allocate-object plan 1))
          (target (allocate-object plan 1)))
      (stats-reset (plan-stats plan))
      (barrier-note-write vm (plan-barrier plan) source 0 target)
      (let ((events (stats-get (plan-stats plan) :barrier-events))
            (transfers (stats-get (plan-stats plan) :barrier-transfers)))
        (if (and (= events 1) (= transfers 1))
            (values t "ok")
            (values nil
                    (format nil "events=~D transfers=~D" events transfers)))))))
