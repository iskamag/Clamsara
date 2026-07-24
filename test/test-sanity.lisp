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
