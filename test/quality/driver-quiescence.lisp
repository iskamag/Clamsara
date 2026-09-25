;;;; Driver quiescence gate: a completed cycle must present a quiescent trace
;;;; context before reclamation.  FINISH-TRACE-CONTEXT is the context's own
;;;; termination evidence (execution.tex: "Finish returns complete only after
;;;; quiescence, else the first failure reason"); the driver must consult it
;;;; rather than infer quiescence from individual drain statuses.
;;;;
;;;; This uses the real hosted collector world from the shared quality support
;;;; fixture; no protocol stubs are installed.
(defpackage #:clamsara.quality.driver-quiescence
  (:use #:cl #:clamsara #:clamsara.quality.support)
  (:export #:run-driver-quiescence-tests))
(in-package #:clamsara.quality.driver-quiescence)

(defun context-is-quiescent-after-cycle (world)
  (let* ((context (clamsara::%cycle-trace (clamsara::%plan-cycle (world-plan world))))
         (state (clamsara::%trace-states context)))
    ;; A finished cycle's context reports :complete from its own check, and
    ;; every claim cell is settled (no :claimed state survives).
    (multiple-value-bind (status reason) (finish-trace-context context)
      (check (and (eq status :complete) (null reason))
             "Finished cycle's trace context was not quiescent: ~S/~S"
             status reason))
    (check (not (find :claimed state))
           "A trace claim survived into reclamation")))

(defun run-driver-quiescence-tests ()
  (dolist (algorithm '(:semispace :marksweep))
    (dolist (starts '(:packed :scalar))
      (with-quality-world
          (world :algorithm algorithm :object-starts starts
                 :extent 2048 :trace-capacity 128
                 :conditional-capacity 64 :stop-capacity 64)
        (let ((a (allocate-node world 1))
              (b (allocate-node world 2))
              (c (allocate-node world 3)))
          (set-world-root world 0 a)
          (set-node-slot world a 1 b)
          (set-node-slot world b 2 c)
          (set-node-slot world c 1 a)
          (set-world-root world 1 b)
          (let ((record (collect-world world)))
            (check (and (eq :complete (cycle-result-status record))
                        (eq :complete (cycle-result-reason record)))
                   "~S/~S cycle failed: ~S/~S" algorithm starts
                   (cycle-result-status record) (cycle-result-reason record)))
          (context-is-quiescent-after-cycle world)
          ;; A second cycle reuses the same context; it must still end quiescent.
          (let ((record (collect-world world)))
            (check (eq :complete (cycle-result-status record))
                   "~S/~S repeat cycle failed: ~S/~S" algorithm starts
                   (cycle-result-status record) (cycle-result-reason record)))
          (context-is-quiescent-after-cycle world)))))
  (format t "~&DRIVER-QUIESCENCE-PASS~%")
  t)
