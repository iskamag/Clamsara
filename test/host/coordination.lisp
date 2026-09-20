;;;; test/host/coordination.lisp
;;;; Adversarial contract checks for the concrete serialized coordinator.
;;;; No scheduler/coordinator stubs are provided here.  All cases exercise
;;;; src/host/coordinator.lisp and its real root service.

(defpackage #:clamsara.host.coordination.test
  (:use #:cl #:clamsara)
  (:export #:run-v14-coordination-host-contracts))

(in-package #:clamsara.host.coordination.test)

(defun %assert (condition format-control &rest args)
  (unless condition (error "v14 coordinator contract failure: ~?" format-control args))
  t)

(defun %host-reason (condition)
  (and (typep condition 'clamsara::host-protocol-error)
       (clamsara::host-error-reason condition)))

(defun %signals-host (function &optional reason)
  (handler-case
      (progn (funcall function) nil)
    (clamsara::host-protocol-error (condition)
      (let ((actual (%host-reason condition)))
        (and (or (null reason) (eq reason actual)) actual)))))

(defun %make-client-with-providers (count)
  (let ((client (clamsara::make-simulator-root-client
                 :provider-capacity (max 1 count))))
    ;; Zero-location providers are still physical registered providers.  They
    ;; make coordinator join accounting observable without inventing roots.
    (dotimes (i count)
      (register-root-provider
       client (intern (format nil "COORD-PROVIDER-~D" i) :keyword)
       0 (clamsara::make-simulator-root-provider 0)))
    client))

(defun test-request-admission-and-release-states ()
  (let* ((client (%make-client-with-providers 2))
         (coordinator (clamsara::make-simulator-coordinator
                       client :stop-capacity 2 :await-bound 8))
         (other-client (%make-client-with-providers 1))
         (other (clamsara::make-simulator-coordinator
                 other-client :stop-capacity 1 :await-bound 8)))
    (%assert (eq :unsupported-scope
                 (nth-value 1 (request-safepoint coordinator :owner :scope)))
             "unsupported scope was admitted")
    (%assert (eq :invalid-reason
                 (nth-value 1 (request-safepoint coordinator :all nil)))
             "unstable/nil reason was admitted")
    (multiple-value-bind (token failure)
        (request-safepoint coordinator :all :first)
      (%assert (and token (null failure)) "valid request failed: ~S" failure)
      ;; A second request cannot overlap a pending stop.
      (%assert (eq :busy (nth-value 1 (request-safepoint coordinator :all :busy)))
               "pending stop did not reject a second request")
      ;; Release cannot run while Await is pending.
      (%assert (eq :invalid (release-safepoint coordinator token))
               "pending stop was released")
      ;; Foreign tokens do not affect this coordinator.
      (multiple-value-bind (foreign ignored)
          (request-safepoint other :all :foreign)
        (declare (ignore ignored))
        (%assert (eq :invalid (release-safepoint coordinator foreign))
                 "foreign token released local stop")
        (%assert (eq :invalid-await-token
                     (%signals-host (lambda ()
                                      (await-safepoint coordinator foreign))))
                 "foreign token awaited on local coordinator")
        (%assert (eq :invalid (release-safepoint other foreign))
                 "foreign coordinator token released before await"))
      (multiple-value-bind (same coverage await-failure)
          (await-safepoint coordinator token)
        (%assert (and (eq same token) coverage (null await-failure))
                 "pending stop did not become covered")
        ;; Covered stops remain busy until release.
        (%assert (eq :busy (nth-value 1 (request-safepoint coordinator :all :busy-covered)))
                 "covered stop did not reject overlap")
        (%assert (eq :released (release-safepoint coordinator token))
                 "covered stop did not release")
        ;; Exact repeat is recognized without effects.  Await on a stale token
        ;; is a protocol error, not a second coverage acquisition.
        (%assert (eq :already-released (release-safepoint coordinator token))
                 "release repeat was not idempotent")
        (%assert (eq :invalid-await-token
                     (%signals-host (lambda ()
                                      (await-safepoint coordinator token))))
                 "stale token was awaited")))
    ;; The same root service is open after release and admits the next request.
    (multiple-value-bind (next ignored)
        (request-safepoint coordinator :all :next)
      (declare (ignore ignored))
      (multiple-value-bind (same coverage failure)
          (await-safepoint coordinator next)
        (%assert (and (eq same next) coverage (null failure))
                 "next stop did not complete")
        (%assert (eq :released (release-safepoint coordinator next))
                 "next stop did not release")))
    t))

(defun test-partial-join-before-and-after-all-providers ()
  (let* ((client (%make-client-with-providers 3))
         (coordinator (clamsara::make-simulator-coordinator
                       client :stop-capacity 3 :await-bound 8))
         (joined (clamsara::simulator-joined-providers coordinator))
         (wakes (clamsara::simulator-wake-counts coordinator)))
    ;; Inject failure after the first provider joins.  Await exposes no
    ;; coverage, release must cancel the partial join, and only that provider
    ;; receives one wake.
    (setf (clamsara::simulator-await-fail-after coordinator) 1)
    (multiple-value-bind (token ignored)
        (request-safepoint coordinator :all :fail-before-all)
      (declare (ignore ignored))
      (multiple-value-bind (same coverage failure)
          (await-safepoint coordinator token)
        (%assert (and (eq same token) (null coverage) (eq :coverage-failed failure))
                 "pre-all failure did not return failed Await")
        (%assert (<= (clamsara::simulator-last-await-steps coordinator)
                     (clamsara::simulator-await-bound coordinator))
                 "Await exceeded configured finite bound")
        (%assert (= 1 (sbit joined 0)) "first provider did not join")
        (%assert (and (zerop (sbit joined 1)) (zerop (sbit joined 2)))
                 "providers joined after injected pre-all failure")
        (%assert (eq :cancelled (release-safepoint coordinator token))
                 "pre-all partial stop did not cancel")
        (%assert (and (= 1 (aref wakes 0))
                      (zerop (aref wakes 1)) (zerop (aref wakes 2)))
                 "partial cancellation woke the wrong providers")))
    ;; Fail after all provider joins.  This exercises the post-join failure
    ;; branch: all joined bits must be unwound and each provider wakes once.
    (setf (clamsara::simulator-await-fail-after coordinator) 3)
    (multiple-value-bind (token ignored)
        (request-safepoint coordinator :all :fail-after-all)
      (declare (ignore ignored))
      (multiple-value-bind (same coverage failure)
          (await-safepoint coordinator token)
        (%assert (and (eq same token) (null coverage) (eq :coverage-failed failure))
                 "post-all failure did not return failed Await")
        (%assert (every (lambda (i) (= 1 (sbit joined i))) '(0 1 2))
                 "post-all failure lost a joined provider")
        (%assert (eq :cancelled (release-safepoint coordinator token))
                 "post-all partial stop did not cancel")
        (%assert (and (= 2 (aref wakes 0))
                      (= 1 (aref wakes 1)) (= 1 (aref wakes 2)))
                 "post-all cancellation did not wake each provider")))
    ;; No injection permits a complete covered stop after both failure paths.
    (setf (clamsara::simulator-await-fail-after coordinator) nil)
    (multiple-value-bind (token ignored)
        (request-safepoint coordinator :all :complete)
      (declare (ignore ignored))
      (multiple-value-bind (same coverage failure)
          (await-safepoint coordinator token)
        (%assert (and (eq same token) coverage (null failure))
                 "post-failure coordinator could not complete")
        (%assert (eq :released (release-safepoint coordinator token))
                 "post-failure coordinator did not release")))
    t))

(defun test-short-await-bound-and-capacity ()
  ;; Bound 2 provides one provider join plus one finite completion/failure
  ;; step, then fails before the second provider.  No wait can exceed bound.
  (let* ((client (%make-client-with-providers 3))
         (coordinator (clamsara::make-simulator-coordinator
                       client :stop-capacity 2 :await-bound 2))
         (joined (clamsara::simulator-joined-providers coordinator)))
    (multiple-value-bind (token ignored)
        (request-safepoint coordinator :all :short-bound)
      (declare (ignore ignored))
      (multiple-value-bind (same coverage failure)
          (await-safepoint coordinator token)
        (%assert (and (eq same token) (null coverage) (eq :coverage-failed failure))
                 "short Await bound did not fail finite")
        (%assert (= 2 (clamsara::simulator-last-await-steps coordinator))
                 "short Await bound used unexpected steps")
        (%assert (= 1 (sbit joined 0))
                 "short Await bound did not preserve partial join")
        (%assert (eq :cancelled (release-safepoint coordinator token))
                 "short Await bound was not cancellable")))
    ;; Stop capacity is a finite preallocated resource.  Use a fresh service
    ;; so the short-bound stop above does not consume this capacity check.
    (let* ((capacity-client (%make-client-with-providers 1))
           (capacity-coordinator
             (clamsara::make-simulator-coordinator
              capacity-client :stop-capacity 1 :await-bound 4)))
      (multiple-value-bind (first ignored)
          (request-safepoint capacity-coordinator :all :capacity-first)
        (declare (ignore ignored))
        (multiple-value-bind (same coverage failure)
            (await-safepoint capacity-coordinator first)
          (%assert (and (eq same first) coverage (null failure))
                   "capacity test first stop failed")
          (%assert (eq :released
                       (release-safepoint capacity-coordinator first))
                   "capacity test first stop did not release")))
      (multiple-value-bind (none reason)
          (request-safepoint capacity-coordinator :all :capacity-exhausted)
        (%assert (and (null none) (eq :insufficient-reserve reason))
                 "stop capacity exhaustion returned ~S/~S" none reason)))
    t))

(defun test-distinct-preallocated-coverage-records ()
  (let* ((client (%make-client-with-providers 1))
         (coordinator (clamsara::make-simulator-coordinator
                       client :stop-capacity 2 :await-bound 4))
         (old nil)
         (first-token nil))
    (multiple-value-bind (first ignored)
        (request-safepoint coordinator :all :record-first)
      (declare (ignore ignored))
      (setf first-token first)
      (multiple-value-bind (same coverage failure)
          (await-safepoint coordinator first)
        (%assert (and (eq same first) coverage (null failure))
                 "first coverage record unavailable")
        (setf old coverage)
        (%assert (eq :released (release-safepoint coordinator first-token))
                 "first coverage record did not release")))
    (multiple-value-bind (second ignored)
        (request-safepoint coordinator :all :record-second)
      (declare (ignore ignored))
      (multiple-value-bind (same coverage failure)
          (await-safepoint coordinator second)
        (%assert (and (eq same second) coverage (null failure)
                      (not (eq old coverage)))
                 "stop token reused a coverage record")
        (%assert (eq :released (release-safepoint coordinator second))
                 "second coverage record did not release")
        ;; Terminal history is per token, not merely current-stop state.
        (%assert (eq :already-released (release-safepoint coordinator first-token))
                 "old terminal token lost repeat history")))
    t))

(defun run-v14-coordination-host-contracts ()
  (test-request-admission-and-release-states)
  (test-partial-join-before-and-after-all-providers)
  (test-short-await-bound-and-capacity)
  (test-distinct-preallocated-coverage-records)
  (values t :complete))
