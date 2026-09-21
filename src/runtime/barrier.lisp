;;;; Immutable composed reference-store driver for the sequential profile.
(in-package #:clamsara)

(defclass composed-barrier ()
  ((model :initarg :model :reader %barrier-model)
   (contributions :initarg :contributions :reader %barrier-contributions)
   ;; Each facts element is a frozen plist whose :EVENTS value is a copied
   ;; proper list/vector, plus :NEEDS-OLD-P, :NEEDS-NEW-P and
   ;; :REPLACEMENT-POLICY.  Builder and runtime share no record class.
   (facts :initarg :facts :reader %barrier-facts)
   (busy-p :initform nil :accessor %barrier-busy-p)
   (failed-p :initform nil :accessor %barrier-failed-p)))

(defun make-composed-barrier (ordered-actuals ordered-facts model)
  (unless (and (vectorp ordered-actuals) (vectorp ordered-facts)
               (= (length ordered-actuals) (length ordered-facts)))
    (%runtime-reject :invalid-barrier-composition))
  (dotimes (index (length ordered-facts))
    (let* ((actual (aref ordered-actuals index))
           (facts (aref ordered-facts index))
           (events (getf facts :events))
           (policy (getf facts :replacement-policy)))
      (unless (and (listp facts)
                   (or (listp events) (vectorp events))
                   (member policy '(:observe :transform :observe-final)))
        (%runtime-reject :invalid-barrier-composition))
      ;; The paper does not settle shared-vs-separate reservation/callback
      ;; ownership for a dual READ+CAS contribution. Do not choose a contract
      ;; by allocating more scratch. Reject before publishing this composition.
      (when (and (find :read events) (find :cas events))
        (%runtime-reject :ambiguous-cas-reservation-contract))
      ;; Admit the actual authored CLOS methods.  Contribution methods must
      ;; dispatch on their opaque contribution and accept the protocol's
      ;; opaque reservation/context/location arguments; NIL probes no host
      ;; fallback and creates no registry.
      (dolist (event (coerce events 'list))
        (labels ((required (generic arguments)
                   (unless (compute-applicable-methods generic arguments)
                     (%runtime-reject :missing-barrier-execution-method))))
          (required #'barrier-contribution-reserve
                    (list actual nil event nil))
          (required #'barrier-contribution-admit
                    (list actual nil nil event nil))
          (required #'barrier-contribution-before-exposure
                    (list actual nil nil event nil nil nil))
          (required #'barrier-contribution-after-exposure
                    (list actual nil nil event nil nil nil))
          (required #'barrier-contribution-cancel (list actual nil))
          (when (eq policy :transform)
            (required #'barrier-contribution-transform
                      (list actual nil nil event nil nil nil)))))))
  (make-instance 'composed-barrier :model model
                 :contributions ordered-actuals
                 :facts ordered-facts))

(defun %barrier-event-p (barrier index event)
  (find event (getf (aref (%barrier-facts barrier) index) :events)
        :test #'eq))

(defun %validate-barrier-entry (barrier context)
  (let ((configuration (%context-configuration context)))
    (unless (and (eq (%context-state context) :bound)
                 (typep configuration '%configuration)
                 (eq barrier (configuration-barrier configuration)))
      (%runtime-reject :foreign-context)))
  (when (or (%barrier-failed-p barrier)
            (eq (%plan-state (%context-plan context)) :fatal))
    (%runtime-reject :fatal-invariant))
  (unless (eq (%plan-state (%context-plan context)) :open)
    (%runtime-reject :collection-busy))
  (values))

(defun %barrier-raw-load (barrier location operation)
  (if (member operation '(:root-read :root-store))
      (host-root-value location)
      (load-reference (%barrier-model barrier) location :acquire)))

(defun %barrier-raw-store (barrier location value operation)
  (if (member operation '(:root-read :root-store))
      (setf (host-root-value location) value)
      (store-reference-raw (%barrier-model barrier) location value :release)))

(defun %barrier-fatal (barrier context reason)
  ;; Close before invoking a hosted diagnostic: ERROR or THROW may be caught
  ;; outside this entry. Preserve unresolved scratch and its configuration pin.
  (setf (%barrier-failed-p barrier) t
        (%context-barrier-state context) :failed
        (%plan-state (%context-plan context)) :fatal)
  (fatal-diagnostic (%plan-diagnostics (%context-plan context)) reason)
  (%runtime-reject reason))

(defun %check-barrier-still-open (barrier context)
  ;; A callback can catch a diagnostic from another nested context. That must
  ;; not turn its enclosing operation into a successful or retrying heap entry.
  (unless (and (not (%barrier-failed-p barrier))
               (eq (%plan-state (%context-plan context)) :open))
    (%barrier-fatal barrier context :fatal-invariant))
  (values))

(defun %barrier-operation-event (barrier index operation)
  ;; Dual READ+CAS is rejected at construction. A disjoint rule has exactly one
  ;; applicable path. Keep reserve/admit consistent with admitted event methods
  ;; and the existing transform/exposure convention (see contract addendum).
  (if (eq operation :cas)
      (cond ((%barrier-event-p barrier index :read) :read)
            ((%barrier-event-p barrier index :cas) :cas))
      (when (%barrier-event-p barrier index operation) operation)))

(defun %check-context-barrier-storage (context count)
  (unless (and (slot-boundp context 'barrier-reservations)
               (slot-boundp context 'barrier-reserved-p)
               (= (length (%context-barrier-reservations context)) count)
               (= (length (%context-barrier-reserved-p context)) count))
    (%runtime-reject :barrier-capacity-exhausted))
  (values))

(defun %cancel-barrier-reservations (barrier context &optional write-only-p)
  (let ((reservations (%context-barrier-reservations context))
        (owned (%context-barrier-reserved-p context)))
    (loop for index downfrom (1- (length owned)) to 0
          when (and (aref owned index)
                    (or (not write-only-p)
                        (not (%barrier-event-p barrier index :read))))
            do (barrier-contribution-cancel
                (aref (%barrier-contributions barrier) index)
                (aref reservations index))
               ;; A nested fatal escape could have been caught inside CANCEL.
               ;; In that case retain the token as unresolved, never cancel it
               ;; again. Otherwise its normal terminal return settles ownership.
               (%check-barrier-still-open barrier context)
               (setf (aref owned index) nil (aref reservations index) nil)))
  (values))

(defun %reserve-barrier-path (barrier context operation location)
  (let ((reservations (%context-barrier-reservations context))
        (owned (%context-barrier-reserved-p context)))
    (dotimes (index (length owned) :ready)
      (let ((event (%barrier-operation-event barrier index operation)))
        (when event
          (multiple-value-bind (reservation status)
              (barrier-contribution-reserve
               (aref (%barrier-contributions barrier) index)
               context event location)
            (case status
              (:ready
               ;; NIL can be an opaque successful token. Ownership is separate.
               (setf (aref reservations index) reservation
                     (aref owned index) t))
              (:retry)
              (otherwise (%runtime-reject :invalid-barrier-reserve-result)))
            (%check-barrier-still-open barrier context)
            (when (eq status :retry) (return :retry))))))))

(defun %admit-barrier-path (barrier context operation location)
  (let ((reservations (%context-barrier-reservations context))
        (owned (%context-barrier-reserved-p context)))
    (dotimes (index (length owned) :complete)
      (when (aref owned index)
        (let ((status
                (barrier-contribution-admit
                 (aref (%barrier-contributions barrier) index)
                 (aref reservations index) context
                 (%barrier-operation-event barrier index operation) location)))
          (%check-barrier-still-open barrier context)
          (case status
            (:complete)
            (:retry (return :retry))
            (otherwise (%runtime-reject :invalid-barrier-admit-result))))))))

(defun %transform-barrier-path (barrier context event location old candidate)
  (let ((reservations (%context-barrier-reservations context))
        (owned (%context-barrier-reserved-p context)))
    (dotimes (index (length owned) (values candidate :complete))
      (when (and (aref owned index)
                 (%barrier-event-p barrier index event)
                 (eq :transform
                     (getf (aref (%barrier-facts barrier) index)
                           :replacement-policy)))
        (multiple-value-bind (next status)
            (barrier-contribution-transform
             (aref (%barrier-contributions barrier) index)
             (aref reservations index) context event location old candidate)
          (%check-barrier-still-open barrier context)
          (case status
            (:complete (setf candidate next))
            (:retry (return (values nil :retry)))
            (otherwise (%runtime-reject :invalid-barrier-transform-result))))))))

(defun %barrier-exposure-callbacks (barrier context operation location old
                                    observed final before-p)
  (let ((reservations (%context-barrier-reservations context))
        (owned (%context-barrier-reserved-p context)))
    ;; One contribution-first pass. All fallible transforms have finished.
    ;; Mismatch has already canceled write-only tokens, leaving only READ.
    (dotimes (index (length owned))
      (when (aref owned index)
        (let* ((event (%barrier-operation-event barrier index operation))
               (value (if (eq event :read) observed final))
               (actual (aref (%barrier-contributions barrier) index))
               (reservation (aref reservations index)))
          (if before-p
              (barrier-contribution-before-exposure
               actual reservation context event location old value)
              (progn
                (barrier-contribution-after-exposure
                 actual reservation context event location old value)
                (%check-barrier-still-open barrier context)
                (setf (aref owned index) nil
                      (aref reservations index) nil)))
          (%check-barrier-still-open barrier context)))))
  (values))

(defun %finish-barrier-invocation (barrier context outcome guard-owned-p)
  ;; This runs on *every* exit after scratch acquisition, including a reserve
  ;; which signals/throws before returning a token. Such an unknown violation
  ;; cannot be relabeled :RETRY or assumed failure-atomic.
  (unless (eq (%context-barrier-state context) :failed)
    (%check-barrier-still-open barrier context)
    (unless outcome
      (%barrier-fatal barrier context
                      (if (eq (%context-barrier-state context) :exposing)
                          :post-publication-failure
                          :fatal-invariant)))
    (let ((settled-p nil))
      (unwind-protect
           (progn
             (when (eq outcome :retry)
               (%cancel-barrier-reservations barrier context))
             (when (find t (%context-barrier-reserved-p context))
               (%barrier-fatal barrier context :fatal-invariant))
             (setf settled-p t))
        ;; CANCEL is required not to fail, but an ERROR or non-error exit must
        ;; still leave the runtime closed rather than drop remaining tokens.
        (unless (or settled-p (eq (%context-barrier-state context) :failed))
          (%barrier-fatal barrier context :fatal-invariant))))
    (when guard-owned-p (setf (%barrier-busy-p barrier) nil))
    (setf (%context-barrier-state context) :idle)
    (decf (%plan-barrier-pin-count (%context-plan context))))
  (values))

(defun %execute-barrier-operation (barrier context location operation expected new)
  (%validate-barrier-entry barrier context)
  ;; Acquire the invocation *before* any scratch clear or authored callback.
  ;; This is not the core location guard: reserve still precedes that guard.
  (unless (eq (%context-barrier-state context) :idle)
    (return-from %execute-barrier-operation (values nil nil :retry)))
  (%check-context-barrier-storage context (length (%barrier-contributions barrier)))
  (let ((outcome nil) (guard-owned-p nil))
    (setf (%context-barrier-state context) :pre-effect)
    ;; Each admitted bound context owns at most one pin. Context generations
    ;; bound the total by MOST-POSITIVE-FIXNUM; no per-call history is consumed.
    (incf (%plan-barrier-pin-count (%context-plan context)))
    (unwind-protect
         (macrolet ((retry ()
                      '(progn (setf outcome :retry)
                              (return-from %execute-barrier-operation
                                (values nil nil :retry)))))
           (fill (%context-barrier-reservations context) nil)
           (fill (%context-barrier-reserved-p context) nil)
           (when (eq (%reserve-barrier-path barrier context operation location) :retry)
             (retry))
           (when (%barrier-busy-p barrier) (retry))
           (setf (%barrier-busy-p barrier) t guard-owned-p t)
           (when (eq (%admit-barrier-path barrier context operation location) :retry)
             (retry))
           (let* ((raw (%barrier-raw-load barrier location operation))
                  (matched-p nil)
                  (write-p nil)
                  (observed raw)
                  (final new))
             (%check-barrier-still-open barrier context)
             (when (eq operation :cas)
               (setf matched-p (reference-encoding-equal-p
                                (%barrier-model barrier) raw expected))
               (%check-barrier-still-open barrier context))
             (setf write-p (or matched-p (member operation '(:store :root-store))))
             (when (member operation '(:read :cas))
               (multiple-value-bind (value status)
                   (%transform-barrier-path barrier context :read location raw raw)
                 (when (eq status :retry) (retry))
                 (setf observed value)))
             (when write-p
               (multiple-value-bind (value status)
                   (%transform-barrier-path barrier context operation location raw new)
                 (when (eq status :retry) (retry))
                 (setf final value)))
             (when (and (eq operation :cas) (not matched-p))
               (%cancel-barrier-reservations barrier context t))
             ;; Enter the non-failing phase before the first BEFORE invocation,
             ;; not after it or after the raw store. No later cancel is an undo.
             (setf (%context-barrier-state context) :exposing)
             (%barrier-exposure-callbacks
              barrier context operation location raw observed final t)
             (when write-p (%barrier-raw-store barrier location final operation))
             (%check-barrier-still-open barrier context)
             (%barrier-exposure-callbacks
              barrier context operation location raw observed final nil)
             (setf outcome :complete)
             (values (if (member operation '(:read :cas)) observed final)
                     matched-p :complete)))
      (%finish-barrier-invocation barrier context outcome guard-owned-p))))

(defun %barrier-store-operation (barrier context location new operation)
  (multiple-value-bind (value matched-p status)
      (%execute-barrier-operation barrier context location operation nil new)
    (declare (ignore matched-p))
    (values value (if (eq status :complete) :stored status))))

(defmethod barrier-store ((barrier composed-barrier)
                          (context sequential-execution-context) location new)
  (%barrier-store-operation barrier context location new :store))

(defmethod barrier-read ((barrier composed-barrier)
                         (context sequential-execution-context) location)
  (multiple-value-bind (value matched-p status)
      (%execute-barrier-operation barrier context location :read nil nil)
    (declare (ignore matched-p))
    (values value status)))

(defmethod barrier-compare-exchange
    ((barrier composed-barrier) (context sequential-execution-context)
     location expected new)
  (%execute-barrier-operation barrier context location :cas expected new))

(defmethod barrier-store ((barrier composed-barrier) context location new)
  (declare (ignore barrier context location new))
  (%runtime-reject :foreign-context))

(defmethod barrier-read ((barrier composed-barrier) context location)
  (declare (ignore barrier context location))
  (%runtime-reject :foreign-context))

(defmethod barrier-compare-exchange
    ((barrier composed-barrier) context location expected new)
  (declare (ignore barrier context location expected new))
  (%runtime-reject :foreign-context))

(defmethod configuration-barrier ((configuration %configuration))
  (unless (%configuration-barrier-bound-p configuration)
    (%runtime-reject :unbound-configuration-barrier))
  (%configuration-barrier configuration))
