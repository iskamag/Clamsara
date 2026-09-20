;;;; Managed bignum payload, primitive boundaries, and moving collections.
(defpackage #:clamsara.workload.numbers.test
  (:use #:cl #:clamsara)
  (:export #:run-workload-number-tests))
(in-package #:clamsara.workload.numbers.test)

(defun full-cycle (runtime)
  (let ((record (make-cycle-result-record (clamsara::workload-runtime-plan runtime))))
    (collect (clamsara::workload-runtime-configuration runtime) :all :explicit record)
    (assert (eq :complete (cycle-result-status record)))
    record))

(defun decoded (env value)
  (if (clamsara::%guest-bignum-p env value)
      (clamsara::%guest-bignum->host env value) value))

(defun check-representation (env value expected)
  (assert (workload-reference-p env value))
  (assert (not (typep value 'bignum)))
  (assert (clamsara::%guest-bignum-p env value))
  (assert (not (clamsara::%guest-array-p env value)))
  (assert (= expected (decoded env value)))
  (assert (= (object-size (workload-model env) value)
             (+ 16 (* 8 (1+ (ceiling (integer-length (abs expected)) 30))))))
  (let ((count (/ (- (object-size (workload-model env) value) 16) 8))
        (strong 0))
    (assert (= (if (minusp expected) -1 1) (clamsara::%bignum-word env value 0)))
    (loop for i from 1 below count
          do (assert (typep (clamsara::%bignum-word env value i) '(unsigned-byte 30))))
    (map-reference-locations
     (workload-model env) value
     (lambda (identity location) (declare (ignore identity location)) (incf strong)))
    (assert (zerop strong))
    ;; The model's numeric-word boundary still rejects a host bignum and a
    ;; managed reference; neither rejection may alter the payload.
    (let ((old (clamsara::%bignum-word env value 1)))
      (dolist (bad (list expected value))
        (assert (handler-case
                    (progn (clamsara::%set-bignum-word env value 1 bad) nil)
                  (error () t)))
        (assert (eql old (clamsara::%bignum-word env value 1))))))
  t)

(defun run-workload-number-tests ()
  (let* ((rt (make-workload-runtime :extent 16384 :max-object-bytes 8192 :root-capacity 512))
         (env (clamsara::workload-runtime-environment rt))
         (checks 0))
    (unwind-protect
         (flet ((check (condition) (incf checks) (assert condition)))
           ;; Native arithmetic is the oracle. Guest source contains immediate
           ;; integers only; the large results must be managed representations.
           (dolist (form '((* 20000000000 20000000000)
                           (- (expt 2 190)) (+ (expt 2 130) (expt 2 65) 1)
                           (expt 10 90) (ash -1 200)))
             (check-representation env (workload-eval env form) (eval form))
             (incf checks))
           (dolist (form '((+ (expt 2 150) (expt 3 100))
                           (- (expt 2 150) (expt 3 100))
                           (* (- (expt 2 90)) (expt 3 70))
                           (/ (expt 2 100) (expt 2 90))
                           (+ most-positive-fixnum 1)
                           (- most-negative-fixnum 1)
                           (- (+ most-positive-fixnum 1) 1)
                           (+ (- most-negative-fixnum 1) 1)
                           (1+ (expt 2 130)) (1- (- (expt 2 130)))
                           (abs (- (expt 2 130))) (signum (- (expt 2 130)))
                           (min (expt 2 130) (expt 2 131))
                           (max (expt 2 130) (expt 2 131))
                           (floor (- (expt 10 100)) (+ (expt 10 40) 7))
                           (truncate (- (expt 10 100)) (+ (expt 10 40) 7))
                           (ceiling (expt 10 100) (+ (expt 10 40) 7))
                           (round (expt 10 100) (+ (expt 10 40) 7))
                           (mod (expt 10 100) (+ (expt 10 40) 7))
                           (rem (- (expt 10 100)) (+ (expt 10 40) 7))
                           (gcd (expt 10 90) (expt 2 100))
                           (lcm (expt 10 90) (expt 2 100))
                           (logand (expt 2 90) -1)
                           (logior (expt 2 90) 1) (logxor (expt 2 90) -1)
                           (lognot (expt 2 100)) (ash (expt 3 120) -65)
                           (integer-length (expt 3 120)) (logcount (expt 3 120))
                           (logbitp 130 (expt 2 130))))
             (let* ((expected (multiple-value-list (eval form)))
                    (actual (multiple-value-list (workload-eval env form))))
               (check (equal expected (mapcar (lambda (x) (decoded env x)) actual)))))
           (dolist (form '((let ((x (expt 2 100)))
                            (and (numberp x) (realp x) (rationalp x) (integerp x)
                                 (not (floatp x)) (not (complexp x)) (plusp x)
                                 (not (zerop x)) (evenp x) (oddp (1+ x))
                                 (typep x 'bignum) (typep x 'integer)
                                 (typep x '(unsigned-byte 101))
                                 (eq (type-of x) 'bignum)))
                           (eql (expt 2 100) (expt 2 100))
                           (equal (cons (expt 2 100) nil) (cons (expt 2 100) nil))
                           (not (eql (expt 2 100) (expt 2 101)))
                           (not (eql (expt 2 100) 0))
                           (not (eql 0 (expt 2 100)))
                           (not (numberp (cons nil nil)))
                           (not (null (member (expt 2 100) (cons (expt 2 100) nil))))
                           (= 17 (cdr (assoc (expt 2 100)
                                            (cons (cons (expt 2 100) 17) nil))))
                           (= (- (expt 2 100) (expt 2 100)) 0)))
             (check (workload-eval env form)))
           ;; Source arithmetic remains host syntax computation, not guest data.
           (workload-eval env '(defmacro numeric-macro ()
                                (if (= (expt 2 100) (expt 2 100)) 17 23)))
           (check (= 17 (workload-eval env '(numeric-macro))))
           (dolist (form (list (expt 2 100) (list 'quote (expt 2 100))))
             (check (handler-case (progn (workload-eval env form) nil)
                      (workload-capability-error (condition)
                        (eq 'clamsara::numeric-literal
                            (clamsara::workload-error-operation condition))))))
           (check (handler-case (progn (workload-eval env '(/ 1 3)) nil)
                    (workload-capability-error () t)))
           (check (handler-case (progn (workload-eval env '(expt 2 40000)) nil)
                    (workload-allocation-error () t)))
           (check (= 5 (workload-eval env '(+ 2 3))))
           ;; Two conses share one large integer; only three objects may move.
           (let* ((value (workload-eval env '(let ((x (expt 3 150)))
                                             (cons x (cons x nil)))))
                  (before (workload-read-slot env value :car))
                  (record (full-cycle rt))
                  (vm (clamsara::workload-provider-vm
                       (clamsara::workload-runtime-root-provider rt)))
                  (after-list (car (maclina.vm-cross::vm-values vm)))
                  (after (workload-read-slot env after-list :car)))
             (check (= 3 (cycle-result-count record :objects-moved)))
             (check (not (eq before after)))
             (check (eq after (workload-read-slot
                              env (workload-read-slot env after-list :cdr) :car)))
             (check-representation env after (expt 3 150))
             (check (handler-case (progn (decoded env before) nil) (error () t))))
           ;; Arithmetic and native predicates must work on corrected values.
           (check (= 2 (workload-eval
                        env '(let ((x (expt 2 100)))
                               (dotimes (i 600) (cons nil nil))
                               (if (and (integerp x) (= (+ x x) (* x 2))) 2 0)))))
           (check (eq :complete
                      (cycle-result-status
                       (clamsara::%plan-automatic-result
                        (clamsara::workload-runtime-plan rt)))))
           (workload-eval env nil)
           (check (zerop (cycle-result-count (full-cycle rt) :objects-discovered)))
           ;; Exact 16KiB geometry leaves 832 bytes after argument evaluation
           ;; and 353 discarded conses. Boxing the quotient fills that space;
           ;; boxing the remainder must collect and correct the saved quotient.
           (let ((answers
                   (multiple-value-list
                    (workload-eval
                     env '(let* ((b (expt 2 1600))
                                 (a (+ (* b (expt 2 3000)) (expt 2 1500))))
                            (dotimes (i 353) (cons nil nil))
                            (floor a b))))))
             (check (equal (list (expt 2 3000) (expt 2 1500))
                           (mapcar (lambda (value) (decoded env value)) answers)))
             (let ((automatic (clamsara::%plan-automatic-result
                               (clamsara::workload-runtime-plan rt))))
               (check (eq :complete (cycle-result-status automatic)))
               (check (= 3 (cycle-result-count automatic :objects-moved)))
               (format t "WORKLOAD-NUMBERS quotient/remainder moved=~D bytes=~D~%"
                       (cycle-result-count automatic :objects-moved)
                       (cycle-result-count automatic :bytes-moved))))
           (workload-eval env nil)
           (check (zerop (cycle-result-count (full-cycle rt) :objects-discovered))))
      (workload-eval env nil)
      (close-workload-runtime rt))
    (format t "WORKLOAD-NUMBERS: ~D checks passed~%" checks)
    t))
