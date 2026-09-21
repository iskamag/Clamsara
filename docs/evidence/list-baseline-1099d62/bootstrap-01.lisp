(require :asdf)
(defun baseline-check-pins ()
  (uiop:run-program (list "sha256sum" "--quiet" "--check" "/tmp/clamsara-mapc-draft-wd3ba0th/independent-review/list-rest-next/list-native-v2-baseline-95p03oqo/pins.sha256")
                    :output *standard-output* :error-output *error-output*)
  (assert (string= "d92e9254b45da4e508503b984f02403c6fb6677a"
                  (string-trim '(#\Newline #\Return)
                    (uiop:run-program '("git" "-C" "/home/iskam/quicklisp/local-projects/Maclina" "rev-parse" "HEAD") :output :string))))
  (assert (string= "" (uiop:run-program
    '("git" "-C" "/home/iskam/quicklisp/local-projects/Maclina" "status" "--porcelain" "--untracked-files=all") :output :string))))
(baseline-check-pins)
(asdf:initialize-source-registry
 '(:source-registry (:directory #p"/tmp/clamsara-list-baseline-1099d62-xzks71ws/") :ignore-inherited-configuration))
(asdf:initialize-output-translations
 '(:output-translations (t ("/tmp/clamsara-mapc-draft-wd3ba0th/independent-review/list-rest-next/list-native-v2-baseline-95p03oqo/fasl/" :implementation)) :ignore-inherited-configuration))
(assert (equal (truename #p"/tmp/clamsara-list-baseline-1099d62-xzks71ws/")
               (truename (asdf:system-source-directory :clamsara))))
(assert (not (equal (asdf:apply-output-translations #p"/one/package.fasl")
                    (asdf:apply-output-translations #p"/two/package.fasl"))))
(unwind-protect
    (progn
      (asdf:load-system :clamsara/workload)
      (assert (equal (truename #p"/tmp/clamsara-list-baseline-1099d62-xzks71ws/")
                     (truename (asdf:system-source-directory :clamsara/workload))))
      (assert (equal (truename #p"/home/iskam/quicklisp/local-projects/Maclina/")
                     (truename (asdf:system-source-directory :maclina))))
      (format t "~&LIST-BASELINE-SOURCE ~S WORKLOAD ~S MACLINA ~S~%"
              (asdf:system-source-directory :clamsara)
              (asdf:system-source-directory :clamsara/workload)
              (asdf:system-source-directory :maclina))
      (load #p"/tmp/clamsara-mapc-draft-wd3ba0th/independent-review/list-rest-next/regression-draft-v2-construction.lisp")
      (format t "~&LIST-BASELINE-V2-LOADED~%")
      (load #p"/tmp/clamsara-mapc-draft-wd3ba0th/independent-review/list-rest-next/list-native-v2-baseline-95p03oqo/runner-01.lisp"))
  ;; Only external pins/cleanliness checks, never runtime cleanup on failure.
  (baseline-check-pins)
  (format t "~&LIST-BASELINE-POST-PINS-OK~%"))
