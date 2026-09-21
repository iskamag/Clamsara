;;;; Unexecuted tests for the finite research model. No runtime collector proof.
(in-package #:claimore.finite.mgc)
(defvar *last-report* nil)
(defstruct counts (layouts 0) (graphs 0) (closures 0) (deletions 0) (rescans 0))

(defun rejects (thunk reason)
  (assert (handler-case (progn (funcall thunk) nil)
            (model-rejection (condition) (eq reason (rejection-reason condition))))))
(defun oracle-units (nursery roots incoming)
  (nth-value 1 (exact-object-oracle nursery roots incoming)))
(defun check-decision (nursery summary roots incoming expected)
  (let ((retained (mgc-retained nursery summary roots incoming)))
    (assert (= expected retained))
    (assert-safe nursery retained (oracle-units nursery roots incoming))
    retained))

(defun worked-example (spanning)
  (make-nursery 8 2 1
    (if spanning '((0 1) (2 3) (5 1) (6 1)) '((0 1) (2 1) (4 1) (6 1)))
    #(2 0 8 4)))
(defun named-tests ()
  ;; Four-granule example: unreachable C--D cycle is released coarsely.
  (let* ((n (worked-example nil)) (s (make-summary n)))
    (check-decision n s 1 0 #b0011)
    (assert (= #b00000101 (oracle-units n 1 0)))
    ;; A reached unknown/saturated row reaches every target. An unreachable
    ;; unknown row does not seed itself. Empty seeds still produce empty closure.
    (setf (summary-unknown s) #b0010)
    (check-decision n s 1 0 #b1111)
    (setf (summary-unknown s) #b0100)
    (check-decision n s 1 0 #b0011)
    (setf (summary-unknown s) #b1111)
    (check-decision n s 0 0 0)
    (setf (summary-unknown s) #b10000)
    (rejects (lambda () (mgc-retained n s 1 0)) :unknown-domain))
  (let* ((n (worked-example t)) (s (make-summary n)))
    (check-decision n s 1 0 #b1111)
    (assert (= #b00011101 (oracle-units n 1 0)))
    (assert (= 2 (logcount
                  (logand (summary-occupancy s)
                          (retained-units n #b1111)
                          (lognot (oracle-units n 1 0))))))
    ;; A truncated policy probe is not a reclaim decision: here it would
    ;; destroy part of live B, despite preserving B's start.
    (multiple-value-bind (partial complete) (probe-closure s #b0001 1)
      (assert (= partial #b0011))
      (assert (not complete))
      (assert (plusp (nth-value 0 (safety-failure n partial (oracle-units n 1 0)))))))
  ;; Granule sharing must not permit a partially retained DEAD allocation either.
  (let* ((n (make-nursery 4 2 1 '((0 1) (1 2)) #(0 0)))
         (s (make-summary n)))
    (check-decision n s 1 0 #b11)
    (multiple-value-bind (missing partial) (safety-failure n #b01 (oracle-units n 1 0))
      (assert (zerop missing)) (assert (= #b10 partial))))
  ;; Short last granule and complete rounded extents, not merely live starts.
  (let* ((n (make-nursery 7 2 1 '((5 2)) #(0))) (s (make-summary n)))
    (check-decision n s 1 0 #b1100)
    (assert (= #b1100000 (oracle-units n 1 0)))
    (assert (= #b1110000 (retained-units n #b1100)))
    (assert (not (logbitp 7 (retained-units n #b1100)))))
  (let* ((n (make-nursery 8 2 2 '((2 3)) #(0))) (s (make-summary n)))
    (assert (= 4 (allocation-charged (aref (nursery-objects n) 0))))
    (assert (= #b111100 (oracle-units n 1 0)))
    (check-decision n s 1 0 #b0110))
  (rejects (lambda () (make-nursery 3 1 2 '((0 3)) #(0))) :allocation-overflow)
  (rejects (lambda () (make-nursery 4 1 1 '((0 2) (1 1)) #(0 0)))
           :overlapping-allocations)
  ;; Incoming coverage is a seed obligation, not a mature liveness trace.
  (let* ((n (worked-example nil)) (s (make-summary n)))
    (check-decision n s 0 #b0100 #b1100)
    ;; Index coverage uncertain over the whole nursery: retain every unit.
    (let ((retained (mgc-retained n s 0 0 :unknown-incoming-p t)))
      (assert (= retained #b1111))
      (assert-safe n retained (oracle-units n 0 #b0100)))
    ;; Extra conservative registrations add seeds, never weaken strong safety.
    ;; This does NOT implement weak/ephemeron/finalizer judgment or callbacks.
    (assert (= #b1111 (mgc-retained n s 1 0 :conservative-seeds #b0100)))
    ;; Outside target bit M has no nursery column and is not followed by BFS.
    (setf (aref (nursery-edges n) 0) (logior #b00010 #b10000))
    (setf s (make-summary n))
    (check-decision n s 1 0 #b0011)
    (check-decision n s #b10000 0 0))
  ;; Deletion keeps old edges. Only a protected COMPLETE source-row rebuild
  ;; may sharpen the summary; incomplete attempts change neither rows nor flags.
  (let* ((n (make-nursery 4 2 1 '((0 1) (2 1)) #(2 0))) (s (make-summary n)))
    (check-decision n s 1 0 #b11)
    (delete-strong-edge n s 0 1)
    (assert (= 1 (summary-dirty s)))
    (assert (= 1 (oracle-units n 1 0)))
    (check-decision n s 1 0 #b11)
    (let ((rows (copy-seq (summary-strong s))) (dirty (summary-dirty s)))
      (rejects (lambda () (rebuild-source-row n s 0 :protected t :complete nil))
               :incomplete-source-rescan)
      (rejects (lambda () (rebuild-source-row n s 0 :protected nil :complete t))
               :incomplete-source-rescan)
      (assert (equalp rows (summary-strong s)))
      (assert (= dirty (summary-dirty s))))
    (rebuild-source-row n s 0 :protected t :complete t)
    (assert (zerop (summary-dirty s)))
    (check-decision n s 1 0 #b01))
  ;; Rebuilding a dirty source row must preserve structural edges, including
  ;; reverse edges belonging to an allocation starting in another granule.
  (let* ((n (make-nursery 4 1 1 '((0 3) (3 1)) #(2 0))) (s (make-summary n)))
    (delete-strong-edge n s 0 1)
    (let ((spans (copy-seq (summary-spans s))))
      (setf (summary-unknown s) 1)
      (rebuild-source-row n s 0 :protected t :complete t)
      (rebuild-source-row n s 1 :protected t :complete t)
      (assert (equalp spans (summary-spans s))))
    (assert (zerop (summary-unknown s)))
    (check-decision n s 1 0 #b0111))
  t)

(defun map-layouts (extent max-objects function)
  "Exhaust all ordered, disjoint positive integer extents, with gaps allowed.
Exhaustive fixtures use Q=1; rounded Q>1 layouts have separate named checks."
  (labels ((walk (remaining lower reverse-specs)
             (if (zerop remaining)
                 (funcall function (reverse reverse-specs))
                 (loop for start from lower below extent do
                   (loop for size from 1 to (- extent start) do
                     (walk (1- remaining) (+ start size)
                           (cons (list start size) reverse-specs)))))))
    (loop for count from 0 to max-objects do (walk count 0 nil))))
(defun map-graphs (count function)
  (dotimes (mask (ash 1 (* count count)))
    (let ((edges (make-array count :initial-element 0)))
      (dotimes (i count) (setf (aref edges i) (ldb (byte count (* count i)) mask)))
      (funcall function edges))))

(defun deletion-history (nursery roots incoming source target counts)
  (let* ((trial (copy-nursery nursery))
         (summary (make-summary nursery))
         (old-live (oracle-units nursery roots incoming))
         (before (mgc-retained nursery summary roots incoming)))
    (setf (nursery-edges trial) (copy-seq (nursery-edges nursery)))
    (delete-strong-edge trial summary source target)
    (assert (logbitp (object-granule trial source) (summary-dirty summary)))
    (let* ((live (oracle-units trial roots incoming))
           (after (mgc-retained trial summary roots incoming)))
      (assert (zerop (logand live (lognot old-live))))
      (assert (= before after)) ; deletion alone does not erase a relation bit
      (assert-safe trial after live)
      (incf (counts-deletions counts))
      (rebuild-source-row trial summary (object-granule trial source)
                          :protected t :complete t)
      (assert (zerop (summary-dirty summary)))
      (let ((refined (mgc-retained trial summary roots incoming)))
        (assert (zerop (logand refined (lognot before))))
        (assert-safe trial refined live)
        (incf (counts-rescans counts))))))

(defun exhaustive-geometry (extent granule counts)
  (map-layouts extent 3
    (lambda (specs)
      (incf (counts-layouts counts))
      (let ((m (length specs)))
        (map-graphs m
          (lambda (edges)
            (incf (counts-graphs counts))
            (let* ((nursery (make-nursery extent granule 1 specs edges))
                   (summary (make-summary nursery)))
              ;; Complete independent local-root AND validated-incoming subsets.
              (dotimes (roots (ash 1 m))
                (dotimes (incoming (ash 1 m))
                  (let ((exact (oracle-units nursery roots incoming)))
                    (dotimes (unknown (ash 1 (summary-count summary)))
                      (setf (summary-unknown summary) unknown)
                      (let ((retained (mgc-retained nursery summary roots incoming)))
                        (assert-safe nursery retained exact)
                        (assert (= retained (granule-closure summary retained)))
                        (incf (counts-closures counts))))
                    (setf (summary-unknown summary) 0)
                    ;; Independently exhaust EVERY one-edge deletion of every
                    ;; graph and seed pair, with a subsequent complete row rescan.
                    (dotimes (source m)
                      (dotimes (target m)
                        (when (logbitp target (aref edges source))
                          (deletion-history nursery roots incoming source target counts))))))))))))))

(defun find-root-counterexample ()
  (map-layouts 3 3
    (lambda (specs)
      (let ((m (length specs)))
        (map-graphs m
          (lambda (edges)
            (let* ((n (make-nursery 3 1 1 specs edges)) (s (make-summary n)))
              (loop for roots from 1 below (ash 1 m) do
                (let ((exact (oracle-units n roots 0)))
                  (assert-safe n (mgc-retained n s roots 0) exact)
                  (dotimes (omitted m)
                    (when (logbitp omitted roots)
                      (let ((retained (mgc-retained n s roots 0 :omit-root omitted)))
                        (multiple-value-bind (missing partial) (safety-failure n retained exact)
                          (when (or (plusp missing) (plusp partial))
                            (return-from find-root-counterexample
                              (append (finite-witness n roots 0 retained exact :omitted-root)
                                      (list :omitted-root omitted))))))))))))))))
  nil)
(defun find-spanning-counterexample ()
  (map-layouts 3 3
    (lambda (specs)
      (let ((m (length specs)))
        (map-graphs m
          (lambda (edges)
            (let* ((n (make-nursery 3 1 1 specs edges)) (complete (make-summary n)))
              (dotimes (from (summary-count complete))
                (dotimes (to (summary-count complete))
                  (when (logbitp to (aref (summary-spans complete) from))
                    (let ((broken (make-summary n :omit-spanning-edge (list from to))))
                      (loop for roots from 1 below (ash 1 m) do
                        (let* ((exact (oracle-units n roots 0))
                               (retained (mgc-retained n broken roots 0)))
                          (assert-safe n (mgc-retained n complete roots 0) exact)
                          (multiple-value-bind (missing partial) (safety-failure n retained exact)
                            (when (or (plusp missing) (plusp partial))
                              (return-from find-spanning-counterexample
                                (append (finite-witness n roots 0 retained exact :omitted-spanning-edge)
                                        (list :omitted-edge (list from to))))))))))))))))))
  nil)

(defun run-model-tests ()
  (setf *last-report* nil)
  (named-tests)
  (let ((counts (make-counts)))
    (exhaustive-geometry 3 1 counts)
    (exhaustive-geometry 4 2 counts)
    ;; Exact enumeration counts are combinatorial fixture checks, not timings.
    (assert (= 46 (counts-layouts counts)))
    (assert (= 4450 (counts-graphs counts)))
    (assert (= 1205964 (counts-closures counts)))
    (assert (= 1189952 (counts-deletions counts)))
    (assert (= 1189952 (counts-rescans counts)))
    (let ((root (find-root-counterexample)) (span (find-spanning-counterexample)))
      ;; Controls MUST find witnesses. A missing counterexample is suite failure,
      ;; not another allegedly passing safety implementation.
      (assert root) (assert span)
      (assert (plusp (getf root :missing-live-units)))
      (assert (plusp (getf span :missing-live-units)))
      (setf *last-report*
            (list :status :complete :model-only t
                  :layouts (counts-layouts counts) :graphs (counts-graphs counts)
                  :coarse-decisions (counts-closures counts)
                  :deletion-histories (counts-deletions counts)
                  :protected-rescans (counts-rescans counts)
                  :root-counterexample root :spanning-counterexample span))
      (format t "~&CLAIMORE-FINITE-MODEL ~S~%" *last-report*)
      *last-report*)))
