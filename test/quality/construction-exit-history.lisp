;;;; Independent postbinding unwind and exact cleanup-order histories.
;;;; See docs/geometry-unwind-review.md. No protocol implementation is replaced.
(defpackage #:clamsara.quality.construction-exit-history
  (:use #:cl #:clamsara #:clamsara.quality.support)
  (:export #:run-construction-exit-history-tests))
(in-package #:clamsara.quality.construction-exit-history)
(defvar *watch* nil)
(defvar *events* nil)
(defvar *kept* nil)
(define-condition deliberate-initialization-error (error) ())
(define-condition deliberate-cleanup-error (error) ())

;; Lifecycle event observers delegate all effects to the actual methods.
(defmethod deactivate-component :before ((component component) context)
  (when (and *watch* (eq context (observed-construction *construction-observation*)))
    (push (list :deactivate component) *events*)))
(defmethod release-construction-resource :before
    ((construction clamsara::%construction-context) identity handle)
  (declare (ignore handle))
  (when (and *watch* (eq construction (observed-construction *construction-observation*)))
    (push (list :resource identity) *events*)))
(defmethod release-managed-layout :before
    ((client clamsara::simulator-address-space) release)
  (declare (ignore client release))
  (when *watch* (push (list :layout :managed-layout) *events*)))

;; Ordinary extension components: no published-state writes or private model
;; modifications. The model-consumer marker schedules initialization after BIND.
(defclass late-component (component)
  ((phase :initarg :phase :reader exit-phase)
   (mode :initarg :mode :reader exit-mode)
   (tag :initarg :tag :reader exit-tag)
   (original-error :initarg :original-error :reader original-error)
   (cleanup-error :initarg :cleanup-error :reader cleanup-error)
   (initialized :initform 0 :accessor initialized)
   (activated :initform 0 :accessor activated)
   (deactivated :initform 0 :accessor deactivated)))
(defmethod clamsara::component-requires-bound-object-model-p ((probe late-component))
  (declare (ignore probe)) t)
(defmethod component-resources ((probe late-component))
  (list (make-resource-contribution probe :late-owned :runtime-object-vector
          :minimum-physical-bytes 32 :logical-entry-bound 2 :auxiliary-bytes 32
          :allocation-context :construction-only :exhaustion-action :reject-before-publication)))
(defun require-private-bound (context)
  (let ((configuration (clamsara::construction-configuration context)))
    (check (and (eq :private (clamsara::%configuration-state configuration))
                (clamsara::%configuration-object-model-bound-p configuration)
                (typep (configuration-object-model configuration) 'clamsara::host-bound-object-model))
           "Late callback did not receive private bound configuration")))
(defun run-exit (probe phase)
  (when (eq (exit-phase probe) phase)
    (ecase (exit-mode probe)
      (:none nil)
      (:throw (throw (exit-tag probe) (values :late-exit 73 probe)))
      (:error (error (original-error probe))))))
(defmethod initialize-component ((probe late-component) context)
  (require-private-bound context)
  (multiple-value-bind (handle present-p bytes entries auxiliary)
      (construction-resource context :late-owned)
    (declare (ignore auxiliary))
    (check (and handle present-p (>= bytes 32) (>= entries 2)) "Late resource not really acquired"))
  (incf (initialized probe))
  (run-exit probe :initialize)
  (values))
(defmethod activate-component ((probe late-component) context)
  (require-private-bound context)
  (incf (activated probe))
  (run-exit probe :activate)
  (values))
(defmethod deactivate-component ((probe late-component) context)
  (declare (ignore context))
  (incf (deactivated probe))
  (when (cleanup-error probe) (error (cleanup-error probe)))
  (values))
(defclass late-plan (clamsara::marksweep-plan)
  ((probe :initarg :probe :reader plan-probe)))
(defmethod component-dependencies ((plan late-plan))
  (append (call-next-method) (list (plan-probe plan))))

(defun make-late-configuration (probe)
  (let* ((roots (make-simulator-root-client :provider-capacity 8))
         (coordinator (make-simulator-coordinator roots :stop-capacity 16 :await-bound 16))
         (address-client (make-simulator-address-space :base 4096 :byte-extent 512
                           :alignment 16 :page-size 256 :coordinator coordinator))
         (model (make-host-object-model :capacity 64 :kind-capacity 4 :slot-capacity 4
                  :max-object-bytes 64 :variant-capacity 8 :location-capacity 4
                  :handle-capacity 4 :stage-capacity 1))
         (kind (make-object-kind-description model :node :size-rule 32 :alignment-rule 16))
         (diagnostics (make-simulator-diagnostics))
         (clients (make-simulator-clients :model model :roots roots :coordinator coordinator
                    :address-space address-client :diagnostics diagnostics :atomics (make-host-atomics)))
         (registry (make-sequential-finalizer-registry :capacity 4 :root-client roots))
         (domain (make-metadata-domain :base 4096 :limit 4608 :granularity 16))
         (space (make-marksweep-space :name :late-space
                  :object-start-map (make-object-start-marks :domain domain)
                  :marks (make-side-marks :domain domain) :extent 512
                  :packing-quantum 16 :descriptor-capacity 64))
         (plan (clamsara::%make-common-plan-instance 'late-plan
                 :probe probe :root-client roots :coordinator coordinator
                 :diagnostics diagnostics :registry registry :spaces (list space)
                 :trace-capacity 64 :conditional-capacity 16 :finalizer-capacity 4
                 :packing-quantum 16 :allocation-routes (list (list :default space :all))
                 :default-algorithm :marksweep :algorithms '(:marksweep))))
    (declare (ignore kind))
    (construct-plan plan clients)))

(defun assert-cleaned (expected-state)
  (check (and (observed-construction *construction-observation*) (observed-layout *construction-observation*)) "Missing real lifecycle observations")
  (let* ((construction (observed-construction *construction-observation*))
         (configuration (clamsara::construction-configuration construction))
         (resources (clamsara::%context-resources construction))
         (expected (append
                    (loop for component in (reverse (clamsara::%configuration-initialization-order configuration))
                          collect (list :deactivate component))
                    (loop for entry in (clamsara::%context-transaction-log construction)
                          collect (list (clamsara::%transaction-entry-kind entry)
                                        (clamsara::%transaction-entry-identity entry))))))
    (check (and (eq :released (clamsara::%context-state construction))
                (eq expected-state (clamsara::%configuration-state configuration)))
           "Wrong released configuration/context state")
    (check (equal expected (reverse *events*))
           "Cleanup missing, duplicated, or out of order: expected ~S actual ~S" expected (reverse *events*))
    (maphash (lambda (identity state)
               (declare (ignore identity))
               (check (and (clamsara::%resource-state-released-p state)
                           (clamsara::%simulator-resource-released-p
                            (clamsara::%resource-state-release-capability state)))
                      "Resource/capability was not released")) resources)
    (check (every #'clamsara::%transaction-entry-released-p
                  (clamsara::%context-transaction-log construction)) "Transaction entry not released")
    (check (and (not (clamsara::%simulator-layout-active-p (observed-layout *construction-observation*)))
                (null (clamsara::%simulator-active-layout
                       (clamsara::%simulator-layout-client (observed-layout *construction-observation*)))))
           "Layout still installed")
    (hash-table-count resources)))

(defun run-late-case (phase mode cleanup-fault-p)
  (let* ((*watch* t) (*construction-observation* (make-construction-observation)) (*events* nil)
         (tag (gensym "LATE-ESCAPE"))
         (original (make-condition 'deliberate-initialization-error))
         (cleanup-fault (and cleanup-fault-p (make-condition 'deliberate-cleanup-error)))
         (probe (make-instance 'late-component :phase phase :mode mode :tag tag
                  :original-error original :cleanup-error cleanup-fault))
         (caught nil) (observed nil) (outcome nil) (configuration nil))
    (handler-case
        (handler-bind
            ((error (lambda (condition)
                      ;; This does not unwind. It must see the completed real
                      ;; cleanup, and the same condition later reaches HANDLER-CASE.
                      (assert-cleaned :failed)
                      (setf observed condition))))
          (setf outcome
            (multiple-value-list
             (catch tag
               (setf configuration (make-late-configuration probe))
               :returned))))
      (error (condition) (setf caught condition)))
    (check (null configuration) "Failure published/returned a configuration")
    (check (= 1 (initialized probe)) "Initialization not reached exactly once")
    (check (= (if (eq phase :activate) 1 0) (activated probe)) "Wrong activation count")
    (check (= 1 (deactivated probe)) "Cleanup hook missing or repeated")
    (cond
      (cleanup-fault-p
       (check (and caught (eq observed caught)
                   (typep caught 'clamsara::construction-rejected)
                   (eq :cleanup-contract-fault (clamsara::construction-rejection-reason caught)))
              "Cleanup fault not reported after all cleanup")
       (let ((cause (clamsara::construction-rejection-cause caught)))
         (check (eq (getf cause :original) (if (eq mode :error) original :non-local-exit))
                "Cleanup fault lost original failure identity/category")
         (check-equal (list cleanup-fault) (getf cause :cleanup-faults) "cleanup fault identities")))
      ((eq mode :error)
       (check (and (eq original caught) (eq original observed)) "Original ERROR identity changed"))
      (t
       (check (and (null caught) (equal outcome (list :late-exit 73 probe)))
              "THROW values changed")))
    (let ((released (assert-cleaned :failed)))
      (format t "~&LATE-PASS ~S~%" (list :phase phase :mode mode :cleanup-fault cleanup-fault-p
                                       :released released :deactivated (deactivated probe)
                                       :observer-after-cleanup (and observed t)
                                       :exact-throw-values (and (eq mode :throw) (not cleanup-fault-p) t))))
    (push (list (observed-construction *construction-observation*) (observed-layout *construction-observation*)) *kept*)))

(defun success-guard-case ()
  (let* ((*watch* t) (*construction-observation* (make-construction-observation)) (*events* nil)
         (probe (make-instance 'late-component :phase :none :mode :none :tag nil
                  :original-error nil :cleanup-error nil))
         (configuration (make-late-configuration probe)))
    (check (and (eq :published (clamsara::%configuration-state configuration))
                (eq :published (clamsara::%context-state (observed-construction *construction-observation*)))
                (= 1 (initialized probe)) (= 1 (activated probe)) (= 0 (deactivated probe))
                (null *events*) (clamsara::%simulator-layout-active-p (observed-layout *construction-observation*)))
           "Success guard unwound successful construction")
    (maphash (lambda (identity state)
               (declare (ignore identity))
               (check (and (not (clamsara::%resource-state-released-p state))
                           (not (clamsara::%simulator-resource-released-p
                                 (clamsara::%resource-state-release-capability state))))
                      "Success prematurely released resource"))
             (clamsara::%context-resources (observed-construction *construction-observation*)))
    (multiple-value-bind (status reason) (shutdown-configuration configuration)
      (check (and (eq status :complete) (null reason)) "Ordinary success shutdown failed"))
    (check (= 1 (deactivated probe)) "Shutdown deactivated wrong count")
    (format t "~&SUCCESS-GUARD-PASS released=~D~%" (assert-cleaned :complete))))

(defun run-construction-exit-history-tests ()
  (let ((*kept* nil))
    (dolist (phase '(:initialize :activate))
      (dolist (mode '(:throw :error))
        (dolist (fault '(nil t)) (run-late-case phase mode fault))))
    (success-guard-case)
    (format t "~&LATE-UNWIND-FINISHED cases=9~%")
    t))
