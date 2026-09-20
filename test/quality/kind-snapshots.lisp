;;;; Allocation geometry is captured at binding, not reevaluated by a collector.
(defpackage #:clamsara.quality.kind-snapshots
  (:use #:cl #:clamsara #:clamsara.quality.support)
  (:import-from #:clamsara #:construction-rejected #:construction-rejection-reason
                #:construction-configuration)
  (:export #:run-kind-geometry-snapshot-tests))
(in-package #:clamsara.quality.kind-snapshots)

(defun allocate-kind (world kind bytes &optional (alignment 16))
  (multiple-value-bind (reference status reason)
      (allocate-object (world-context world) kind bytes alignment
                       (object-kind-descriptor (world-model world) kind))
    (check (eq :allocated status) "Kind allocation failed: ~S/~S" status reason)
    reference))

(defun complete-cycle (world expected)
  (let ((result (collect-world world)))
    (check (eq :complete (cycle-result-status result))
           "Snapshot collection failed: ~S/~S/~S"
           (cycle-result-status result) (cycle-result-phase result) (cycle-result-reason result))
    (check (= expected (cycle-result-count result :objects-discovered))
           "Snapshot changed reachability: expected ~D, got ~S"
           expected (cycle-result-count result :objects-discovered))
    result))

(defun run-function-geometry (algorithm starts change)
  (let* ((size 32) (alignment 8) (size-calls 0) (alignment-calls 0)
         (kind nil) (offer nil)
         (size-rule (lambda (description) (declare (ignore description))
                      (incf size-calls) size))
         (alignment-rule (lambda (description) (declare (ignore description))
                           (incf alignment-calls) alignment))
         (world
           (make-quality-world
            :algorithm algorithm :object-starts starts :extent 512
            :configure-model
            (lambda (model)
              (setf offer model
                    kind (make-object-kind-description model :captured
                           :size-rule size-rule :alignment-rule alignment-rule
                           :strong-layout '(:quality-id :left))))))
         (model (world-model world))
         (binding-calls (list size-calls alignment-calls)))
    ;; A real fixed parent is encountered before the callable-rule child. The
    ;; old semispace implementation had already forwarded the parent on failure.
    (set-world-root world 0 (allocate-node world 10))
    (let ((child (allocate-kind world :captured 32)))
      (set-node-slot world child 0 20)
      (set-node-slot world (read-world-root world 0) 1 child))
    (ecase change (:size (setf size 48)) (:alignment (setf alignment 32)))
    (dotimes (round 3)
      (complete-cycle world 2)
      (let* ((parent (read-world-root world 0))
             (child (read-node-slot world parent 1)))
        (check (and (= 10 (read-node-slot world parent 0))
                    (= 20 (read-node-slot world child 0))
                    (= 32 (object-size model child))
                    (= 8 (object-alignment model child)))
               "Moved object no longer has its bound ABI")))
    (check-equal '(1 1) binding-calls "rule evaluation at binding")
    (check (and (= 1 size-calls) (= 1 alignment-calls))
           "Fixed rules were reevaluated: size ~D alignment ~D" size-calls alignment-calls)
    ;; Opaque token identity is preserved without using its offered rule fields.
    (check (eq kind (object-kind-descriptor model :captured)) "Allocation token changed")
    (check (= 32 (object-size model (allocate-kind world :captured 32)))
           "Bound allocation changed with caller environment")
    (multiple-value-bind (reference status reason)
        (allocate-object (world-context world) :captured 48 16 kind)
      (check (and (null reference) (eq :failed status) (eq :invalid-size reason))
             "Mutated size was accepted by old binding"))
    (multiple-value-bind (name offered-size offered-alignment)
        (describe-object-kind offer kind)
      (declare (ignore name))
      (check (and (eq size-rule offered-size) (eq alignment-rule offered-alignment))
             "Binding rewrote the offered kind"))
    (check (and (= 1 size-calls) (= 1 alignment-calls)) "Allocation reran a fixed rule")
    (set-world-root world 0 nil)
    (complete-cycle world 0)
    (close-quality-world world)))

(defun run-variable-geometry (algorithm starts)
  (let* ((rule (clamsara::make-host-variable-size-rule
                :header-bytes 16 :element-bytes 8 :maximum-elements 4))
         (kind nil)
         (world
           (make-quality-world
            :algorithm algorithm :object-starts starts :extent 512
            :configure-model
            (lambda (model)
              (setf kind (make-object-kind-description
                          model :snapshot-array :size-rule rule :alignment-rule 16
                          :strong-layout '(:indexed :base-offset 16))))))
         (model (world-model world)))
    (set-world-root world 0 (allocate-kind world :snapshot-array 48))
    (let ((child (allocate-node world 91)))
      (set-node-slot world (read-world-root world 0) 3 child))
    ;; This is a caller-created private hosted rule input, not an opaque
    ;; description returned by a public query. Keep that scope explicit.
    (setf (clamsara::host-variable-size-rule-element-bytes rule) 16)
    (dotimes (round 3)
      (complete-cycle world 2)
      (let ((identities nil))
        (map-reference-locations model (read-world-root world 0)
                                 (lambda (identity location)
                                   (declare (ignore location)) (push identity identities)))
        (check-equal '(0 1 2 3) (nreverse identities) "bound array geometry")
        (check (= 91 (read-node-slot world
                      (read-node-slot world (read-world-root world 0) 3) 0))
               "Snapshot array lost its last-slot child")))
    (check (eq kind (object-kind-descriptor model :snapshot-array)) "Array token changed")
    (let ((fresh (allocate-kind world :snapshot-array 48)) (slots 0))
      (map-reference-locations model fresh
                              (lambda (identity location)
                                (declare (ignore identity location)) (incf slots)))
      (check (and (= 48 (object-size model fresh)) (= 4 slots))
             "Bound array allocation changed: ~D slots" slots))
    (set-world-root world 0 nil)
    (complete-cycle world 0)
    (close-quality-world world)))

(defun assert-rejected-construction-released ()
    (check (and (observed-construction *construction-observation*) (observed-layout *construction-observation*)) "Missing real construction effects")
    (let* ((construction (observed-construction *construction-observation*))
           (configuration (construction-configuration construction))
           (resources (clamsara::%context-resources construction)))
      (check (and (eq :released (clamsara::%context-state construction))
                  (eq :failed (clamsara::%configuration-state configuration))
                  (not (clamsara::%configuration-object-model-bound-p configuration)))
             "Failed rule published a bound configuration or skipped unwind")
      (check (plusp (hash-table-count resources)) "No actual resources acquired")
      (maphash (lambda (identity state)
                 (declare (ignore identity))
                 (check (and (clamsara::%resource-state-released-p state)
                             (clamsara::%simulator-resource-released-p
                              (clamsara::%resource-state-release-capability state)))
                        "Abandoned construction retained an acquired resource"))
               resources))
    (check (and (not (clamsara::%simulator-layout-active-p (observed-layout *construction-observation*)))
                (null (clamsara::%simulator-active-layout
                       (clamsara::%simulator-layout-client (observed-layout *construction-observation*)))))
           "Abandoned construction retained layout ownership"))

(defun run-rule-binding-rejection (algorithm starts case)
  (let ((*construction-observation* (make-construction-observation))
        (rejection nil) (observed-signal nil))
    (handler-case
        (handler-bind
            ((construction-rejected
               (lambda (condition)
                 ;; A non-unwinding observer must see cleanup already complete.
                 (assert-rejected-construction-released)
                 (setf observed-signal condition))))
          (let ((world
                (make-quality-world
                 :algorithm algorithm :object-starts starts :extent 512
                 :configure-model
                 (lambda (model)
                   (ecase case
                     (:size
                      (make-object-kind-description model :signaling-size
                       :size-rule (lambda (kind) (declare (ignore kind)) (error "Size rule failure"))
                       :alignment-rule 8))
                     (:alignment
                      (make-object-kind-description model :signaling-alignment :size-rule 32
                       :alignment-rule (lambda (kind) (declare (ignore kind)) (error "Alignment rule failure")))))))))
            (close-quality-world world)))
      (construction-rejected (condition) (setf rejection condition)))
    (check (and rejection (eq :bind-object-model-signaled
                             (construction-rejection-reason rejection)))
           "Signaling ~S rule was not rejected at binding" case)
    (check (eq observed-signal rejection) "Construction rejection identity changed")
    (assert-rejected-construction-released)))

(defun run-rule-binding-escape (algorithm starts case)
  (let ((*construction-observation* (make-construction-observation))
        (tag (gensym "RULE-EXIT")) (reached nil))
    (let* ((escape (lambda (kind)
                     (declare (ignore kind))
                     (setf reached t)
                     (throw tag (values :rule-escaped 47))))
           (outcome
             (multiple-value-list
              (catch tag
                (let ((world
                        (make-quality-world
                         :algorithm algorithm :object-starts starts :extent 512
                         :configure-model
                         (lambda (model)
                           (make-object-kind-description model :escaping-rule
                            :size-rule (if (eq case :size) escape 32)
                            :alignment-rule (if (eq case :alignment) escape 8))))))
                  (close-quality-world world)
                  :unexpected-return)))))
      (check reached "Rule escape was not reached")
      (check-equal '(:rule-escaped 47) outcome "construction escape values"))
    (assert-rejected-construction-released)))

(defun run-kind-geometry-snapshot-tests ()
  (let ((failures nil))
    (dolist (algorithm '(:semispace :marksweep))
      (dolist (starts '(:packed :scalar))
        (dolist (case '(:size :alignment :variable))
          (handler-case
              (progn
                (if (eq case :variable) (run-variable-geometry algorithm starts)
                    (run-function-geometry algorithm starts case))
                (format t "~&KIND-GEOMETRY-PASS ~S ~S ~S~%" algorithm starts case))
            (error (condition)
              (push (list algorithm starts case (princ-to-string condition)) failures))))))
    (check (null failures) "Kind geometry snapshot failures: ~S" (nreverse failures)))
  (dolist (algorithm '(:semispace :marksweep))
    (dolist (starts '(:packed :scalar))
      (dolist (case '(:size :alignment))
        (run-rule-binding-rejection algorithm starts case)
        (run-rule-binding-escape algorithm starts case))))
  (format t "~&KIND-GEOMETRY-SNAPSHOTS-PASS cases=12 rejections=8 escapes=8~%")
  t)
