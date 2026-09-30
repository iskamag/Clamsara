;;;; Monotone NoGC plan (paper-v14 chapters/collectors.tex, "NoGC").
;;;;
;;;; NoGC uses the common initialization and layout contracts with a monotone
;;;; bump allocator.  It publishes no forwarding store, no reclamation and no
;;;; movement participant: exhaustion is an ordinary allocation failure.  It is
;;;; the smallest complete plan, for validating the object ABI, object starts,
;;;; roots and the allocation path before reclamation exists.
;;;;
;;;; A collection is still admitted: it takes a covering stop, traces declared
;;;; roots through the shared reference dispatcher, and stages the common
;;;; conditional/finalizer closure.  Because the plan trusts no space
;;;; (%plan-trusts-space-in-cycle-p), every canonical start is out of scope, so
;;;; trace-reference returns each exact original encoding untouched and no work
;;;; item, movement or death is ever recorded.  reclaim-space builds an empty
;;;; candidate and finish-space changes no published state.
(in-package #:clamsara)

(defclass nogc-space (runtime-space) ())

(defmethod initialize-component :after ((space nogc-space) context)
  (let ((allocator (make-instance 'bump-runtime-allocator :space space)))
    (setf (%allocator-cursor allocator) (%space-base space)
          (%allocator-limit allocator) (%space-limit space)
          (%space-allocator space) allocator)
    (%register-resource-auxiliary context (%space-state-resource-id space)
                                  allocator))
  (metadata-reset-range (%space-object-start-map space) (%space-range space))
  (values))

(defun make-nogc-space (&key name object-start-map extent packing-quantum)
  (%check-space-extent extent packing-quantum)
  (make-instance 'nogc-space :name name :object-start-map object-start-map
                 :extent extent :packing-quantum packing-quantum))

;;; NoGC never traces, forwards or reclaims.
(defmethod prepare-space ((space nogc-space) cycle)
  (declare (ignore space cycle))
  (values))

(defmethod trace-object ((space nogc-space)
                         (context sequential-trace-context) start)
  (declare (ignore context))
  start)

(defmethod object-live-p ((space nogc-space) cycle reference)
  "NoGC never proves an object dead; a live encoding stays live, a dead one is
not NoGC's judgment to make.  Returning true keeps the common conditional and
finalizer closure from inventing reclamation."
  (declare (ignore cycle))
  (let ((model (%space-model space)))
    (and (valid-reference-p model reference) t)))

(defmethod reclaim-space ((space nogc-space) cycle)
  "An empty candidate: no survivor extents, no holes, no new generation."
  (declare (ignore space cycle))
  (values :ready nil))

(defmethod cancel-reclaim-space ((space nogc-space) cycle)
  (declare (ignore space cycle))
  (values))

(defmethod finish-space ((space nogc-space) cycle)
  (declare (ignore space cycle))
  (values))

(defclass nogc-plan (sequential-runtime-plan) ())

(defmethod %plan-trusts-space-in-cycle-p ((plan nogc-plan) space)
  (declare (ignore plan space))
  nil)

;;; NoGC never discovers an object, so a single capacity cell is enough to make
;;; the shared trace context and cycle storage well-formed.
(defmethod %plan-required-work-capacity ((plan nogc-plan))
  (declare (ignore plan)) 0)

(defun make-nogc-plan (&key space root-client coordinator diagnostics registry
                         trace-capacity conditional-capacity finalizer-capacity
                         packing-quantum allocation-routes)
  (unless (and (typep space 'nogc-space)
               (= (%space-packing-quantum space) packing-quantum))
    (%runtime-reject :invalid-nogc-space))
  (%make-common-plan-instance
   'nogc-plan :root-client root-client
   :coordinator coordinator :diagnostics diagnostics :registry registry
   :spaces (list space) :trace-capacity trace-capacity
   :conditional-capacity conditional-capacity
   :finalizer-capacity finalizer-capacity :packing-quantum packing-quantum
   :allocation-routes (or allocation-routes (list (list :default space :all)))
   :movement-participants nil
   :default-algorithm :nogc :algorithms '(:nogc)))
