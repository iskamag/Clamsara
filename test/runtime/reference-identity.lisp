;;;; test/runtime/reference-identity.lisp -- reference-object identity portability.
;;;;
;;;; The hosted object model interns one base reference per descriptor cell, so
;;;; an implementation that keys source tables by reference EQ identity happens
;;;; to work there.  The paper declares references model-private opaque
;;;; (clients.tex "References and object representations") and names
;;;; reference-equal / reference-encoding-equal-p as THE identity tests, so a
;;;; model that materializes a fresh reference per normalization must work too.
;;;;
;;;; These tests install a non-interning wrapper over the hosted model: two
;;;; normalizations of the same canonical source return two DIFFERENT objects
;;;; that are reference-equal and share reference-address.  The real trace
;;;; context and the real source-directory participant are then driven through
;;;; that model, so an EQ/EQL-keyed core fails here and an address-keyed core
;;;; passes.
(defpackage #:clamsara.runtime.reference-identity.test
  (:use #:cl #:clamsara #:clamsara.quality.support)
  (:export #:run-reference-identity-tests))
(in-package #:clamsara.runtime.reference-identity.test)

;;; ------------------------------------------------------------------
;;; Non-interning object model.
;;;
;;; BIND-OBJECT-MODEL is the only seam that publishes a model; it changes the
;;; class of the bound model so every runtime lookup dispatches on the wrapper.
;;; NORMALIZE-REFERENCE then returns a fresh copy of the interned base while
;;; preserving the descriptor, address and reference-equal judgment.

(defclass non-interning-offer (clamsara::host-object-model) ())
(defclass non-interning-bound (clamsara::host-bound-object-model) ())

(defun %fresh-base (model base)
  (clamsara::%make-host-reference
   :model model
   :descriptor (clamsara::host-reference-descriptor base)
   :address (clamsara::host-reference-address base)
   :kind :base :tag 0 :displacement 0))

(defun %interned-base (model reference)
  ;; The interned planes are the model's own storage, not a host interned
  ;; identity: rebuilding from them yields the canonical base again.
  (or (clamsara::%host-base-reference-by-index
       model (clamsara::host-reference-descriptor reference))
      reference))

(defmethod bind-object-model ((model non-interning-offer) layout bindings)
  (change-class (call-next-method) 'non-interning-bound))

(defmethod normalize-reference ((model non-interning-bound) reference)
  (multiple-value-bind (base descriptor) (call-next-method)
    (values (%fresh-base model base) descriptor)))

(defmethod reference-address ((model non-interning-bound) start)
  (unless (valid-reference-p model start) (error "Not a reference"))
  (clamsara::host-reference-address start))

(defmethod rebuild-reference ((model non-interning-bound) new-start descriptor)
  (call-next-method model (%interned-base model new-start) descriptor))

(defmethod reference-equal ((model non-interning-bound) left right)
  (let ((left-base
          (and (valid-reference-p model left)
               (nth-value 0 (normalize-reference model left))))
        (right-base
          (and (valid-reference-p model right)
               (nth-value 0 (normalize-reference model right)))))
    (cond ((and left-base right-base)
           (= (clamsara::host-reference-address left-base)
              (clamsara::host-reference-address right-base)))
          (t (eql left right)))))

(defmethod reference-encoding-equal-p ((model non-interning-bound) left right)
  (cond ((and (valid-reference-p model left) (valid-reference-p model right))
         (and (eql (clamsara::host-reference-address left)
                   (clamsara::host-reference-address right))
              (eql (clamsara::host-reference-kind left)
                   (clamsara::host-reference-kind right))
              (eql (clamsara::host-reference-tag left)
                   (clamsara::host-reference-tag right))
              (eql (clamsara::host-reference-displacement left)
                   (clamsara::host-reference-displacement right))))
        (t (eql left right))))

(defun non-interning-configure (model)
  "Model-extension seam: wrap the offered model before binding."
  (change-class model 'non-interning-offer))

;;; ------------------------------------------------------------------
;;; The identity premise.

(defun run-non-interning-premise ()
  (with-quality-world (world :algorithm :semispace :object-starts :packed
                             :configure-model #'non-interning-configure)
    (let* ((model (world-model world))
           (object (allocate-node world 1))
           (first (normalize-reference model object))
           (second (normalize-reference model object)))
      (check (not (eql first second))
             "Non-interning model returned the same reference object twice")
      (check (reference-equal model first second)
             "Fresh references for one source were not reference-equal")
      (check (eql (reference-address model first) (reference-address model second))
             "Fresh references for one source disagreed on reference-address"))))

;;; ------------------------------------------------------------------
;;; Trace context: a second claim for the same source is :SEEN, never a fatal.

(defun run-trace-context-fresh-reference-dedup ()
  (with-quality-world (world :algorithm :semispace :object-starts :packed
                             :configure-model #'non-interning-configure)
    (let* ((object (allocate-node world 1))
           (model (world-model world))
           (space (world-space world))
           (cycle (clamsara::%plan-cycle (world-plan world))))
      (set-world-root world 0 object)
      (clamsara::%reset-cycle cycle (world-configuration world) :all
                              :explicit :semispace)
      (begin-trace-context cycle :all 128)
      (let* ((context (clamsara::%cycle-trace cycle))
             (first (normalize-reference model object))
             (second (normalize-reference model object)))
        (check (not (eql first second))
               "Premise lost: references were interned")
        (multiple-value-bind (status claim reservation)
            (trace-claim-object context space first)
          (check (eq :first status)
                 "First claim was ~S, not :FIRST" status)
          (check (eq :complete
                     (trace-commit-object context claim reservation space first))
                 "First claim did not commit"))
        (multiple-value-bind (status claim reservation)
            (trace-claim-object context space second)
          (check (eq :seen status)
                 "Second claim for one source was ~S, not :SEEN" status)
          (check (and (null claim) (null reservation))
                 "A :SEEN result transferred a capability"))
        ;; Drain the single committed item, then the context must be quiescent.
        (multiple-value-bind (work-space work-start status)
            (trace-take-work context cycle)
          (check (eq :work status) "Take-work returned ~S" status)
          (check (and (eq space work-space)
                      (reference-equal model work-start first))
                 "Taken work start is not the committed destination")
          (trace-finish-work context cycle work-space work-start))
        (multiple-value-bind (status reason) (finish-trace-context context)
          (check (and (eq :complete status) (null reason))
                 "Trace context did not finish quiescent: ~S/~S"
                 status reason))))))

(defun run-shared-source-cycle-completes ()
  ;; A source reached through two roots is claimed once and discovered once.
  ;; With a non-interning model the old EQ/EQL comparison failed the second
  ;; claim and retained the cycle as :fatal-invariant.
  (with-quality-world (world :algorithm :semispace :object-starts :packed
                             :configure-model #'non-interning-configure)
    (let ((shared (allocate-node world 1)))
      (set-world-root world 0 shared)
      (set-world-root world 1 shared))
    (let ((record (collect-world world :scope :all)))
      (check (and (eq :complete (cycle-result-status record))
                  (eq :complete (cycle-result-reason record)))
             "Shared-source cycle failed: ~S/~S"
             (cycle-result-status record) (cycle-result-reason record))
      (check (= 1 (nth-value 0 (cycle-result-count record :objects-discovered)))
             "Shared source was discovered more than once"))))

;;; ------------------------------------------------------------------
;;; Movement participant: one row per canonical source, keyed by address.

(defclass enumerating-cycle (clamsara::sequential-cycle)
  ;; MOVEMENTS is a list of (OLD . NEW); DEATHS is a list of (SPACE . START).
  ((movements :initarg :movements :initform nil :accessor enum-movements)
   (deaths :initarg :deaths :initform nil :accessor enum-deaths)))

(defmethod map-cycle-movements ((cycle enumerating-cycle) function)
  (dolist (pair (enum-movements cycle))
    (funcall function (car pair) (cdr pair)))
  (values))

(defmethod map-cycle-deaths ((cycle enumerating-cycle) function)
  (dolist (pair (enum-deaths cycle))
    (funcall function (car pair) (cdr pair)))
  (values))

(defun %enumerating-cycle (world movements deaths)
  (let ((cycle (make-instance 'enumerating-cycle
                              :movements movements :deaths deaths)))
    (setf (clamsara::%cycle-configuration cycle) (world-configuration world))
    cycle))

(defun run-participant-dedup-across-fresh-references ()
  (let ((participant (make-source-directory-participant :capacity 8)))
    (with-quality-world (world :algorithm :marksweep :object-starts :packed
                               :movement-participants (list participant)
                               :configure-model #'non-interning-configure)
      (let* ((model (world-model world))
             (space (world-space world))
             (source (allocate-node world 1))
             (destination (allocate-node world 2))
             ;; Two DIFFERENT objects for the same canonical source, exactly as
             ;; a non-interning model would present a move and a death.
             (move-source (normalize-reference model source))
             (death-source (normalize-reference model source)))
        (check (not (eql move-source death-source))
               "Premise lost: move and death sources were interned")
        (let ((cycle (%enumerating-cycle world
                                         (list (cons move-source destination))
                                         (list (cons space death-source)))))
          (multiple-value-bind (status reason)
              (prepare-movement-participant participant cycle)
            (check (and (eq :ready status) (null reason))
                   "Participant did not become ready: ~S/~S" status reason))
          (check (= 1 (participant-directory-count participant))
                 "Movement+death for one source staged ~D rows, not one"
                 (participant-directory-count participant))
          (map-participant-directory
           participant
           (lambda (key value dead)
             (check (reference-equal model key source)
                    "Staged row key is not the canonical source")
             (check (eql 0 dead)
                    "A moved-then-dead source lost its move to a tombstone")
             (check (reference-equal model value destination)
                    "Staged destination is not the move's destination")))
          (cancel-movement-participant participant cycle))))))

(defun run-participant-repeated-movement-updates-in-place ()
  (let ((participant (make-source-directory-participant :capacity 8)))
    (with-quality-world (world :algorithm :marksweep :object-starts :packed
                               :movement-participants (list participant)
                               :configure-model #'non-interning-configure)
      (let* ((model (world-model world))
             (source (allocate-node world 1))
             (first-destination (allocate-node world 2))
             (second-destination (allocate-node world 3)))
        (let ((cycle
                (%enumerating-cycle
                 world
                 (list (cons (normalize-reference model source) first-destination)
                       (cons (normalize-reference model source) second-destination))
                 nil)))
          (multiple-value-bind (status reason)
              (prepare-movement-participant participant cycle)
            (check (and (eq :ready status) (null reason))
                   "Participant did not become ready: ~S/~S" status reason))
          (check (= 1 (participant-directory-count participant))
                 "Repeated movement staged ~D rows, not one"
                 (participant-directory-count participant))
          (map-participant-directory
           participant
           (lambda (key value dead)
             (declare (ignore key))
             (check (eql 0 dead) "A move row was marked dead")
             (check (reference-equal model value second-destination)
                    "Repeated movement did not update the row in place")))
          (cancel-movement-participant participant cycle))))))

;;; ------------------------------------------------------------------
;;; Address keying and collector-path allocation.

(defun run-participant-index-is-address-keyed ()
  ;; The staged row index is keyed by the canonical byte address, not by a
  ;; reference object, so it must be an EQL (integer) table.
  (let ((participant (make-source-directory-participant :capacity 8)))
    (with-quality-world (world :algorithm :marksweep
                               :movement-participants (list participant))
      (check (eq 'eql (hash-table-test (clamsara::%participant-index participant)))
             "Participant source index is not address (EQL) keyed"))))

(defun run-participant-staging-conses-nothing ()
  ;; Warm prepare/cancel of a real participant stages rows through the address
  ;; index without allocating.
  (let ((participant (make-source-directory-participant :capacity 8)))
    (with-quality-world (world :algorithm :marksweep :object-starts :packed
                               :movement-participants (list participant)
                               :configure-model #'non-interning-configure)
      (let* ((model (world-model world))
             (space (world-space world))
             (source (allocate-node world 1))
             (destination (allocate-node world 2))
             (cycle
               (%enumerating-cycle
                world
                (list (cons (normalize-reference model source) destination))
                (list (cons space (normalize-reference model source))))))
        (flet ((stage ()
                 (prepare-movement-participant participant cycle)
                 (cancel-movement-participant participant cycle)))
          ;; Warm the transient paths before measuring.  No explicit GC: a
          ;; full collection induces a one-time post-GC allocation in SBCL.
          (dotimes (index 16) (stage))
          (let ((before (sb-ext:get-bytes-consed)))
            (dotimes (index 64) (stage))
            (check (zerop (- (sb-ext:get-bytes-consed) before))
                   "Participant staging consed ~D bytes over 64 warm cycles"
                   (- (sb-ext:get-bytes-consed) before))))))))

(defun run-trace-staging-conses-nothing ()
  ;; Warm claim/commit through the address-keyed source plane, and warm
  ;; take-work/finish/replay through the address-keyed work plane, allocate
  ;; nothing.  Each round re-begins the context so a fresh claim is :FIRST.
  (with-quality-world (world :algorithm :semispace :object-starts :packed
                             :configure-model #'non-interning-configure)
    (let* ((object (allocate-node world 1))
           (cycle (clamsara::%plan-cycle (world-plan world))))
      (set-world-root world 0 object)
      (clamsara::%reset-cycle cycle (world-configuration world) :all
                              :explicit :semispace)
      (let ((context (clamsara::%cycle-trace cycle))
            (space (world-space world)))
        (flet ((stage-round ()
                 (begin-trace-context cycle :all 128)
                 (multiple-value-bind (status claim reservation)
                     (trace-claim-object context space object)
                   (check (eq :first status) "Claim was ~S" status)
                   (trace-commit-object context claim reservation
                                        space object))
                 (multiple-value-bind (work-space work-start status)
                     (trace-take-work context cycle)
                   (check (eq :work status) "Take-work returned ~S" status)
                   (map-trace-discoveries context
                                          (lambda (found-space found-start)
                                            (declare (ignore found-space
                                                             found-start))))
                   (trace-finish-work context cycle work-space work-start))))
          (dotimes (index 16) (stage-round))
          (let ((before (sb-ext:get-bytes-consed)))
            (dotimes (index 64) (stage-round))
            (check (zerop (- (sb-ext:get-bytes-consed) before))
                   "Trace staging consed ~D bytes over 64 warm rounds"
                   (- (sb-ext:get-bytes-consed) before))))))))

(defun run-reference-identity-tests ()
  (run-non-interning-premise)
  (run-trace-context-fresh-reference-dedup)
  (run-shared-source-cycle-completes)
  (run-participant-dedup-across-fresh-references)
  (run-participant-repeated-movement-updates-in-place)
  (run-participant-index-is-address-keyed)
  (run-participant-staging-conses-nothing)
  (run-trace-staging-conses-nothing)
  (format t "~&REFERENCE-IDENTITY-PASS~%")
  t)
