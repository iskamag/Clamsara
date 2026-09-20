;;;; Adversarial hosted ABI tests.  These tests are independent of production
;;;; constructors and do not replace workload/collector acceptance.
(defpackage #:clamsara.host.atomics.test
  (:use #:cl #:clamsara)
  (:export #:run-v14-atomics-host-contracts))
(in-package #:clamsara.host.atomics.test)

(defun %check (value format-control &rest args)
  (unless value (error (apply #'format nil format-control args)))
  t)
(defun %signals (thunk)
  (handler-case (progn (funcall thunk) nil)
    (error () t)))
(defun %new (width &optional (value 0) (alignment 1))
  (let* ((a (clamsara::make-host-atomics :word-width width))
         (v (vector value))
         (p (clamsara::make-host-atomic-place :storage v :index 0
                                               :width width :alignment alignment)))
    (values a p v)))

(defun run-v14-atomics-host-contracts ()
  ;; Every invalid order is rejected before place validation/access.
  (multiple-value-bind (a p v) (%new 8 7)
    (declare (ignore v))
    (%check (%signals (lambda () (atomic-load a p :release)))
            "load admitted a release order")
    (%check (%signals (lambda () (atomic-store a p 1 :acquire)))
            "store admitted an acquire order")
    (%check (%signals (lambda () (atomic-bit-set a p 0 :bogus)))
            "bit operation admitted an invalid order")
    (%check (%signals (lambda ()
                        (atomic-load a
                                      (clamsara::make-host-atomic-place
                                       :storage nil :index -1 :width 8 :alignment 1)
                                      :release)))
            "invalid order was not checked before place"))
  ;; Width masking, observed CAS value, and modulo fetch-add.
  (multiple-value-bind (a p v) (%new 8 255)
    (%check (= 255 (atomic-load a p :relaxed)) "load mismatch")
    (%check (= 255 (atomic-store a p 511 :relaxed)) "store must return masked value")
    (%check (= 255 (aref v 0)) "store did not mask modulo word width")
    (%check (= 255 (atomic-cas a p 255 256 :sequential)) "CAS returned wrong observed word")
    (%check (= 0 (aref v 0)) "CAS did not mask new word")
    (%check (= 0 (atomic-cas a p 99 7 :acq-rel)) "CAS mismatch observed wrong word")
    (%check (= 0 (aref v 0)) "failed CAS changed storage")
    (%check (= 0 (atomic-fetch-add a p -1 :release)) "fetch-add previous mismatch")
    (%check (= 255 (aref v 0)) "fetch-add did not wrap modulo"))
  ;; Bit operations return the prior bit, not the new value, and validate index
  ;; before touching a place.
  (multiple-value-bind (a p v) (%new 8 0)
    (%check (not (atomic-bit-set a p 3 :relaxed)) "first bit-set old bit wrong")
    (%check (logbitp 3 (aref v 0)) "bit-set did not update word")
    (%check (atomic-bit-set a p 3 :sequential) "second bit-set old bit wrong")
    (%check (atomic-bit-clear a p 3 :acq-rel) "bit-clear old bit wrong")
    (%check (not (logbitp 3 (aref v 0))) "bit-clear did not update word")
    (%check (%signals (lambda () (atomic-bit-set a p 8 :relaxed)))
            "out-of-range bit index admitted")
    (%check (= 0 (aref v 0)) "invalid bit operation changed word")
    (%check (%signals (lambda () (atomic-bit-clear a p -1 :relaxed)))
            "negative bit index admitted"))
  ;; Width/alignment/profile capability checks happen before access.
  (multiple-value-bind (a p v) (%new 8 4)
    (declare (ignore p v))
    (%check (%signals (lambda ()
                        (atomic-load a (clamsara::make-host-atomic-place
                                        :storage nil :index 0 :width 64 :alignment 1)
                                     :relaxed)))
            "unsupported width was admitted")
    (%check (%signals (lambda ()
                        (atomic-load a (clamsara::make-host-atomic-place
                                        :storage nil :index 0 :width 8 :alignment 3)
                                     :relaxed)))
            "invalid alignment was admitted")
    (%check (%signals (lambda ()
                        (clamsara::make-host-atomics :word-width 8
                                                     :profile :concurrent)))
            "unsupported concurrent profile was admitted"))
  ;; Fences have no host fallback and accept only the four fence orders.
  (let ((a (clamsara::make-host-atomics)))
    (dolist (order '(:acquire :release :acq-rel :sequential))
      (%check (null (fence a order)) "fence returned a value"))
    (%check (%signals (lambda () (fence a :relaxed)))
            "relaxed fence was admitted"))
  t)
