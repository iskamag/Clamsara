(in-package #:clamsara.tests)

(def-suite test-space :description "Space tests"
  :in clamsara-tests)

(in-suite test-space)

(test space-contains-p
  "Space containment check works."
  (with-clamsara (:plan-type :marksweep :heap-size 65536)
    (let* ((plan *active-plan*)
           (space (plan-get-space plan :default))
           (start (* (space-start-page space) +page-size-words+))
           (end (+ start (* (space-page-count space) +page-size-words+))))
      (is (space-contains-p space start))
      (is (space-contains-p space (1- end)))
      (is (not (space-contains-p space (1+ end)))))))

(test space-address-range
  "Space address range is correct."
  (with-clamsara (:plan-type :marksweep :heap-size 65536)
    (let* ((plan *active-plan*)
           (space (plan-get-space plan :default)))
      (multiple-value-bind (start end) (space-address-range space)
        (is (< (address-index start) (address-index end)))
        (is (= (space-start-page space) (floor (address-index start) +page-size-words+)))))))
