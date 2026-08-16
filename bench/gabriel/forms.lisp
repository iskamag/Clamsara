;;;; bench/gabriel/forms.lisp -- a deliberately small, cons-only subset.
;;;
;;; These are Gabriel-*style* smoke workloads, not a port of the complete
;;; Gabriel benchmark suite.  Maclina's simulated values currently accept
;;; NIL, integers, and tagged simulated conses, so the list workload uses
;;; integer operator tags rather than symbols in its expression tree.

(in-package #:clamsara-gabriel-bench)

(defstruct (gabriel-workload
            (:constructor make-gabriel-workload (name source expected)))
  "One source string and its scalar expected result.

SOURCE is evaluated by Maclina, rather than by the host Lisp.  Keeping the
expected value scalar makes a result check independent of host printer and
host-list behavior."
  (name nil :type symbol)
  (source "" :type string)
  expected)

(defparameter *gabriel-workloads*
  (list
   (make-gabriel-workload
    :tak
    "(progn
       (defun tak (x y z)
         (if (< y x)
             (tak (tak (1- x) y z)
                  (tak (1- y) z x)
                  (tak (1- z) x y))
             z))
       (tak 12 6 0))"
    1)
   (make-gabriel-workload
    :destructive-cons
    "(let ((x (cons 1 (cons 2 (cons 3 nil))))
          (scratch nil))
       ;; Churn makes this a useful moving-collector smoke test as well as
       ;; checking RPLACA/RPLACD and subsequent CAR/CDR reads.
       (dotimes (i 1000)
         (setf scratch (cons i scratch)))
       (rplaca x 10)
       (rplacd (cdr x) (cons 40 nil))
       (+ (car x) (car (cdr x)) (car (cdr (cdr x)))))"
    52)
   (make-gabriel-workload
    :dderiv-like
    "(progn
       ;; A dderiv-shaped symbolic-list walk.  Operator tags are integers
       ;; (0 = addition, 1 = multiplication) because this supported Maclina
       ;; seam intentionally rejects symbols in simulated cons slots.
       (defun dderiv (a x)
         (cond ((not (consp a)) (if (= a x) 1 0))
               ((= (car a) 0)
                (list 0 (dderiv (car (cdr a)) x)
                         (dderiv (car (cdr (cdr a))) x)))
               ((= (car a) 1)
                (list 0
                      (list 1 (dderiv (car (cdr a)) x)
                               (car (cdr (cdr a))))
                      (list 1 (car (cdr a))
                               (dderiv (car (cdr (cdr a))) x))))
               (t 0)))
       ;; Fold the resulting simulated list to a scalar expected value.
       (defun checksum (a)
         (if (null a) 0
             (if (not (consp a)) a
                 (+ (checksum (car a)) (checksum (cdr a))))))
       (checksum
        (dderiv (list 0 (list 1 99 99) (list 1 3 99)) 99)))"
    307))
  "The small, supported Gabriel-style workload set.")
