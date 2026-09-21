(require :asdf)
(asdf:initialize-source-registry
 '(:source-registry (:directory #p"/tmp/clamsara-gcbench-52e08f1-tfa6uf75/") :ignore-inherited-configuration))
(asdf:initialize-output-translations
 '(:output-translations (t ("/tmp/clamsara-gcbench-current-native-o0sjay3_/fasl/" :implementation)) :ignore-inherited-configuration))
(assert (equal (truename #p"/tmp/clamsara-gcbench-52e08f1-tfa6uf75/")
               (truename (asdf:system-source-directory :clamsara))))
(assert (not (equal (asdf:apply-output-translations #p"/one/package.fasl")
                    (asdf:apply-output-translations #p"/two/package.fasl"))))
(asdf:load-system :clamsara/workload)
(assert (equal (truename #p"/tmp/clamsara-gcbench-52e08f1-tfa6uf75/")
               (truename (asdf:system-source-directory :clamsara/workload))))
(assert (equal (truename #p"/home/iskam/quicklisp/local-projects/Maclina/")
               (truename (asdf:system-source-directory :maclina))))
(format t "~&GCBENCH-CURRENT-PROVENANCE head=52e08f118de9c121a5b9c81cbfb2bb843c117c53 clamsara=~A maclina=~A~%"
        (asdf:system-source-directory :clamsara) (asdf:system-source-directory :maclina))
(load #p"/tmp/clamsara-gcbench-52e08f1-tfa6uf75/tools/run-gcbench.lisp")
(format t "~&GCBENCH-CURRENT-STRICT-RUNNER-RETURNED~%")
