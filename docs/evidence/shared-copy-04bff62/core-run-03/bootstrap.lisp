(require :asdf)
(asdf:initialize-source-registry '(:source-registry (:directory #p"/tmp/clamsara-shared-copy-04bff62-xzksq1om/") :ignore-inherited-configuration))
(asdf:initialize-output-translations '(:output-translations (t ("/tmp/clamsara-shared-copy-core3-cx0r1j_2/fasl/" :implementation)) :ignore-inherited-configuration))
(assert (not (equal (asdf:apply-output-translations #p"/one/package.fasl") (asdf:apply-output-translations #p"/two/package.fasl"))))
(assert (equal (truename #p"/tmp/clamsara-shared-copy-04bff62-xzksq1om/") (truename (asdf:system-source-directory :clamsara))))
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
  (with-open-file (stream #p"/tmp/clamsara-shared-copy-core3-cx0r1j_2/wrong-mode-diagnostic.sexp" :direction :output :if-exists :error)
    (uiop:symbol-call :clamsara.structure :write-structure-report report stream)))
(uiop:symbol-call :clamsara.structure :assert-project-structure)
(let ((files (uiop:symbol-call :clamsara.structure :%system-source-files :clamsara/generational #p"/tmp/clamsara-shared-copy-04bff62-xzksq1om/")))
  (assert (find (truename #p"/tmp/clamsara-shared-copy-04bff62-xzksq1om/src/runtime/generational.lisp") files :test #'equal :key #'truename))
  (uiop:symbol-call :clamsara.structure :assert-source-structure files
                    :expected-package (find-package :clamsara) :inspect-loaded t
                   :duplicate-whitelist
                   (symbol-value (find-symbol "*PROJECT-DUPLICATE-WHITELIST*" :clamsara.structure))
                   :foreign-method-whitelist
                   (symbol-value (find-symbol "*PROJECT-FOREIGN-METHOD-WHITELIST*" :clamsara.structure))))
(format t "~&SHARED-COPY-STRUCTURE-PASS~%")
(assert (not (find-package "MACLINA.MACHINE")))
(format t "~&SHARED-COPY-CORE-SUITES-COMPLETE~%")
