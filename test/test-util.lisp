(in-package #:clamsara.tests)

(in-suite clamsara-tests)

;;; --- Shared allocation helpers ---

(defun allocate-object (plan n-slots &key (type-tag +type-tag-object+))
  (let* ((vm (plan-vm plan))
         (total-words (1+ n-slots))
         (addr (plan-allocate plan total-words :default)))
    (when addr
      (setf (vm-object-header vm addr)
            (make-object-header n-slots :type-tag type-tag)))
    addr))

(defun allocate-cons (plan car cdr)
  (let* ((vm (plan-vm plan))
         (addr (plan-allocate plan 3 :default)))
    (when addr
      (setf (vm-object-header vm addr)
            (make-object-header 2 :type-tag +type-tag-cons+))
      (setf (vm-object-reference vm addr 0) car)
      (setf (vm-object-reference vm addr 1) cdr))
    addr))

(defun allocate-fill (plan n-slots &rest values)
  "Allocate an object with N-SLOTS and fill reference slots with VALUES."
  (let ((addr (allocate-object plan n-slots)))
    (loop for v in values for i from 0
          do (setf (vm-object-reference (plan-vm plan) addr i) v))
    addr))

;;; --- Linked structure builders ---

(defun build-linked-list (plan n)
  "Build a singly-linked list of N cons cells. Returns the head."
  (let ((head nil))
    (dotimes (i n)
      (setf head (allocate-cons plan (1+ i) (or head 0))))
    head))

(defun linked-list-length (plan head)
  "Count elements in a linked list allocated by CLAMSARA."
  (let* ((vm (plan-vm plan))
         (len 0)
         (cur head))
    (loop while (and cur (not (zerop cur))
                     (vm-object-start-p vm cur)
                     (= (vm-object-type-tag vm cur) +type-tag-cons+))
          do (incf len)
             (setf cur (vm-object-reference vm cur 1)))
    len))

(defun linked-list-values (plan head)
  "Return a list of CAR values from a linked list."
  (let* ((vm (plan-vm plan))
         (vals nil)
         (cur head))
    (loop while (and cur (not (zerop cur))
                     (vm-object-start-p vm cur)
                     (= (vm-object-type-tag vm cur) +type-tag-cons+))
          do (push (vm-object-reference vm cur 0) vals)
             (setf cur (vm-object-reference vm cur 1)))
    (nreverse vals)))

(defun build-binary-tree (plan depth)
  "Build a binary tree of DEPTH levels. Each node is an object with
slot 0 = depth, slot 1 = left child, slot 2 = right child."
  (let ((addr (allocate-object plan 3)))
    (let ((vm (plan-vm plan)))
      (setf (vm-object-reference vm addr 0) depth)
      (when (> depth 0)
        (setf (vm-object-reference vm addr 1) (build-binary-tree plan (1- depth)))
        (setf (vm-object-reference vm addr 2) (build-binary-tree plan (1- depth)))))
    addr))

(defun verify-binary-tree (plan addr expected-depth)
  "Verify a binary tree's integrity. Returns T on success."
  (unless (and addr (not (zerop addr)) (vm-object-start-p (plan-vm plan) addr))
    (return-from verify-binary-tree nil))
  (let* ((vm (plan-vm plan))
         (depth (vm-object-reference vm addr 0)))
    (unless (= depth expected-depth)
      (return-from verify-binary-tree nil))
    (when (> depth 0)
      (unless (verify-binary-tree plan (vm-object-reference vm addr 1) (1- depth))
        (return-from verify-binary-tree nil))
      (unless (verify-binary-tree plan (vm-object-reference vm addr 2) (1- depth))
        (return-from verify-binary-tree nil)))
    t))

(defun tree-checksum (plan addr)
  "Compute a simple checksum of a binary tree for verification."
  (unless (and addr (not (zerop addr)) (vm-object-start-p (plan-vm plan) addr))
    (return-from tree-checksum 0))
  (let* ((vm (plan-vm plan))
         (depth (vm-object-reference vm addr 0))
         (left (vm-object-reference vm addr 1))
         (right (vm-object-reference vm addr 2)))
    (+ depth
       (if (> depth 0)
           (+ (tree-checksum plan left) (tree-checksum plan right))
           0))))

;;; --- Root helpers ---

(defun get-root-addr (plan)
  "After GC, get the first static root's forwarded address."
  (let* ((vm (plan-vm plan))
         (rs (vm-root-set vm))
         (root (first (rs-static-roots rs))))
    (or (vm-object-forwarding-pointer vm root) root)))

(defun clear-roots (plan)
  "Remove all registered roots."
  (let ((rs (vm-root-set (plan-vm plan))))
    (setf (rs-static-roots rs) nil)))
