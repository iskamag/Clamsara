;;;; Native baseline only. Every test uses a separate caller-owned runtime.
;;;; Failed runtimes remain published and rooted; no failure cleanup.
(in-package #:clamsara.workload.mapc.strict-draft)
(defvar *runner-runtimes* nil)
(defvar *runner-results* nil)
(defvar *runner-passes* 0)
(defvar *runner-failures* 0)
(dolist (case *cases*)
  (let ((runtime nil))
    (format t "~&STRICT9-GROUP-BEGIN ~S~%" case)
    (handler-case
        (progn
          (setf runtime (make-workload-runtime :extent 16384 :max-object-bytes 8192
                                               :root-capacity 512))
          ;; The caller retains the runtime before the case adopts its owner.
          (push (list case runtime) *runner-runtimes*)
          (run-mapc-strict-case runtime case
                               :pathname (asdf:system-relative-pathname
                                          :clamsara "bench/gabriel/reference/dderiv.cl"))
          (assert (null (clamsara::workload-runtime-configuration runtime)))
          (incf *runner-passes*)
          (push (list case :pass) *runner-results*)
          (format t "~&STRICT9-GROUP-PASS ~S~%" case))
      (error (condition)
        (incf *runner-failures*)
        (let ((owner (find runtime *owners* :key #'owner-runtime :test #'eq)))
          (push (list case :fail condition owner runtime) *runner-results*)
          (format t "~&STRICT9-GROUP-FAIL ~S phase=~S [~S] ~A~%"
                  case (and owner (owner-phase owner)) (type-of condition) condition)
          (format t "~&STRICT9-PRE-UNWIND ~S ~S~%"
                  case (and owner (owner-pre-unwind-registers owner))))))))
(format t "~&STRICT9-SUMMARY groups=~D passes=~D failures=~D owners=~D~%"
        (length *cases*) *runner-passes* *runner-failures* (length *owners*))
(dolist (owner (reverse *owners*))
  (let* ((runtime (owner-runtime owner))
         (configuration (clamsara::workload-runtime-configuration runtime))
         (token (clamsara::workload-runtime-root-token runtime)))
    (format t "~&STRICT9-OWNER ~S status=~S phase=~S runtime=~S config=~S token-active=~S~%"
            (owner-name owner) (owner-status owner) (owner-phase owner)
            (not (null runtime))
            (and configuration (clamsara::%configuration-state configuration))
            (and token (clamsara::simulator-provider-token-active-p token)))))
(assert (= 9 (length *runner-results*)))
(assert (zerop *runner-failures*))
