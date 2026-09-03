;;;; test/test-maclina.lisp -- optional Maclina workload integration.

(in-package #:clamsara-maclina)

(defun %load-maclina-source-file (pathname)
  "Evaluate each top-level form through Maclina, preserving source semantics."
  (load-maclina-source-file pathname))

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
  ;; structs, keyword constructors, simulated arrays/floats, macros, cons allocation,
  ;; moving collections, and liveness assertions.
  (with-clamsara-maclina (:plan-type :semispace :heap-size 32768)
    ;; The compatibility objects themselves must be simulator references,
    ;; rather than host vectors/structures hidden behind a passing API.
    (let ((array (clamsara-maclina-eval
                  '(make-array 3 :initial-element 7))))
      (assert (clamsara:vm-reference-p clamsara:*clamsara-vm* array))
      (assert (= clamsara:+tag-array+
                 (clamsara:vm-object-type-tag
                  clamsara:*clamsara-vm*
                  (%reference-address clamsara:*clamsara-vm* array))))
      (assert (= 3 (clamsara-maclina-eval `(length ,array))))
      (assert (= 7 (clamsara-maclina-eval `(aref ,array 0))))
      (assert (= 9
                 (clamsara-maclina-eval
                  `(progn (setf (aref ,array 1) 9)
                          (aref ,array 1))))))
    (clamsara-maclina-eval
     '(defstruct allocation-probe left right))
    (let ((node (clamsara-maclina-eval
                 '(make-allocation-probe :left 11 :right 22))))
      (assert (clamsara:vm-reference-p clamsara:*clamsara-vm* node))
      (assert (= clamsara:+tag-struct+
                 (clamsara:vm-object-type-tag
                  clamsara:*clamsara-vm*
                  (%reference-address clamsara:*clamsara-vm* node))))
      (assert (= 11 (clamsara-maclina-eval `(allocation-probe-left ,node)))))
    (%load-maclina-source-file (%boehm-fixture-path))
    (assert (clamsara-maclina-eval '(gcbench 8)))
    (assert (plusp
             (clamsara:stats-get
              (clamsara:plan-stats clamsara:*clamsara-plan*)
              :gc-cycles))))
  ;; Global variable cells are registered GC roots: a special variable
  ;; holding a simulated cons must survive moving collections.  This is the
  ;; property TAKL depends on (special-based list traversal under GC).
  (with-clamsara-maclina (:plan-type :semispace :heap-size 4096)
    (clamsara-maclina-eval-string
     "(defparameter *maclina-root-probe* (cons 7 8))")
    (let ((probe (clamsara-maclina-eval-string "*maclina-root-probe*")))
      (assert (clamsara:vm-reference-p clamsara:*clamsara-vm* probe))
      (clamsara-maclina-eval-string "(dotimes (i 3000) (cons i nil))")
      (assert (plusp
               (clamsara:stats-get
                (clamsara:plan-stats clamsara:*clamsara-plan*)
                :gc-cycles)))
      ;; Read through the registered global cell.  The host lexical PROBE is
      ;; deliberately not a simulated root and may contain a stale address.
      (assert (= 7 (clamsara-maclina-eval-string
                    "(car *maclina-root-probe*)")))))
  ;; ANSI proclamation shorthand: (PROCLAIM '(FIXNUM X)) is canonicalized to
  ;; (TYPE FIXNUM X) before the installed PROCLAIM sees it (STAK prerequisite).
  (with-clamsara-maclina (:plan-type :semispace :heap-size 4096)
    (clamsara-maclina-eval-string
     "(defparameter *maclina-proclaim-probe* 0)")
    (clamsara-maclina-eval-string
     "(proclaim '(fixnum *maclina-proclaim-probe*))")
    (assert (zerop (clamsara-maclina-eval-string "*maclina-proclaim-probe*"))))
  ;; Source-language LIST: macro expansion into nested simulated CONS,
  ;; the FUNCALL fallback, moving-GC survival, and (on SBCL) first-call and
  ;; repeated-call host-allocation measurements.
  (run-maclina-list-tests)
  t)

;; ---- source-language LIST: macro path, fallback, movement, allocation -----

#+sbcl
(sb-alien:define-alien-variable
    ("bytes_allocated" %list-test-bytes-allocated)
    sb-alien:unsigned-long)

#+sbcl
(defun %list-test-host-bytes (fn)
  "Host bytes consed by FN, with the thread allocation region closed around
the measured window so deferred region bumps become visible."
  (sb-vm::close-thread-alloc-region)
  (let ((before %list-test-bytes-allocated))
    (funcall fn)
    (sb-vm::close-thread-alloc-region)
    (- %list-test-bytes-allocated before)))

#+sbcl
(defun run-maclina-allocation-windows ()
  ;; Every allocation window runs against a VIRGIN environment inside a fresh
  ;; process: read, compile, link, and setup happen outside all windows, and
  ;; no seam function below is called before its "first" window.  The windows
  ;; call ordinary host functions DIRECTLY -- no reader, eval, compiler, or
  ;; dispatch work is measured.  The simulated CONS primitive, the CL:LIST
  ;; FUNCALL fallback, and the direct Maclina entry (the compiled %%list5 and
  ;; the runner seam CLAMSARA-MACLINA-COMPILE-STRING) are each asserted EXACT
  ;; zero on first invocation and on repeats.  Residual open CLOS dispatch is
  ;; not part of these windows; it is measured and labeled separately.
  (with-clamsara-maclina (:plan-type :semispace :heap-size 4096)
    (let ((client *clamsara-maclina-client*)
          (env *clamsara-maclina-environment*))
      ;; Substrate setup, not a language-seam call: one throwaway compiled
      ;; Maclina function runs once so interpreter machinery is warm before
      ;; the first language-level window.
      (let ((*package* (find-package '#:clamsara-maclina)))
        (clamsara-maclina-eval-string "(defun %%substrate-warmup () nil)")
        (funcall (clostrum:fdefinition client env '%%substrate-warmup)))
      ;; the ANSI seam is installed and the function cell is a genuine
      ;; function (FUNCALL/APPLY fallback)
      (assert (clostrum:compiler-macro-function client env 'cl:list))
      ;; simulated CONS primitive: genuinely first call, then repeats
      (let ((cons-fn (clostrum:fdefinition client env 'cl:cons)))
        (assert (functionp cons-fn))
        (let ((first (%list-test-host-bytes (lambda () (funcall cons-fn 1 2)))))
          (let ((repeated
                  (%list-test-host-bytes
                   (lambda () (dotimes (i 100) (funcall cons-fn 1 2))))))
            (assert (zerop first))
            (assert (zerop repeated))
            (format t "LIST-ALLOC: cons primitive first ~D B, 100 calls ~D B~%"
                    first repeated))))
      ;; CL:LIST function fallback: genuinely first call, then repeats
      (let ((list-fn (clostrum:fdefinition client env 'cl:list)))
        (assert (functionp list-fn))
        (let ((first (%list-test-host-bytes
                      (lambda () (funcall list-fn 1 2 3 4 5)))))
          (let ((repeated
                  (%list-test-host-bytes
                   (lambda ()
                     (dotimes (i 100)
                       (let ((x (funcall list-fn 1 2 3 4 5)))
                         (assert (clamsara:vm-reference-p
                                  clamsara:*clamsara-vm* x))))))))
            (assert (zerop first))
            (assert (zerop repeated))
            (format t "LIST-ALLOC: cl:list function first ~D B, 100 calls ~D B~%"
                    first repeated))))
      ;; Direct Maclina entry: a compiled function whose body is a source
      ;; LIST call.  Compile happens outside the window; the window wraps the
      ;; bound direct entry only.  First invocation and repeats are both
      ;; asserted zero: the substrate owns frames, dynamic environments,
      ;; argument marshalling, and multiple-value returns, so the interpreter
      ;; itself allocates no host objects.
      (let ((*package* (find-package '#:clamsara-maclina)))
        (clamsara-maclina-eval-string "(defun %%list5 () (list 1 2 3 4 5))"))
      (let ((list5 (clostrum:fdefinition client env '%%list5)))
        (assert (functionp list5))
        (let ((first (%list-test-host-bytes (lambda () (funcall list5)))))
          (let ((repeated
                  (%list-test-host-bytes
                   (lambda ()
                     (dotimes (i 100)
                       (let ((x (funcall list5)))
                         (assert (clamsara:vm-reference-p
                                  clamsara:*clamsara-vm* x))))))))
            (assert (zerop first))
            (assert (zerop repeated))
            (format t "LIST-ALLOC: %%list5 direct Maclina entry first ~D B, 100 calls ~D B~%"
                    first repeated))))
      ;; Runner seam: READ + COMPILE once at setup (outside the window); the
      ;; returned bound entry is called per iteration.  This is the shape
      ;; Gabriel/GCBench runners should use instead of EVAL-STRING.
      (let ((entry (clamsara-maclina-compile-string "(list 1 2 3 4 5)")))
        (assert (functionp entry))
        (let ((first (%list-test-host-bytes (lambda () (funcall entry)))))
          (let ((repeated
                  (%list-test-host-bytes
                   (lambda ()
                     (dotimes (i 100)
                       (let ((x (funcall entry)))
                         (assert (clamsara:vm-reference-p
                                  clamsara:*clamsara-vm* x))))))))
            (assert (zerop first))
            (assert (zerop repeated))
            (format t "LIST-ALLOC: compile-string bound entry first ~D B, 100 calls ~D B~%"
                    first repeated))))
      ;; Labeled and REPORTED, not asserted: one open CLOS dispatch per
      ;; iteration (clostrum:fdefinition is a generic function).  None of the
      ;; zero windows above contains a generic call; this keeps the isolated
      ;; dispatch cost visible and separate.
      (let ((clos-window
              (%list-test-host-bytes
               (lambda ()
                 (dotimes (i 100)
                   (clostrum:fdefinition client env 'cl:car))))))
        (format t "LIST-ALLOC: labeled open CLOS dispatch (clostrum:fdefinition, ~D B/100 calls, outside the zero windows)~%"
                clos-window)))
    t))

(defun run-maclina-list-tests ()
  ;; Allocation windows first, against a virgin environment: every "first"
  ;; window is the genuinely first invocation of its seam function in a
  ;; fresh process.  Earlier revisions measured "first" calls that the
  ;; preceding correctness evals had already warmed; that is corrected here.
  #+sbcl (run-maclina-allocation-windows)
  ;; Source-language LIST: the macro path builds nested simulated CONS; the
  ;; CL:LIST function cell remains the FUNCALL fallback; a macro-built list
  ;; survives moving collections; direct runtime conses no host bytes.
  (with-clamsara-maclina (:plan-type :semispace :heap-size 4096)
    (let ((vm clamsara:*clamsara-vm*))
      ;; Correctness: exact simulated-heap shape and values; empty form NIL.
      (assert (null (clamsara-maclina-eval-string "(list)")))
      (let ((l (clamsara-maclina-eval-string "(list 10 20 30)")))
        (assert (clamsara:vm-reference-p vm l))
        (assert (= clamsara:+tag-cons+
                   (clamsara:vm-object-type-tag
                    vm (%reference-address vm l))))
        (let ((a1 (%reference-address vm l)))
          (assert (= 10 (%decode-heap-value
                         vm (clamsara:vm-object-reference vm a1 0))))
          (let ((raw-cdr (clamsara:vm-object-reference vm a1 1)))
            (assert (clamsara:vm-reference-p vm raw-cdr))
            (let ((a2 (%reference-address vm raw-cdr)))
              (assert (= 20 (%decode-heap-value
                             vm (clamsara:vm-object-reference vm a2 0))))
              (let ((raw-cdr2 (clamsara:vm-object-reference vm a2 1)))
                (assert (clamsara:vm-reference-p vm raw-cdr2))
                (let ((a3 (%reference-address vm raw-cdr2)))
                  (assert (= 30 (%decode-heap-value
                                 vm (clamsara:vm-object-reference vm a3 0))))
                  (assert (zerop (clamsara:vm-object-reference vm a3 1)))))))))
      ;; FUNCALL fallback (host side): the function cell still works and
      ;; still returns simulated conses.
      (let ((list-fn (clostrum:fdefinition
                      *clamsara-maclina-client*
                      *clamsara-maclina-environment*
                      'cl:list)))
        (let ((l (funcall list-fn 5 6 7)))
          (assert (clamsara:vm-reference-p vm l))
          (assert (= 3 (clamsara-maclina-eval `(length ,l))))
          (assert (= 5 (clamsara-maclina-eval `(car ,l))))))
      ;; FUNCALL fallback (Maclina side): FUNCALL of the standard name.
      (assert (= 6 (clamsara-maclina-eval-string
                    "(let ((l (funcall (function list) 1 2 3)))
                       (+ (car l) (car (cdr l)) (car (cdr (cdr l)))))")))
      ;; Moving GC: a source-built list survives semispace flips and is
      ;; still an exact simulated chain afterwards.  The churn drops every
      ;; cons it builds (pure allocation pressure: ~9000 words through a
      ;; 4096-word heap forces several flips) so no dead scratch chain has
      ;; to fit a destination half.
      (let ((l (clamsara-maclina-eval-string
                "(let ((l (list 7 8 9)))
                   (dotimes (i 3000) (cons i nil))
                   l)")))
        (assert (plusp (clamsara:stats-get
                        (clamsara:plan-stats clamsara:*clamsara-plan*)
                        :gc-cycles)))
        (assert (clamsara:vm-reference-p vm l))
        (let ((sum 0) (addr (%reference-address vm l)))
          (dotimes (slot 3)
            (incf sum (%decode-heap-value
                       vm (clamsara:vm-object-reference vm addr 0)))
            (setf addr (clamsara:vm-object-reference vm addr 1)))
          (assert (= sum 24))))
      ;; Host-allocation windows live in RUN-MACLINA-ALLOCATION-WINDOWS,
      ;; which runs FIRST below against a virgin environment so every "first"
      ;; window is the genuinely first invocation of its seam function.
      t)))
