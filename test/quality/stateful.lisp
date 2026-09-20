;;;; Independent bounded stateful regressions for the canonical v14 runtime.
(defpackage #:clamsara.quality.stateful
  (:use #:cl #:clamsara #:clamsara.quality.support)
  (:export #:run-stateful-quality-tests))
(in-package #:clamsara.quality.stateful)

(defconstant +stateful-seed+ #x14c1a05e)
(defconstant +stateful-iterations+ 18)

(defstruct (deterministic-source (:constructor make-source (state)))
  (state 0 :type (unsigned-byte 32)))

(defun next-word (source)
  ;; Numerical Recipes LCG, explicitly reduced to 32 bits.  This avoids a
  ;; dependence on implementation-specific RANDOM state serialization.
  (setf (deterministic-source-state source)
        (ldb (byte 32 0)
             (+ (* 1664525 (deterministic-source-state source)) 1013904223))))

(defun choose (source sequence)
  (check sequence "Cannot choose from an empty sequence")
  (elt sequence (mod (next-word source) (length sequence))))

(defun expected-reachable (roots edges)
  (let ((queue (remove nil (coerce roots 'list)))
        (seen '()))
    (loop while queue
          for id = (pop queue)
          unless (member id seen)
            do (let ((edge (gethash id edges)))
                 (check edge "Oracle root/edge names missing ID ~S" id)
                 (push id seen)
                 (when (car edge) (push (car edge) queue))
                 (when (cdr edge) (push (cdr edge) queue))))
    (sort seen #'<)))

(defun expected-snapshot (roots edges)
  (let ((reachable (expected-reachable roots edges)))
    (list (coerce roots 'list)
          (mapcar (lambda (id)
                    (let ((edge (gethash id edges)))
                      (list id (car edge) (cdr edge))))
                  reachable))))

(defun reference-for (references id)
  (cdr (or (assoc id references)
           (error "No current managed reference for ID ~S" id))))

(defun set-oracle-edge (world edges references id side target-id)
  (set-node-slot world (reference-for references id) side
                 (and target-id (reference-for references target-id)))
  (let ((edge (or (gethash id edges)
                  (error "No oracle node ~S" id))))
    (ecase side
      (1 (setf (car edge) target-id))
      (2 (setf (cdr edge) target-id))))
  target-id)

(defun set-oracle-root (world roots references index id)
  (set-world-root world index (and id (reference-for references id)))
  (setf (aref roots index) id))

(defun assert-reference-fates (world algorithm old-references reachable)
  ;; These are hosted representation-generation/address-reuse checks.  They are
  ;; not generational-GC evidence; docs/quality-stateful.md reserves that matrix.
  (dolist (entry old-references)
    (let ((id (car entry)) (reference (cdr entry)))
      (if (or (eq algorithm :semispace)
              (not (member id reachable)))
          (check (stale-reference-p world reference)
                 "~S/~S old reference for ID ~D unexpectedly normalized"
                 algorithm (world-object-starts world) id)
          (check (live-reference-p world reference)
                 "MarkSweep live reference for ID ~D became stale" id)))))

(defun collect-and-check (world algorithm roots edges old-references label)
  (let ((record (collect-world world)))
    (check (and (eq :complete (cycle-result-status record))
                (eq :complete (cycle-result-reason record)))
           "~A collection failed at ~S: ~S/~S"
           label (cycle-result-phase record)
           (cycle-result-status record) (cycle-result-reason record))
    (multiple-value-bind (actual references visited)
        (snapshot-world-graph world)
      (declare (ignore visited))
      (let ((expected (expected-snapshot roots edges))
            (reachable (expected-reachable roots edges)))
        (check-equal expected actual label)
        (assert-reference-fates world algorithm old-references reachable)
        (values references expected record)))))

(defun initialize-stateful-graph (world edges roots)
  (let ((references '()))
    (dotimes (id 8)
      (let ((reference (allocate-node world id)))
        (push (cons id reference) references)
        (setf (gethash id edges) (cons nil nil))))
    ;; Rooted subgraph: a shared node (4), cycles 0->2->0 and 1->3->1.
    ;; Unrooted 5<->6 and isolated 7 must be reclaimed on the first cycle.
    (dolist (row '((0 1 2) (1 3 4) (2 4 0) (3 1 nil)
                   (4 nil nil) (5 6 nil) (6 5 nil) (7 nil nil)))
      (destructuring-bind (id left right) row
        (when left (set-oracle-edge world edges references id 1 left))
        (when right (set-oracle-edge world edges references id 2 right))))
    (set-oracle-root world roots references 0 0)
    (set-oracle-root world roots references 1 4)
    (set-oracle-root world roots references 3 1)
    references))

(defun run-one-stateful-profile (algorithm object-starts)
  (with-quality-world
      (world :algorithm algorithm :object-starts object-starts
             :extent 2048 :root-count 8 :trace-capacity 128
             :conditional-capacity 128 :stop-capacity 64)
    (let ((source (make-source +stateful-seed+))
          (edges (make-hash-table :test #'eql))
          (roots (make-array 8 :initial-element nil))
          (next-id 8)
          (trace '()))
      ;; Validation rejection precedes raw allocation and object exposure.
      (multiple-value-bind (reference status reason)
          (allocate-object (world-context world) :quality-node 0 16
                           (world-node-kind world))
        (check (and (null reference) (eq status :failed)
                    (eq reason :invalid-size))
               "Invalid-size allocation returned ~S/~S/~S"
               reference status reason))
      (let ((references (initialize-stateful-graph world edges roots)))
        (multiple-value-bind (current snapshot record)
            (collect-and-check world algorithm roots edges references "initial")
          (declare (ignore record))
          (setf references current)
          (push snapshot trace))
        (dotimes (iteration +stateful-iterations+)
          (let* ((live-ids (mapcar #'car references))
                 (new-id next-id)
                 (new-reference (allocate-node world new-id)))
            (incf next-id)
            (setf (gethash new-id edges)
                  (cons (choose source live-ids)
                        (if (zerop (mod (next-word source) 3))
                            nil
                            (choose source live-ids))))
            (push (cons new-id new-reference) references)
            (set-node-slot world new-reference 1
                           (reference-for references
                                          (car (gethash new-id edges))))
            (when (cdr (gethash new-id edges))
              (set-node-slot world new-reference 2
                             (reference-for references
                                            (cdr (gethash new-id edges)))))
            ;; Attach the new object through an existing live object.  This is
            ;; a real barrier mutation, not an oracle-only graph operation.
            (let ((parent (choose source live-ids))
                  (side (if (zerop (logand (next-word source) 1)) 1 2)))
              (set-oracle-edge world edges references parent side new-id))
            ;; Replace a root.  Periodic NIL replacements discharge old cycles;
            ;; other replacements can select the newly allocated object.
            (let* ((root-index (mod (next-word source) 4))
                   (candidates (cons new-id live-ids))
                   (replacement
                     (if (zerop (mod iteration 5))
                         nil
                         (choose source candidates))))
              (set-oracle-root world roots references root-index replacement))
            ;; Keep at least one root and also force root-zero replacement often.
            (when (every #'null roots)
              (set-oracle-root world roots references 0 new-id))
            (when (zerop (mod iteration 4))
              (set-oracle-root world roots references 0 new-id))
            ;; A second mutation can remove an old edge, creating garbage that
            ;; is discoverable only after several prior state transitions.
            (let ((target (choose source live-ids))
                  (side (if (zerop (logand (next-word source) 1)) 1 2))
                  (replacement
                    (if (zerop (mod (next-word source) 4))
                        nil
                        (choose source (cons new-id live-ids)))))
              (set-oracle-edge world edges references target side replacement))
            (multiple-value-bind (current snapshot record)
                (collect-and-check
                 world algorithm roots edges references
                 (format nil "iteration ~D" iteration))
              (declare (ignore record))
              (setf references current)
              (push snapshot trace))
            ;; Repeat without mutation.  This detects stale marks/forwarding,
            ;; lost sharing, and one-cycle-only reclamation behavior.
            (when (zerop (mod iteration 3))
              (multiple-value-bind (current snapshot record)
                  (collect-and-check
                   world algorithm roots edges references
                   (format nil "iteration ~D repeat" iteration))
                (declare (ignore record))
                (setf references current)
                (push snapshot trace)))))
        (nreverse trace)))))

(defun run-equivalent-profile-matrix ()
  (let ((baseline nil) (profile-count 0))
    (run-profile
     (lambda (algorithm starts)
       (let ((trace (run-one-stateful-profile algorithm starts)))
         (incf profile-count)
         (if baseline
             (check-equal baseline trace
                          (format nil "logical trace ~S/~S" algorithm starts))
             (setf baseline trace)))))
    (check (= profile-count 4) "Expected four stateful profiles, ran ~D"
           profile-count)
    t))

(defun run-admission-regression ()
  (with-quality-world
      (world :algorithm :marksweep :object-starts :scalar
             :extent 512 :trace-capacity 32 :stop-capacity 16)
    (let ((node (allocate-node world 900)))
      (set-world-root world 0 node)
      (flet ((fresh () (make-cycle-result-record (world-plan world))))
        (dolist (case '((:scope :unsupported-scope)
                        (:cause :unsupported-cause)
                        (:algorithm :unsupported-algorithm)))
          (let ((record (fresh)))
            (signals-runtime-reason
             (lambda ()
               (ecase (first case)
                 (:scope
                  (collect (world-configuration world) :quality-scope
                           :explicit record))
                 (:cause
                  (collect (world-configuration world) :all
                           :quality-unknown-cause record))
                 (:algorithm
                  (collect (world-configuration world) :all :explicit record
                           :algorithm :quality-algorithm))))
             (second case))
            (check (and (eq :uninitialized (cycle-result-status record))
                        (null (cycle-result-phase record))
                        (null (cycle-result-reason record)))
                   "Rejected ~S admission mutated its result record" (first case))))
        ;; A foreign record also rejects before either owner or heap changes.
        (with-quality-world
            (foreign :algorithm :marksweep :object-starts :packed
                     :extent 512 :trace-capacity 32)
          (let ((record (make-cycle-result-record (world-plan foreign))))
            (signals-runtime-reason
             (lambda ()
               (collect (world-configuration world) :all :explicit record))
             :foreign-result-record)
            (check (eq :uninitialized (cycle-result-status record))
                   "Foreign rejection mutated its record")))
        ;; Valid entry still works after all pre-admission failures.  Terminal
        ;; record reuse is permitted after the previous call has returned.
        (let ((record (fresh)))
          (collect (world-configuration world) :all :explicit record)
          (check (eq :complete (cycle-result-status record))
                 "Valid collect failed after admission rejections")
          (collect (world-configuration world) :all :explicit record)
          (check (eq :complete (cycle-result-status record))
                 "Terminal result record was not reusable"))))))

(defun run-full-heap-profile (algorithm starts)
  ;; Eight 32-byte objects exactly fill this 256-byte space.
  (with-quality-world
      (world :algorithm algorithm :object-starts starts
             :extent 256 :root-count 1 :trace-capacity 16
             :conditional-capacity 16 :stop-capacity 16)
    (let ((references '()))
      (dotimes (id 8)
        (push (cons id (allocate-node world (+ 1000 id))) references))
      ;; Make every object strongly reachable in a cycle.
      (dotimes (index 8)
        (set-node-slot world (cdr (nth index references)) 1
                       (cdr (nth (mod (1+ index) 8) references))))
      (set-world-root world 0 (cdar references))
      (multiple-value-bind (reference status reason)
          (try-allocate-node world 2000)
        (check (and (null reference) (eq status :failed)
                    (eq reason :heap-exhausted))
               "Full ~S/~S heap returned ~S/~S/~S"
               algorithm starts reference status reason))
      ;; The failed reservation may have completed automatic collection.  Read
      ;; current encodings from the managed graph before changing the root.
      (multiple-value-bind (snapshot current visited)
          (snapshot-world-graph world)
        (declare (ignore snapshot visited))
        (check (= 8 (length current))
               "Failed full-heap allocation changed the live graph")
        (set-world-root world 0 nil)
        (let ((record (collect-world world)))
          (check (eq :complete (cycle-result-status record))
                 "Reclamation after full-heap failure returned ~S/~S"
                 (cycle-result-status record) (cycle-result-reason record)))
        (dolist (entry current)
          (check (stale-reference-p world (cdr entry))
                 "Reclaimed full-heap reference ~S still normalized" (car entry)))
        (let ((fresh (allocate-node world 3000)))
          (check (live-reference-p world fresh)
                 "Allocation after complete reclamation did not normalize")
          (set-world-root world 0 fresh))))))

(defun run-full-heap-regressions ()
  (run-profile #'run-full-heap-profile)
  t)

(defun run-retained-continuation-profile (algorithm)
  ;; Inject one partial Await failure.  The collection returns :RETAINED at a
  ;; safe pre-coverage boundary, cancels the stop, and later entry must work.
  (with-quality-world
      (world :algorithm algorithm :object-starts :packed
             :extent 512 :trace-capacity 32 :stop-capacity 16
             :await-fail-after 1)
    (let ((node (allocate-node world 4000))
          (coordinator (world-coordinator world)))
      (set-world-root world 0 node)
      (let ((record (collect-world world)))
        (check (and (eq :retained (cycle-result-status record))
                    (eq :coverage-failed (cycle-result-reason record)))
               "Injected Await failure returned ~S/~S"
               (cycle-result-status record) (cycle-result-reason record)))
      (let* ((wakes (clamsara::simulator-wake-counts coordinator))
             (first-total (reduce #'+ wakes)))
        (check (= first-total 1)
               "Partial retained cancellation woke ~D continuations, expected 1"
               first-total)
        ;; Disable only the deterministic host fault.  Collector continuation
        ;; uses the ordinary allocation/barrier/collection entries.
        (setf (clamsara::simulator-await-fail-after coordinator) nil)
        (let ((child (allocate-node world 4001)))
          (set-node-slot world node 1 child))
        (let ((record (collect-world world)))
          (check (eq :complete (cycle-result-status record))
                 "Collection could not continue after safe retained return: ~S/~S"
                 (cycle-result-status record) (cycle-result-reason record)))
        (let* ((providers (clamsara::simulator-root-providers
                           (world-roots world)))
               (provider-count (count-if #'identity providers))
               (second-total (reduce #'+ wakes)))
          (check (= second-total (+ first-total provider-count))
                 "Successful continuation did not wake each participant once: ~D/~D"
                 second-total (+ first-total provider-count)))))))

(defun run-stop-reservation-regression ()
  ;; A one-token coordinator has no reservation for its second collection.
  ;; Rejection must leave the fresh caller record untouched and ordinary root
  ;; mutation entry open.  This fixture closes without another collection.
  (let ((world
          (make-quality-world
           :algorithm :marksweep :object-starts :packed
           :extent 512 :trace-capacity 32 :stop-capacity 1)))
    (check (eq :complete (cycle-result-status (collect-world world)))
           "First one-token collection failed")
    (let ((record (make-cycle-result-record (world-plan world))))
      (signals-runtime-reason
       (lambda ()
         (collect (world-configuration world) :all :explicit record))
       :preflight-failed)
      (check (eq :uninitialized (cycle-result-status record))
             "Failed stop reservation mutated its result record"))
    (set-world-root world 0 :quality-immediate)
    (check (eq :quality-immediate (read-world-root world 0))
           "Failed stop reservation closed later root mutation")
    (set-world-root world 0 nil)
    (check (eq :unbound
               (unbind-mutator (world-configuration world)
                               (world-context world)))
           "Stop-reservation fixture did not unbind")
    (multiple-value-bind (status reason)
        (shutdown-configuration (world-configuration world))
      (check (and (eq status :complete) (null reason))
             "Stop-reservation fixture did not close: ~S/~S" status reason))
    t))

(defun run-finalizer-profile (algorithm)
  (with-quality-world
      (world :algorithm algorithm :object-starts :scalar
             :extent 1024 :trace-capacity 64 :conditional-capacity 64
             :finalizer-capacity 8 :stop-capacity 16)
    (let ((counts (make-array 3 :initial-element 0))
          (callback-references (make-array 3 :initial-element nil))
          (tokens '()))
      (dotimes (index 3)
        (let ((referent (allocate-node world (+ 6000 index))))
          (push
           (register-finalizer
            (world-registry world) (world-context world) referent
            (let ((position index))
              (lambda (corrected)
                (incf (aref counts position))
                (setf (aref callback-references position) corrected)
                (check (live-reference-p world corrected)
                       "Finalizer ~D received a stale referent" position)
                (when (= position 1)
                  (error "intentional quality finalizer failure")))))
           tokens)))
      (let ((record (collect-world world)))
        (check (eq :complete (cycle-result-status record))
               "Finalizer selection collection failed: ~S/~S"
               (cycle-result-status record) (cycle-result-reason record)))
      (check (= 3 (drain-pending-finalizers
                   (world-registry world) (world-context world)))
             "Finalizer drain did not consume all three pending actions")
      (check-equal '(1 1 1) (coerce counts 'list)
                   "finalizer callback counts")
      (check (= 0 (drain-pending-finalizers
                   (world-registry world) (world-context world)))
             "Second drain repeated a finalizer action")
      (dolist (token tokens)
        (check (eq :already-finalized
                   (cancel-finalizer (world-registry world)
                                     (world-context world) token))
               "Drained finalizer token remained active"))
      ;; No pending records now root the referents.  A later collection retires
      ;; every callback encoding, while the callbacks stay exactly-once.
      (let ((record (collect-world world)))
        (check (eq :complete (cycle-result-status record))
               "Post-drain reclamation failed"))
      (dotimes (index 3)
        (check (stale-reference-p world
                                  (aref callback-references index))
               "Finalizer referent ~D survived after pending drain" index))
      (check-equal '(1 1 1) (coerce counts 'list)
                   "post-reclamation finalizer callback counts"))))

(defun run-stateful-quality-tests ()
  (run-equivalent-profile-matrix)
  (run-admission-regression)
  (run-full-heap-regressions)
  (run-retained-continuation-profile :semispace)
  (run-retained-continuation-profile :marksweep)
  (run-stop-reservation-regression)
  (run-finalizer-profile :semispace)
  (run-finalizer-profile :marksweep)
  (format t "~&QUALITY-STATEFUL-PASS seed=#x~8,'0X iterations=~D profiles=4~%"
          +stateful-seed+ +stateful-iterations+)
  t)
