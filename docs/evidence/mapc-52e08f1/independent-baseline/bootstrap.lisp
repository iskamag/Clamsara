(require :asdf)
(asdf:initialize-source-registry
 '(:source-registry (:directory #p"/tmp/clamsara-gcbench-52e08f1-tfa6uf75/") :ignore-inherited-configuration))
(asdf:initialize-output-translations
 '(:output-translations (t ("/tmp/clamsara-gcbench-52e08f1-tfa6uf75/independent-review/gabriel-next/native-strict9-c2zybsxw/fasl/" :implementation)) :ignore-inherited-configuration))
(assert (equal (truename #p"/tmp/clamsara-gcbench-52e08f1-tfa6uf75/")
               (truename (asdf:system-source-directory :clamsara))))
(assert (not (equal (asdf:apply-output-translations #p"/one/package.fasl")
                    (asdf:apply-output-translations #p"/two/package.fasl"))))
(asdf:load-system :clamsara/workload)
(assert (equal (truename #p"/tmp/clamsara-gcbench-52e08f1-tfa6uf75/")
               (truename (asdf:system-source-directory :clamsara/workload))))
(assert (equal (truename #p"/home/iskam/quicklisp/local-projects/Maclina/")
               (truename (asdf:system-source-directory :maclina))))


;; Audit inherited helper names before loading any test definitions.
(let ((package (make-package "CLAMSARA.MAPC.STRICT.NAME-AUDIT"
                             :use '("COMMON-LISP" "CLAMSARA"))))
  (dolist (name '("*CASES*" "*CLOSURE-FORM*" "*ERROR-FORM*" "*MOVING-FORM*" "*NESTED-FORM*" "*OWNERS*" "*THROW-FORM*" "AUTOMATIC-MOVEMENT" "CHECK-DDERIV-LOAD" "CHECK-DESIGNATOR" "CHECK-DIRECT-EMPTY" "CHECK-ERROR" "CHECK-MOVING" "CHECK-RETRY" "CHECK-RETURNED-GRAPH" "CHECK-SEMANTICS" "CHECK-SINGLE-RESULT" "CHECK-THROW" "CLIENT" "CONS-FORM" "DESIGNATOR-CALLBACK" "DESIGNATOR-TOTAL" "ENV" "EXPECTED-MAPC-STOP" "FINISH-SUCCESS" "FULL-CYCLE" "GUEST-ENVIRONMENT" "NO-ACTIVE-SCOPES" "NOTE-PROBE-PHASE" "OWNER" "PROVIDER" "REGISTERS" "RUN-MAPC-STRICT-CASE" "SEMANTIC-FORM" "VM" "WRONG-HOST-DESIGNATOR"))
    (multiple-value-bind (symbol status) (find-symbol name package)
      (format t "~&STRICT9-NAME-AUDIT ~A ~S ~S~%" name status
              (and symbol (package-name (symbol-package symbol))))
      (assert (not (eq status :inherited)))))
(format t "~&STRICT9-OLD-PHASE-COLLISION ~S~%"
        (symbol-package (find-symbol "PHASE" "COMMON-LISP")))
(load #p"/tmp/clamsara-gcbench-52e08f1-tfa6uf75/independent-review/gabriel-next/mapc-strict-regression-v2.lisp")
(load #p"/tmp/clamsara-gcbench-52e08f1-tfa6uf75/independent-review/gabriel-next/native-strict9-c2zybsxw/runner.lisp")
