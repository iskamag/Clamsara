(require :asdf)
(asdf:initialize-source-registry
 '(:source-registry (:directory #p"/tmp/clamsara-mapc-draft-wd3ba0th/") :ignore-inherited-configuration))
(asdf:initialize-output-translations
 '(:output-translations (t ("/tmp/clamsara-mapc-draft-native-5t3q1ipj/fasl/" :implementation)) :ignore-inherited-configuration))
(assert (equal (truename #p"/tmp/clamsara-mapc-draft-wd3ba0th/")
               (truename (asdf:system-source-directory :clamsara))))
(assert (not (equal (asdf:apply-output-translations #p"/one/package.fasl")
                    (asdf:apply-output-translations #p"/two/package.fasl"))))
(asdf:load-system :clamsara/workload)
(assert (equal (truename #p"/tmp/clamsara-mapc-draft-wd3ba0th/")
               (truename (asdf:system-source-directory :clamsara/workload))))
(assert (equal (truename #p"/home/iskam/quicklisp/local-projects/Maclina/")
               (truename (asdf:system-source-directory :maclina))))


(load #p"/tmp/clamsara-dderiv-kernel-uffuyg9n/probe.lisp")
