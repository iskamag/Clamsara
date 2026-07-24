;;;; test/test-maclina.lisp -- optional Maclina workload integration.

(in-package #:clamsara-maclina)

(defun run-maclina-tests ()
  (with-clamsara-maclina (:plan-type :semispace :heap-size 4096)
    (assert (= 42 (clamsara-maclina-eval-string "(+ 20 22)")))
    (assert (= 50
               (clamsara-maclina-eval-string
                "(let ((x (cons 10 20)))
                   (rplaca x 30)
                   (+ (car x) (cdr x)))")))
    (assert
     (= 7
        (clamsara-maclina-eval-string
         "(let ((x (cons 0 -7)))
            (if (null (car x)) 100 (- (car x) (cdr x))))")))
    (let ((cell (clamsara-maclina-eval-string "(cons 1 2)")))
      (assert (clamsara:vm-valid-reference-p clamsara:*clamsara-vm* cell))
      (assert (= clamsara:+tag-cons+
                 (clamsara:vm-object-type-tag
                  clamsara:*clamsara-vm*
                  (%reference-address clamsara:*clamsara-vm* cell))))
      (assert
       (= 1
          (%decode-heap-value
           clamsara:*clamsara-vm*
           (clamsara:vm-object-reference
            clamsara:*clamsara-vm*
            (%reference-address clamsara:*clamsara-vm* cell)
            0))))
      (assert
       (= 2
          (%decode-heap-value
           clamsara:*clamsara-vm*
           (clamsara:vm-object-reference
            clamsara:*clamsara-vm*
            (%reference-address clamsara:*clamsara-vm* cell)
            1)))))
    ;; Keep X in a Maclina lexical cell while enough ephemeral conses force
    ;; semispace flips. The VM root scanner must rewrite X after evacuation.
    (assert
     (= 99
        (clamsara-maclina-eval-string
         "(let ((x (funcall (function cons) 99 nil))
                (scratch nil))
            (dotimes (i 2000)
              (setf scratch (funcall (function cons) i nil)))
            (car x))")))
    ;; A language integer equal to a live raw heap address is still an
    ;; immediate, not a conservative root. Force collections while that exact
    ;; integer is live in a Maclina lexical cell.
    (let* ((cell (clamsara-maclina-eval-string "(cons 11 12)"))
           (raw (%reference-address clamsara:*clamsara-vm* cell)))
      (assert
       (= raw
          (clamsara-maclina-eval
           `(let ((n ,raw)
                  (scratch nil))
              (dotimes (i 2000)
                (setf scratch (funcall (function cons) i nil)))
              n)))))
    (assert (plusp
             (clamsara:stats-get
              (clamsara:plan-stats clamsara:*clamsara-plan*)
              :gc-cycles))))
  t)
