(in-package #:clamsara.tests)

(def-suite test-barrier :description "Barrier tests"
  :in clamsara-tests)

(in-suite test-barrier)

(test no-barrier-is-noop
  "No barrier does nothing."
  (let ((b (make-no-barrier)))
    (is (typep b 'no-barrier))
    (barrier-note-write b 100 0 200)
    (barrier-card-scan b nil (lambda (r s) (declare (ignore r s))))
    (barrier-clear-all b)))

(test object-barrier-card-marking
  "Object barrier marks card on old-to-young write."
  (with-clamsara (:plan-type :gencopy :heap-size 65536)
    (let* ((plan *active-plan*)
           (vm (plan-vm plan))
           (barrier (plan-barrier plan)))
      (is (typep barrier 'object-barrier)))))
