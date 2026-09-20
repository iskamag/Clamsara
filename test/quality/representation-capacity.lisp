;;;; Dense representation admission, rollback and full-survivor copy peaks.
(defpackage #:clamsara.quality.representation-capacity
  (:use #:cl #:clamsara #:clamsara.quality.support)
  (:import-from #:clamsara #:construction-rejected #:construction-rejection-reason
                #:construction-rejection-cause #:construction-configuration)
  (:export #:run-representation-capacity-tests))
(in-package #:clamsara.quality.representation-capacity)

(defvar *watch-construction* nil)
(defvar *observed-construction* nil)
(defvar *observed-model* nil)
(defvar *observed-layout* nil)
(defvar *peak-model* nil)
(defvar *peak-live-count* 0)

;; Observe actual implementations. No fake resource, binding, or initialization.
(defmethod clamsara::%acquire-construction-resource :around
    ((clients clamsara::simulator-clients) construction description placement)
  (when *watch-construction* (setf *observed-construction* construction))
  (call-next-method))
(defmethod bind-object-model :around
    ((model clamsara::host-object-model) layout bindings)
  (when *watch-construction*
    (setf *observed-model* model *observed-layout* layout))
  (call-next-method))
(defmethod initialize-object :after
    ((model clamsara::host-object-model) address kind size descriptor)
  (declare (ignore address kind size descriptor))
  (when (eq model *peak-model*)
    (setf *peak-live-count* (max *peak-live-count* (clamsara::host-model-live-count model)))))

(defun required-cells (algorithm granularity)
  (/ (* 128 (if (eq algorithm :semispace) 2 1)) granularity))

(defun run-construction-rejection (algorithm starts granularity offered)
  (let ((*watch-construction* t) (*observed-construction* nil)
        (*observed-model* nil) (*observed-layout* nil)
        (required (required-cells algorithm granularity))
        (rejection nil))
    (handler-case
        (let ((world (make-quality-world :algorithm algorithm :object-starts starts
                      :extent 128 :map-granularity granularity :object-capacity offered)))
          (close-quality-world world))
      (construction-rejected (condition) (setf rejection condition)))
    (check rejection "Undersized representation offer ~D/~D was admitted" offered required)
    (check (eq :bind-object-model-signaled (construction-rejection-reason rejection))
           "Wrong capacity rejection phase: ~S" rejection)
    (let ((cause (construction-rejection-cause rejection)))
      (check (and (typep cause 'simple-error)
                  (equal (list offered required) (simple-condition-format-arguments cause)))
             "Capacity diagnostic lost actual offered/required values: ~S" cause))
    (check (and *observed-model* *observed-layout* *observed-construction*)
           "Capacity rejection did not reach real binding")
    (check (and (= offered (clamsara::host-model-capacity *observed-model*))
                (not (clamsara::host-model-bound-p *observed-model*))
                (null (clamsara::host-model-arena *observed-model*))
                (zerop (clamsara::host-model-live-count *observed-model*)))
           "Binding mutated or repaired the offered model")
    (let* ((construction *observed-construction*)
           (configuration (construction-configuration construction))
           (resources (clamsara::%context-resources construction)))
      (check (and (eq :released (clamsara::%context-state construction))
                  (eq :failed (clamsara::%configuration-state configuration))
                  (not (clamsara::%configuration-object-model-bound-p configuration)))
             "Rejected configuration was published or not unwound")
      (check (plusp (hash-table-count resources)) "Rollback had no real resources")
      (maphash
       (lambda (identity state)
         (declare (ignore identity))
         (check (and (clamsara::%resource-state-released-p state)
                     (clamsara::%simulator-resource-released-p
                      (clamsara::%resource-state-release-capability state)))
                "Binding rejection retained an acquired resource"))
       resources))
    (check (and (not (clamsara::%simulator-layout-active-p *observed-layout*))
                (null (clamsara::%simulator-active-layout
                       (clamsara::%simulator-layout-client *observed-layout*))))
           "Binding rejection retained installed layout ownership")))

(defun run-full-survivors (algorithm starts granularity offered)
  (let* ((leaf nil)
         (world (make-quality-world
                 :algorithm algorithm :object-starts starts :extent 128
                 :map-granularity granularity :object-capacity offered
                 :configure-model
                 (lambda (model)
                   (setf leaf (make-object-kind-description model :capacity-leaf
                                :size-rule 16 :alignment-rule 16
                                :strong-layout '(:quality-id))))))
         (model (world-model world))
         (required (required-cells algorithm granularity)))
    (check (and (= offered (clamsara::host-model-capacity model))
                (= required (length (clamsara::host-model-sizes model)))
                (= (* 128 (if (eq algorithm :semispace) 2 1))
                   (length (clamsara::host-model-arena model))))
           "Admission silently changed capacity or physical geometry")
    (dotimes (index 8)
      (multiple-value-bind (reference status reason)
          (allocate-object (world-context world) :capacity-leaf 16 16 leaf)
        (check (eq :allocated status) "Leaf allocation failed: ~S" reason)
        (set-node-slot world reference 0 index)
        (set-world-root world index reference)))
    (dotimes (round 4)
      (let ((*peak-model* model)
            (*peak-live-count* (clamsara::host-model-live-count model)))
        (let ((result (collect-world world)))
          (check (eq :complete (cycle-result-status result)) "Full survivor cycle failed")
          (check (= 8 (cycle-result-count result :objects-discovered)) "Lost full survivors")
          (check (= (if (eq algorithm :semispace) 8 0)
                    (cycle-result-count result :objects-moved)) "Wrong copy count"))
        (check (= (if (eq algorithm :semispace) 16 8) *peak-live-count*)
               "Source/destination coexistence not observed: ~D" *peak-live-count*)
        (check (= 8 (clamsara::host-model-live-count model)) "Old representations not retired"))
      (dotimes (index 8)
        (check (= index (read-node-slot world (read-world-root world index) 0))
               "Full survivor payload corrupted")))
    ;; Actual owners release roots; a real collection discharges the graph.
    (dotimes (index 8) (set-world-root world index nil))
    (let ((result (collect-world world)))
      (check (eq :complete (cycle-result-status result)) "Discharge failed")
      (check (zerop (clamsara::host-model-live-count model)) "Garbage representation retained"))
    (close-quality-world world)))

(defun run-representation-capacity-tests ()
  (dolist (algorithm '(:semispace :marksweep))
    (dolist (starts '(:packed :scalar))
      (dolist (granularity '(8 16))
        (let ((required (required-cells algorithm granularity)))
          (dolist (offered (list 1 3 (1- required)))
            (run-construction-rejection algorithm starts granularity offered))
          (dolist (offered (list required (+ required 7)))
            (run-full-survivors algorithm starts granularity offered)))
        (format t "~&REPRESENTATION-CAPACITY-PASS ~S ~S granularity=~D~%"
                algorithm starts granularity))))
  (format t "~&REPRESENTATION-CAPACITY-TESTS-PASS rejections=24 survivor-histories=16~%")
  t)
