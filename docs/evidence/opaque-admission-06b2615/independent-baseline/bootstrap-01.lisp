(require :asdf)
(asdf:initialize-source-registry
 '(:source-registry (:directory #p"/tmp/clamsara-cas-staged-yik9o9qk/") :ignore-inherited-configuration))
(asdf:initialize-output-translations
 '(:output-translations (t ("/tmp/clamsara-cas-staged-yik9o9qk/independent-review/opaque-admission/fasl-01/" :implementation))
   :ignore-inherited-configuration))
(assert (equal (truename #p"/tmp/clamsara-cas-staged-yik9o9qk/")
               (truename (asdf:system-source-directory :clamsara))))
(let ((left (asdf:apply-output-translations #p"/one/package.fasl"))
      (right (asdf:apply-output-translations #p"/two/package.fasl")))
  (format t "~&PRIVATE-OUTPUT-PATHS ~S ~S~%" left right)
  (assert (not (equal left right))))
(asdf:load-system :clamsara/quality/support)
(assert (equal (truename #p"/tmp/clamsara-cas-staged-yik9o9qk/")
               (truename (asdf:system-source-directory :clamsara/quality/support))))
(format t "~&OPAQUE-BASELINE-ROOT ~A implementation=~A/~A~%"
        (asdf:system-source-directory :clamsara) (lisp-implementation-type)
        (lisp-implementation-version))
(load #p"/tmp/clamsara-cas-staged-yik9o9qk/independent-review/opaque-admission/acceptance-source-02.lisp")
(load #p"/tmp/clamsara-cas-staged-yik9o9qk/independent-review/opaque-admission/authored-token-probes.lisp")
(let ((rows (uiop:symbol-call :clamsara.independent.opaque-admission
                            :describe-authored-token-probes)))
  (dolist (row rows)
    (format t "~&OPAQUE-APPLICABILITY ~S~%" row)
    (assert (null (getf row :nil-probe)))
    (assert (equal (getf row :own-token) '(nil)))
    (assert (getf row :token-owned-by-contribution))
    (assert (not (getf row :executed)))))
(let ((success nil))
  (handler-case
      (progn
        (uiop:symbol-call :clamsara.independent.opaque-admission :run-opaque-admission-tests)
        (setf success t))
    (error (condition)
      (format t "~&OPAQUE-STRICT-RUNNER-ERROR [~S] ~A~%" (type-of condition) condition)))
  (let ((failed (symbol-value
                 (find-symbol "*FAILED-WORLDS*" :clamsara.independent.opaque-admission)))
        (rejected (symbol-value
                   (find-symbol "*REJECTED-BUILDS*" :clamsara.independent.opaque-admission))))
    (dolist (entry failed)
      (destructuring-bind (label world plan rule observation condition) entry
        (declare (ignore rule))
        (let* ((construction (clamsara.quality.support:observed-construction observation))
               (configuration (and construction (clamsara::construction-configuration construction)))
               (rejection
                 (and (typep condition 'simple-condition)
                      (find-if (lambda (x) (typep x 'clamsara::construction-rejected))
                               (simple-condition-format-arguments condition)))))
          (format t "~&OPAQUE-RETAINED-FAIL ~S world=~S plan=~S config=~S construction=~S outer=~S cause=~S roots=~S~%"
                  label (not (null world)) (not (null plan))
                  (and configuration (clamsara::%configuration-state configuration))
                  (and construction (clamsara::%context-state construction))
                  (and rejection (clamsara::construction-rejection-reason rejection))
                  (and rejection
                       (let ((cause (clamsara::construction-rejection-cause rejection)))
                         (if (typep cause 'clamsara::runtime-rejection)
                             (clamsara::runtime-rejection-reason cause) (type-of cause))))
                  (and world (clamsara::simulator-provider-token-active-p
                              (clamsara.quality.support:world-root-token world)))))))
    (format t "~&OPAQUE-BASELINE-RETENTION failed=~D rejected=~D published-failed=~D~%"
            (length failed) (length rejected)
            (count-if #'second failed)))
  (uiop:quit (if success 0 1)))
