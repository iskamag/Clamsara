;;;; Full, unchanged depth-18 GCBench with explicit collection and close gates.
;;;; Run from the repository root in a fresh SBCL process. See tools/README.md.
(require :asdf)
(asdf:load-system :clamsara/workload)

(defpackage #:clamsara.gcbench.runner
  (:use #:cl #:clamsara))
(in-package #:clamsara.gcbench.runner)

(defun required-count (record counter)
  (multiple-value-bind (count known-p) (cycle-result-count record counter)
    (unless known-p (error "Missing collection counter ~S" counter))
    count))

(defun collection-evidence (record)
  (list :status (cycle-result-status record)
        :scope (cycle-result-scope record)
        :algorithm (cycle-result-algorithm record)
        :cause (cycle-result-cause record)
        :reason (cycle-result-reason record)
        :counts (loop for counter in '(:objects-discovered :objects-moved
                                      :bytes-moved :objects-dead)
                      append (list counter (required-count record counter)))))

(defun finish-collections (runtime)
  (let* ((plan (clamsara::workload-runtime-plan runtime))
         (automatic (clamsara::%plan-automatic-result plan))
         ;; The unchanged translation derives these anchors from depth 18:
         ;; a depth-16 tree (131071 64-byte nodes) and 524284 float elements.
         (nodes (1- (expt 2 17)))
         (elements (* 4 nodes))
         (minimum-objects (1+ nodes))
         (minimum-bytes (+ (* 64 nodes) 16 (* 8 elements))))
    (assert (eq :complete (cycle-result-status automatic)))
    (assert (>= (required-count automatic :objects-moved) minimum-objects))
    (assert (>= (required-count automatic :bytes-moved) minimum-bytes))
    (let ((automatic-evidence (collection-evidence automatic))
          (discharge (make-cycle-result-record plan)))
      (format t "~&GCBENCH-AUTOMATIC ~S~%" automatic-evidence)
      ;; Do not clear any result, global, temporary, or VM frame root here.
      ;; The benchmark must have released its own local anchors on return.
      (collect (clamsara::workload-runtime-configuration runtime)
               :all :explicit discharge)
      (assert (eq :complete (cycle-result-status discharge)))
      (assert (zerop (required-count discharge :objects-discovered)))
      (let ((discharge-evidence (collection-evidence discharge)))
        (format t "~&GCBENCH-DISCHARGE ~S~%" discharge-evidence)
        (list :status :complete :automatic automatic-evidence
              :discharge discharge-evidence)))))

(defun run-full-gcbench ()
  (format t "~&GCBENCH-GEOMETRY ~S~%"
          '(:active-semispace-bytes 33554432 :reserved-semispace-bytes 67108864
            :max-object-bytes 8388608 :stretch-depth 18
            :long-lived-tree-depth 16 :array-elements 524284
            :backend :maclina-vm-cross))
  (let* ((runtime (make-workload-runtime :extent (* 32 1024 1024)
                                         :max-object-bytes (* 8 1024 1024)))
         (result nil) (workload-error nil) (close-error nil))
    (handler-case
        (setf result
              (run-unmodified-boehm-gcbench
               (clamsara::workload-runtime-environment runtime)
               :depth 18 :provenance :checked-in-lisp-translation
               :collect-finalize
               (lambda (environment)
                 (assert (eq environment
                             (clamsara::workload-runtime-environment runtime)))
                 (finish-collections runtime))))
      (error (condition)
        (setf workload-error condition)
        (format t "~&GCBENCH-WORKLOAD-ERROR ~A~%" condition)))
    ;; Always attempt close, but preserve and report both failures separately.
    ;; A swallowed close failure must never produce a successful process exit.
    (handler-case
        (progn (close-workload-runtime runtime)
               (format t "~&GCBENCH-CLOSE :COMPLETE~%"))
      (error (condition)
        (setf close-error condition)
        (format t "~&GCBENCH-CLOSE-ERROR ~A~%" condition)))
    (when (or workload-error close-error)
      (error "Full GCBench acceptance failed: workload=~A; close=~A"
             workload-error close-error))
    (assert (eq :ok (getf result :status)))
    (assert (eq :complete (getf (getf result :final-collection-status) :status)))
    (assert (null (clamsara::workload-runtime-configuration runtime)))
    (format t "~&GCBENCH-ACCEPTED ~S~%" result)
    result))

(run-full-gcbench)
