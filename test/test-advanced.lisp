;;;; test/test-advanced.lisp -- Iso (publication/DLG), ZGC (SATB+LVB+relocate),
;;;; Claimore (RC+nursery+checkpoint).  Plus barrier unit tests.

(in-package #:clamsara)

(defun %vm () *clamsara-vm*)
(defun %slot (a i) (vm-object-reference (%vm) a i))
(defun (setf %slot) (v a i) (setf (vm-object-reference (%vm) a i) v))

(deftest iso-publication-dlg ()
  (with-clamsara (:plan-type :iso :heap-size 65536)
    (let ((a (clamsara-allocate-object 2))
          (b (clamsara-allocate-object 1)))
      (setf (%slot a 0) b)
      (clamsara-register-root a)
      (let ((pub (clamsara-allocate-object 1)))
        (setf (vm-object-is-public-p (%vm) pub) t)
        (clamsara-write pub 0 a))   ; publication barrier publishes `a`
      (clamsara-gc)
      (let ((a2 (clamsara-root 0)))
        (if (and (plusp a2) (= (vm-object-reference-count (%vm) a2) 2)
                 (vm-object-is-public-p (%vm) a2))
            (values t "ok") (values nil "publication/DLG failed"))))))

(deftest zgc-relocate-heal ()
  (with-clamsara (:plan-type :zgcish :heap-size 65536)
    (let ((a (clamsara-allocate-object 3))
          (b (clamsara-allocate-object 2)))
      (setf (%slot a 0) b)
      (clamsara-register-root a)
      (clamsara-gc)
      (let ((a2 (clamsara-root 0)))
        (if (and (/= a2 a)
                 (/= (%slot a2 0) b)
                 (vm-valid-reference-p (%vm) a2)
                 (vm-valid-reference-p (%vm) (%slot a2 0))
                 (not (vm-object-start-p (%vm) a))
                 (not (vm-object-start-p (%vm) b)))
            (values t "ok") (values nil "relocate/heal failed"))))))

(deftest zgc-satb-remark-retains-snapshot-object ()
  (with-clamsara (:plan-type :zgcish :heap-size 65536)
    (let ((parent (clamsara-allocate-object 1))
          (snapshot-child (clamsara-allocate-object 0)))
      (setf (%slot parent 0) snapshot-child)
      (clamsara-register-root parent)
      ;; The SATB barrier records the overwritten child. It is absent from the
      ;; graph by the time root marking begins and must enter through remark.
      (clamsara-write parent 0 0)
      (plan-collect *clamsara-plan* :cycle-kind :full)
      (let* ((space (z-from *clamsara-plan*))
             (object-start (vm-object-start *clamsara-vm*))
             (live-count
               (loop for address from (space-base-address space)
                     below (space-end-address space)
                     count (s-test-bit object-start address))))
        (if (and (= live-count 2)
                 (not (vm-object-start-p *clamsara-vm* snapshot-child)))
            (values t "ok")
            (values nil "SATB remark did not retain/relocate snapshot child"))))))

(deftest claimore-major ()
  (with-clamsara (:plan-type :claimore :heap-size 65536)
    (let ((a (clamsara-allocate-object 2))
          (b (clamsara-allocate-object 1)))
      (setf (%slot a 0) b)
      (clamsara-register-root a)
      (clamsara-gc)
      (dotimes (i 3)
        (dotimes (j 40) (clamsara-allocate-object 3))
        (clamsara-gc))
      (clamsara-gc :cycle-kind :major)
      (let ((a2 (clamsara-root 0)))
        (if (and (plusp a2) (= (vm-object-reference-count (%vm) a2) 2))
            (values t "ok") (values nil "claimore major failed"))))))

(deftest barrier-card-rule ()
  ;; The card rule must actually dirty the source card on an old->young write,
  ;; not merely report the right trigger keyword.
  (let ((vm (make-simulator-vm 4096)))
    (vm-register-stratum vm :card (make-stratum :card (g-card) :bit 4096))
    (vm-register-stratum vm :age (make-stratum :age (g-word) :u4 4096))
    (let ((os (vm-object-start vm)))
      (s-set-bit os 512)                        ; "old" object
      (s-set-bit os 1024))                      ; "young" object
    (s-set (vm-stratum vm :age) 512 3)         ; aged => old
    (let ((rule (card-barrier-rule))
          (barrier (make-instance 'barrier :rules nil)))
      (funcall (barrier-rule-transfer rule) vm barrier 512 0 1024)
      (if (and (eq (barrier-rule-trigger rule) :ref-write)
               (s-test-bit (vm-stratum vm :card) 512))
          (values t "ok")
          (values nil "card rule did not dirty the source card")))))
