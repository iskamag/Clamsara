(require :asdf)
(asdf:initialize-source-registry
 '(:source-registry (:directory #p"/tmp/clamsara-list-baseline-1099d62-xzks71ws/") :ignore-inherited-configuration))
(asdf:initialize-output-translations
 '(:output-translations (t ("/tmp/clamsara-list-baseline-1099d62-xzks71ws/independent-review/finalizer-admission/finalizer-admission-native-ww84_306/fasl/" :implementation)) :ignore-inherited-configuration))
(assert (not (equal (asdf:apply-output-translations #p"/one/package.fasl")
                    (asdf:apply-output-translations #p"/two/package.fasl"))))
(assert (equal (truename #p"/tmp/clamsara-list-baseline-1099d62-xzks71ws/")
               (truename (asdf:system-source-directory :clamsara))))
(assert (equal (truename #p"/tmp/clamsara-list-baseline-1099d62-xzks71ws/")
               (truename (asdf:system-source-directory :clamsara/quality/support))))
(format t "~&FNA-SOURCE clamsara=~A support=~A~%"
        (asdf:system-source-directory :clamsara)
        (asdf:system-source-directory :clamsara/quality/support))
(asdf:load-system :clamsara/quality/support)
(format t "~&FNA-LOADED-SYSTEMS ~S~%" (asdf:already-loaded-systems))
(let ((forbidden (remove-if-not
                   (lambda (name)
                     (or (search "workload" name :test #'char-equal)
                         (search "maclina" name :test #'char-equal)))
                   (asdf:already-loaded-systems))))
  (format t "~&FNA-FORBIDDEN-SYSTEMS ~S machine-package=~S workload-package=~S~%"
          forbidden (not (null (find-package "MACLINA.MACHINE")))
          (not (null (find-package "CLAMSARA.WORKLOAD.MAPC.TEST"))))
  (assert (null forbidden)))
(load #p"/tmp/clamsara-list-baseline-1099d62-xzks71ws/independent-review/finalizer-admission/admission-baseline-draft-v1.lisp")
(load #p"/tmp/clamsara-list-baseline-1099d62-xzks71ws/independent-review/finalizer-admission/finalizer-admission-native-ww84_306/runner-v1.lisp")
