(require :asdf)
(asdf:initialize-source-registry
 '(:source-registry (:directory #p"/tmp/clamsara-opaque-draft-8qjnkk81/") :ignore-inherited-configuration))
(asdf:initialize-output-translations
 '(:output-translations (t ("/tmp/clamsara-opaque-draft-8qjnkk81/independent-review/opaque-admission/fasl-01/" :implementation))
   :ignore-inherited-configuration))
(assert (equal (truename #p"/tmp/clamsara-opaque-draft-8qjnkk81/")
               (truename (asdf:system-source-directory :clamsara))))
(let ((left (asdf:apply-output-translations #p"/one/package.fasl"))
      (right (asdf:apply-output-translations #p"/two/package.fasl")))
  (format t "~&PRIVATE-OUTPUT-PATHS ~S ~S~%" left right)
  (assert (not (equal left right))))
(asdf:load-system :clamsara/quality/support)
(assert (equal (truename #p"/tmp/clamsara-opaque-draft-8qjnkk81/")
               (truename (asdf:system-source-directory :clamsara/quality/support))))
(format t "~&OPAQUE-DRAFT-ROOT ~A implementation=~A/~A~%"
        (asdf:system-source-directory :clamsara) (lisp-implementation-type)
        (lisp-implementation-version))
(load #p"/tmp/clamsara-cas-staged-yik9o9qk/independent-review/opaque-admission/acceptance-source-02.lisp")
(load #p"/tmp/clamsara-opaque-draft-8qjnkk81/independent-review/opaque-admission/additional-source-02.lisp")
(let ((success t))
  (dolist (call '((:clamsara.independent.opaque-admission :run-opaque-admission-tests)
                  (:clamsara.independent.opaque-edges :run-opaque-admission-edge-tests)))
    (handler-case
        (assert (apply #'uiop:symbol-call call))
      (error (condition)
        (setf success nil)
        (format t "~&OPAQUE-DRAFT-STRICT-ERROR ~S [~S] ~A~%" call (type-of condition) condition))))
  (let ((failed (symbol-value
                 (find-symbol "*FAILED-WORLDS*" :clamsara.independent.opaque-admission)))
        (rejected (symbol-value
                   (find-symbol "*REJECTED-BUILDS*" :clamsara.independent.opaque-admission))))
    (dolist (entry failed)
      (destructuring-bind (label world plan rule observation condition) entry
        (declare (ignore rule condition))
        (let* ((construction (and observation (clamsara.quality.support:observed-construction observation)))
               (configuration (and construction (clamsara::construction-configuration construction))))
          (format t "~&OPAQUE-DRAFT-RETAINED-FAIL ~S world=~S plan=~S config=~S construction=~S roots=~S~%"
                  label (not (null world)) (not (null plan))
                  (and configuration (clamsara::%configuration-state configuration))
                  (and construction (clamsara::%context-state construction))
                  (and world (clamsara::simulator-provider-token-active-p
                              (clamsara.quality.support:world-root-token world)))))))
    (format t "~&OPAQUE-DRAFT-RETENTION failed=~D rejected=~D published-failed=~D~%"
            (length failed) (length rejected) (count-if #'second failed))
    (when failed (setf success nil)))
  (uiop:quit (if success 0 1)))
