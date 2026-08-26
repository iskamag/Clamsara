;;;; bench/gcbench/package.lisp -- the real Boehm GCBench over Maclina.

(defpackage #:clamsara-bench-gcbench
  (:use #:cl)
  (:export
   #:gcbench-dependencies-available-p
   #:run-gcbench
   #:run-gcbench-tests
   #:run-gcbench-suite
   #:gcbench-result
   #:*gcbench-suite-heap-size*
   #:*gcbench-suite-plans*))
