(defpackage #:clamsara.tests
  (:use #:cl #:fiveam #:clamsara)
  (:shadow #:space)
  (:export #:run-tests))

(in-package #:clamsara.tests)

(def-suite clamsara-tests
  :description "Master test suite for Clamsara")

(defun run-tests ()
  (let ((results (run! 'clamsara-tests)))
    (if (eq results t) t
        (progn
          (format t "~&Test failures: ~A~%" results)
          results))))
