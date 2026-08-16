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

(deftest lvb-heals-forwarded-bare-t0-reference ()
  ;; A T0 VM has no colour protocol.  LVB must still consult the off-heap
  ;; forwarding table for a bare heap address.
  (let* ((heap (make-array 128 :element-type '(unsigned-byte 64)
                           :initial-element 0))
         (fwd (make-array 128 :element-type 'fixnum :initial-element 0))
         (vm (make-instance 'vm-binding :heap heap :heap-size 128
                            :fwd-table fwd))
         (barrier (make-barrier (lvb-barrier-rule)))
         (source 17)
         (destination 37)
         (slot-addr 9))
    (vm-set-location vm :forwarding :off-heap)
    (setf (aref fwd source) destination
          (ref-u64 vm slot-addr) source)
    (let ((healed (barrier-note-read vm barrier slot-addr source)))
      (if (and (= healed destination)
               (= (ref-u64 vm slot-addr) destination))
          (values t "ok")
          (values nil (format nil "bare T0 reference was not healed: ~a" healed))))))

(deftest lvb-heals-forwarded-good-colour-reference ()
  ;; A good-coloured pointer can still be stale when its slot was stored bare;
  ;; colour goodness must not skip the forwarding lookup.
  (let* ((vm (make-simulator-vm 1024))
         (barrier (make-barrier (lvb-barrier-rule)))
         (source 17)
         (destination 37)
         (slot-addr 9))
    (vm-set-location vm :forwarding :off-heap)
    (setf (aref (vm-fwd-table vm) source) destination)
    (let* ((reference (ref-set-colour vm source (vm-good-colour vm)))
           (healed (barrier-note-read vm barrier slot-addr reference)))
      (if (and (= (ref-strip vm healed) destination)
               (ref-good-colour-p vm healed)
               (= (ref-strip vm (ref-u64 vm slot-addr)) destination))
          (values t "ok")
          (values nil (format nil "good-coloured reference was not healed: ~a"
                              healed))))))


(deftest lvb-heals-bare-forwarded-reference ()
  ;; Bare heap words have the good colour, so an LVB must consult forwarding
  ;; even when the colour test says the value is already good.
  (let* ((vm (make-simulator-vm 4096))
         (barrier (make-instance 'barrier :rules (list (lvb-barrier-rule))))
         (old 512)
         (new 768)
         (slot 100))
    (vm-set-location vm :forwarding :off-heap)
    (setf (aref (vm-fwd-table vm) old) new
          (ref-u64 vm slot) old)
    (let ((healed (barrier-note-read vm barrier slot old)))
      (if (and (= healed new) (= (ref-u64 vm slot) new))
          (values t "ok")
          (values nil (format nil "bare LVB did not heal ~a -> ~a (slot ~a)"
                              old new (ref-u64 vm slot)))))))
