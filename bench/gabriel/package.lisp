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
   #:maclina-benchmark-unavailable
   #:gabriel-benchmark-failure
   #:maclina-dependencies-available-p
   #:run-gabriel-bench))

(in-package #:clamsara-gabriel-bench)
