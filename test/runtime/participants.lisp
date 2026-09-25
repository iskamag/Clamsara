;;;; test/runtime/participants.lisp -- movement-participant contract tests.
;;;; Real source-indexed participant staged through real moving cycles.
(defpackage #:clamsara.runtime.participants.test
  (:use #:cl #:clamsara #:clamsara.quality.support)
  (:export #:run-movement-participant-tests))
(in-package #:clamsara.runtime.participants.test)

(defun check (value control &rest arguments)
  (unless value (apply #'error control arguments)) value)

(defun run-source-directory-lifecycle (algorithm starts)
  ;; A real cycle stages one row per source fact: a move row per copied source
  ;; for a moving plan.  A staged source key is the OLD start, so after source
  ;; retirement it must no longer normalize; the destination must be live.
  (let ((participant (make-source-directory-participant :capacity 16))
        (moved-p (eq algorithm :semispace)))
    (with-quality-world (w :algorithm algorithm :object-starts starts
                           :movement-participants (list participant))
      (let ((a (allocate-node w 1)))
        (set-world-root w 0 a)
        (let ((b (allocate-node w 2)))
          (set-node-slot w a 1 b)
          (set-world-root w 1 b))
        (let ((record (collect-world w :scope :all)))
          (check (eq :complete (cycle-result-status record))
                 "Cycle failed: ~S/~S" (cycle-result-status record)
                 (cycle-result-reason record)))
        (let ((moves 0) (deaths 0))
          (map-participant-directory
           participant
           (lambda (key value dead)
             ;; The source is retired, so a move row's key must be stale.
             (check (stale-reference-p w key)
                    "Move source key was not retired")
             (if (eq dead 1)
                 (incf deaths)
                 (progn
                   (incf moves)
                   (check (live-reference-p w value)
                          "Staged destination is not a live reference")))))
          ;; A moving plan copies both live nodes; a nonmoving plan stages no
          ;; move rows but may stage tombstones for reclaimed sources.
          (if moved-p
              (check (= moves 2) "Expected two move rows, got ~D" moves)
              (check (zerop moves) "Nonmoving plan staged move rows: ~D" moves))))
      (check (not (clamsara::%participant-prepared-p participant))
             "Participant remained staged after commit"))))

(defun run-source-directory-death ()
  ;; A nonmoving plan with an unreachable source must stage a tombstone row.
  (let ((participant (make-source-directory-participant :capacity 16)))
    (with-quality-world (w :algorithm :marksweep
                           :movement-participants (list participant))
      (let ((garbage (allocate-node w 99)))
        (declare (ignore garbage))
        (set-world-root w 0 (allocate-node w 1)))
      (let ((record (collect-world w :scope :all)))
        (check (eq :complete (cycle-result-status record))
               "Death cycle failed: ~S" (cycle-result-reason record)))
      (let ((deaths 0))
        (map-participant-directory
         participant (lambda (key value dead)
                       (declare (ignore key value))
                       (when (eq dead 1) (incf deaths))))
        (check (plusp deaths) "No tombstone row staged for a dead source")))))

(defun run-source-directory-failure ()
  ;; Capacity exhaustion is a precommit failure: the cycle retains, the plan
  ;; does not resume, and the participant clears its own staged rows.  A
  ;; retained world cannot be closed, so this case owns its world directly and
  ;; deliberately leaves it retained (as the copy-action fault cases do).
  (let* ((participant (make-source-directory-participant :capacity 1))
         (world (make-quality-world :algorithm :semispace
                                    :movement-participants (list participant))))
    (set-world-root world 0 (allocate-node world 1))
    (set-world-root world 1 (allocate-node world 2))
    (let ((record (collect-world world :scope :all)))
      (check (and (eq :retained (cycle-result-status record))
                  (eq :capacity-exhausted (cycle-result-reason record)))
             "Capacity failure outcome changed: ~S/~S"
             (cycle-result-status record) (cycle-result-reason record)))
    (check (eq :retained (clamsara::%plan-state (world-plan world)))
           "Precommit participant failure resumed the plan")
    (check (zerop (participant-directory-count participant))
           "Failed participant retained staged rows")
    (check (not (clamsara::%participant-prepared-p participant))
           "Failed participant remained prepared")))

(defun run-source-directory-cancel-idempotent ()
  ;; Cancel is bounded, non-failing and cycle-idempotent on a prepared or
  ;; unprepared participant.
  (let ((participant (make-source-directory-participant :capacity 4)))
    (with-quality-world (w :algorithm :semispace
                           :movement-participants (list participant))
      (set-world-root w 0 (allocate-node w 1))
      (cancel-movement-participant participant
                                   (clamsara::%plan-cycle (world-plan w)))
      (cancel-movement-participant participant
                                   (clamsara::%plan-cycle (world-plan w)))
      (check (zerop (participant-directory-count participant))
             "Cancelled participant has rows"))))

(defun run-directory-matches-cycle-counts ()
  ;; The staged rows must agree with the cycle's own movement/death counts.
  (run-profile
   (lambda (algorithm starts)
     (let ((participant (make-source-directory-participant :capacity 64)))
       (with-quality-world (w :algorithm algorithm :object-starts starts
                              :movement-participants (list participant))
         (let ((nodes nil))
           (dotimes (index 8)
             (let ((node (allocate-node w index)))
               (push node nodes)
               (set-world-root w index node)))
           (loop for (a b) on nodes while b do (set-node-slot w a 1 b)))
         (let ((record (collect-world w :scope :all)))
           (check (eq :complete (cycle-result-status record))
                  "cycle failed: ~S" (cycle-result-reason record))
           (let ((moves 0) (deaths 0))
             (map-participant-directory
              participant
              (lambda (key value dead)
                (declare (ignore key value))
                (if (eq dead 1) (incf deaths) (incf moves))))
             (multiple-value-bind (moved moved-known)
                 (cycle-result-count record :objects-moved)
               (multiple-value-bind (dead dead-known)
                   (cycle-result-count record :objects-dead)
                 (check (and moved-known dead-known)
                        "cycle counts unavailable")
                 (check (= moves moved)
                        "Move rows ~D disagree with :objects-moved ~D"
                        moves moved)
                 (check (= deaths dead)
                        "Tombstone rows ~D disagree with :objects-dead ~D"
                        deaths dead))))))))
   :algorithms '(:semispace :marksweep)))

(defun run-capacity-boundary ()
  ;; Exactly at capacity succeeds and stages every source; one over fails
  ;; precommit and leaves no rows.
  (flet ((attempt (capacity objects)
           (let ((participant (make-source-directory-participant :capacity capacity)))
             (handler-case
                 (let ((world (make-quality-world
                               :algorithm :semispace
                               :movement-participants (list participant))))
                   (set-world-root world 0 (allocate-node world 1))
                   (dotimes (index (1- objects))
                     (set-world-root world 1 (allocate-node world (+ 2 index))))
                   (values participant (collect-world world :scope :all)))
               (error () (values participant nil))))))
    ;; A single live root: exactly one source, capacity one succeeds.
    (multiple-value-bind (participant record) (attempt 1 1)
      (check (and record (eq :complete (cycle-result-status record)))
             "Exact-capacity cycle failed")
      (check (= 1 (participant-directory-count participant))
             "Exact-capacity participant did not stage one row"))
    ;; Four distinct live sources with capacity two fails precommit.
    (multiple-value-bind (participant record) (attempt 2 4)
      (check (and record (eq :retained (cycle-result-status record))
                  (eq :capacity-exhausted (cycle-result-reason record)))
             "Over-capacity cycle did not retain with :capacity-exhausted")
      (check (zerop (participant-directory-count participant))
             "Over-capacity participant retained staged rows"))))

(defclass prepare-once-participant (movement-participant)
  ((prepared :initform nil :accessor once-prepared)))
(defmethod prepare-movement-participant ((p prepare-once-participant) cycle)
  (declare (ignore cycle))
  (when (once-prepared p)
    (error "prepare called twice for one cycle"))
  (setf (once-prepared p) t)
  (values :ready nil))
(defmethod cancel-movement-participant ((p prepare-once-participant) cycle)
  (declare (ignore cycle)) (values))
(defmethod finish-movement-participant ((p prepare-once-participant) cycle)
  (declare (ignore cycle)) (setf (once-prepared p) nil) (values))

(defun run-prepare-exactly-once-per-cycle ()
  ;; The driver must call prepare exactly once per cycle, and a manual second
  ;; prepare on a staged source directory is an invariant rejection, not a
  ;; silent reuse of stale rows.
  (let ((participant (make-instance 'prepare-once-participant)))
    (with-quality-world (w :algorithm :semispace
                           :movement-participants (list participant))
      (set-world-root w 0 (allocate-node w 1))
      (dotimes (round 3)
        (collect-world w :scope :all)
        (check (not (once-prepared participant))
               "Participant stayed prepared after collect"))))
  (let ((participant (make-source-directory-participant :capacity 8)))
    (with-quality-world (w :algorithm :semispace
                           :movement-participants (list participant))
      (set-world-root w 0 (allocate-node w 1))
      (collect-world w :scope :all)
      (let ((cycle (clamsara::%plan-cycle (world-plan w))))
        (prepare-movement-participant participant cycle)
        (check (handler-case
                   (progn (prepare-movement-participant participant cycle) nil)
                 (clamsara::runtime-rejection () t))
               "Second prepare was silently admitted")
        ;; Leave the participant clean so the fixture can discharge and close.
        (cancel-movement-participant participant cycle)))))

(defclass counting-participant (movement-participant)
  ((prepared-p :initform nil :accessor count-prepared-p)
   (cancels :initform 0 :accessor count-cancels)
   (finishes :initform 0 :accessor count-finishes)
   (fail-prepare-p :initarg :fail-prepare-p :initform nil
                   :reader count-fail-prepare-p)))
(defmethod prepare-movement-participant ((p counting-participant) cycle)
  (declare (ignore cycle))
  (if (count-fail-prepare-p p)
      (values :retained :capacity-exhausted)
      (progn (setf (count-prepared-p p) t) (values :ready nil))))
(defmethod cancel-movement-participant ((p counting-participant) cycle)
  (declare (ignore cycle))
  (when (count-prepared-p p) (incf (count-cancels p)))
  (setf (count-prepared-p p) nil)
  (values))
(defmethod finish-movement-participant ((p counting-participant) cycle)
  (declare (ignore cycle))
  (incf (count-finishes p))
  (values))

(defun run-ready-participant-cancelled-once ()
  ;; When a later participant fails preflight, an already-ready participant is
  ;; cancelled exactly once (execution.tex: precommit cancellation of every
  ;; ready participant).
  (let* ((ready (make-instance 'counting-participant))
         (failing (make-instance 'counting-participant :fail-prepare-p t))
         (world (make-quality-world :algorithm :semispace
                                    :movement-participants (list ready failing))))
    (set-world-root world 0 (allocate-node world 1))
    (let ((record (collect-world world :scope :all)))
      (check (and (eq :retained (cycle-result-status record))
                  (eq :capacity-exhausted (cycle-result-reason record)))
             "Expected precommit failure, got ~S/~S"
             (cycle-result-status record) (cycle-result-reason record)))
    (check (= 1 (count-cancels ready))
           "Ready participant was not cancelled exactly once: ~D"
           (count-cancels ready))
    (check (zerop (count-finishes ready))
           "Cancelled participant was finished anyway")))

(defun run-middle-participant-failure ()
  ;; Three participants, the middle one fails: the prefix is cancelled exactly
  ;; once, the failing one is not cancelled, and the later one is never touched.
  (let* ((first (make-instance 'counting-participant))
         (middle (make-instance 'counting-participant :fail-prepare-p t))
         (last (make-instance 'counting-participant))
         (world (make-quality-world :algorithm :semispace
                                    :movement-participants
                                    (list first middle last))))
    (set-world-root world 0 (allocate-node world 1))
    (let ((record (collect-world world :scope :all)))
      (check (and (eq :retained (cycle-result-status record))
                  (eq :capacity-exhausted (cycle-result-reason record)))
             "Expected precommit failure, got ~S/~S"
             (cycle-result-status record) (cycle-result-reason record)))
    (check (= 1 (count-cancels first))
           "Prefix participant not cancelled exactly once")
    (check (zerop (count-cancels middle))
           "Failing participant was cancelled by the driver")
    (check (zerop (count-cancels last))
           "Participant after the failure was touched")
    (check (zerop (count-finishes last))
           "Participant after the failure was finished")))

(defclass bad-finish-participant (movement-participant) ())
(defmethod prepare-movement-participant ((p bad-finish-participant) cycle)
  (declare (ignore p cycle)) (values :ready nil))
(defmethod cancel-movement-participant ((p bad-finish-participant) cycle)
  (declare (ignore p cycle)) (values))
(defmethod finish-movement-participant ((p bad-finish-participant) cycle)
  (declare (ignore p cycle)) (error "Participant finish must not signal"))

(defun run-failed-finish-holds-stop ()
  ;; A signalling closed commit keeps the stop and refuses ordinary entry
  ;; (execution.tex: retained exit is forbidden from the first destructive
  ;; write; complete recovery or keep the stop for the fatal path).
  (let* ((participant (make-instance 'bad-finish-participant))
         (world (make-quality-world :algorithm :semispace
                                    :movement-participants (list participant))))
    (set-world-root world 0 (allocate-node world 1))
    (let ((record (collect-world world :scope :all)))
      (check (eq :retained (cycle-result-status record))
             "Failed finish did not retain the cycle"))
    (check (eq :retained (clamsara::%plan-state (world-plan world)))
           "Failed finish resumed the plan")
    (check (eq :covered (clamsara::simulator-stop-state (world-coordinator world)))
           "Failed finish released the covering stop")
    (check (handler-case
               (progn (allocate-object (world-context world) :quality-node
                                       32 16 (world-node-kind world)) nil)
             (clamsara::runtime-rejection () t))
           "Ordinary allocation was admitted under a retained stop")))

(defclass order-probe-participant (movement-participant)
  ((rows :initform nil :accessor order-rows)
   (sources-live-at-finish :initform :unset :accessor order-sources-live)))
(defmethod prepare-movement-participant ((p order-probe-participant) cycle)
  (setf (order-rows p) nil
        (order-sources-live p) :unset)
  (map-cycle-movements cycle (lambda (old new) (push (cons old new) (order-rows p))))
  (values :ready nil))
(defmethod cancel-movement-participant ((p order-probe-participant) cycle)
  (declare (ignore p cycle)) (values))
(defmethod finish-movement-participant ((p order-probe-participant) cycle)
  ;; At finish the source must still be live; source retirement happens after
  ;; participants finish (execution.tex closed-commit order).  A real
  ;; destination-substituting participant depends on this.
  (let ((model (configuration-object-model (clamsara::%cycle-configuration cycle))))
    (setf (order-sources-live p)
          (every (lambda (pair)
                   (handler-case
                       (progn (normalize-reference model (car pair)) t)
                     (error () nil)))
                 (order-rows p))))
  (values))

(defun run-finish-precedes-source-retirement ()
  (let ((participant (make-instance 'order-probe-participant)))
    (with-quality-world (w :algorithm :semispace
                           :movement-participants (list participant))
      (set-world-root w 0 (allocate-node w 1))
      (collect-world w :scope :all)
      (check (plusp (length (order-rows participant)))
             "Order probe staged no moves")
      (check (eq t (order-sources-live participant))
             "Source was already retired when participant finished"))))

(defclass signalling-cycle (clamsara::sequential-cycle) ())
(defmethod map-cycle-movements ((cycle signalling-cycle) function)
  ;; Stage nothing observable, then signal: the participant must not be left
  ;; with a prepared flag or staged rows.
  (declare (ignore function))
  (error "Enumerator signalled"))

(defun run-signalling-prepare-leaves-no-rows ()
  ;; If the cycle enumerators signal mid-prepare, the participant must not be
  ;; left with partial staged rows or a prepared flag.
  (let ((participant (make-source-directory-participant :capacity 8)))
    (with-quality-world (w :algorithm :semispace
                           :movement-participants (list participant))
      (set-world-root w 0 (allocate-node w 1))
      (collect-world w :scope :all)
      ;; A cycle object carrying the real configuration but a signalling
      ;; movement enumerator.
      (let ((bad (make-instance 'signalling-cycle)))
        (setf (clamsara::%cycle-configuration bad)
              (clamsara::%cycle-configuration (clamsara::%plan-cycle
                                               (world-plan w))))
        (handler-case
            (progn (prepare-movement-participant participant bad)
                   (error "Signalling prepare returned normally"))
          (error () nil)))
      (check (zerop (participant-directory-count participant))
             "Signalling prepare left staged rows")
      (check (not (clamsara::%participant-prepared-p participant))
             "Signalling prepare left the participant prepared"))))

(defun run-movement-participant-tests ()
  (run-profile (lambda (algorithm starts)
                 (run-source-directory-lifecycle algorithm starts)))
  (run-source-directory-death)
  (run-source-directory-failure)
  (run-source-directory-cancel-idempotent)
  (run-directory-matches-cycle-counts)
  (run-prepare-exactly-once-per-cycle)
  (run-capacity-boundary)
  (run-finish-precedes-source-retirement)
  (run-signalling-prepare-leaves-no-rows)
  (run-ready-participant-cancelled-once)
  (run-middle-participant-failure)
  (run-failed-finish-holds-stop)
  (format t "~&MOVEMENT-PARTICIPANT-PASS~%")
  t)
