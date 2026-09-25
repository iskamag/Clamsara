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
  ;; for a moving plan, and a tombstone row per dead source for a nonmoving
  ;; plan.  Both are the participant's source-indexed evidence.
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
             (check (valid-reference-p (world-model w) key)
                    "Staged source key is not a live reference")
             (if (eq dead 1)
                 (incf deaths)
                 (progn
                   (incf moves)
                   (check (valid-reference-p (world-model w) value)
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

(defun run-movement-participant-tests ()
  (run-profile (lambda (algorithm starts)
                 (run-source-directory-lifecycle algorithm starts)))
  (run-source-directory-death)
  (run-source-directory-failure)
  (run-source-directory-cancel-idempotent)
  (format t "~&MOVEMENT-PARTICIPANT-PASS~%")
  t)
