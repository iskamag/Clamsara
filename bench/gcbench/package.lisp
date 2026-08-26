;;;; bench/gcbench/package.lisp -- the real Boehm GCBench over Maclina.

(defpackage #:clamsara-bench-gcbench
  (:use #:cl)
  (:export
   #:*gcbench-fixture-pathname*
   #:gcbench-dependencies-available-p
   #:run-gcbench
   #:gcbench-result))