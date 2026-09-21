;;;; One case only. No unwind cleanup, close, drain, cancel, GC or root release.
(in-package #:clamsara.finalizer.admission.baseline.v1)
(defvar *fna-caller-world* nil)
(defvar *fna-construction-observation* (make-construction-observation))
(defvar *fna-run-condition* nil)
(defvar *fna-run-owner* nil)
(defvar *fna-reached* 0)
(handler-case
    (progn
      (let ((clamsara.quality.support:*construction-observation*
              *fna-construction-observation*))
        (setf *fna-caller-world*
              (make-quality-world :algorithm :semispace :object-starts :packed
                                  :extent 2048 :root-count 2
                                  :finalizer-capacity 2
                                  :finalizer-registration-capacity 4)))
      (format t "~&FNA-CALLER-WORLD-OWNED ~S~%" (not (null *fna-caller-world*)))
      (run-native-callback-admission *fna-caller-world*))
  (error (condition)
    (setf *fna-run-condition* condition)
    (format t "~&FNA-ERROR [~S] ~A~%" (type-of condition) condition)))
(setf *fna-run-owner* (first *admission-owners*))
(when *fna-run-owner*
  ;; The before-state is taken only after complete setup/observer installation,
  ;; immediately before the actual registration call and its root read argument.
  (when (fna-owner-before *fna-run-owner*) (setf *fna-reached* 1))
  (format t "~&FNA-OWNER ~S~%" (fna-summary *fna-run-owner*))
  (format t "~&FNA-BEFORE-AFTER-SAME ~S~%"
          (fna-state-same-p (fna-owner-before *fna-run-owner*)
                            (fna-owner-after *fna-run-owner*)))
  (when (fna-owner-before *fna-run-owner*)
    ;; FNA-SNAPSHOT's final scalar row is fixed by this unchanged V1 source.
    ;; Display its last 25 values alongside the actual registry facts. No
    ;; guessed mutation or saved encoded root is used for liveness evidence.
    (format t "~&FNA-BEFORE-SCALARS ~S~%"
            (last (fna-state-values (fna-owner-before *fna-run-owner*)) 25)))
  (when (fna-owner-after *fna-run-owner*)
    (format t "~&FNA-AFTER-SCALARS ~S~%"
            (last (fna-state-values (fna-owner-after *fna-run-owner*)) 25))))
(when *fna-caller-world*
  (let* ((world *fna-caller-world*) (registry (world-registry world))
         (root (read-world-root world 0))
         (callback #'fna-native-callback))
    (format t "~&FNA-DOMAIN functionp=~S model-reference-p=~S root0-local=~S root0-id=~S~%"
            (functionp callback) (valid-reference-p (world-model world) callback)
            (clamsara::%registry-local-referent-p registry root)
            (read-node-slot world root 0))
    (format t "~&FNA-REGISTRY next-token=~D states=~S token-indices=~S returned-token-local-index=~S~%"
            (clamsara::%registry-next-token registry)
            (coerce (clamsara::%registry-states registry) 'list)
            (map 'list #'clamsara::sequential-finalizer-token-index
                 (clamsara::%registry-token-reserve registry))
            (and *fna-run-owner*
                 (first (fna-owner-returned-values *fna-run-owner*))
                 (clamsara::%registry-token-index registry
                   (first (fna-owner-returned-values *fna-run-owner*)))))))
(format t "~&FNA-COUNTS reached=~D retained-worlds=~D retained-owners=~D closed-owners=0 outcome=~S~%"
        *fna-reached* (if *fna-caller-world* 1 0) (length *admission-owners*)
        (cond ((and *fna-run-owner* (eq :red-accepted (fna-owner-status *fna-run-owner*)))
               :strict-red-native-admission)
              (*fna-run-condition* :construction-or-harness-or-other-error)
              (t :admission-rejected-retained)))
;; A predicted wrong acceptance is still a strict failing command, not PASS.
(when *fna-run-condition* (error *fna-run-condition*))
(assert (= 1 *fna-reached* (length *admission-owners*)))
(assert (eq :rejected-retained (fna-owner-status *fna-run-owner*)))
