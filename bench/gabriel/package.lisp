;;;; bench/gabriel/package.lisp -- canonical Gabriel and labelled smoke harness.

(defpackage #:clamsara-gabriel-bench
  (:use #:cl)
  (:export
   #:gabriel-workload
   #:make-gabriel-workload
   #:gabriel-workload-name
   #:gabriel-workload-source
   #:gabriel-workload-expected
   #:canonical-gabriel-workload
   #:canonical-gabriel-workload-reference-file
   #:gabriel-workload-canonical-p
   #:*gabriel-workloads*
   #:*gabriel-canonical-skips*
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
