(require :asdf)
(asdf:initialize-source-registry '(:source-registry (:directory #p"/tmp/clamsara-shared-copy-integrated-_nomuxyd/") :ignore-inherited-configuration))
(asdf:initialize-output-translations '(:output-translations (t ("/tmp/clamsara-shared-copy-integration-f48l0iau/fasl/" :implementation)) :ignore-inherited-configuration))
(assert (not (equal (asdf:apply-output-translations #p"/one/package.fasl") (asdf:apply-output-translations #p"/two/package.fasl"))))
(assert (equal (truename #p"/tmp/clamsara-shared-copy-integrated-_nomuxyd/") (truename (asdf:system-source-directory :clamsara))))
(format t "~&SHARED-COPY-CANDIDATE-SOURCE ~A~%" (asdf:system-source-directory :clamsara))
(asdf:test-system :clamsara)
(format t "~&SHARED-COPY-MAIN-PASS~%")
(asdf:test-system :clamsara/tools/test)
(format t "~&SHARED-COPY-TOOLS-PASS~%")
(asdf:test-system :clamsara/generational/test)
(format t "~&SHARED-COPY-GENERATIONAL-PASS~%")
(asdf:test-system :clamsara/quality/generational/test)
(format t "~&SHARED-COPY-GENERATIONAL-QUALITY-PASS~%")
(asdf:load-system :clamsara/quality)
(let ((report (uiop:symbol-call :clamsara.structure :check-project-structure :include-optional-loaded t)))
  ;; Preserve a detailed diagnostic of the first runner's wrong mode.  This
  ;; does not make that failed run PASS or admit unloaded workload code.
  (with-open-file (stream #p"/tmp/clamsara-shared-copy-integration-f48l0iau/wrong-mode-diagnostic.sexp" :direction :output :if-exists :error)
    (uiop:symbol-call :clamsara.structure :write-structure-report report stream)))
(uiop:symbol-call :clamsara.structure :assert-project-structure)
(let ((files (uiop:symbol-call :clamsara.structure :%system-source-files :clamsara/generational #p"/tmp/clamsara-shared-copy-integrated-_nomuxyd/")))
  (assert (find (truename #p"/tmp/clamsara-shared-copy-integrated-_nomuxyd/src/runtime/generational.lisp") files :test #'equal :key #'truename))
  (uiop:symbol-call :clamsara.structure :assert-source-structure files
                    :expected-package (find-package :clamsara) :inspect-loaded t
                   :duplicate-whitelist
                   (symbol-value (find-symbol "*PROJECT-DUPLICATE-WHITELIST*" :clamsara.structure))
                   :foreign-method-whitelist
                   (symbol-value (find-symbol "*PROJECT-FOREIGN-METHOD-WHITELIST*" :clamsara.structure))))
(format t "~&SHARED-COPY-STRUCTURE-PASS~%")
(assert (not (find-package "MACLINA.MACHINE")))
(format t "~&SHARED-COPY-CORE-SUITES-COMPLETE~%")

(load #p"/tmp/clamsara-shared-copy-integrated-_nomuxyd/docs/evidence/shared-copy-04bff62/regression-source/copy-action-tests-v1.lisp")
(uiop:symbol-call :clamsara.copy-action.independent.v1 :run-focused-copy-tests)
(uiop:symbol-call :clamsara.quality.copy-action :run-copy-action-tests)
(format t "~&SHARED-COPY-INTEGRATION-ARCHIVE-REPEAT-PASS~%")
