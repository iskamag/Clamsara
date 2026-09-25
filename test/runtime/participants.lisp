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

(defun run-movement-participant-tests ()
  (run-profile (lambda (algorithm starts)
                 (run-source-directory-lifecycle algorithm starts)))
  (run-source-directory-death)
  (run-source-directory-failure)
  (run-source-directory-cancel-idempotent)
  (run-ready-participant-cancelled-once)
  (run-failed-finish-holds-stop)
  (format t "~&MOVEMENT-PARTICIPANT-PASS~%")
  t)
