;;;; src/runtime/participants.lisp -- source-indexed movement participants.
;;;;
;;;; Paper contract (chapters/execution.tex, "Tracing and phase state"):
;;;;   "Every installed component with source-indexed facts is a movement
;;;;    participant.  It prepares staged repairs/tombstones from the cycle's
;;;;    move/death enumerators.  All must be ready.  Precommit cancellation of
;;;;    every ready participant is bounded, non-failing and cycle-idempotent;
;;;;    after ready, participant finish is bounded and non-failing."
;;;; and chapters/collectors.tex: "Every movement participant prepares
;;;; tombstones for dead sources."
;;;;
;;;; A participant holds one bounded source-indexed row table: for each distinct
;;;; source start, either its destination (a move) or a tombstone (a death).
;;;; Prepare stages the rows from the cycle enumerators without touching any
;;;; published representation, so precommit cancellation is a bounded clear.
(in-package #:clamsara)

(defclass source-directory-participant (movement-participant)
  ((capacity :initarg :capacity :reader %participant-capacity)
   (resource-id :initform (gensym "MOVEMENT-DIRECTORY-")
                :reader %participant-resource-id)
   (keys :initform nil :accessor %participant-keys)
   (values :initform nil :accessor %participant-values)
   (dead-p :initform nil :accessor %participant-dead-p)
   (count :initform 0 :accessor %participant-count)
   (prepared-p :initform nil :accessor %participant-prepared-p)))

(defun make-source-directory-participant (&key capacity)
  "One source-indexed movement participant with a bounded row table.

CAPACITY bounds distinct sources per cycle: every moved source and every dead
source gets one row, so it must cover the whole source population (moves plus
deaths), not just survivors.  Exhaustion is a precommit failure that retains the
cycle."
  (unless (typep capacity '(integer 1 #.most-positive-fixnum))
    (%runtime-reject :invalid-participant-capacity))
  (make-instance 'source-directory-participant :capacity capacity))

(defmethod component-resources ((participant source-directory-participant))
  (let ((capacity (%participant-capacity participant)))
    (list (make-resource-contribution
           participant (%participant-resource-id participant)
           :runtime-object-vector
           :minimum-physical-bytes (+ 16 (* 8 (* 3 capacity)))
           :logical-entry-bound (* 3 capacity)
           :auxiliary-bytes 1024
           :allocation-context :construction-only
           :exhaustion-action :reject-before-publication))))

(defmethod initialize-component ((participant source-directory-participant) context)
  (let ((capacity (%participant-capacity participant)))
    (multiple-value-bind (storage present-p physical entries auxiliary)
        (construction-resource context (%participant-resource-id participant))
      (unless (and present-p (typep storage 'simple-vector)
                   (>= physical (+ 16 (* 8 (* 3 capacity))))
                   (>= entries (* 3 capacity))
                   (>= (length storage) (* 3 capacity))
                   (>= auxiliary 1024))
        (%runtime-reject :participant-resource-capacity))
      (setf (%participant-keys participant)
            (make-array capacity :displaced-to storage)
            (%participant-values participant)
            (make-array capacity :displaced-to storage
                        :displaced-index-offset capacity)
            (%participant-dead-p participant)
            (make-array capacity :displaced-to storage
                        :displaced-index-offset (* 2 capacity)))
      (dolist (object (list (%participant-keys participant)
                            (%participant-values participant)
                            (%participant-dead-p participant)))
        (%register-resource-auxiliary context (%participant-resource-id participant)
                                      object))
      (fill (%participant-keys participant) nil)
      (fill (%participant-values participant) nil)
      (fill (%participant-dead-p participant) 0)
      (setf (%participant-count participant) 0
            (%participant-prepared-p participant) nil)
      (values))))

(defun %participant-find (participant model key)
  "Return the staged row index for KEY, or NIL.  Bounded linear probe over the
construction-fixed row bound."
  (dotimes (index (%participant-count participant) nil)
    (let ((existing (aref (%participant-keys participant) index)))
      (when (reference-equal model existing key)
        (return index)))))

(defmethod prepare-movement-participant
    ((participant source-directory-participant) cycle)
  ;; A second prepare for the same cycle without an intervening finish/cancel is
  ;; an invariant fault, not permission to reuse stale rows.  The driver calls
  ;; prepare once per cycle per participant.
  (when (%participant-prepared-p participant)
    (%runtime-reject :fatal-invariant))
  ;; Stage from scratch for this cycle.
  (setf (%participant-count participant) 0)
  (fill (%participant-keys participant) nil)
  (fill (%participant-values participant) nil)
  (fill (%participant-dead-p participant) 0)
  (let ((model (configuration-object-model
                (%cycle-configuration cycle)))
        (overflow nil)
        (ready nil))
    (unwind-protect
         (flet ((row (source value dead)
                  (let ((index (%participant-find participant model source)))
                    (cond (index
                           ;; A source moves or dies once; a later duplicate is
                           ;; a different fact for the same start only if it
                           ;; disagrees.
                           (when (and (not dead)
                                      (not (eql 1 (aref (%participant-dead-p
                                                         participant) index))))
                             (setf (aref (%participant-values participant) index)
                                   value)))
                          ((>= (%participant-count participant)
                               (%participant-capacity participant))
                           (setf overflow t))
                          (t
                           (let ((index (%participant-count participant)))
                             (setf (aref (%participant-keys participant) index)
                                   source
                                   (aref (%participant-values participant) index)
                                   value
                                   (aref (%participant-dead-p participant) index)
                                   (if dead 1 0))
                             (incf (%participant-count participant))))))))
           (map-cycle-movements cycle (lambda (old new) (row old new nil)))
           ;; Deaths are staged second so a source that both moved and is
           ;; reported dead keeps the move's destination rather than a
           ;; tombstone.
           (map-cycle-deaths
            cycle (lambda (space start)
                    (declare (ignore space)) (row start nil t)))
           ;; Reaching here means both enumerations returned normally.
           (setf ready (not overflow)))
      ;; Any non-ready exit -- capacity overflow or a signalling enumerator --
      ;; leaves this participant with no staged rows.  It never became ready,
      ;; so the driver's ready-list cancellation cannot reach it.
      (unless ready
        (setf (%participant-count participant) 0
              (%participant-prepared-p participant) nil)))
    (if overflow
        (values :retained :capacity-exhausted)
        (progn
          (setf (%participant-prepared-p participant) t)
          (values :ready nil)))))

(defmethod cancel-movement-participant
    ((participant source-directory-participant) cycle)
  (declare (ignore cycle))
  ;; Bounded, non-failing, cycle-idempotent clear of staged state.
  (setf (%participant-count participant) 0
        (%participant-prepared-p participant) nil)
  (values))

(defmethod finish-movement-participant
    ((participant source-directory-participant) cycle)
  (declare (ignore cycle))
  (unless (%participant-prepared-p participant)
    (%runtime-reject :fatal-invariant))
  ;; Closed commit: bounded, non-failing.  The staged rows become the
  ;; participant's authoritative published directory.
  (setf (%participant-prepared-p participant) nil)
  (values))

;;; Read-only inspection of the committed directory.
(defun participant-directory-count (participant)
  (%participant-count participant))

(defun map-participant-directory (participant function)
  (dotimes (index (%participant-count participant))
    (funcall function (aref (%participant-keys participant) index)
             (aref (%participant-values participant) index)
             (aref (%participant-dead-p participant) index)))
  (values))

(export '(make-source-directory-participant map-participant-directory
          participant-directory-count))
