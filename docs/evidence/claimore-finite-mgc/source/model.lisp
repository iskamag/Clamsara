;;;; Finite Claimore MGC decision model. Research only, NOT a runtime collector.
;;;; Source: paper-v14/chapters/claimore.tex. No Clamsara, ASDF or VM dependency.
(defpackage #:claimore.finite.mgc
  (:use #:cl)
  (:export #:run-model-tests #:*last-report*))
(in-package #:claimore.finite.mgc)

(defconstant +max-extent+ 16)
(defconstant +max-objects+ 4)
(defconstant +max-granules+ 16)
(define-condition model-rejection (error)
  ((reason :initarg :reason :reader rejection-reason)))
(defun require-model (test reason)
  (unless test (error 'model-rejection :reason reason)))
(defun bits (count) (1- (ash 1 count)))
(defun interval-bits (start count) (ash (bits count) start))
(defun power-of-two-p (n)
  (and (integerp n) (plusp n) (zerop (logand n (1- n)))))

(defstruct (allocation (:constructor %allocation (start requested charged)))
  start requested charged)
(defstruct (nursery (:constructor %nursery (extent granule quantum objects edges)))
  extent granule quantum objects edges)
(defstruct (summary (:constructor %summary (count occupancy strong spans)))
  count occupancy strong spans (unknown 0) (dirty 0))

(defun make-nursery (extent granule quantum specifications edge-masks)
  "Base is zero (Q-aligned). Each specification is (START REQUESTED-BYTES).
Charges are Q-rounded. Bit M of an edge mask denotes an out-of-scope target;
it has no granule column. Nursery object identities are 0..M-1."
  (require-model (and (integerp extent) (<= 1 extent +max-extent+)
                      (integerp granule) (<= 1 granule +max-extent+)
                      (power-of-two-p quantum) (<= quantum extent)) :geometry)
  (require-model (<= (ceiling extent granule) +max-granules+) :granule-capacity)
  (let ((count (length specifications)))
    (require-model (and (<= count +max-objects+) (= count (length edge-masks)))
                   :object-capacity)
    (let ((objects (make-array count)) (occupied 0))
    (loop for spec in specifications for i from 0 do
      (require-model (and (listp spec) (= (length spec) 2)) :allocation-shape)
      (destructuring-bind (start requested) spec
        (require-model (and (integerp start) (<= 0 start) (< start extent)
                            (zerop (mod start quantum))
                            (integerp requested) (<= 1 requested extent)) :allocation)
        (let ((charged (* quantum (ceiling requested quantum))))
          (require-model (<= (+ start charged) extent) :allocation-overflow)
          (let ((mask (interval-bits start charged)))
            (require-model (zerop (logand occupied mask)) :overlapping-allocations)
            (setf occupied (logior occupied mask)
                  (aref objects i) (%allocation start requested charged))))))
    (let ((edges (map 'vector #'identity edge-masks)))
      (dotimes (i count)
        (require-model (and (integerp (aref edges i))
                            (<= 0 (aref edges i) (bits (1+ count)))) :edge-domain))
      (%nursery extent granule quantum objects edges)))))

(defun object-granule (nursery index)
  (floor (allocation-start (aref (nursery-objects nursery) index))
         (nursery-granule nursery)))
(defun strong-row-from-complete-sources (nursery row)
  ;; Setup/reconciliation operation, not a liveness trace.
  (let ((result 0) (objects (nursery-objects nursery)) (edges (nursery-edges nursery)))
    (dotimes (i (length objects) result)
      (when (= row (object-granule nursery i))
        (dotimes (j (length objects))
          (when (logbitp j (aref edges i))
            (setf result (logior result (ash 1 (object-granule nursery j))))))))))

(defun make-summary (nursery &key omit-spanning-edge)
  "Build complete facts. Negative control may omit exactly ONE directed
structural edge (FROM TO); strong edges are not removed by that control."
  (let* ((n (ceiling (nursery-extent nursery) (nursery-granule nursery)))
         (strong (make-array n :initial-element 0))
         (spans (make-array n :initial-element 0)) (occupied 0))
    (labels ((join (from to)
               (unless (and omit-spanning-edge
                            (= from (first omit-spanning-edge))
                            (= to (second omit-spanning-edge)))
                 (setf (aref spans from) (logior (aref spans from) (ash 1 to))))))
      (dotimes (i n) (setf (aref strong i) (strong-row-from-complete-sources nursery i)))
      (loop for object across (nursery-objects nursery) do
        (let* ((start (allocation-start object))
               (end (+ start (allocation-charged object)))
               (first (floor start (nursery-granule nursery))))
          (setf occupied (logior occupied (interval-bits start (- end start))))
          (loop for g from first to (floor (1- end) (nursery-granule nursery)) do
            (unless (= g first) (join first g) (join g first)))))
      (%summary n occupied strong spans))))

(defun validate-reference-mask (nursery mask)
  (require-model (and (integerp mask)
                      (<= 0 mask (bits (1+ (length (nursery-objects nursery))))))
                 :reference-mask)
  mask)
(defun seed-granules (nursery roots incoming &key (conservative-seeds 0)
                                                  unknown-incoming-p omit-root)
  "Complete local+validated incoming seeds. Unknown incoming coverage here
means the affected scope is the whole nursery, so conservatively seed it all.
Conservative registrations may add seeds; their registry semantics are NOT modeled."
  (mapc (lambda (mask) (validate-reference-mask nursery mask))
        (list roots incoming conservative-seeds))
  (let* ((count (length (nursery-objects nursery)))
         (n (ceiling (nursery-extent nursery) (nursery-granule nursery)))
         (covered-roots (if omit-root
                            (logand roots (lognot (ash 1 omit-root))) roots))
         (objects (logior covered-roots incoming conservative-seeds)) (seeds 0))
    (if unknown-incoming-p (bits n)
        (dotimes (i count seeds)
          (when (logbitp i objects)
            (setf seeds (logior seeds (ash 1 (object-granule nursery i)))))))))

(defun closure-step (summary retained)
  (let ((next retained) (n (summary-count summary)))
    (dotimes (row n next)
      (when (logbitp row retained)
        (setf next
              (logior next
                      (if (logbitp row (summary-unknown summary))
                          (bits n)
                          (logior (aref (summary-strong summary) row)
                                  (aref (summary-spans summary) row)))))))))
(defun granule-closure (summary seeds)
  "The coarse decision reads only seeds/relations/unknown rows, never EDGES."
  (require-model (<= 0 seeds (bits (summary-count summary))) :seed-domain)
  (require-model (<= 0 (summary-unknown summary) (bits (summary-count summary)))
                 :unknown-domain)
  (loop with retained = seeds
        for round from 0 to (summary-count summary)
        for next = (closure-step summary retained)
        when (= next retained) do (return-from granule-closure retained)
        do (setf retained next))
  (error 'model-rejection :reason :closure-did-not-converge))
(defun probe-closure (summary seeds rounds)
  "Policy probe only. A partial result does not authorize reclamation."
  (require-model (and (integerp rounds) (<= 0 rounds (summary-count summary))) :probe-bound)
  (let ((retained seeds))
    (dotimes (i rounds) (setf retained (closure-step summary retained)))
    (values retained (= retained (closure-step summary retained)))))
(defun mgc-retained (nursery summary roots incoming &rest seed-options)
  (granule-closure summary (apply #'seed-granules nursery roots incoming seed-options)))
(defun retained-units (nursery retained)
  ;; Includes granule holes, but never units past a short last granule.
  (let ((result 0))
    (dotimes (unit (nursery-extent nursery) result)
      (when (logbitp (floor unit (nursery-granule nursery)) retained)
        (setf result (logior result (ash 1 unit)))))))

(defun exact-object-oracle (nursery roots incoming)
  "INDEPENDENT object BFS over concrete strong pointers, not MGC relations.
No granule arithmetic, span facts, dirty flags, or summary state is read.
The second value covers COMPLETE Q-charged allocation extents, including padding."
  (validate-reference-mask nursery roots)
  (validate-reference-mask nursery incoming)
  (let* ((objects (nursery-objects nursery)) (count (length objects))
         (queue (make-array count :initial-element 0))
         (head 0) (tail 0) (seen 0) (units 0))
    (labels ((enqueue (index)
               (unless (logbitp index seen)
                 (assert (< tail count))
                 (setf seen (logior seen (ash 1 index))
                       (aref queue tail) index)
                 (incf tail))))
      (dotimes (i count)
        (when (or (logbitp i roots) (logbitp i incoming)) (enqueue i)))
      (loop while (< head tail) do
        (let ((index (aref queue head)))
          (incf head)
          (dotimes (target count)
            (when (logbitp target (aref (nursery-edges nursery) index))
              (enqueue target)))))
      (dotimes (i count)
        (when (logbitp i seen)
          (let ((object (aref objects i)))
            ;; Unit-by-unit exact extent construction, independent of granules.
            (loop for offset below (allocation-charged object) do
              (setf units (logior units (ash 1 (+ (allocation-start object) offset))))))))
      (values seen units))))

(defun safety-failure (nursery retained exact-live-units)
  (let* ((units (retained-units nursery retained))
         (missing (logand exact-live-units (lognot units))) (partial 0))
    ;; Not only reachable starts: every retained allocation must be wholly
    ;; retained, including an unreachable object sharing a retained granule.
    (loop for object across (nursery-objects nursery) for i from 0 do
      (let* ((extent (interval-bits (allocation-start object) (allocation-charged object)))
             (kept (logand extent units)))
        (unless (or (zerop kept) (= kept extent))
          (setf partial (logior partial (ash 1 i))))))
    (values missing partial)))
(defun assert-safe (nursery retained exact-live-units)
  (multiple-value-bind (missing partial) (safety-failure nursery retained exact-live-units)
    (assert (zerop missing))
    (assert (zerop partial)))
  t)

(defun delete-strong-edge (nursery summary source target)
  "Logical deletion dirties the canonical SOURCE row and keeps old summary bits."
  (let ((count (length (nursery-objects nursery))))
    (require-model (and (<= 0 source) (< source count) (<= 0 target) (< target count))
                   :edge-domain))
  (setf (aref (nursery-edges nursery) source)
        (logand (aref (nursery-edges nursery) source) (lognot (ash 1 target)))
        (summary-dirty summary)
        (logior (summary-dirty summary) (ash 1 (object-granule nursery source))))
  summary)
(defun rebuild-source-row (nursery summary row &key protected complete)
  "No partial/unprotected row clear. Structural edges survive until reclamation."
  (require-model (and protected complete) :incomplete-source-rescan)
  (require-model (<= 0 row (1- (summary-count summary))) :row-domain)
  (let ((new (strong-row-from-complete-sources nursery row)))
    (setf (aref (summary-strong summary) row) new
          (summary-dirty summary) (logand (summary-dirty summary) (lognot (ash 1 row)))
          (summary-unknown summary) (logand (summary-unknown summary) (lognot (ash 1 row)))))
  summary)

(defun finite-witness (nursery roots incoming retained exact-live-units reason)
  (multiple-value-bind (missing partial) (safety-failure nursery retained exact-live-units)
    (list :reason reason :geometry (list (nursery-extent nursery)
                                       (nursery-granule nursery) (nursery-quantum nursery))
          :allocations (loop for o across (nursery-objects nursery)
                             collect (list (allocation-start o) (allocation-requested o)
                                           (allocation-charged o)))
          :edges (coerce (nursery-edges nursery) 'list) :roots roots :incoming incoming
          :retained-granules retained :exact-live-units exact-live-units
          :missing-live-units missing :partial-allocations partial)))
