;;;; Independent paper-v14 acceptance tests for concrete metadata stores.
;;;; Load after construction protocol/records, client metadata, and
;;;; src/metadata/metadata.lisp. These exercise externally stated effects.

(defpackage #:clamsara.acceptance.metadata
  (:use #:cl #:clamsara)
  (:export #:run-metadata-safety-acceptance))
(in-package #:clamsara.acceptance.metadata)

(defun check (value control &rest arguments)
  (unless value
    (error "v14 metadata acceptance failure: ~?" control arguments))
  t)

(defclass acceptance-resource-context ()
  ((handles :initform (make-hash-table :test #'eq)
            :reader acceptance-resource-handles)))
(defmethod construction-resource
    ((context acceptance-resource-context) identity)
  (let* ((table (acceptance-resource-handles context))
         (present (nth-value 1 (gethash identity table)))
         (handle (gethash identity table))
         (capacity (clamsara::storage-capacity identity)))
    (unless present
      (setf handle
            (cond ((typep identity 'clamsara::packed-bit-storage)
                   (make-array capacity :element-type 'bit :initial-element 0))
                  ((typep identity 'clamsara::side-forwarding)
                   (make-array capacity :initial-element nil))
                  (t (make-array capacity :initial-element 0)))
            (gethash identity table) handle))
    (values handle t
            (+ (clamsara::%storage-bytes identity) 16)
            capacity 16)))

(defun make-domain ()
  (clamsara::make-metadata-domain
   :base 4096 :limit 4160 :granularity 16))
(defun initialize-side (class)
  (let ((value (make-instance class :domain (make-domain))))
    (initialize-component value (make-instance 'acceptance-resource-context))
    value))

(defclass acceptance-field-model ()
  ((values :initform (make-hash-table :test #'equal)
           :reader acceptance-field-values)
   (legal :initarg :legal :initform '(0 1) :reader acceptance-field-legal)
   (operations :initarg :operations :initform '(:read :write :cas)
               :reader acceptance-field-operations)
   (orders :initarg :orders :initform '(:relaxed)
           :reader acceptance-field-orders)))
(defmethod describe-metadata-field-offer
    ((model acceptance-field-model) field)
  (values field 1 (acceptance-field-legal model)
          (acceptance-field-operations model) (acceptance-field-orders model)
          '(:acceptance-object) nil :clear :preserve))
(defmethod field-read ((model acceptance-field-model) field key)
  (gethash (list field key) (acceptance-field-values model) 0))
(defmethod field-write ((model acceptance-field-model) field key value)
  (setf (gethash (list field key) (acceptance-field-values model)) value))
(defmethod field-cas ((model acceptance-field-model) field key old new)
  (let ((observed (field-read model field key)))
    (if (eql observed old)
        (progn (field-write model field key new) (values observed t))
        (values observed nil))))

(defun make-inline (&optional (model (make-instance 'acceptance-field-model)))
  (let ((value (make-instance 'inline-marks :domain (make-domain)
                              :model model :field :marks)))
    (initialize-component value (make-instance 'acceptance-resource-context))
    value))

(defun metadata-condition-p (thunk &optional class)
  (handler-case (progn (funcall thunk) nil)
    (clamsara::metadata-error (condition)
      (and (or (null class) (typep condition class)) condition))))

(defun test-two-side-representations ()
  (dolist (class '(side-marks clamsara::scalar-side-marks))
    (let ((marks (initialize-side class)))
      (check (= 0 (metadata-set-bit marks 4112))
             "~S first set did not return zero" class)
      (check (= 1 (metadata-set-bit marks 4112))
             "~S repeated set did not return one" class)
      (metadata-transfer marks 4112 marks 4128)
      (check (and (= 1 (metadata-ref marks 4112))
                  (= 1 (metadata-ref marks 4128)))
             "~S transfer cleared source or missed destination" class)
      (metadata-reset-range marks (cons 4096 4160))
      (check (= 0 (metadata-fold marks (cons 4096 4160) #'+ 0))
             "~S reset did not establish defaults" class)))
  t)

(defun test-empty-range-at-exact-limit ()
  ;; The paper explicitly admits END equal to a short/exact bound limit, and an
  ;; empty valid range visits nothing. LIMIT is not a scalar key.
  (let ((marks (initialize-side 'side-marks))
        (called nil))
    (check (eq :initial
               (metadata-fold marks (cons 4160 4160)
                              (lambda (value accumulator)
                                (declare (ignore value accumulator))
                                (setf called t)
                                :wrong)
                              :initial))
           "empty limit range changed fold result")
    (check (not called) "empty limit range invoked callback")
    (check (eq marks (metadata-reset-range marks (cons 4160 4160)))
           "empty reset did not return metadata"))
  t)

(defun test-invalid-range-preflight ()
  (let ((marks (initialize-side 'side-marks))
        (called nil))
    (metadata-set-bit marks 4112)
    (check (metadata-condition-p
            (lambda ()
              (metadata-fold marks (cons 4096 4113)
                             (lambda (value accumulator)
                               (declare (ignore value accumulator))
                               (setf called t)) nil))
            'clamsara::metadata-key-error)
           "misaligned bulk range did not reject")
    (check (and (not called) (= 1 (metadata-ref marks 4112)))
           "invalid bulk range called back or mutated state"))
  t)

(defun test-fold-callback-cannot-mutate-traversed-metadata ()
  (let ((marks (initialize-side 'side-marks)))
    (check (metadata-condition-p
            (lambda ()
              (metadata-fold marks (cons 4096 4112)
                             (lambda (value accumulator)
                               (declare (ignore value accumulator))
                               (metadata-set marks 4096 1)
                               nil)
                             nil))
            'clamsara::metadata-operation-error)
           "mutating fold callback was not rejected")
    (check (= 0 (metadata-ref marks 4096))
           "rejected fold callback left forbidden metadata mutation"))
  t)

(defun test-project-reducer-cannot-mutate-either-input ()
  (let ((source (initialize-side 'side-marks))
        (destination (initialize-side 'side-marks)))
    (check (metadata-condition-p
            (lambda ()
              (metadata-project source destination
                                (lambda (source-value destination-value)
                                  (declare (ignore source-value destination-value))
                                  (metadata-set source 4096 1)
                                  0)))
            'clamsara::metadata-operation-error)
           "mutating projection reducer was not rejected")
    (check (and (= 0 (metadata-ref source 4096))
                (= 0 (metadata-ref destination 4096)))
           "rejected projection reducer changed source or destination"))
  t)

(defun test-inline-interior-address-selects-containing-cell ()
  (let ((marks (make-inline)))
    (metadata-set marks 4113 1)
    (check (= 1 (metadata-ref marks 4112))
           "interior inline key did not select canonical containing cell")
    (check (= 1 (metadata-ref marks 4113))
           "interior inline read did not select containing cell"))
  t)

(defun test-inline-offer-must-prove-required-operations ()
  (let* ((model (make-instance 'acceptance-field-model
                               :legal nil :operations nil :orders nil))
         (marks (make-inline model)))
    ;; NIL capability sets prove no admitted legal value/operation/order. The
    ;; consumer cannot interpret missing evidence as wildcard support.
    (check (metadata-condition-p
            (lambda () (validate-component marks nil))
            'clamsara::metadata-invalid)
           "inline provider with no declared capabilities was admitted"))
  t)

(defun test-transfer-and-alias-preflight ()
  (let ((marks (initialize-side 'side-marks)))
    (metadata-set-bit marks 4096)
    (check (metadata-condition-p
            (lambda () (metadata-transfer marks 4096 marks 4096))
            'clamsara::metadata-alias-error)
           "same-cell transfer did not reject")
    (check (= 1 (metadata-ref marks 4096))
           "rejected same-cell transfer changed source"))
  t)

(defun call-test (name function failures)
  (handler-case (progn (funcall function) failures)
    (error (condition) (acons name condition failures))))

(defun run-metadata-safety-acceptance ()
  (let ((failures nil))
    (setf failures (call-test :two-side-representations
                              #'test-two-side-representations failures)
          failures (call-test :empty-limit-range
                              #'test-empty-range-at-exact-limit failures)
          failures (call-test :invalid-range-preflight
                              #'test-invalid-range-preflight failures)
          failures (call-test :fold-callback-guard
                              #'test-fold-callback-cannot-mutate-traversed-metadata
                              failures)
          failures (call-test :projection-callback-guard
                              #'test-project-reducer-cannot-mutate-either-input
                              failures)
          failures (call-test :inline-interior
                              #'test-inline-interior-address-selects-containing-cell
                              failures)
          failures (call-test :inline-capability-proof
                              #'test-inline-offer-must-prove-required-operations
                              failures)
          failures (call-test :transfer-preflight
                              #'test-transfer-and-alias-preflight failures))
    (when failures
      (error "v14 metadata acceptance failures: ~{~S: ~A~^; ~}"
             (loop for (name . condition) in (nreverse failures)
                   append (list name condition))))
    (values t :complete)))
