;;;; test/test-maclina.lisp -- optional Maclina workload integration.

(in-package #:clamsara-maclina)

(defun %load-maclina-source-file (pathname)
  "Evaluate each top-level form through Maclina, preserving source semantics."
  ;; ASDF may invoke TEST-OP with *PACKAGE* bound to an implementation
  ;; package.  Source symbols must nevertheless resolve in Maclina's package,
  ;; exactly as they do for an interactive source load.
  (let ((*package* (find-package '#:clamsara-maclina)))
    (with-open-file (stream pathname)
      (loop for form = (read stream nil :eof)
          until (eq form :eof)
            do (clamsara-maclina-eval form))))
  t)

(defun %boehm-fixture-path ()
  (asdf:system-relative-pathname
   :clamsara/maclina/test "test/fixtures/boehm-gc.lisp"))

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
    ;; CAR/CDR are mutator reads too.  A bare stale child (good colour 0)
    ;; must pass through the ZGC read barrier and heal the parent slots.
    (with-clamsara-maclina (:plan-type :zgcish :heap-size 4096)
      (let* ((vm clamsara:*clamsara-vm*)
             (plan clamsara:*clamsara-plan*)
             (client *clamsara-maclina-client*)
             (environment *clamsara-maclina-environment*)
             (parent (clamsara-maclina-eval-string
                      "(cons (cons 10 20) (cons 30 40))"))
             (parent-address (%reference-address vm parent))
             (old-car (clamsara:vm-object-reference vm parent-address 0))
             (old-cdr (clamsara:vm-object-reference vm parent-address 1))
             (new-car (clamsara::allocate-object
                       plan 2 :type-tag clamsara:+tag-cons+))
             (new-cdr (clamsara::allocate-object
                       plan 2 :type-tag clamsara:+tag-cons+))
             (car-fn (clostrum:fdefinition client environment 'cl:car))
             (cdr-fn (clostrum:fdefinition client environment 'cl:cdr)))
        (clamsara:vm-object-copy vm old-car new-car)
        (clamsara:vm-object-copy vm old-cdr new-cdr)
        (setf (aref (clamsara::vm-fwd-table vm) old-car) new-car
              (aref (clamsara::vm-fwd-table vm) old-cdr) new-cdr)
        (assert (= new-car (%reference-address vm (funcall car-fn parent))))
        ;; A headered object passes slot 0 at ADDRESS + 1 to the read
        ;; barrier; this diagnostic guards against clobbering its type word.
        (assert (= clamsara:+tag-cons+
                   (clamsara:vm-object-type-tag vm parent-address)))
        (assert (= new-cdr (%reference-address vm (funcall cdr-fn parent))))
        (assert (= new-car (clamsara:vm-object-reference vm parent-address 0)))
        (assert (= new-cdr (clamsara:vm-object-reference vm parent-address 1)))))
  ;; Load the real Boehm benchmark source, not a translated workload.  The
  ;; reduced depth keeps this optional test bounded while exercising simulated
  ;; structs, keyword constructors, arrays/floats, macros, cons allocation,
  ;; moving collections, and liveness assertions.
  (with-clamsara-maclina (:plan-type :semispace :heap-size 32768)
    (%load-maclina-source-file (%boehm-fixture-path))
    (assert (clamsara-maclina-eval '(gcbench 8)))
    (assert (plusp
             (clamsara:stats-get
              (clamsara:plan-stats clamsara:*clamsara-plan*)
              :gc-cycles))))
  t)
