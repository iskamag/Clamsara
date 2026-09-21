(require :asdf)
(asdf:initialize-source-registry
 '(:source-registry (:directory #p"/tmp/clamsara-mapc-draft-wd3ba0th/") :ignore-inherited-configuration))
(asdf:initialize-output-translations
 '(:output-translations (t ("/tmp/clamsara-gcbench-52e08f1-tfa6uf75/independent-review/gabriel-next/capacity-native-v3-y4t009zr/fasl/" :implementation)) :ignore-inherited-configuration))
(assert (equal (truename #p"/tmp/clamsara-mapc-draft-wd3ba0th/")
               (truename (asdf:system-source-directory :clamsara))))
(assert (not (equal (asdf:apply-output-translations #p"/one/package.fasl")
                    (asdf:apply-output-translations #p"/two/package.fasl"))))
(asdf:load-system :clamsara/workload)
(assert (equal (truename #p"/tmp/clamsara-mapc-draft-wd3ba0th/")
               (truename (asdf:system-source-directory :clamsara/workload))))
(assert (equal (truename #p"/home/iskam/quicklisp/local-projects/Maclina/")
               (truename (asdf:system-source-directory :maclina))))


(let ((p (make-package "CAPACITY.V3.NAME-AUDIT" :use '("COMMON-LISP" "CLAMSARA"))))
  (dolist (name '("*CAP-ACTIVE*" "*CAP-CONSTRUCTING*" "*CAP-COUNT-EFFECTS*" "*CAP-ENTRY-WITNESS-ENABLED*" "*CAP-OWNERS*" "*CAP-WITNESS*" "CAP-CALIBRATE" "CAP-CALLBACK-FORM" "CAP-CENSUS-CLEAN" "CAP-CHECK-RECOVERY-LIST" "CAP-CLIENT" "CAP-ENTRY-WITNESS" "CAP-ENV" "CAP-EXPECT-REJECTION" "CAP-FINISH" "CAP-FN" "CAP-FSET" "CAP-FULL-CYCLE" "CAP-GUARD" "CAP-GUEST" "CAP-INNER-ATTEMPT" "CAP-METRICS" "CAP-NEW" "CAP-NOTE" "CAP-OBSERVED-MAPC" "CAP-OBSERVER-SELF-CHECK" "CAP-OWNER" "CAP-PREPARE" "CAP-RECORD-ROW" "CAP-RUN-BOUNDARY-MATRIX" "CAP-RUN-NESTED-REJECTION" "CAP-RUN-POST-OUTER-NONEMPTY-RECOVERY" "CAP-RUN-SMALLER-NONEMPTY-RECOVERY" "CAP-RUN-SNAPSHOT-WITNESS" "CAP-STATE" "CAP-UNCHANGED-P" "CAP-UNEXPECTED-CALLBACK" "CAP-VM" "CAP-WITH-FIXTURE-METHODS" "CAP-WITH-UNIQUE-METHOD"))
    (multiple-value-bind (symbol status) (find-symbol name p)
      (format t "~&CAP3-NAME-AUDIT ~A ~S ~S~%" name status
              (and symbol (package-name (symbol-package symbol))))
      (assert (not (eq status :inherited))))))
(load #p"/tmp/clamsara-gcbench-52e08f1-tfa6uf75/independent-review/gabriel-next/capacity-strengthening-v3/capacity-ownership-v3.lisp")
(load #p"/tmp/clamsara-gcbench-52e08f1-tfa6uf75/independent-review/gabriel-next/capacity-native-v3-y4t009zr/runner.lisp")
