;;;; Independent paper-v14 acceptance tests for the concrete hosted root and
;;;; coordinator services. Load after src/host/{roots,coordinator}.lisp.
;;;; These are semantic tests. They do not claim native stack or target safety.

(defpackage #:clamsara.acceptance.host
  (:use #:cl #:clamsara)
  (:export #:run-host-safety-acceptance))
(in-package #:clamsara.acceptance.host)

(defun check (value control &rest arguments)
  (unless value
    (error "v14 host acceptance failure: ~?" control arguments))
  t)

(defun host-error-reason-of (thunk)
  (handler-case (progn (funcall thunk) nil)
    (clamsara::host-protocol-error (condition)
      (clamsara::host-error-reason condition))))

(defclass acceptance-location ()
  ((value :initform nil :accessor acceptance-location-value)))
(defmethod clamsara::host-root-value ((location acceptance-location))
  (acceptance-location-value location))
(defmethod (setf clamsara::host-root-value)
    (value (location acceptance-location))
  (setf (acceptance-location-value location) value))
(defmethod clamsara::host-root-kind ((location acceptance-location))
  (declare (ignore location))
  :exact)

(defclass acceptance-provider ()
  ((locations :initarg :locations :accessor acceptance-provider-locations)))
(defmethod map-provider-roots ((provider acceptance-provider) function)
  (map nil function (acceptance-provider-locations provider))
  (values))
(defun make-acceptance-provider (&rest locations)
  (make-instance 'acceptance-provider :locations (coerce locations 'vector)))

(defun make-roots (capacity)
  (clamsara::make-simulator-root-client :provider-capacity capacity))
(defun make-provider (capacity)
  (clamsara::make-simulator-root-provider capacity))
(defun provider-location (provider index)
  (clamsara::simulator-root-location provider index))
(defun make-coordinator (roots &key (capacity 8) (bound 16))
  (clamsara::make-simulator-coordinator
   roots :stop-capacity capacity :await-bound bound))

(defun request-and-await (coordinator &optional (reason :acceptance))
  (multiple-value-bind (token request-failure)
      (request-safepoint coordinator :all reason)
    (check (and token (null request-failure))
           "request failed: ~S" request-failure)
    (multiple-value-bind (same coverage await-failure)
        (await-safepoint coordinator token)
      (check (and (eql same token) coverage (null await-failure))
             "await failed: ~S" await-failure)
      (values token coverage))))

(defun test-registration-rejection-is-atomic ()
  (let* ((roots (make-roots 1))
         (location (make-instance 'acceptance-location))
         (duplicate (make-acceptance-provider location location)))
    (check (eq :duplicate-root-location
               (host-error-reason-of
                (lambda ()
                  (register-root-provider roots :bad 2 duplicate))))
           "duplicate enumeration did not reject")
    ;; The rejected attempt must not consume the only provider slot or leave a
    ;; directory owner behind.
    (let* ((provider (make-acceptance-provider location))
           (token (register-root-provider roots :good 1 provider)))
      (check token "registration after rejection did not succeed")
      (unregister-root-provider roots token)))
  t)

(defun test-provider-capacity-is-a-maximum ()
  ;; CAPACITY is the maximum number of locations for the generation, not a
  ;; requirement to enumerate unused slots. The accepted generation must then
  ;; enumerate its one registered physical location exactly once.
  (let* ((roots (make-roots 1))
         (location (make-instance 'acceptance-location))
         (provider (make-acceptance-provider location))
         (registration (register-root-provider roots :bounded 2 provider))
         (coordinator (make-coordinator roots)))
    (multiple-value-bind (stop coverage) (request-and-await coordinator)
      (let ((visits 0))
        (with-root-snapshot roots coverage
          (lambda (snapshot)
            (map-root-locations snapshot
              (lambda (owner actual)
                (check (and (eq owner roots) (eq actual location))
                       "wrong registered root location")
                (incf visits)))))
        (check (= visits 1) "registered location visited ~D times" visits))
      (check (eq :released (release-safepoint coordinator stop))
             "covered stop did not release"))
    (unregister-root-provider roots registration))
  t)

(defun test-request-rejection-has-no-effect ()
  (let* ((roots (make-roots 2))
         (coordinator (make-coordinator roots)))
    (multiple-value-bind (token reason)
        (request-safepoint coordinator :smaller :bad-scope)
      (check (and (null token) (eq reason :unsupported-scope))
             "unsupported scope result was ~S/~S" token reason))
    ;; Rejection did not close root admission or reserve a stop.
    (let ((registration
            (register-root-provider roots :after-rejection 0
                                    (make-acceptance-provider))))
      (unregister-root-provider roots registration))
    (multiple-value-bind (token reason)
        (request-safepoint coordinator :all nil)
      (check (and (null token) (eq reason :invalid-reason))
             "invalid reason result was ~S/~S" token reason))
    (multiple-value-bind (stop request-failure)
        (request-safepoint coordinator :all :first)
      (check (and stop (null request-failure)) "valid request failed")
      (multiple-value-bind (other busy)
          (request-safepoint coordinator :all :second)
        (check (and (null other) (eq busy :busy))
               "overlapping request was not rejected busy"))
      (check (eq :invalid (release-safepoint coordinator stop))
             "Release raced pending Await")
      (multiple-value-bind (same coverage failure)
          (await-safepoint coordinator stop)
        (declare (ignore coverage))
        (check (and (eql same stop) (null failure))
               "pending stop was damaged by rejected operations"))
      (check (eq :released (release-safepoint coordinator stop))
             "stop failed to release")))
  t)

(defun test-partial-await-cancellation ()
  (let* ((roots (make-roots 3))
         (p0 (register-root-provider roots :p0 0 (make-acceptance-provider)))
         (p1 (register-root-provider roots :p1 0 (make-acceptance-provider)))
         (coordinator (make-coordinator roots)))
    (setf (clamsara::simulator-await-fail-after coordinator) 1)
    (multiple-value-bind (stop request-failure)
        (request-safepoint coordinator :all :partial)
      (check (and stop (null request-failure)) "partial request failed")
      (multiple-value-bind (same coverage failure)
          (await-safepoint coordinator stop)
        (check (and (eql same stop) (null coverage)
                    (eq failure :coverage-failed))
               "partial Await exposed coverage: ~S/~S" coverage failure))
      (check (eq :root-registration-closed
                 (host-error-reason-of
                  (lambda ()
                    (register-root-provider roots :too-early 0
                                            (make-acceptance-provider)))))
             "failed Await reopened admission before cancellation")
      (check (eq :cancelled (release-safepoint coordinator stop))
             "failed Await did not explicitly cancel")
      (check (eq :already-released (release-safepoint coordinator stop))
             "exact cancellation repeat was not idempotent")
      (let ((wakes (clamsara::simulator-wake-counts coordinator)))
        (check (and (= 1 (aref wakes 0)) (= 0 (aref wakes 1)))
               "partial joins were not restored exactly once: ~S" wakes)))
    ;; Cancellation reopened admission.
    (let ((p2 (register-root-provider roots :p2 0 (make-acceptance-provider))))
      (unregister-root-provider roots p2))
    (unregister-root-provider roots p0)
    (unregister-root-provider roots p1))
  t)

(defun test-snapshot-borrow-and-release-order ()
  (let* ((roots (make-roots 1))
         (provider (make-provider 1))
         (registration (register-root-provider roots :snapshot 1 provider))
         (location (provider-location provider 0))
         (coordinator (make-coordinator roots)))
    (multiple-value-bind (stop coverage) (request-and-await coordinator)
      (with-root-snapshot roots coverage
        (lambda (snapshot)
          (check (eq :invalid (release-safepoint coordinator stop))
                 "stop released while snapshot was borrowed")
          (map-root-locations snapshot
            (lambda (owner actual)
              (check (eq actual location) "snapshot returned wrong location")
              (store-root owner actual :corrected)
              (check (eq :corrected (load-root owner actual))
                     "corrected root was not immediately visible")))))
      (check (eq :released (release-safepoint coordinator stop))
             "stop did not release after borrowed callback returned")
      (check (eq :invalid-root-coverage
                 (host-error-reason-of
                  (lambda () (with-root-snapshot roots coverage #'identity))))
             "released coverage remained usable"))
    (check (eq :corrected (root-provider-load roots registration location))
           "correction was not published before resume")
    (unregister-root-provider roots registration))
  t)

(defun test-callback-failure-retains-stop ()
  (let* ((roots (make-roots 1))
         (registration
           (register-root-provider roots :fatal 0 (make-acceptance-provider)))
         (coordinator (make-coordinator roots)))
    (multiple-value-bind (stop coverage) (request-and-await coordinator)
      (handler-case
          (with-root-snapshot roots coverage
            (lambda (snapshot)
              (declare (ignore snapshot))
              (error "injected callback failure")))
        (error () nil))
      (check (eq :invalid (release-safepoint coordinator stop))
             "callback failure incorrectly released the stop")
      (check (eq :root-generation-protected
                 (host-error-reason-of
                  (lambda () (unregister-root-provider roots registration))))
             "callback failure reopened root admission")))
  t)

(defun test-provider-change-fails-coverage ()
  (let* ((roots (make-roots 1))
         (location (make-instance 'acceptance-location))
         (provider (make-acceptance-provider location))
         (registration (register-root-provider roots :changing 1 provider))
         (coordinator (make-coordinator roots)))
    (declare (ignore registration))
    (multiple-value-bind (stop coverage) (request-and-await coordinator)
      ;; The registration snapshot named LOCATION. Removing it from the
      ;; provider during the protected generation cannot become a successful
      ;; snapshot.
      (setf (acceptance-provider-locations provider) #())
      (check (eq :missing-root-location
                 (host-error-reason-of
                  (lambda ()
                    (with-root-snapshot roots coverage
                      (lambda (snapshot)
                        (map-root-locations snapshot
                                            (lambda (owner actual)
                                              (declare (ignore owner actual)))))))))
             "changed provider enumeration was accepted")
      (check (eq :invalid (release-safepoint coordinator stop))
             "failed root correction released the stop")))
  t)

(defun test-completed-token-repeat-after-later-stop ()
  ;; Tokens are never reused. A recognizable exact repeat has no effect and
  ;; remains :ALREADY-RELEASED even after a later stop completes.
  (let* ((roots (make-roots 1))
         (coordinator (make-coordinator roots)))
    (multiple-value-bind (first coverage) (request-and-await coordinator :first)
      (declare (ignore coverage))
      (check (eq :released (release-safepoint coordinator first))
             "first stop did not release")
      (multiple-value-bind (second later-coverage)
          (request-and-await coordinator :second)
        (declare (ignore later-coverage))
        (check (not (eql first second)) "stop token identity was reused")
        (check (eq :released (release-safepoint coordinator second))
               "second stop did not release")
        (check (eq :already-released (release-safepoint coordinator first))
               "recognizable exact old repeat was reported stale"))))
  t)

(defun run-host-safety-acceptance ()
  (test-registration-rejection-is-atomic)
  (test-provider-capacity-is-a-maximum)
  (test-request-rejection-has-no-effect)
  (test-partial-await-cancellation)
  (test-snapshot-borrow-and-release-order)
  (test-callback-failure-retains-stop)
  (test-provider-change-fails-coverage)
  (test-completed-token-repeat-after-later-stop)
  (values t :complete))
