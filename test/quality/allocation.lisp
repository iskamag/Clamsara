;;;; Allocation rejection must precede raw allocation, refill and collection.
(defpackage #:clamsara.quality.allocation
  (:use #:cl #:clamsara #:clamsara.quality.support)
  (:import-from #:clamsara #:make-host-variable-size-rule)
  (:export #:run-allocation-admission-tests))
(in-package #:clamsara.quality.allocation)

(defvar *watch-entry* nil)
(defvar *entries* nil)
(defmethod allocate-raw :around
    ((allocator clamsara::runtime-allocator) bytes alignment kind)
  (when *watch-entry* (push :raw *entries*))
  (call-next-method))
(defmethod refill-mutator :around
    ((allocator clamsara::runtime-allocator)
     (context clamsara::sequential-execution-context) request)
  (when *watch-entry* (push :refill *entries*))
  (call-next-method))
(defmethod automatic-collect :around (configuration scope cause)
  (when *watch-entry* (push :collect *entries*))
  (call-next-method))

(defun allocator-snapshot (allocator)
  (list (clamsara::%allocator-last-valid-p allocator)
        (etypecase allocator
          (clamsara::bump-runtime-allocator
           (list (clamsara::%allocator-cursor allocator)
                 (clamsara::%allocator-last-cursor allocator)))
          (clamsara::free-list-runtime-allocator
           (list (clamsara::%free-count allocator)
                 (clamsara::%free-last-index allocator)
                 (clamsara::%free-last-start allocator)
                 (copy-seq (clamsara::%free-starts allocator))
                 (copy-seq (clamsara::%free-limits allocator)))))))

(defun world-snapshot (world)
  (let ((model (world-model world)) (context (world-context world)))
    (list (read-world-root world 0)
          (clamsara::host-model-live-count model)
          (copy-seq (clamsara::host-model-sizes model))
          (copy-seq (clamsara::host-model-descriptor-generations model))
          (copy-seq (clamsara::host-model-arena model))
          (copy-seq (clamsara::host-model-words model))
          (clamsara::%context-allocator context)
          (clamsara::%context-cursor context) (clamsara::%context-limit context)
          (copy-seq (clamsara::%context-refill-request context))
          (mapcar (lambda (space)
                    (allocator-snapshot (clamsara::%space-allocator space)))
                  (clamsara::%plan-spaces (world-plan world))))))

(defun check-rejected (world kind bytes alignment descriptor expected)
  (let ((before (world-snapshot world)) (*watch-entry* t) (*entries* nil))
    (multiple-value-bind (reference status reason)
        (allocate-object (world-context world) kind bytes alignment descriptor)
      (check (and (null reference) (eq status :failed) (eq reason expected))
             "Bad rejection for ~S/~S/~S: ~S/~S/~S, expected ~S"
             kind bytes alignment reference status reason expected))
    (check (null *entries*) "Invalid request entered slow/raw paths: ~S" *entries*)
    (check (equalp before (world-snapshot world)) "Invalid request changed storage")
    (check (= 91 (read-node-slot world (read-world-root world 0) 0))
           "Invalid request damaged the rooted object")))

(defun make-admission-world (algorithm starts &optional (extent 512))
  (make-quality-world
   :algorithm algorithm :object-starts starts :extent extent
   :configure-model
   (lambda (model)
     (make-object-kind-description model :small :size-rule 8 :alignment-rule 8
                                  :strong-layout '(:edge))
     (make-object-kind-description model :short-word :size-rule 4 :alignment-rule 8
                                  :strong-layout '(:edge))
     (make-object-kind-description model :over-aligned :size-rule 32 :alignment-rule 32)
     (make-object-kind-description model :bad-alignment :size-rule 32 :alignment-rule 3)
     (make-object-kind-description model :computed
       :size-rule (lambda (kind) (declare (ignore kind)) 32)
       :alignment-rule (lambda (kind) (declare (ignore kind)) 8))
     (make-object-kind-description model :short-weak :size-rule 4 :alignment-rule 8
       :weak-descriptions (list (make-weak-location-description model :edge :leaf nil)))
     (make-object-kind-description model :short-ephemeron :size-rule 12 :alignment-rule 8
       :ephemeron-descriptions (list (make-ephemeron-description model :pair t nil nil)))
     (make-object-kind-description model :valid-weak :size-rule 8 :alignment-rule 8
       :weak-descriptions (list (make-weak-location-description model :edge :leaf nil)))
     (make-object-kind-description model :valid-ephemeron :size-rule 16 :alignment-rule 8
       :ephemeron-descriptions (list (make-ephemeron-description model :pair t nil nil)))
     (make-object-kind-description model :variable
       :size-rule (make-host-variable-size-rule :header-bytes 16 :element-bytes 8
                    :minimum-elements 1 :maximum-elements 4 :element-kind :numeric)
       :alignment-rule 8)
     (make-object-kind-description model :unbounded-variable
       :size-rule (make-host-variable-size-rule :header-bytes 16 :element-bytes 8
                    :element-kind :numeric)
       :alignment-rule 8))))

(defun run-invalid-requests (algorithm starts)
  (let* ((world (make-admission-world algorithm starts))
         (model (world-model world))
         (descriptor (world-node-kind world))
         (maximum (clamsara::%context-target-maximum
                   (clamsara::configuration-construction-context
                    (world-configuration world)))))
    (set-world-root world 0 (allocate-node world 91))
    (dolist (bytes '(nil -1 0 1 16 24 31 33 64 512))
      (check-rejected world :quality-node bytes 16 descriptor :invalid-size))
    (dolist (alignment '(nil -1 0 1 2 4 8 3 32))
      (check-rejected world :quality-node 32 alignment descriptor :invalid-alignment))
    (dolist (bytes (list maximum (1+ maximum) (ash 1 100)))
      (check-rejected world :quality-node bytes 16 descriptor :arithmetic-overflow))
    ;; Largest charge that fits target arithmetic reaches kind validation;
    ;; its successor must reject as overflow, not as a malformed kind size.
    (let ((largest (- maximum (1- (world-packing-quantum world)))))
      (check-rejected world :quality-node largest 16 descriptor :invalid-size)
      (check-rejected world :quality-node (1+ largest) 16 descriptor :arithmetic-overflow))
    (check-rejected world :unknown 32 16 descriptor :invalid-kind)
    (check-rejected world :quality-node 32 16 nil :invalid-kind)
    (check-rejected world :quality-node 32 16 (copy-structure descriptor) :invalid-kind)
    (let* ((foreign-model (make-host-object-model))
           (foreign (make-object-kind-description foreign-model :quality-node
                      :size-rule 32 :alignment-rule 16)))
      (check-rejected world :quality-node 32 16 foreign :invalid-kind))
    (let ((variable (object-kind-descriptor model :variable)))
      (dolist (bytes '(8 16 23 25 56))
        (check-rejected world :variable bytes 8 variable :invalid-size)))
    (check-rejected world :unbounded-variable 264 8
                    (object-kind-descriptor model :unbounded-variable) :invalid-size)
    (check-rejected world :short-word 4 8
                    (object-kind-descriptor model :short-word) :invalid-size)
    (check-rejected world :over-aligned 32 16
                    (object-kind-descriptor model :over-aligned) :invalid-alignment)
    (check-rejected world :bad-alignment 32 16
                    (object-kind-descriptor model :bad-alignment) :invalid-alignment)
    (dolist (request '((:short-weak 4) (:short-ephemeron 12) (:computed 16)))
      (destructuring-bind (kind bytes) request
        (check-rejected world kind bytes 8 (object-kind-descriptor model kind) :invalid-size)))
    ;; Signaling fixed rules now reject construction. Their assertions and
    ;; resource-unwind checks live in kind-snapshots.lisp.
    ;; Valid smaller alignments and variable endpoints still use the usual path.
    (dolist (request '((:small 8 8) (:variable 24 8) (:variable 32 16)
                       (:variable 48 8) (:unbounded-variable 16 8) (:computed 32 8)
                       (:unbounded-variable 256 8) (:valid-weak 8 8)
                       (:valid-ephemeron 16 8)))
      (destructuring-bind (kind bytes alignment) request
        (let ((*watch-entry* t) (*entries* nil))
          (multiple-value-bind (reference status reason)
              (allocate-object (world-context world) kind bytes alignment
                               (object-kind-descriptor model kind))
            (check (and (eq status :allocated) (null reason)
                        (= bytes (object-size model reference)))
                   "Valid allocation failed: ~S ~S/~S" request status reason)
            (when (member kind '(:valid-weak :valid-ephemeron))
              (let ((visited 0))
                (if (eq kind :valid-weak)
                    (map-weak-descriptors model reference
                      (lambda (identity location cleared)
                        (declare (ignore identity))
                        (incf visited)
                        (check (eql cleared (load-reference model location))
                               "Exact weak word was not initialized")))
                    (map-ephemeron-descriptors model reference
                      (lambda (identity key value clear-key-p cleared-key cleared-value)
                        (declare (ignore identity clear-key-p))
                        (incf visited)
                        (check (and (eql cleared-key (load-reference model key))
                                    (eql cleared-value (load-reference model value)))
                               "Exact ephemeron words were not initialized"))))
                (check (= 1 visited) "Valid exact conditional layout was not mapped"))))
          (check-equal '(:raw) *entries* "valid allocation path"))))
    (set-world-root world 0 nil)
    (close-quality-world world)
    (format t "~&ALLOCATION-ADMISSION-PASS ~S ~S~%" algorithm starts)))

(defun run-valid-exhaustion (algorithm starts)
  (let* ((world (make-admission-world algorithm starts 128))
         (model (world-model world)))
    (set-world-root world 0 (allocate-node world 91))
    (let ((*watch-entry* t) (*entries* nil))
      (multiple-value-bind (reference status reason)
          (allocate-object (world-context world) :unbounded-variable 160 8
                           (object-kind-descriptor model :unbounded-variable))
        (check (and (null reference) (eq status :failed) (eq reason :heap-exhausted))
               "Valid oversized-for-space request was mislabeled: ~S/~S" status reason))
      (check (and (= 1 (count :collect *entries*)) (= 1 (count :refill *entries*)))
             "Valid exhausted request skipped/duplicated retry stages: ~S" *entries*))
    (check (= 91 (read-node-slot world (read-world-root world 0) 0))
           "Valid exhaustion damaged root")
    (set-world-root world 0 nil)
    (close-quality-world world)))

(defun run-allocation-admission-tests ()
  (dolist (algorithm '(:semispace :marksweep))
    (dolist (starts '(:packed :scalar))
      (run-invalid-requests algorithm starts)
      (run-valid-exhaustion algorithm starts)))
  (format t "~&ALLOCATION-ADMISSION-TESTS-PASS~%")
  t)
