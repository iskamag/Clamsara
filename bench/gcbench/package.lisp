;;;; bench/gcbench/package.lisp -- the real Boehm GCBench over Maclina.

(defpackage #:clamsara-bench-gcbench
  (:use #:cl)
  (:export
   #:gcbench-dependencies-available-p
   #:run-gcbench
   #:run-gcbench-tests
   #:run-gcbench-suite
   #:gcbench-result
   #:gcbench-result-name #:gcbench-result-depth #:gcbench-result-heap-size
   #:gcbench-result-plan #:gcbench-result-iterations #:gcbench-result-value
   #:gcbench-result-elapsed-ms #:gcbench-result-stats
   #:gcbench-result-collector-host-bytes #:gcbench-result-gc-cycles
   #:gcbench-result-words-copied #:gcbench-result-objects-copied
   #:gcbench-result-barrier-transfers #:gcbench-result-ref-locations-scanned
   #:gcbench-result-root-locations-scanned #:gcbench-result-barrier-events
   #:gcbench-result-satb-log-records #:gcbench-result-satb-log-bytes
   #:gcbench-result-rc-log-records #:gcbench-result-rc-log-bytes
   #:gcbench-result-queue-spills #:gcbench-result-relation-rows-rebuilt
   #:gcbench-result-safepoint-requests #:gcbench-result-safepoint-arrivals
   #:gcbench-result-collection-aborts #:gcbench-result-allocation-retries
   #:gcbench-result-retained-bytes-sample #:gcbench-result-heap-retries
   #:gcbench-result-collections-checked #:gcbench-result-sanity-errors
   #:*gcbench-suite-heap-size*
   #:*gcbench-suite-plans*))
