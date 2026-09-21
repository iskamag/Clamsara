;;;; Additional bounded draft-only admission edges. Not yet executed.
;;;; Load CLAMSARA/QUALITY/SUPPORT and the unchanged acceptance-source-02.lisp
;;;; from the preceding independent review first. No production GF is redefined.
(defpackage #:clamsara.independent.opaque-edges
  (:use #:cl #:clamsara #:clamsara.quality.support)
  (:import-from #:clamsara.independent.opaque-admission
   #:rule #:private-token #:proof-plan #:typed-all-rule
   #:rule-token #:rule-calls #:rule-auxiliary-calls #:rule-mode
   #:reserve-token #:perform-phase #:assert-never-executed #:invoke-and-check
   #:*rule* #:*last-plan* #:*cases* #:*failures* #:*failed-worlds* #:*rejected-builds*)
  (:export #:run-opaque-admission-edge-tests))
(in-package #:clamsara.independent.opaque-edges)

;; The actual contributor inherits its primary methods; exact CLASS-OF equality
;; would wrongly reject it. The existing real-fixture runner exercises its body.
(defclass inherited-contribution (typed-all-rule) ())

;; A genuine non-STANDARD-OBJECT contribution: a fresh one-element vector holding
;; its author's private state. No registry/property table or mutable global
;; author state is needed. Each EQL specialization names only its fresh value.
(defvar *defining-actual* nil)
(defvar *actual* nil)
(defclass vector-plan (proof-plan)
  ((actual :initarg :actual :reader plan-actual)))
(defmethod component-barrier-contributions ((p vector-plan))
  (list (plan-actual p)))
(defmethod clamsara::map-construction-auxiliary-storage ((p vector-plan) f)
  (call-next-method) ; inherited RULE/TOKEN/counter auxiliary ownership
  (funcall f (plan-actual p)) ; the actual extra vector itself, once
  (values))
(defun configure-vector-plan (plan)
  (check (typep plan 'clamsara::semispace-plan) "Expected real SemiSpace plan")
  (change-class plan 'vector-plan :rules (list *rule*) :actual *actual*)
  (setf *last-plan* plan))
(defun install-vector-methods (actual)
  ;; Ordinary test-author definition work before construction. Add distinct
  ;; author methods, not a new DEFGENERIC or changed method combination.
  ;; Existing failed worlds' EQL methods and state are never replaced/removed.
  (let ((*defining-actual* actual))
    (eval
     '(progn
        (defmethod describe-barrier-contribution ((actual (eql *defining-actual*)))
          (values :own-vector-contribution (list :read) nil
                  t nil nil nil :transform :retry-before-exposure/fatal-after))
        (defmethod barrier-contribution-reserve
            ((actual (eql *defining-actual*)) context (operation (eql :read)) location)
          (declare (ignore context operation location))
          (reserve-token (svref actual 0)))
        (defmethod barrier-contribution-admit
            ((actual (eql *defining-actual*)) (token private-token)
             context (operation (eql :read)) location)
          (declare (ignore context operation location))
          (perform-phase (svref actual 0) token 1))
        (defmethod barrier-contribution-transform
            ((actual (eql *defining-actual*)) (token private-token)
             context (operation (eql :read)) location old candidate)
          (declare (ignore context operation location old))
          (perform-phase (svref actual 0) token 2 candidate))
        (defmethod barrier-contribution-before-exposure
            ((actual (eql *defining-actual*)) (token private-token)
             context (operation (eql :read)) location old final)
          (declare (ignore context operation location old final))
          (perform-phase (svref actual 0) token 3))
        (defmethod barrier-contribution-after-exposure
            ((actual (eql *defining-actual*)) (token private-token)
             context (operation (eql :read)) location old final)
          (declare (ignore context operation location old final))
          (perform-phase (svref actual 0) token 4))
        (defmethod barrier-contribution-cancel
            ((actual (eql *defining-actual*)) (token private-token))
          (perform-phase (svref actual 0) token 5)))))
  actual)

(defun vector-one (mode)
  (incf *cases*)
  (let* ((*rule* (make-instance 'rule)) (*actual* (vector *rule*))
         (*last-plan* nil) (world nil)
         (*construction-observation* (make-construction-observation))
         (label (list :eql-vector-actual mode)))
    (handler-case
        (progn
          (check (not (typep *actual* 'standard-object)) "Contribution is not a nonstandard object")
          (install-vector-methods *actual*)
          (setf world (make-quality-world :configure-plan #'configure-vector-plan))
          (assert-never-executed *rule*)
          (let* ((configuration (world-configuration world))
                 (construction (clamsara::configuration-construction-context configuration))
                 (barrier (configuration-barrier configuration))
                 (context (world-context world))
                 (reservations (clamsara::%context-barrier-reservations context))
                 (owned (clamsara::%context-barrier-reserved-p context)))
            (check (and (eq (clamsara::%configuration-state configuration) :published)
                        (eq (clamsara::%context-state construction) :published))
                   "Normal construction/publication did not complete")
            (check (eq (aref (clamsara::%barrier-contributions barrier) 0) *actual*)
                   "Composition replaced the author's actual opaque value")
            (check (and (= (length reservations) 1) (= (length owned) 1))
                   "Admission altered per-contribution workspace cardinality")
            (let ((source (allocate-node world 811)) (old (allocate-node world 812)))
              (set-world-root world 0 source) (set-world-root world 1 old)
              (set-node-slot world source 1 old)
              (setf (rule-mode *rule*) mode)
              (let ((outcome
                      (catch 'clamsara::simulator-fatal
                        (invoke-and-check world source old (eq mode :retry-transform) nil)
                        (when (eq mode :retry-transform)
                          (fill (rule-calls *rule*) 0) (fill (rule-auxiliary-calls *rule*) 0)
                          (setf (rule-mode *rule*) nil)
                          (invoke-and-check world source old nil nil))
                        :complete)))
                (check (eq outcome :complete) "Unexpected fatal diagnostic: ~S" outcome)))
            (check (and (eq reservations (clamsara::%context-barrier-reservations context))
                        (eq owned (clamsara::%context-barrier-reserved-p context)))
                   "Invocation replaced fixed context workspace"))
          (setf (rule-mode *rule*) nil)
          (check (eq (cycle-result-status (collect-world world)) :complete) "Real vector-actual GC did not complete")
          (check (equal (second (snapshot-world-graph world)) '((811 812 nil) (812 nil nil)))
                 "Rooted vector-contribution graph changed")
          (close-quality-world world)
          (format t "~&OPAQUE-EDGE-PASS ~S~%" label))
      (error (condition)
        (incf *failures*)
        (push (list label world *last-plan* *rule* *construction-observation* condition)
              *failed-worlds*)
        (format t "~&OPAQUE-EDGE-FAIL ~S [~S] ~A~%" label (type-of condition) condition)))))

;; Private metadata probes. These are deliberately NOT public barrier GFs.
;; Their unknown-position restrictions show a necessary signature filter only;
;; no actual execution or satisfiable cross-phase domain is inferred from them.
(defclass probe-actual () ())
(defclass probe-child (probe-actual) ())
(defclass unrelated-actual () ())
(defclass probe-token () ())
(defclass probe-context () ())
(defclass probe-location () ())
(defclass probe-value () ())
(defvar *probe-bodies* 0)
(defgeneric known-probe (actual token context operation location old value))
(defmethod known-probe
    ((actual probe-actual) (token probe-token) (context probe-context)
     (operation (eql :read)) (location probe-location) (old probe-value) (value probe-value))
  (declare (ignore actual token context operation location old value))
  (incf *probe-bodies*))
(defmethod known-probe
    ((actual (eql :owned-contribution)) (token probe-token) (context probe-context)
     (operation (eql :read)) (location probe-location) (old probe-value) (value probe-value))
  (declare (ignore actual token context operation location old value))
  (incf *probe-bodies*))
(defgeneric reserve-probe (actual context operation location))
(defmethod reserve-probe
    ((actual probe-actual) (context probe-context) (operation (eql :read)) (location probe-location))
  (declare (ignore actual context operation location))
  (incf *probe-bodies*))
(defgeneric cancel-probe (actual token))
(defmethod cancel-probe ((actual probe-actual) (token (eql :private-token-value)))
  (declare (ignore actual token))
  (incf *probe-bodies*))
(defgeneric event-class-probe (actual token context operation location old value))
(defmethod event-class-probe
    ((actual probe-actual) (token probe-token) (context probe-context)
     (operation symbol) (location probe-location) (old probe-value) (value probe-value))
  (declare (ignore actual token context operation location old value))
  (incf *probe-bodies*))
(defgeneric auxiliary-probe (actual token))
(defmethod auxiliary-probe :before ((actual probe-actual) (token probe-token))
  (declare (ignore actual token))
  (incf *probe-bodies*))
(defgeneric empty-probe (actual token))
(defgeneric sum-probe (actual token) (:method-combination +))
(defmethod sum-probe + ((actual probe-actual) (token probe-token))
  (declare (ignore actual token))
  (incf *probe-bodies*))

(defun production-combinations ()
  (mapcar (lambda (generic) (cons generic (sb-mop:generic-function-method-combination generic)))
          (list #'barrier-contribution-reserve #'barrier-contribution-admit
                #'barrier-contribution-transform #'barrier-contribution-before-exposure
                #'barrier-contribution-after-exposure #'barrier-contribution-cancel)))
(defun candidate-p (generic actual position event)
  (clamsara::%barrier-primary-candidate-p generic actual position event))
(defun meta-one (label thunk)
  (incf *cases*)
  (handler-case
      (progn
        (funcall thunk)
        (check (zerop *probe-bodies*) "Admission executed a private author method body")
        (format t "~&OPAQUE-EDGE-PASS ~S~%" label))
    (error (condition)
      (incf *failures*)
      ;; Metadata-only failures have no constructed world. Do not invent one.
      (push (list label nil nil nil (make-construction-observation) condition) *failed-worlds*)
      (format t "~&OPAQUE-EDGE-FAIL ~S [~S] ~A~%" label (type-of condition) condition))))

(defun run-opaque-admission-edge-tests ()
  (let ((*cases* 0) (*failures* 0) (*probe-bodies* 0)
        (previous-failed (length *failed-worlds*))
        (previous-rejected (length *rejected-builds*))
        (combinations (production-combinations))
        (actual (make-instance 'probe-actual)))
    (dolist (mode '(nil :retry-transform))
      (clamsara.independent.opaque-admission::one 'inherited-contribution mode))
    (dolist (mode '(nil :retry-transform)) (vector-one mode))
    (meta-one :unknown-tail-is-not-nil
      (lambda ()
        (check (null (compute-applicable-methods #'known-probe (list actual nil nil :read nil nil nil)))
               "Control does not exclude the NIL prototype")
        (check (candidate-p #'known-probe actual 3 :read) "Unknown positions were falsely instantiated")))
    (meta-one :known-contribution-subclass
      (lambda () (check (candidate-p #'known-probe (make-instance 'probe-child) 3 :read)
                         "Inherited known contribution specializer ignored")))
    (meta-one :known-contribution-class-mismatch
      (lambda () (check (not (candidate-p #'known-probe (make-instance 'unrelated-actual) 3 :read))
                         "Incompatible known contribution accepted")))
    (meta-one :known-contribution-eql-symbol
      (lambda () (check (candidate-p #'known-probe :owned-contribution 3 :read)
                         "Opaque symbol EQL contribution rejected")))
    (meta-one :known-contribution-eql-mismatch
      (lambda () (check (not (candidate-p #'known-probe :different-contribution 3 :read))
                         "Wrong opaque EQL contribution accepted")))
    (meta-one :known-event-eql-mismatch
      (lambda () (check (not (candidate-p #'known-probe actual 3 :cas)) "Wrong EQL event accepted")))
    (meta-one :reserve-event-position-two
      (lambda () (check (candidate-p #'reserve-probe actual 2 :read) "Reserve event index wrong")))
    (meta-one :reserve-event-mismatch
      (lambda () (check (not (candidate-p #'reserve-probe actual 2 :store)) "Reserve event mismatch accepted")))
    (meta-one :cancel-no-event-position
      (lambda () (check (candidate-p #'cancel-probe actual nil :ignored) "Cancel inspected an unknown token/event")))
    (meta-one :known-event-class
      (lambda () (check (candidate-p #'event-class-probe actual 3 :read) "Known event class not matched")))
    (meta-one :known-event-class-mismatch
      (lambda () (check (not (candidate-p #'event-class-probe actual 3 42)) "Wrong event class accepted")))
    (meta-one :standard-auxiliary-not-primary
      (lambda () (check (not (candidate-p #'auxiliary-probe actual nil nil)) "Auxiliary counted as primary")))
    (meta-one :empty-standard-generic
      (lambda () (check (not (candidate-p #'empty-probe actual nil nil)) "Absent method treated as candidate")))
    (meta-one :private-nonstandard-combination-is-capability-rejection
      (lambda ()
        (signals-runtime-reason (lambda () (candidate-p #'sum-probe actual nil nil))
                                :unsupported-barrier-method-combination)))
    (meta-one :production-method-combinations-unchanged
      (lambda ()
        (dolist (pair combinations)
          (check (eq (cdr pair) (sb-mop:generic-function-method-combination (car pair)))
                 "Edge fixture changed a production method combination")
          (check (eq (cdr pair) (sb-mop:find-method-combination (car pair) 'standard nil))
                 "Production GF was not STANDARD"))))
    (format t "~&OPAQUE-EDGE-SUMMARY cases=~D failures=~D new-failed=~D retained-failed=~D rejected-delta=~D probe-bodies=~D~%"
            *cases* *failures* (- (length *failed-worlds*) previous-failed)
            (length *failed-worlds*) (- (length *rejected-builds*) previous-rejected) *probe-bodies*)
    (check (= *cases* 19) "Opaque edge matrix changed: ~D" *cases*)
    (check (zerop *failures*) "Opaque admission edge failures: ~D" *failures*)))
