;;;; bench/gabriel/package.lisp -- optional Gabriel-style benchmark harness.

(defpackage #:clamsara-gabriel-bench
  (:use #:cl)
  (:export
   #:gabriel-workload
   #:make-gabriel-workload
   #:gabriel-workload-name
   #:gabriel-workload-source
   #:gabriel-workload-expected
   #:*gabriel-workloads*
   #:*gabriel-default-iterations*
   #:*gabriel-max-iterations*
   #:*gabriel-suite-heap-size*
   #:*gabriel-suite-plans*
   #:maclina-benchmark-unavailable
   #:gabriel-benchmark-failure
   #:maclina-dependencies-available-p
   #:run-gabriel-bench
   #:run-gabriel-suite
   #:run-gabriel-tests))

(in-package #:clamsara-gabriel-bench)
