;;;; Optional fixture-owned applicability witness. This is NOT a proposed
;;;; author API or a production token-sampling algorithm. It constructs only
;;;; this test author's own tokens, never invokes an execution method, and is
;;;; called explicitly after acceptance-source-02.lisp has been loaded.
(in-package #:clamsara.independent.opaque-admission)
(defun describe-authored-token-probes ()
  (loop for (phase class generic) in
        '((:admit typed-admit-rule barrier-contribution-admit)
          (:transform typed-transform-rule barrier-contribution-transform)
          (:before typed-before-rule barrier-contribution-before-exposure)
          (:after typed-after-rule barrier-contribution-after-exposure)
          (:cancel typed-cancel-rule barrier-contribution-cancel))
        for actual = (make-instance class)
        for token = (rule-token actual)
        collect
        (labels ((arguments (reservation)
                   (case phase
                     (:cancel (list actual reservation))
                     (:admit (list actual reservation nil :read nil))
                     (otherwise (list actual reservation nil :read nil nil nil))))
                 (qualifiers (reservation)
                   (mapcar #'method-qualifiers
                           (compute-applicable-methods
                            (fdefinition generic) (arguments reservation)))))
          ;; Primary qualifiers are NIL, hence (NIL) means one real primary;
          ;; NIL means no applicable method. Keep these visibly distinct.
          (list :phase phase :nil-probe (qualifiers nil)
                :own-token (qualifiers token)
                :token-owned-by-contribution (eq (token-owner token) actual)
                :executed (not (every #'zerop (rule-calls actual)))))))
