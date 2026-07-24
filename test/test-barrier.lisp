;;;; test/test-barrier.lisp -- barrier rule constructors + fused note-write/read.

(in-package #:clamsara)

(deftest barrier-rule-constructors ()
  (let ((card (card-barrier-rule))
        (satb (satb-barrier-rule))
        (rc (rc-barrier-rule))
        (pub (publication-barrier-rule))
        (lvb (lvb-barrier-rule)))
    (if (and (eq (barrier-rule-trigger card) :ref-write)
             (eq (barrier-rule-trigger satb) :ref-write)
             (eq (barrier-rule-trigger rc) :ref-write)
             (eq (barrier-rule-trigger pub) :ref-write)
             (eq (barrier-rule-trigger lvb) :ref-read))
        (values t "ok") (values nil "rule triggers wrong"))))

(deftest barrier-fusion ()
  ;; a barrier with two write rules applies both on note-write
  (let* ((hits 0)
         (b (make-instance 'barrier
              :rules (list (make-barrier-rule :name :r1 :trigger :ref-write
                            :transfer (lambda (&rest args) (declare (ignore args)) (incf hits)))
                           (make-barrier-rule :name :r2 :trigger :ref-write
                            :transfer (lambda (&rest args) (declare (ignore args)) (incf hits)))))))
    (barrier-note-write (make-simulator-vm 1024) b 0 0 1)
    (if (= hits 2) (values t "ok") (values nil "fusion wrong"))))
