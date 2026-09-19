;;;; Clamsara v11 component kernel -- standalone contract test.
;;;;
;;;; Run:  sbcl --script test/v11-component-contract.lisp
;;;;
;;;; Covers: diamond discovery order/dedup, resource merge with provenance,
;;;; resource conflict, missing resource with dependency path, ordinary
;;;; cycle rejection, declared cohort acceptance, exact seven-phase order,
;;;; no publication on failure, immutable activation with mutable runtime
;;;; slots, and reverse-order deactivation.

(cl:load (merge-pathnames "../src/core/component.lisp"
                          (make-pathname :defaults *load-truename*)))

(defpackage :v11-component-contract-test
  (:use :cl :clamsara-core))

(in-package :v11-component-contract-test)

;;; --- harness ---------------------------------------------------------

(defparameter *checks* 0)
(defparameter *failures* ())

(defmacro check (label form)
  (let ((value (gensym "VALUE")))
    `(let ((,value ,form))
       (incf *checks*)
       (unless ,value (push ,(string label) *failures*))
       ,value)))

(defun try-construction-error (thunk)
  (handler-case (progn (funcall thunk) nil)
    (construction-error (condition) condition)
    (error (condition) (list :other condition))))

(defun rejected-as-sealed-p (thunk)
  (handler-case (progn (funcall thunk) nil)
    (configuration-sealed () t)
    (error () :wrong-error)))

;;; --- test components -------------------------------------------------

(defparameter *init-order* ())
(defparameter *deact-order* ())

(defclass test-component (component)
  ((name :initarg :name :reader test-name)
   (deps :initarg :deps :initform ())
   (resources :initarg :resources :initform ())
   (constraints :initarg :constraints :initform ())
   (cohort :initarg :cohort :initform nil)
   (validate-ok :initarg :validate-ok :initform t)
   (activate-ok :initarg :activate-ok :initform t)
   (activations :initform 0 :accessor test-activations)))

(defmethod component-dependencies ((c test-component)) (slot-value c 'deps))
(defmethod component-resources ((c test-component)) (slot-value c 'resources))
(defmethod component-constraints ((c test-component)) (slot-value c 'constraints))
(defmethod component-cohort ((c test-component)) (slot-value c 'cohort))
(defmethod validate-component ((c test-component) configuration)
  (declare (ignore configuration))
  (slot-value c 'validate-ok))
(defmethod initialize-component :after ((c test-component) context)
  (declare (ignore context))
  (push (test-name c) *init-order*))
(defmethod activate-component ((c test-component) context)
  (declare (ignore context))
  (unless (slot-value c 'activate-ok)
    (error "activation rejected for ~s" (test-name c)))
  (incf (test-activations c)))
(defmethod deactivate-component :after ((c test-component) context)
  (declare (ignore context))
  (push (test-name c) *deact-order*))

(defun mk (name &key deps resources constraints cohort
                         (validate-ok :unset) (activate-ok :unset))
  (apply #'make-instance 'test-component
         :name name :deps deps :resources resources
         :constraints constraints :cohort cohort
         (append (if (eq validate-ok :unset) ()
                     (list :validate-ok validate-ok))
                 (if (eq activate-ok :unset) ()
                     (list :activate-ok activate-ok)))))

;;; --- 1. diamond: order, dedup, merge provenance ----------------------

(defparameter *cfg*
  (let* ((shared (mk :shared
                     :resources (list (make-resource :name :arena :role :provide
                                                     :size 64 :granularity 16
                                                     :ownership :shared :lifetime :plan))))
         (a (mk :a :deps (list shared)
                :resources (list (make-resource :name :arena))))
         (b (mk :b :deps (list shared)
                :resources (list (make-resource :name :arena))))
         (root (mk :root :deps (list a b)
                   :constraints (list '(:requires-atomic-bit-set)))))
    (build-configuration (list root)
                         :layout (lambda (configuration)
                                   (let ((arena (find-resource configuration :arena)))
                                     (setf (resource-start arena) #x1000)
                                     (setf (resource-extent arena) 64))))))

(check diamond-dedup
       (= 4 (length (configuration-topological-order *cfg*))))
(check diamond-initialize-order
       (equal (reverse *init-order*) '(:shared :a :b :root)))
(check diamond-activate-once
       (every (lambda (c) (= 1 (test-activations c)))
              (configuration-topological-order *cfg*)))
(check diamond-merged-one-resource
       (= 1 (length (configuration-resources *cfg*))))
(check provenance-provider
       (equal (mapcar #'test-name
                      (resource-providers (find-resource *cfg* :arena)))
              '(:shared)))
(check provenance-consumers
       (equal (mapcar #'test-name
                      (resource-consumers (find-resource *cfg* :arena)))
              '(:a :b)))
(check constraints-collected
       (equal (configuration-constraints *cfg*) '((:requires-atomic-bit-set))))
(check bind-resolved-handles
       (eq :arena (resource-name
                   (first (component-bindings
                           *cfg* (second (configuration-topological-order *cfg*)))))))

;;; --- 2. exact seven phases, published once ---------------------------

(check phase-order
       (equal (configuration-phases *cfg*)
              '(:construct-discover :merge :layout-callback :bind
                :initialize :validate :activate)))
(check state-active (eq (configuration-state *cfg*) :active))
(check published-in-ledger (member *cfg* *published-configurations* :test #'eq))
(check geometry-published (= #x1000 (resource-start (find-resource *cfg* :arena))))
(check extent-published (= 64 (resource-extent (find-resource *cfg* :arena))))
(check layout-product-recorded (= 64 (configuration-layout *cfg*)))

;;; --- 3. resource conflict --------------------------------------------

(defparameter *p1* (mk :p1 :resources (list (make-resource :name :buf :role :provide :size 8))))
(defparameter *p2* (mk :p2 :deps (list *p1*)
                       :resources (list (make-resource :name :buf :role :provide :size 16))))
(defparameter *conflict-root* (mk :conflict-root :deps (list *p2*)))
(let ((condition (try-construction-error
                  (lambda () (build-configuration (list *conflict-root*))))))
  (check conflict-signaled (typep condition 'resource-conflict))
  (check conflict-requiring-component (eq (construction-error-component condition) *p2*))
  (check conflict-fact-names-resource
         (eq (getf (construction-error-fact condition) :resource-conflict) :buf))
  (check conflict-fact-shows-attributes
         (and (= 8 (getf (getf (construction-error-fact condition) :existing) :size))
              (= 16 (getf (getf (construction-error-fact condition) :offending) :size))))
  (check conflict-path
         (equal (mapcar #'test-name (construction-error-path condition))
                '(:conflict-root :p2)))
  (check conflict-stops-at-merge
         (equal (configuration-phases *most-recent-configuration*)
                '(:construct-discover))))

;;; --- 4. missing resource exposes requiring component and path ---------

(defparameter *consumer*
  (mk :consumer :resources (list (make-resource :name :frob :role :require :size 4))))
(defparameter *missing-root* (mk :missing-root :deps (list *consumer*)))
(let ((condition (try-construction-error
                  (lambda () (build-configuration (list *missing-root*))))))
  (check missing-signaled (typep condition 'missing-resource))
  (check missing-requiring-component (eq (construction-error-component condition) *consumer*))
  (check missing-fact
         (eq (getf (construction-error-fact condition) :missing-resource) :frob))
  (check missing-path
         (equal (mapcar #'test-name (construction-error-path condition))
                '(:missing-root :consumer)))
  (check missing-stops-at-merge-before-layout
         (equal (configuration-phases *most-recent-configuration*)
                '(:construct-discover))))

;;; --- 4b. later provider refines an underspecified requirement ----------

(let* ((consumer (mk :refine-consumer
                     :resources (list (make-resource :name :refined))))
       (provider (mk :refine-provider
                     :resources (list (make-resource :name :refined
                                                     :role :provide
                                                     :size 128
                                                     :granularity 16))))
       (root (mk :refine-root :deps (list consumer provider)))
       (configuration (build-configuration root))
       (resource (find-resource configuration :refined)))
  (check provider-refines-unspecified-size (= 128 (resource-size resource)))
  (check provider-refines-unspecified-granularity
         (= 16 (resource-granularity resource)))
  (check refined-provider-provenance
         (equal (mapcar #'test-name (resource-providers resource))
                '(:refine-provider))))

;;; --- 5. ordinary cycle rejected, declared cohort accepted --------------

(defparameter *x* (mk :x :resources (list (make-resource :name :pair :role :provide))))
(defparameter *y* (mk :y :deps (list *x*)))
(setf (slot-value *x* 'deps) (list *y*))               ; x <-> y, undeclared
(let ((condition (try-construction-error (lambda () (build-configuration (list *x*))))))
  (check cycle-signaled (typep condition 'dependency-cycle))
  (check cycle-requiring-component (eq (construction-error-component condition) *y*))
  (check cycle-path
         (equal (mapcar #'test-name (construction-error-path condition)) '(:x :y :x)))
  (check cycle-stops-at-discover
         (null (configuration-phases *most-recent-configuration*))))

(defparameter *x2* (mk :x2 :cohort :duo
                       :resources (list (make-resource :name :pair :role :provide :size 32))))
(defparameter *y2* (mk :y2 :cohort :duo :deps (list *x2*)))
(setf (slot-value *x2* 'deps) (list *y2*))             ; x2 <-> y2, declared
(setf *init-order* ())
(defparameter *cohort-config* (build-configuration (list *x2*)))
(check cohort-accepted (configuration-active-p *cohort-config*))
(check cohort-initialized-as-one-batch (equal (reverse *init-order*) '(:y2 :x2)))
(check cohort-runs-all-phases
       (equal (configuration-phases *cohort-config*)
              '(:construct-discover :merge :layout-callback :bind
                :initialize :validate :activate)))

(defparameter *x3* (mk :x3 :cohort :duo))
(defparameter *y3* (mk :y3 :cohort :trio :deps (list *x3*)))
(setf (slot-value *x3* 'deps) (list *y3*))             ; mismatched cohorts
(check cohort-mismatch-rejected
       (typep (try-construction-error (lambda () (build-configuration (list *x3*))))
              'dependency-cycle))

;;; --- 6. failure publishes nothing --------------------------------------

(defparameter *ledger-before* (length *published-configurations*))
(defparameter *bad* (mk :bad :validate-ok nil))
(defparameter *bad-root* (mk :bad-root :deps (list *bad*)))
(let ((condition (try-construction-error
                  (lambda () (build-configuration (list *bad-root*))))))
  (check validate-failure-signaled (typep condition 'component-failure))
  (check validate-failure-phase
         (and (typep condition 'component-failure)
              (eq (component-failure-phase condition) :validate)))
  (check validate-failure-names-component (eq (construction-error-component condition) *bad*))
  (check validate-failure-path
         (equal (mapcar #'test-name (construction-error-path condition))
                '(:bad-root :bad))))
(let ((config *most-recent-configuration*))
  (check no-publish-not-active (not (configuration-active-p config)))
  (check no-publish-state (eq (configuration-state config) :building))
  (check no-publish-no-activate-phase
         (not (member :activate (configuration-phases config))))
  (check no-publish-ledger-unchanged
         (= *ledger-before* (length *published-configurations*))))

;;; --- 6b. activation failure rolls back and never publishes ------------

(setf *deact-order* ())
(let* ((bad-activation (mk :bad-activation :activate-ok nil))
       (activation-root (mk :activation-root :deps (list bad-activation)))
       (ledger-before (length *published-configurations*))
       (condition (try-construction-error
                   (lambda () (build-configuration activation-root)))))
  (check activation-failure-wrapped (typep condition 'component-failure))
  (check activation-failure-phase
         (eq (component-failure-phase condition) :activate))
  (check activation-failure-component
         (eq (construction-error-component condition) bad-activation))
  (check activation-failure-not-published
         (= ledger-before (length *published-configurations*)))
  (check activation-failure-state-building
         (eq (configuration-state *most-recent-configuration*) :building))
  (check activation-failure-no-activate-phase
         (not (member :activate
                      (configuration-phases *most-recent-configuration*))))
  (check activation-failure-reverse-cleanup
         (equal (reverse *deact-order*)
                '(:activation-root :bad-activation))))

;;; --- 7. activation is immutable, runtime slots stay mutable ------------

(let ((arena (find-resource *cfg* :arena)))
  (check resource-start-immutable
         (eq t (rejected-as-sealed-p (lambda () (setf (resource-start arena) 1)))))
  (check resource-extent-immutable
         (eq t (rejected-as-sealed-p (lambda () (setf (resource-extent arena) 2)))))
  (check start-unchanged (= #x1000 (resource-start arena))))
(check config-layout-immutable
       (eq t (rejected-as-sealed-p (lambda () (setf (configuration-layout *cfg*) :patched)))))
(check config-graph-immutable
       (eq t (rejected-as-sealed-p (lambda () (setf (configuration-components *cfg*) ())))))
(check config-resources-immutable
       (eq t (rejected-as-sealed-p
              (lambda () (setf (configuration-resources *cfg*) ())))))
(check config-constraints-immutable
       (eq t (rejected-as-sealed-p
              (lambda () (setf (configuration-constraints *cfg*) ())))))
(check config-phases-immutable
       (eq t (rejected-as-sealed-p
              (lambda () (setf (configuration-phases *cfg*) ())))))
(check resource-provenance-immutable
       (eq t (rejected-as-sealed-p
              (lambda ()
                (setf (resource-providers (find-resource *cfg* :arena)) ())))))
(check no-public-state-writer
       (not (fboundp '(setf configuration-state))))
(check no-public-seal-writer
       (not (fboundp '(setf resource-sealed-p))))
(check runtime-slot-mutable
       (progn (incf (test-activations (first (configuration-components *cfg*))))
              (= (test-activations (first (configuration-components *cfg*))) 2)))

;;; --- 8. deactivation runs in reverse order but never unseals ----------

(setf *deact-order* ())
(deactivate-configuration *cfg*)
(check deactivate-state (eq (configuration-state *cfg*) :inactive))
(check deactivate-reverse-order
       (equal (reverse *deact-order*) '(:root :b :a :shared)))
(check deactivate-keeps-geometry-sealed
       (eq t (rejected-as-sealed-p
              (lambda ()
                (setf (resource-start (find-resource *cfg* :arena)) #x2000)))))
(check deactivate-keeps-original-geometry
       (= #x1000 (resource-start (find-resource *cfg* :arena))))

;;; --- summary -----------------------------------------------------------

(format t "~&v11 component contract: ~d checks, ~d failure~:p~%"
        *checks* (length *failures*))
(dolist (failure (reverse *failures*))
  (format t "  FAIL: ~a~%" failure))
(sb-ext:exit :code (if *failures* 1 0))
