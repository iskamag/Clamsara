(in-package #:clamsara.acceptance.resources-layout)
(defun test-ownership-update-keeps-descriptor-granularity ()
  ;; Both independently declared maps cover both physical ranges, but only
  ;; equal-granularity replacement preserves the bound model's cell domain.
  (dolist (other-granularity '(8 16))
    (let* ((roots (clamsara::make-simulator-root-client :provider-capacity 1))
           (coordinator (clamsara::make-simulator-coordinator
                         roots :stop-capacity 2 :await-bound 2))
           (client (clamsara::make-simulator-address-space
                    :base 4096 :byte-extent 4096 :coordinator coordinator
                    :ownership-capacity 2))
           (maps (vector (make-instance 'acceptance-map :base 4096 :limit 8192
                                        :granularity 16)
                         (make-instance 'acceptance-map :base 4096 :limit 8192
                                        :granularity other-granularity)))
           (spaces (map 'vector (lambda (map)
                                  (make-instance 'acceptance-space :map map)) maps))
           (arena (clamsara::%layout-arena (make-reference-layout client)))
           (solutions (make-array 2))
           (assignments (make-hash-table :test #'eql)))
      (dotimes (i 2)
        (let* ((base (+ 4096 (* i 2048)))
               (description
                 (clamsara::%make-placement-description
                  :owner (aref spaces i) :path (list :granularity i) :position i
                  :identity i :minimum-extent 2048 :preferred-extent 2048
                  :maximum-extent 2048 :alignment 16 :granularity 16
                  :access '(:read :write) :lifetime :configuration :mobility :fixed
                  :reclaimability :collector :aliasable-p nil :inputs nil
                  :size-function nil :derived-p nil :constraint-count 0))
               (solution (clamsara::%make-placement-solution
                          :description description :base base
                          :exclusive-limit (+ base 2048) :object-start-map (aref maps i))))
          (setf (aref solutions i) solution (gethash i assignments) solution)))
      (let ((candidate (make-instance 'clamsara::%reference-layout :arena arena
                         :assignments assignments :ordered-solutions solutions
                         :free-intervals nil)))
        (multiple-value-bind (layout release) (install-managed-layout client candidate)
          (let* ((offer (make-host-object-model
                         :capacity (+ 128 (/ 2048 other-granularity))
                         :variant-capacity (+ 128 (/ 2048 other-granularity))
                         :max-object-bytes 16 :stage-capacity 1))
                 (bindings (map 'vector (lambda (space map)
                                          (make-object-start-binding offer space map))
                                spaces maps))
                 (model (bind-object-model offer layout bindings))
                 (route (aref (clamsara::simulator-layout-ranges layout) 0))
                 (generation (clamsara::%simulator-layout-range-generation route)))
            (multiple-value-bind (stop failure)
                (request-safepoint coordinator :all :granularity-check)
              (check (and stop (null failure)) "Granularity stop request failed")
              (multiple-value-bind (same coverage reason) (await-safepoint coordinator stop)
                (declare (ignore coverage))
                (check (and (eql same stop) (null reason)) "Granularity coverage failed"))
              (multiple-value-bind (capability status reason)
                  (prepare-space-ownership-update layout model (cons 4096 6144)
                                                  (aref spaces 1))
                (if (= other-granularity 8)
                    (check (and (null capability) (eq status :rejected)
                                (eq reason :incompatible-object-start-granularity)
                                (zerop (clamsara::%simulator-next-ownership layout))
                                (null (clamsara::%simulator-layout-range-pending route))
                                (= generation (clamsara::%simulator-layout-range-generation route))
                                (eq (aref maps 0) (clamsara::%simulator-layout-range-map route))
                                (eq (aref spaces 0) (clamsara::%simulator-layout-range-space route)))
                           "Changed cell granularity was admitted or rejection had effects")
                    (progn
                      (check (and capability (eq status :ready) (null reason))
                             "Equal-granularity owner replacement rejected")
                      (update-space-ownership layout capability)
                      (check (and (eq (aref maps 1) (clamsara::%simulator-layout-range-map route))
                                  (eq (aref spaces 1) (clamsara::%simulator-layout-range-space route))
                                  (= (1+ generation)
                                     (clamsara::%simulator-layout-range-generation route)))
                             "Equal-granularity replacement failed to publish"))))
              (check (eq :released (release-safepoint coordinator stop))
                     "Granularity stop release failed")))
          (release-managed-layout client release)))))
  t)

