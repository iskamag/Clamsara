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

(defun %barrier-any-event-p (barrier index events)
  (dolist (event events nil)
    (when (%barrier-event-p barrier index event)
      (return t))))

(defun %validate-barrier-entry (barrier context)
  (let ((configuration (%context-configuration context)))
    (unless (and (eq (%context-state context) :bound)
                 (typep configuration '%configuration)
                 (eq barrier (configuration-barrier configuration)))
      (%runtime-reject :foreign-context)))
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

(defun %cancel-barrier-reservations (barrier reservations reserved-p count)
  (loop for index downfrom (1- count) to 0
        when (aref reserved-p index)
          do (barrier-contribution-cancel
              (aref (%barrier-contributions barrier) index)
              (aref reservations index))
             (setf (aref reserved-p index) nil
                   (aref reservations index) nil))
  (values))

(defun %ensure-context-barrier-storage (context count)
  (unless (and (slot-boundp context 'barrier-reservations)
               (>= (length (%context-barrier-reservations context)) count))
    (%runtime-reject :barrier-capacity-exhausted))
  (fill (%context-barrier-reserved-p context) nil)
  (fill (%context-barrier-reservations context) nil)
  (values (%context-barrier-reservations context)
          (%context-barrier-reserved-p context)))

(defun %reserve-barrier-path (barrier context events location)
  (let ((count (length (%barrier-contributions barrier))))
    (multiple-value-bind (reservations reserved-p)
        (%ensure-context-barrier-storage context count)
      (dotimes (index count (values reservations reserved-p :ready))
        (when (%barrier-any-event-p barrier index events)
          (multiple-value-bind (reservation status)
              (barrier-contribution-reserve
               (aref (%barrier-contributions barrier) index)
               context (first events) location)
            (unless (eq status :ready)
              (%cancel-barrier-reservations barrier reservations reserved-p index)
              (return (values reservations reserved-p :retry)))
            (setf (aref reservations index) reservation
                  (aref reserved-p index) t)))))))

(defun %admit-barrier-path (barrier context events location reservations reserved-p)
  (dotimes (index (length (%barrier-contributions barrier)) :complete)
    (when (and (aref reserved-p index)
               (%barrier-any-event-p barrier index events))
      (unless (eq :complete
                  (barrier-contribution-admit
                   (aref (%barrier-contributions barrier) index)
                   (aref reservations index) context (first events) location))
        (return :retry)))))

(defun %transform-barrier-path (barrier context event location old candidate
                                reservations reserved-p)
  (dotimes (index (length (%barrier-contributions barrier))
                  (values candidate :complete))
    (when (and (aref reserved-p index)
               (%barrier-event-p barrier index event)
               (eq :transform
                   (getf (aref (%barrier-facts barrier) index)
                         :replacement-policy)))
      (multiple-value-bind (next status)
          (barrier-contribution-transform
           (aref (%barrier-contributions barrier) index)
           (aref reservations index) context event location old candidate)
        (unless (eq status :complete)
          (return (values nil :retry)))
        (setf candidate next)))))

(defun %barrier-exposure-callbacks (barrier context event location old final
                                    reservations reserved-p before-p)
  (dotimes (index (length (%barrier-contributions barrier)))
    (when (and (aref reserved-p index)
               (%barrier-event-p barrier index event))
      (if before-p
          (barrier-contribution-before-exposure
           (aref (%barrier-contributions barrier) index)
           (aref reservations index) context event location old final)
          (barrier-contribution-after-exposure
           (aref (%barrier-contributions barrier) index)
           (aref reservations index) context event location old final))))
  (values))

(defun %barrier-fatal (barrier context reason)
  (setf (%barrier-failed-p barrier) t)
  (let ((diagnostics (%plan-diagnostics (%context-plan context))))
    (fatal-diagnostic diagnostics reason))
  ;; FATAL-DIAGNOSTIC is required not to return on this path.
  (%runtime-reject reason))

(defun %barrier-store-operation (barrier context location new operation)
  (%validate-barrier-entry barrier context)
  (when (%barrier-failed-p barrier)
    (%runtime-reject :fatal-invariant))
  (multiple-value-bind (reservations reserved-p reserve-status)
      (%reserve-barrier-path barrier context (ecase operation
                                (:store '(:store))
                                (:root-store '(:root-store))) location)
    (unless (eq reserve-status :ready)
      (return-from %barrier-store-operation (values nil :retry)))
    (when (%barrier-busy-p barrier)
      (%cancel-barrier-reservations barrier reservations reserved-p
                                    (length (%barrier-contributions barrier)))
      (return-from %barrier-store-operation (values nil :retry)))
    (setf (%barrier-busy-p barrier) t)
    (unwind-protect
         (progn
           (unless (eq :complete
                       (%admit-barrier-path barrier context (ecase operation
                                (:store '(:store))
                                (:root-store '(:root-store)))
                                            location reservations reserved-p))
             (%cancel-barrier-reservations
              barrier reservations reserved-p
              (length (%barrier-contributions barrier)))
             (return-from %barrier-store-operation (values nil :retry)))
           (let ((old (%barrier-raw-load barrier location operation)))
             (multiple-value-bind (final transform-status)
                 (%transform-barrier-path barrier context operation location
                                          old new reservations reserved-p)
               (unless (eq transform-status :complete)
                 (%cancel-barrier-reservations
                  barrier reservations reserved-p
                  (length (%barrier-contributions barrier)))
                 (return-from %barrier-store-operation (values nil :retry)))
               (handler-case
                   (progn
                     (%barrier-exposure-callbacks
                      barrier context operation location old final
                      reservations reserved-p t)
                     (%barrier-raw-store barrier location final operation)
                     (%barrier-exposure-callbacks
                      barrier context operation location old final
                      reservations reserved-p nil))
                 (error () (%barrier-fatal barrier context
                                           :post-publication-failure)))
               ;; After callbacks consume reservations.  Clear local ownership
               ;; without calling CANCEL.
               (fill reserved-p nil)
               (fill reservations nil)
               (values final :stored))))
      (setf (%barrier-busy-p barrier) nil))))

(defmethod barrier-store ((barrier composed-barrier)
                          (context sequential-execution-context) location new)
  (%barrier-store-operation barrier context location new :store))

(defmethod barrier-read ((barrier composed-barrier)
                         (context sequential-execution-context) location)
  (%validate-barrier-entry barrier context)
  (when (%barrier-failed-p barrier) (%runtime-reject :fatal-invariant))
  (multiple-value-bind (reservations reserved-p reserve-status)
      (%reserve-barrier-path barrier context '(:read) location)
    (unless (eq reserve-status :ready)
      (return-from barrier-read (values nil :retry)))
    (when (%barrier-busy-p barrier)
      (%cancel-barrier-reservations barrier reservations reserved-p
                                    (length (%barrier-contributions barrier)))
      (return-from barrier-read (values nil :retry)))
    (setf (%barrier-busy-p barrier) t)
    (unwind-protect
         (progn
           (unless (eq :complete
                       (%admit-barrier-path barrier context '(:read) location
                                            reservations reserved-p))
             (%cancel-barrier-reservations
              barrier reservations reserved-p
              (length (%barrier-contributions barrier)))
             (return-from barrier-read (values nil :retry)))
           (let ((raw (%barrier-raw-load barrier location :read)))
             (multiple-value-bind (usable status)
                 (%transform-barrier-path barrier context :read location raw raw
                                          reservations reserved-p)
               (unless (eq status :complete)
                 (%cancel-barrier-reservations
                  barrier reservations reserved-p
                  (length (%barrier-contributions barrier)))
                 (return-from barrier-read (values nil :retry)))
               (handler-case
                   (progn
                     (%barrier-exposure-callbacks
                      barrier context :read location raw usable
                      reservations reserved-p t)
                     (%barrier-exposure-callbacks
                      barrier context :read location raw usable
                      reservations reserved-p nil))
                 (error () (%barrier-fatal barrier context
                                           :post-publication-failure)))
               (fill reserved-p nil)
               (fill reservations nil)
               (values usable :complete))))
      (setf (%barrier-busy-p barrier) nil))))

(defmethod barrier-compare-exchange
    ((barrier composed-barrier) (context sequential-execution-context)
     location expected new)
  (%validate-barrier-entry barrier context)
  (when (%barrier-failed-p barrier) (%runtime-reject :fatal-invariant))
  ;; CAS reserves the simultaneous union of its write and returned-read paths.
  (multiple-value-bind (reservations reserved-p reserve-status)
      (%reserve-barrier-path barrier context '(:cas :read) location)
    (unless (eq reserve-status :ready)
      (return-from barrier-compare-exchange (values nil nil :retry)))
    (when (%barrier-busy-p barrier)
      (%cancel-barrier-reservations barrier reservations reserved-p
                                    (length (%barrier-contributions barrier)))
      (return-from barrier-compare-exchange (values nil nil :retry)))
    (setf (%barrier-busy-p barrier) t)
    (unwind-protect
         (progn
           (unless (eq :complete
                       (%admit-barrier-path barrier context '(:cas :read)
                                            location reservations reserved-p))
             (%cancel-barrier-reservations
              barrier reservations reserved-p
              (length (%barrier-contributions barrier)))
             (return-from barrier-compare-exchange
               (values nil nil :retry)))
           (let ((raw (%barrier-raw-load barrier location :cas)))
             (multiple-value-bind (observed read-status)
                 (%transform-barrier-path barrier context :read location raw raw
                                          reservations reserved-p)
               (unless (eq read-status :complete)
                 (%cancel-barrier-reservations
                  barrier reservations reserved-p
                  (length (%barrier-contributions barrier)))
                 (return-from barrier-compare-exchange
                   (values nil nil :retry)))
               (if (not (reference-encoding-equal-p
                         (%barrier-model barrier) raw expected))
                   (progn
                     ;; Mismatch exposes only the read path.  Write-only
                     ;; reservations are cancelled exactly.
                     (dotimes (index (length (%barrier-contributions barrier)))
                       (when (and (aref reserved-p index)
                                  (not (%barrier-event-p barrier index :read)))
                         (barrier-contribution-cancel
                          (aref (%barrier-contributions barrier) index)
                          (aref reservations index))
                         (setf (aref reserved-p index) nil
                               (aref reservations index) nil)))
                     (%barrier-exposure-callbacks
                      barrier context :read location raw observed
                      reservations reserved-p t)
                     (%barrier-exposure-callbacks
                      barrier context :read location raw observed
                      reservations reserved-p nil)
                     (fill reserved-p nil)
                     (fill reservations nil)
                     (values observed nil :complete))
                   (multiple-value-bind (final write-status)
                       (%transform-barrier-path
                        barrier context :cas location raw new
                        reservations reserved-p)
                     (unless (eq write-status :complete)
                       (%cancel-barrier-reservations
                        barrier reservations reserved-p
                        (length (%barrier-contributions barrier)))
                       (return-from barrier-compare-exchange
                         (values nil nil :retry)))
                     (handler-case
                         (progn
                           (%barrier-exposure-callbacks
                            barrier context :read location raw observed
                            reservations reserved-p t)
                           (%barrier-exposure-callbacks
                            barrier context :cas location raw final
                            reservations reserved-p t)
                           ;; The sequential guard makes this sole release
                           ;; store equivalent to the raw CAS success.
                           (%barrier-raw-store barrier location final :cas)
                           (%barrier-exposure-callbacks
                            barrier context :read location raw observed
                            reservations reserved-p nil)
                           (%barrier-exposure-callbacks
                            barrier context :cas location raw final
                            reservations reserved-p nil))
                       (error () (%barrier-fatal
                                  barrier context :post-publication-failure)))
                     (fill reserved-p nil)
                     (fill reservations nil)
                     (values observed t :complete))))))
      (setf (%barrier-busy-p barrier) nil))))


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
