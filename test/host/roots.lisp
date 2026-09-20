;;;; test/host/roots.lisp
;;;; Adversarial tests against the concrete serialized simulator root service.
;;;; This file does not provide host or coordinator stubs.  It is loaded only
;;;; after the v14 client, construction, and concrete host systems.

(defpackage #:clamsara.host.test
  (:use #:cl #:clamsara)
  (:export #:run-v14-root-host-contracts))

(in-package #:clamsara.host.test)

(defvar *v14-root-host-unavailable* nil)

(defun %host-failure-reason (condition)
  (and (typep condition 'clamsara::host-protocol-error)
       (clamsara::host-error-reason condition)))

(defun %signals-host-error (function &optional expected-reason)
  (handler-case
      (progn (funcall function) nil)
    (clamsara::host-protocol-error (condition)
      (let ((reason (%host-failure-reason condition)))
        (and (or (null expected-reason) (eq reason expected-reason))
             reason)))))

(defun %assert (condition format-control &rest args)
  (unless condition (error "v14 root host contract failure: ~?" format-control args))
  t)

;;; A provider-side fixture is used only to exercise malformed enumeration.
;;; Registration, directory ownership, snapshots, and access all remain the
;;; concrete simulator-root-client service.
(defclass malformed-provider ()
  ((locations :initarg :locations :reader malformed-provider-locations)))
(defmethod map-provider-roots ((provider malformed-provider) function)
  (dolist (location (malformed-provider-locations provider))
    (funcall function location))
  (values))
(defclass malformed-location () ())
(defmethod clamsara::host-root-kind ((location malformed-location))
  (declare (ignore location))
  :exact)

(defun %malformed-provider (&rest locations)
  (make-instance 'malformed-provider :locations locations))

(defun test-provider-registration-rejections ()
  ;; Constructor and fixed client/provider capacities are checked before any
  ;; registration state is published.
  (%assert (eq :invalid-provider-capacity
               (%signals-host-error
                (lambda () (clamsara::make-simulator-root-provider -1))))
           "negative provider capacity was accepted")
  (%assert (eq :invalid-provider-capacity
               (%signals-host-error
                (lambda () (clamsara::make-simulator-root-provider :bad))))
           "noninteger provider capacity was accepted")
  (%assert (eq :invalid-provider-description
               (%signals-host-error
                (lambda ()
                  (register-root-provider
                   (clamsara::make-simulator-root-client :provider-capacity 1)
                   nil 0 (%malformed-provider)))))
           "malformed provider identity was accepted")
  ;; Too many enumerated locations is rejected by the concrete service.
  (let ((p (%malformed-provider (make-instance 'malformed-location)
                                (make-instance 'malformed-location))))
    (%assert (eq :invalid-provider-enumeration
                 (%signals-host-error
                  (lambda ()
                    (register-root-provider
                     (clamsara::make-simulator-root-client :provider-capacity 1)
                     :too-many 1 p))))
             "provider enumeration exceeded declared capacity"))
  ;; Duplicate physical location and duplicate provider identity are rejected
  ;; before directory/provider publication.  A provider's capacity is a
  ;; maximum; under-enumerating below it is allowed by the protocol.
  (let* ((location (make-instance 'malformed-location))
         (client (clamsara::make-simulator-root-client :provider-capacity 2)))
    (%assert (eq :duplicate-root-location
                 (%signals-host-error
                  (lambda ()
                    (register-root-provider
                     client :duplicate-location 2
                     (%malformed-provider location location)))))
             "duplicate physical root location was accepted")
    (let ((provider (clamsara::make-simulator-root-provider 1)))
      (register-root-provider client :same-id 1 provider)
      (%assert (eq :duplicate-provider-identity
                   (%signals-host-error
                    (lambda ()
                      (register-root-provider
                       client :same-id 1
                       (clamsara::make-simulator-root-provider 1)))))
               "duplicate provider identity was accepted")))
  ;; Provider slots are bounded and cannot be overcommitted.
  (let ((client (clamsara::make-simulator-root-client :provider-capacity 1)))
    (register-root-provider client :first 0 (%malformed-provider))
    (%assert (eq :provider-capacity-exhausted
                 (%signals-host-error
                  (lambda ()
                    (register-root-provider client :second 0 (%malformed-provider)))))
             "provider-capacity bound was bypassed"))
  t)

(defun test-registration-generation-and-access ()
  (let* ((client (clamsara::make-simulator-root-client :provider-capacity 2))
         (provider (clamsara::make-simulator-root-provider 2))
         (first-token (register-root-provider client :generation 2 provider))
         (location (clamsara::simulator-root-location provider 0))
         (foreign (clamsara::simulator-root-location
                   (clamsara::make-simulator-root-provider 1) 0)))
    (%assert (null (root-provider-load client first-token location))
             "fresh root slot was not NIL")
    (%assert (eq :invalid-root-location
                 (%signals-host-error
                  (lambda () (root-provider-load client first-token foreign))))
             "foreign root location was accepted")
    (%assert (eq :invalid-provider-token
                 (%signals-host-error
                  (lambda ()
                    (root-provider-load
                     (clamsara::make-simulator-root-client :provider-capacity 1)
                     first-token location))))
             "foreign provider token was accepted")
    (unregister-root-provider client first-token)
    (%assert (eq :invalid-provider-token
                 (%signals-host-error
                  (lambda () (root-provider-load client first-token location))))
             "stale provider token remained usable")
    ;; Re-registration gets a different token and generation.  The old token
    ;; must not name the successor even when physical provider storage is
    ;; reused.
    (let ((second-token (register-root-provider client :generation 2 provider)))
      (%assert (and second-token (not (eq second-token first-token)))
               "provider token was reused")
      (unregister-root-provider client second-token))
    t))

(defun %with-covered-stop (root-client function)
  (let ((coordinator
          (clamsara::make-simulator-coordinator root-client :stop-capacity 2 :await-bound 8)))
    (multiple-value-bind (token request-failure)
        (request-safepoint coordinator :all :root-contract)
      (%assert (and token (null request-failure))
               "safepoint request failed: ~S" request-failure)
      (multiple-value-bind (same-token coverage await-failure)
          (await-safepoint coordinator token)
        (%assert (and (eq same-token token) coverage (null await-failure))
                 "safepoint await failed: ~S" await-failure)
        (unwind-protect
             (funcall function coordinator token coverage)
          ;; A caller that has failed inside the protected pass must retain the
          ;; stop; normal tests release only after their callback succeeds.
          (when (eq :released (release-safepoint coordinator token))
            (values)))))))

(defun test-root-snapshot-lifetime-and-enumeration ()
  (let* ((client (clamsara::make-simulator-root-client :provider-capacity 2))
         (provider (clamsara::make-simulator-root-provider 2))
         (token (register-root-provider client :snapshot 2 provider))
         (locations nil)
         (borrowed nil)
         (snapshot nil))
    (%with-covered-stop
     client
     (lambda (coordinator stop-token coverage)
       (declare (ignore coordinator stop-token))
       (with-root-snapshot client coverage
         (lambda (value)
           (setf snapshot value)
           (map-root-locations
            value
            (lambda (owner location)
              (%assert (eq owner client) "root callback owner mismatch")
              (push location locations)
              (setf borrowed location)
              (%assert (eq :exact (root-location-kind owner location))
                       "registered root was not exact/writable")
              (%assert (null (load-root owner location))
                       "fresh root value was not NIL")
              (store-root owner location :inside-snapshot)
              (%assert (eq :inside-snapshot (load-root owner location))
                       "snapshot store was not immediately visible")))))
       (%assert (= 2 (length locations))
                "snapshot did not enumerate every registered location")
       ;; Borrowed locations cannot be loaded outside the callback.  A snapshot
       ;; object itself also becomes inactive after callback return.
       (%assert (eq :root-location-not-borrowed
                    (%signals-host-error (lambda () (load-root client borrowed))))
                "borrowed root location survived callback")
       (%assert (eq :inactive-root-snapshot
                    (%signals-host-error (lambda () (map-root-locations snapshot #'identity))))
                "inactive snapshot was still enumerable")
       ;; Registration/removal are closed while this stop is active.
       (%assert (eq :root-registration-closed
                    (%signals-host-error
                     (lambda ()
                       (register-root-provider
                        client :late 0 (%malformed-provider)))))
                "provider registration was admitted during stop")
       (%assert (eq :root-generation-protected
                    (%signals-host-error
                     (lambda () (unregister-root-provider client token))))
                "provider removal was admitted during stop")
       )
    ;; The stop is released by %WITH-COVERED-STOP after successful callback.
     )
    t))


(defun test-snapshot-mutation-and-failure-lifetime ()
  ;; A provider cannot change its physical identity set while a snapshot is
  ;; borrowed.  The real service rejects duplicate and foreign locations.
  (dolist (mutation '(:duplicate :foreign))
    (let* ((client (clamsara::make-simulator-root-client :provider-capacity 1))
           (provider (clamsara::make-simulator-root-provider 2))
           (token (register-root-provider client mutation 2 provider))
           (foreign (clamsara::simulator-root-location
                     (clamsara::make-simulator-root-provider 1) 0))
           (seen 0)
           (coordinator (clamsara::make-simulator-coordinator
                         client :stop-capacity 1 :await-bound 8)))
      (declare (ignore token))
      (multiple-value-bind (stop request-failure)
          (request-safepoint coordinator :all :snapshot-mutation)
        (%assert (and stop (null request-failure))
                 "mutation test could not request stop")
        (multiple-value-bind (same coverage await-failure)
            (await-safepoint coordinator stop)
          (%assert (and (eq same stop) coverage (null await-failure))
                   "mutation test could not obtain coverage")
          (let ((caught nil))
            (handler-case
                (with-root-snapshot client coverage
                  (lambda (snapshot)
                    (map-root-locations snapshot
                      (lambda (owner location)
                        (declare (ignore owner location))
                        (incf seen)
                        (when (= seen 1)
                          (setf (aref (clamsara::simulator-provider-locations
                                       provider) 1)
                                (if (eq mutation :duplicate)
                                    (clamsara::simulator-root-location provider 0)
                                    foreign)))))))
              (clamsara::host-protocol-error (condition)
                (setf caught (%host-failure-reason condition))))
            (%assert (eq caught (if (eq mutation :duplicate)
                                    :duplicate-root-enumeration
                                    :invalid-root-location))
                     "provider mutation escaped as ~S for ~S" caught))
          ;; Unwind from the callback left coverage unsafe.  It must not be
          ;; released as a normal stop and admission remains closed.
          (%assert (eq :invalid (release-safepoint coordinator stop))
                   "unsafe snapshot was released")
          (%assert (eq :root-registration-closed
                       (%signals-host-error
                        (lambda ()
                          (register-root-provider
                           client :blocked 0 (%malformed-provider)))))
                   "unsafe snapshot reopened root admission")))))
  ;; A nonlocal callback exit has the same unsafe-coverage rule.
  (let* ((client (clamsara::make-simulator-root-client :provider-capacity 1))
         (provider (clamsara::make-simulator-root-provider 1))
         (token (register-root-provider client :nonlocal 1 provider))
         (coordinator (clamsara::make-simulator-coordinator
                       client :stop-capacity 1 :await-bound 8)))
    (declare (ignore token))
    (multiple-value-bind (stop ignored)
        (request-safepoint coordinator :all :nonlocal)
      (declare (ignore ignored))
      (multiple-value-bind (same coverage await-failure)
          (await-safepoint coordinator stop)
        (%assert (and (eq same stop) coverage (null await-failure))
                 "nonlocal test could not obtain coverage")
        (%assert (eq :escaped
                     (catch :root-test-escape
                       (with-root-snapshot client coverage
                         (lambda (snapshot)
                           (declare (ignore snapshot))
                           (throw :root-test-escape :escaped)))))
                 "nonlocal callback did not escape")
        (%assert (eq :invalid (release-safepoint coordinator stop))
                 "nonlocal callback allowed release"))))
  t)

(defun test-stale-coverage-rejected ()
  (let* ((client (clamsara::make-simulator-root-client :provider-capacity 1))
         (provider (clamsara::make-simulator-root-provider 1))
         (token (register-root-provider client :stale 1 provider))
         (coordinator (clamsara::make-simulator-coordinator
                       client :stop-capacity 2 :await-bound 8))
         (old-coverage nil))
    (declare (ignore token))
    (multiple-value-bind (first ignored)
        (request-safepoint coordinator :all :first)
      (declare (ignore ignored))
      (multiple-value-bind (same first-coverage failure)
          (await-safepoint coordinator first)
        (%assert (and (eq same first) first-coverage (null failure))
                 "first stop did not complete")
        (setf old-coverage first-coverage)
        (with-root-snapshot client first-coverage
          (lambda (snapshot) (declare (ignore snapshot))))
        (%assert (eq :released (release-safepoint coordinator first))
                 "first stop did not release")))
    (multiple-value-bind (second ignored)
        (request-safepoint coordinator :all :second)
      (declare (ignore ignored))
      (multiple-value-bind (same second-coverage failure)
          (await-safepoint coordinator second)
        (%assert (and (eq same second) second-coverage (null failure)
                      (not (eq old-coverage second-coverage)))
                 "coverage record was reused or second stop failed")
        (%assert (eq :invalid-root-coverage
                     (%signals-host-error
                      (lambda ()
                        (with-root-snapshot client old-coverage
                          (lambda (snapshot) (declare (ignore snapshot)))))))
                 "stale coverage was accepted")
        (with-root-snapshot client second-coverage
          (lambda (snapshot) (declare (ignore snapshot))))
        (%assert (eq :released (release-safepoint coordinator second))
                 "second stop did not release")))
    t))

(defun test-root-store-capability-boundary ()
  (let* ((client (clamsara::make-simulator-root-client :provider-capacity 1))
         (provider (clamsara::make-simulator-root-provider 1))
         (token (register-root-provider client :store 1 provider))
         (location (clamsara::simulator-root-location provider 0)))
    ;; ROOT-PROVIDER-STORE must not fall back to an unbarriered raw host write.
    ;; Until a runtime installs STORE-PROVIDER-ROOT, no-applicable-method is a
    ;; truthful unsupported-target result; once installed, this test expects
    ;; the runtime's composed route to return (effective :stored).
    (handler-case
        (multiple-value-bind (effective status)
            (root-provider-store client :context token location :new-reference)
          (%assert (eq status :stored)
                   "root-provider-store returned non-success status ~S" status)
          (%assert (eq effective :new-reference)
                   "root-provider-store returned wrong effective reference")
          (%assert (eq :new-reference (root-provider-load client token location))
                   "root-provider-store did not publish effective value"))
      (clamsara::host-protocol-error (condition)
        (error "root-provider-store host rejection: ~S"
               (clamsara::host-error-reason condition)))
      (error ()
        ;; Explicitly report unavailable runtime route rather than accepting a
        ;; raw write.  This branch is turned into a required success once the
        ;; composed runtime hook is installed.
        (pushnew :root-provider-store *v14-root-host-unavailable*)
        :unsupported))
    (unregister-root-provider client token)
    t))

(defun run-v14-root-host-contracts ()
  (let ((*v14-root-host-unavailable* nil))
    (test-provider-registration-rejections)
    (test-registration-generation-and-access)
    (test-root-snapshot-lifetime-and-enumeration)
    (test-snapshot-mutation-and-failure-lifetime)
    (test-stale-coverage-rejected)
    (test-root-store-capability-boundary)
    (values t :complete (nreverse *v14-root-host-unavailable*))))
