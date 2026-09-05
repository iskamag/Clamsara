;;;; bench/gabriel/forms.lisp -- canonical benchmarks plus a cons-only style
;;; subset.
;;;
;;; The :tak and :takr workloads are the checked-in canonical Gabriel sources
;;; under bench/gabriel/reference/.  Every fresh Maclina environment loads the
;;; file itself, exactly like an interactive load, and the invocation runs at
;;; the canonical driver size.  They are not re-typed lookalikes.
;;;
;;; Canonical sources that cannot be added, and why (nothing is hidden):
;;;   ctak.cl -- loads and compiles, but the canonical invocation fails at
;;;     runtime: THROW unwinding into a CATCH that sits in a call-operand
;;;     position is broken in the current Maclina VM ("The value 7 is not of
;;;     type FUNCTION when binding MACLINA.VM-CROSS::CALLEE" at
;;;     (CTAK 18 12 6); also at (CTAK 2 1 0) and (CTAK 6 3 0), while
;;;     (CTAK 1 1 1) and body-position throws succeed).  Fixing that means
;;;     touching the VM, which is outside this benchmark's scope.
;;;   stak.cl -- cannot load: (PROCLAIM '(FIXNUM STAK-X STAK-Y STAK-Z)) makes
;;;     the Maclina/Extrinsicl PROCLAIM handler fall through its ECASE, which
;;;     supports only the declaration identifiers (DECLARATION INLINE
;;;     NOTINLINE SPECIAL OPTIMIZE TYPE FTYPE).
;;;   takl.cl -- cannot load: (DEFVAR 18L (LISTN 18)) needs
;;;     (SETF EXTRINSICL:SYMBOL-VALUE), which has no applicable method in the
;;;     run-time environment.  Independently, 18l/12l/6l would be simulated
;;;     references in global value cells, and the VM root scan covers only the
;;;     Maclina stack and value area, not global value cells: a global
;;;     simulated reference would not be enumerated as a root.  No workload
;;;     here reads those globals.
;;;
;;; The remaining entries stay Gabriel-style cons-churn smoke workloads, not
;;; canonical benchmarks.  Maclina's simulated values accept NIL, integers,
;;; and tagged simulated conses, so the symbolic workload uses integer
;;; operator tags rather than symbols in its expression tree.

(in-package #:clamsara-gabriel-bench)

(defstruct (gabriel-workload
            (:constructor make-gabriel-workload (name source expected)))
  "One source string and its scalar expected result.

SOURCE is evaluated by Maclina, rather than by the host Lisp.  Keeping the
expected value scalar makes a result check independent of host printer and
host-list behavior."
  (name nil :type symbol)
  (source "" :type string)
  expected)

(defstruct (canonical-gabriel-workload
            (:include gabriel-workload)
            (:constructor
             make-canonical-gabriel-workload
             (name reference-file source expected)))
  "A workload run from its checked-in canonical source.

REFERENCE-FILE names a file under bench/gabriel/reference/ that every fresh
Maclina environment loads before SOURCE -- the invocation form -- is
evaluated.  The expected value stays scalar: the canonical TAK-family
drivers return one fixnum, which the host compares with EQUAL, independent
of simulated-heap representation."
  (reference-file "" :type string))

(defun gabriel-workload-canonical-p (workload)
  "True when WORKLOAD runs a checked-in canonical source file."
  (typep workload 'canonical-gabriel-workload))

(defparameter *gabriel-workloads*
  (list
   (make-canonical-gabriel-workload
    :tak "tak.cl" "(tak 18 12 6)" 7)
   (make-canonical-gabriel-workload
    :takr "takr.cl" "(tak0 18 12 6)" 7)
   (make-gabriel-workload
    :destructive-cons
    "(let ((x (cons 1 (cons 2 (cons 3 nil))))
          (scratch nil))
       ;; Churn makes this a useful moving-collector smoke test as well as
       ;; checking RPLACA/RPLACD and subsequent CAR/CDR reads.
       (dotimes (i 1000)
         (setf scratch (cons i scratch)))
       (rplaca x 10)
       (rplacd (cdr x) (cons 40 nil))
       (+ (car x) (car (cdr x)) (car (cdr (cdr x)))))"
    52)
   (make-gabriel-workload
    :dderiv-like
    "(progn
       ;; A dderiv-shaped symbolic-list walk.  Operator tags are integers
       ;; (0 = addition, 1 = multiplication) because this supported Maclina
       ;; seam intentionally rejects symbols in simulated cons slots.
       (defun dderiv (a x)
         (cond ((not (consp a)) (if (= a x) 1 0))
               ((= (car a) 0)
                (list 0 (dderiv (car (cdr a)) x)
                         (dderiv (car (cdr (cdr a))) x)))
               ((= (car a) 1)
                (list 0
                      (list 1 (dderiv (car (cdr a)) x)
                               (car (cdr (cdr a))))
                      (list 1 (car (cdr a))
                               (dderiv (car (cdr (cdr a))) x))))
               (t 0)))
       ;; Fold the resulting simulated list to a scalar expected value.
       (defun checksum (a)
         (if (null a) 0
             (if (not (consp a)) a
                 (+ (checksum (car a)) (checksum (cdr a))))))
       (checksum
        (dderiv (list 0 (list 1 99 99) (list 1 3 99)) 99)))"
    307))
  "The supported workload set: canonical Gabriel TAK/TAKR plus style workloads.")

(defparameter *gabriel-canonical-skips*
  '((:name :ctak :reference-file "ctak.cl" :canonical t :status :skipped
     :missing-feature :catch-throw-call-operand-unwind
     :reason "Maclina mis-restores a CATCH/THROW result used as a call operand; (CTAK 18 12 6) reaches 7 but then binds 7 as MACLINA.VM-CROSS::CALLEE")
    (:name :stak :reference-file "stak.cl" :canonical t :status :skipped
     :missing-feature :variable-type-proclamation
     :reason "Extrinsicl PROCLAIM rejects the canonical (FIXNUM STAK-X STAK-Y STAK-Z) proclamation")
    (:name :takl :reference-file "takl.cl" :canonical t :status :skipped
     :missing-feature :enumerated-global-value-cell-roots
     :reason "(SETF EXTRINSICL:SYMBOL-VALUE) is absent and simulated global value cells are not enumerated as roots"))
  "Canonical checked-in sources not executed.  These machine-readable records
are part of the suite report; a skipped source is never counted as a passing
lookalike workload.")
