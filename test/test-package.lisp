(defpackage #:clamsara.tests
  (:use #:cl #:alexandria #:serapeum #:fiveam #:clamsara)
  (:shadow #:space)
  (:nicknames #:clamsara-tests)
  (:export #:run-tests
           #:run-benchmark
           #:run-all-benchmarks
           #:clamsara-tests))

(in-package #:clamsara.tests)

(def-suite clamsara-tests
  :description "Clamsara test suite")

(defun run-tests ()
  "Run all Clamsara tests. Returns T on pass, list of failures otherwise."
  (let ((results (run! 'clamsara-tests)))
    (if (eq results t)
        t
      (progn
        (format t "~&Test failures: ~A~%" results)
        results))))
