(in-package #:clamsara.tests)

(def-suite test-util :description "Test utilities"
  :in clamsara-tests)

(in-suite test-util)

(defun allocate-object (plan n-slots &key (type-tag +type-tag-object+))
  (let* ((vm (plan-vm plan))
         (total-words (1+ n-slots))
         (addr (plan-allocate plan total-words :default)))
    (when addr
      (setf (vm-object-header vm addr) (make-object-header n-slots :type-tag type-tag)))
    addr))

(defun allocate-cons (plan car cdr)
  (let* ((vm (plan-vm plan))
         (addr (plan-allocate plan 3 :default)))
    (when addr
      (setf (vm-object-header vm addr) (make-object-header 2 :type-tag +type-tag-cons+))
      (setf (vm-object-reference vm addr 0) car)
      (setf (vm-object-reference vm addr 1) cdr))
    addr))
