;;;; Synthetic self-check plus five runtime groups. No failure owner cleanup.
(in-package #:clamsara.workload.mapc.capacity.v1)
(defvar *cap-group-results* nil)
(dolist (entry '((:observer-self-check . cap-observer-self-check)
                 (:boundaries . cap-run-boundary-matrix)
                 (:snapshot . cap-run-snapshot-witness)
                 (:nested . cap-run-nested-rejection)
                 (:smaller-nonempty-recovery . cap-run-smaller-nonempty-recovery)
                 (:post-outer-nonempty-recovery . cap-run-post-outer-nonempty-recovery)))
  (format t "~&CAP-GROUP-BEGIN ~S~%" (car entry))
  (handler-case
      (progn (funcall (cdr entry))
             (push (list (car entry) :pass) *cap-group-results*)
             (format t "~&CAP-GROUP-PASS ~S~%" (car entry)))
    (error (condition)
      (push (list (car entry) :fail condition) *cap-group-results*)
      (let ((*print-level* 4) (*print-length* 12))
        (format t "~&CAP-GROUP-FAIL ~S [~S] ~A~%" (car entry)
                (type-of condition) condition)))))
(format t "~&CAP-GROUP-SUMMARY groups=~D passes=~D failures=~D owners=~D~%"
        (length *cap-group-results*)
        (count :pass *cap-group-results* :key #'second)
        (count :fail *cap-group-results* :key #'second)
        (length *cap-owners*))
(loop for owner in (reverse *cap-owners*) for index from 1 do
  (let* ((rt (cap-owner-runtime owner)) (p (cap-owner-provider owner))
         (configuration (and rt (clamsara::workload-runtime-configuration rt)))
         (token (and rt (clamsara::workload-runtime-root-token rt))))
    (format t "~&CAP-OWNER ~D phase=~S spec=~S runtime=~S config=~S token=~S condition=~S calls=~D sum=~D snapshots=~D moves=~D inner-rejections=~D~%"
            index (cap-owner-phase owner) (cap-owner-spec owner)
            (not (null rt))
            (and configuration (clamsara::%configuration-state configuration))
            (and token (clamsara::simulator-provider-token-active-p token))
            (and (cap-owner-condition owner) (type-of (cap-owner-condition owner)))
            (cap-owner-calls owner) (cap-owner-sum owner)
            (cap-owner-snapshot-count owner) (cap-owner-moving-cycles owner)
            (cap-owner-inner-rejections owner))
    (when p
      (format t "~&CAP-PHYSICAL ~D tokens=~D frames=~D saved=~D cells=~D snapshot-queue=~D census-queue=~D stack=~S~%"
              index (length (clamsara::workload-provider-locations p))
              (length (clamsara::workload-provider-functions p))
              (length (clamsara::workload-provider-saved-values p))
              (length (clamsara::workload-provider-native-cells p))
              (length (clamsara::workload-root-walk-queue
                       (clamsara::workload-provider-control-walk p)))
              (length (clamsara::workload-root-walk-queue
                       (clamsara::workload-provider-census-walk p)))
              (and (clamsara::workload-provider-vm p)
                   (length (maclina.vm-cross::vm-stack
                            (clamsara::workload-provider-vm p))))))))
(assert (= 6 (length *cap-group-results*)))
(assert (= 17 (length *cap-owners*)))
(assert (every (lambda (result) (eq :pass (second result))) *cap-group-results*))

(assert (every (lambda (owner)
                 (and (eq :complete (cap-owner-phase owner))
                      (null (cap-owner-condition owner))
                      (null (clamsara::workload-runtime-configuration
                             (cap-owner-runtime owner)))))
               *cap-owners*))
(format t "~&CAP3-ACCEPTED self-check=1 runtime-groups=5 complete-owners=17~%")
