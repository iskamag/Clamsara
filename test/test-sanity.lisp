;;;; test/test-sanity.lisp -- the invariant checker catches corruption.

(in-package #:clamsara)

(deftest sanity-clean-heap ()
  (with-clamsara (:plan-type :marksweep :heap-size 32768)
    (let ((a (clamsara-allocate-object 2)))
      (clamsara-register-root a)
      (clamsara-gc))
    (if (null (sanity-check *clamsara-plan*)) (values t "ok")
        (values nil "false positives on a clean heap"))))

(deftest sanity-detects-stale-forwarding ()
  ;; plant a forwarding marker on a reachable object; the checker must flag it.
  (with-clamsara (:plan-type :marksweep :heap-size 32768)
    (let ((a (clamsara-allocate-object 1)))
      (clamsara-register-root a)
      (vm-set-location *clamsara-vm* :forwarding :in-header)
      (setf (vm-object-forwarding-pointer *clamsara-vm* a) 999)  ; stale
      (let ((errs (sanity-check *clamsara-plan* :check-mark nil)))
        (if (find-if (lambda (e) (search "forwarded" e)) errs)
            (values t "ok") (values nil "missed stale forwarding"))))))


(deftest sanity-detects-global-forwarding-entry ()
  ;; A stale off-heap entry can name an unreachable address, so checking only
  ;; the reachable walk is insufficient.
  (with-clamsara (:plan-type :marksweep :heap-size 32768)
    (let ((vm *clamsara-vm*))
      (vm-set-location vm :forwarding :off-heap)
      (setf (aref (vm-fwd-table vm) 123) 456)
      (let ((errs (sanity-check *clamsara-plan*
                                :check-mark nil :check-dlg nil :check-rc nil)))
        (if (find-if (lambda (e) (search "forwarding table" e)) errs)
            (values t "ok")
            (values nil "missed unreachable forwarding entry"))))))

(deftest sanity-claimore-hierarchy-clean ()
  (with-clamsara (:plan-type :claimore :heap-size 65536)
    (let ((errs (sanity-check *clamsara-plan*
                              :check-mark nil :check-dlg nil :check-fwd nil)))
      (if (null errs)
          (values t "ok")
          (values nil (format nil "false positive: ~{~a~^; ~}" errs))))))

(deftest sanity-detects-claimore-rc-corruption ()
  (with-clamsara (:plan-type :claimore :heap-size 65536)
    (let* ((mature (cl-mature *clamsara-plan*))
           (counts (sb-refcounts mature)))
      ;; SB 1 is present in the simulator-sized geometry but has no incoming
      ;; references.  A phantom count must not be silently accepted.
      (setf (aref counts (if (> (length counts) 1) 1 0)) 1)
      (let ((errs (sanity-check *clamsara-plan*
                                :check-mark nil :check-dlg nil :check-fwd nil)))
        (if (find-if (lambda (e) (search "hierarchical RC mismatch" e)) errs)
            (values t "ok")
            (values nil "missed hierarchical RC corruption"))))))

(deftest sanity-detects-claimore-matrix-and-escape-corruption ()
  (with-clamsara (:plan-type :claimore :heap-size 65536)
    (let* ((vm *clamsara-vm*)
           (mature (cl-mature *clamsara-plan*))
           (mb (aref (sb-mb-matrices mature) 0)))
      ;; Both regions are free.  A set relation or escape bit here is stale
      ;; metadata left behind by a broken release/reuse path.
      (matrix-set mb 0 1)
      (setf (sb-escape-value mature vm 0) +escape-to-foreign+)
      (let ((errs (sanity-check *clamsara-plan*
                                :check-mark nil :check-dlg nil :check-fwd nil
                                :check-rc nil)))
        (if (and (find-if (lambda (e) (search "matrix edge" e)) errs)
                 (find-if (lambda (e) (search "escape @ free block" e)) errs))
            (values t "ok")
            (values nil "missed hierarchical matrix/escape corruption"))))))
