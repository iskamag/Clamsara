(require :asdf)
(asdf:initialize-source-registry
 '(:source-registry (:directory #p"/tmp/clamsara-gcbench-52e08f1-tfa6uf75/") :ignore-inherited-configuration))
(asdf:initialize-output-translations
 '(:output-translations (t ("/tmp/clamsara-mapc-parent-red-c0rz4slu/fasl/" :implementation)) :ignore-inherited-configuration))
(assert (equal (truename #p"/tmp/clamsara-gcbench-52e08f1-tfa6uf75/")
               (truename (asdf:system-source-directory :clamsara))))
(assert (not (equal (asdf:apply-output-translations #p"/one/package.fasl")
                    (asdf:apply-output-translations #p"/two/package.fasl"))))
(asdf:load-system :clamsara/workload)
(assert (equal (truename #p"/tmp/clamsara-gcbench-52e08f1-tfa6uf75/")
               (truename (asdf:system-source-directory :clamsara/workload))))
(assert (equal (truename #p"/home/iskam/quicklisp/local-projects/Maclina/")
               (truename (asdf:system-source-directory :maclina))))

(load #p"/tmp/clamsara-mapc-parent-red-c0rz4slu/cases.lisp")
