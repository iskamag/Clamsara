;;;; conditions.lisp -- condition types.

(in-package #:clamsara)

(define-condition clamsara-condition (condition) ())

(define-condition clamsara-error (error)
  ((message :initarg :message :reader clamsara-error-message))
  (:report (lambda (c s)
             (format s "Clamsara error: ~a" (clamsara-error-message c)))))

(define-condition heap-exhausted (clamsara-error)
  ((requested-size :initarg :requested-size :reader heap-exhausted-size)
   (space          :initarg :space :reader heap-exhausted-space))
  (:report (lambda (c s)
             (format s "Heap exhausted: cannot allocate ~d words in ~a"
                     (heap-exhausted-size c) (heap-exhausted-space c)))))

(define-condition plan-incompatible (clamsara-error)
  ((plan :initarg :plan :reader plan-incompatible-plan))
  (:report (lambda (c s)
             (format s "Plan incompatible: ~a"
                     (clamsara-error-message c)))))

(define-condition barrier-incompatible (clamsara-error)
  ((plan :initarg :plan :reader barrier-incompatible-plan))
  (:report (lambda (c s)
             (format s "Barrier incompatible: ~a"
                     (clamsara-error-message c)))))

(define-condition gc-phase-error (clamsara-error)
  ((phase :initarg :phase :reader gc-phase-error-phase))
  (:report (lambda (c s)
             (format s "GC phase error (~a): ~a"
                     (gc-phase-error-phase c)
                     (clamsara-error-message c)))))

(defmacro signal-clamsara (datum &rest args)
  `(error ,datum ,@args))
