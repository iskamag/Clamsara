(in-package #:clamsara)

(define-condition heap-exhausted (error)
  ((plan :initarg :plan :initform nil :reader heap-exhausted-plan)
   (message :initarg :message :initform "Heap exhausted" :reader heap-exhausted-message))
  (:report (lambda (c s)
             (format s "Heap exhausted~@[ in plan ~A~]: ~A"
                     (when (heap-exhausted-plan c)
                       (plan-name (heap-exhausted-plan c)))
                     (heap-exhausted-message c)))))

(define-condition no-active-plan (error)
  ((message :initarg :message :initform "No active Clamsara plan" :reader no-active-plan-message))
  (:report (lambda (c s)
             (format s "~A" (no-active-plan-message c)))))

(define-condition queue-overflow (error)
  ((message :initarg :message :initform "Work queue overflow" :reader queue-overflow-message))
  (:report (lambda (c s)
             (format s "~A" (queue-overflow-message c)))))
