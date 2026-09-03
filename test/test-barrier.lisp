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

(deftest rc-barrier-ignores-non-mature-target ()
  ;; A mature object may point into the nursery.  Such an edge is not part of
  ;; the mature hierarchy matrices (and must not be converted to a negative
  ;; mature block index).
  (let* ((vm (make-simulator-vm 4096))
         (nursery (make-instance 'immix-space :vm vm :start-page 0
                                 :page-count 1 :name :nursery))
         (mature (make-instance 'superblock-space :vm vm :start-page 1
                                :page-count 6 :name :mature
                                :block-words 512
                                :blocks-per-metablock 2
                                :metablocks-per-superblock 2))
         (source (space-base-address mature))
         (target (+ (space-base-address nursery) 17)))
    (superblock-note-write mature vm source target)
    (if (and (notany #'plusp (matrix-bits (aref (sb-mb-matrices mature) 0)))
             (notany #'plusp (matrix-bits (aref (sb-block-matrices mature) 0)))
             (zerop (sb-escape-value mature vm (sb-block-index mature source))))
        (values t "ok")
        (values nil "nursery target polluted mature hierarchy metadata"))))

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


;; ---- RC log lossless reservation (v11 execution-model: reserve for the
;; ---- whole event before exposure; never a partial record) ---------------

(defun %rc-test-rig ()
  "A hand-built plan over one superblock space for RC rule tests.
Geometry: 512-word blocks, 2x2 metablocks => 4-block (4-page) superblocks,
so blocks 0-3, 4-7, 8-11 are superblocks 0, 1, and 2."
  (let* ((heap (make-array 8704 :element-type '(unsigned-byte 64)
                           :initial-element 0))
         (vm (make-instance 'vm-binding :heap heap :heap-size 8704))
         (mature (make-instance 'superblock-space :vm vm :start-page 1
                                :page-count 16 :name :mature
                                :block-words 512
                                :blocks-per-metablock 2
                                :metablocks-per-superblock 2))
         (plan (make-instance 'plan :name :rc-rule-test :vm vm
                                    :spaces (list mature)))
         (barrier (make-instance 'barrier :plan plan
                                 :rules (list (rc-barrier-rule)))))
    (values vm plan mature barrier)))

(defun %rc-block-base (mature block-index)
  (+ (space-base-address mature) (* block-index 512)))

(deftest rc-log-delta-appends-whole-triples-or-nothing ()
  (let ((barrier (make-instance 'barrier)))
    ;; Room for exactly one triple: the append is complete.
    (setf (barrier-rc-buffer barrier)
          (make-array 3 :element-type 'fixnum :initial-element 0
                      :fill-pointer 0))
    (rc-log-delta barrier 7 99 -1)
    (unless (and (= (fill-pointer (barrier-rc-buffer barrier)) 3)
                 (= (aref (barrier-rc-buffer barrier) 0) 7)
                 (= (aref (barrier-rc-buffer barrier) 1) 99)
                 (= (aref (barrier-rc-buffer barrier) 2) -1))
      (return-from rc-log-delta-appends-whole-triples-or-nothing
        (values nil "single triple appended incompletely")))
    ;; Two tail slots left: a three-element triple must not be appended
    ;; partially; the declared failure leaves the log unchanged.
    (setf (barrier-rc-buffer barrier)
          (make-array 4 :element-type 'fixnum :initial-element 0
                      :fill-pointer 2))
    (let ((signalled nil))
      (handler-case (rc-log-delta barrier 8 100 -1)
        (heap-exhausted () (setf signalled t)))
      (unless (and signalled
                   (= (fill-pointer (barrier-rc-buffer barrier)) 2)
                   (zerop (aref (barrier-rc-buffer barrier) 2))
                   (zerop (aref (barrier-rc-buffer barrier) 3)))
        (return-from rc-log-delta-appends-whole-triples-or-nothing
          (values nil "partial triple appended")))
      ;; A full log: failure leaves the previous triple untouched.
      (setf (barrier-rc-buffer barrier)
            (make-array 3 :element-type 'fixnum :initial-element 0
                        :fill-pointer 0))
      (rc-log-delta barrier 7 99 -1)
      (setf signalled nil)
      (handler-case (rc-log-delta barrier 8 100 +1)
        (heap-exhausted () (setf signalled t)))
      (if (and signalled
               (= (fill-pointer (barrier-rc-buffer barrier)) 3)
               (= (aref (barrier-rc-buffer barrier) 0) 7)
               (= (aref (barrier-rc-buffer barrier) 1) 99)
               (= (aref (barrier-rc-buffer barrier) 2) -1))
          (values t "ok")
          (values nil "full-log failure signalled wrongly or corrupted log")))))

(deftest rc-write-event-cancels-same-target-replacement ()
  ;; Replacing an edge to X with another edge to X nets zero external
  ;; in-degree for X's superblock: the event records nothing.
  (multiple-value-bind (vm plan mature barrier) (%rc-test-rig)
    (declare (ignore plan))
    (let* ((src (%rc-block-base mature 0))   ; SB0
           (x1 (%rc-block-base mature 4))    ; SB1
           (x2 (%rc-block-base mature 5)))   ; SB1: same target superblock
      (vm-write-header vm src +tag-object+ 1)
      (vm-write-header vm x1 +tag-object+ 1)
      (vm-write-header vm x2 +tag-object+ 1)
      (setf (barrier-rc-buffer barrier)
            (make-array 6 :element-type 'fixnum :initial-element 0
                        :fill-pointer 0))
      (setf (vm-object-reference vm src 0) x1)
      (funcall (barrier-rule-transfer (first (barrier-rules barrier)))
               vm barrier src 0 x2)
      (if (zerop (fill-pointer (barrier-rc-buffer barrier)))
          (values t "ok")
          (values nil
                  (format nil "same-target replacement logged ~a elements"
                          (fill-pointer (barrier-rc-buffer barrier))))))))

(deftest rc-write-event-reserves-exact-capacity-for-two-records ()
  ;; A replacement whose old and new external targets differ records two
  ;; triples.  With capacity for exactly the whole event the event must
  ;; append COMPLETELY (one reservation, no per-record re-reservation), and
  ;; with one triple short it must fail before exposure with the log
  ;; unchanged.
  (multiple-value-bind (vm plan mature barrier) (%rc-test-rig)
    (declare (ignore plan))
    (let* ((src (%rc-block-base mature 0))   ; SB0
           (a   (%rc-block-base mature 4))   ; SB1
           (b   (%rc-block-base mature 8))   ; SB2
           (transfer (barrier-rule-transfer
                      (first (barrier-rules barrier)))))
      (vm-write-header vm src +tag-object+ 1)
      (vm-write-header vm a +tag-object+ 1)
      (vm-write-header vm b +tag-object+ 1)
      (setf (vm-object-reference vm src 0) a)
      ;; Exactly six free elements: the whole two-record event fits.
      (setf (barrier-rc-buffer barrier)
            (make-array 6 :element-type 'fixnum :initial-element 0
                        :fill-pointer 0))
      (funcall transfer vm barrier src 0 b)
      (let ((buf (barrier-rc-buffer barrier)))
        (unless (and (= (fill-pointer buf) 6)
                     (= (aref buf 0) 0) (= (aref buf 1) a)
                     (= (aref buf 2) -1)
                     (= (aref buf 3) 0) (= (aref buf 4) b)
                     (= (aref buf 5) +1))
          (return-from rc-write-event-reserves-exact-capacity-for-two-records
            (values nil "exact-capacity event did not append both records")))
        ;; One element short: after preloading one complete triple, five
        ;; elements remain, so the two-triple event must fail before exposure
        ;; with the first record intact and nothing else written.
        (setf (barrier-rc-buffer barrier)
              (make-array 8 :element-type 'fixnum :initial-element 0
                          :fill-pointer 0))
        (rc-log-delta barrier 0 a -1)
        (let ((signalled nil))
          (handler-case (funcall transfer vm barrier src 0 b)
            (heap-exhausted () (setf signalled t)))
          (let ((buf (barrier-rc-buffer barrier)))
            (if (and signalled
                     (= (fill-pointer buf) 3)
                     (= (aref buf 0) 0) (= (aref buf 1) a)
                     (= (aref buf 2) -1))
                (values t "ok")
                (values nil "short-capacity event tore the log"))))))))
