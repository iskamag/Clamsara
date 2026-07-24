;;;; test/test-heap.lisp -- allocator + space protocol unit tests.

(in-package #:clamsara)

(deftest free-list-allocator ()
  (let ((a (make-instance 'free-list-allocator :start 100 :limit 100000))
        addrs)
    (dotimes (i 300)
      (let ((x (alloc a 6)))
        (unless x (return-from free-list-allocator (values nil "alloc failed")))
        (push x addrs)))
    (dolist (x (nreverse addrs)) (free a x 6))
    (if (alloc a 6) (values t "ok") (values nil "realloc failed"))))

(deftest bump-allocator ()
  (let ((a (make-instance 'bump-allocator :start 0 :limit 1000)))
    (alloc a 10) (alloc a 20)
    (if (= (ba-cursor a) 30) (values t "ok") (values nil "bump wrong"))))

(deftest space-contains ()
  (let* ((vm (make-simulator-vm 8192))
         (s (make-instance 'mark-sweep-space :vm vm :start-page 1
                          :page-count 4 :name :t)))
    (if (and (space-contains-p s (ash 1 +log-page-words+))
             (not (space-contains-p s (ash 6 +log-page-words+))))
        (values t "ok") (values nil "contains wrong"))))
