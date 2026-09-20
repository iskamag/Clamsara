;;;; Native reader syntax belongs to the compiler, not the guest heap.
(in-package #:clamsara)

(defun %install-workload-reader-macros (client environment)
  "Install this host reader's syntax expander in one interpreter environment.
The expander returns compiler source forms. It does not create guest payload
or replace any global Maclina/SBCL function."
  #+sbcl
  (let ((expander (macro-function 'sb-int:quasiquote)))
    (unless expander
      (error 'workload-capability-error :operation 'workload-load
             :reason :missing-native-quasiquote-expander))
    (setf (clostrum:macro-function client environment 'sb-int:quasiquote)
          (lambda (form macro-environment)
            ;; Reader quasiquotation has no lexical-environment dependency.
            ;; Never pass a Trucler environment to an SBCL native expander.
            (declare (ignore macro-environment))
            (funcall expander form nil))))
  #-sbcl
  (error 'workload-capability-error :operation 'workload-load
         :reason :unsupported-native-source-reader)
  (values))
