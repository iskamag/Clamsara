;;;; Optional paper-v14 sequential generational composition.
(in-package #:clamsara)

(defclass generational-nursery-space (semispace-space) ())
(defclass generational-mature-space (marksweep-space) ())

(defclass generational-plan (sequential-runtime-plan)
  ((nursery-from :initarg :nursery-from :reader %gen-nursery-from)
   (nursery-to :initarg :nursery-to :reader %gen-nursery-to)
   (mature :initarg :mature :reader %gen-mature)
   (state-resource-id :initform (gensym "GENERATIONAL-STATE-")
                      :reader %gen-state-resource-id)
   (source-resource-id :initform (gensym "GENERATIONAL-SOURCES-")
                       :reader %gen-source-resource-id)
   (mature-source-starts :initform nil :accessor %gen-mature-source-starts)
   (promotion-addresses :initform nil :accessor %gen-promotion-addresses)
   (promotion-present :initform nil :accessor %gen-promotion-present)
   (promotion-destinations :initform nil
                           :accessor %gen-promotion-destinations)
   (scratch-starts :initform nil :accessor %gen-scratch-starts)
   (scratch-limits :initform nil :accessor %gen-scratch-limits)
   (scratch-count :initform 0 :accessor %gen-scratch-count)
   (nursery-object-count :initform 0 :accessor %gen-nursery-object-count)
   (mature-object-count :initform 0 :accessor %gen-mature-object-count)
   (reservation-failure :initform nil :accessor %gen-reservation-failure)
   ;; A single conservative card covers the entire mature range.
   (remembered-dirty-p :initform nil :accessor %gen-remembered-dirty-p)
   (remembered-candidate-p :initform nil
                           :accessor %gen-remembered-candidate-p)
   (barrier-descriptions :initform nil :accessor %gen-barrier-descriptions)
   ;; Fixed construction-time enumeration callbacks use these dynamic slots.
   (enumeration-cycle :initform nil :accessor %gen-enumeration-cycle)
   (enumeration-function :initform nil :accessor %gen-enumeration-function)
   (enumeration-mode :initform nil :accessor %gen-enumeration-mode)
   (nursery-callback :initform nil :accessor %gen-nursery-callback)
   (mature-callback :initform nil :accessor %gen-mature-callback)))

(defclass generational-remembered-contribution ()
  ((plan :initarg :plan :reader %gen-contribution-plan)))

(defmethod describe-barrier-contribution
    ((contribution generational-remembered-contribution))
  (values :generational-remembered '(:store :cas) nil nil nil nil nil
          :observe :retry-before-exposure/fatal-after))

(defun make-generational-nursery-space
    (&key name object-start-map forwarding extent packing-quantum role)
  (unless (member role '(:allocation :reserve))
    (%runtime-reject :invalid-space-role))
  (unless (and (typep extent '(integer 1 *))
               (%positive-power-of-two-p packing-quantum)
               (zerop (mod extent packing-quantum)))
    (%runtime-reject :invalid-space-extent))
  (make-instance 'generational-nursery-space
                 :name name :object-start-map object-start-map
                 :forwarding forwarding :extent extent
                 :packing-quantum packing-quantum :role role))

(defun make-generational-mature-space
    (&key name object-start-map marks extent packing-quantum
          descriptor-capacity)
  (unless (and (typep descriptor-capacity '(integer 1 *))
               (typep extent '(integer 1 *))
               (%positive-power-of-two-p packing-quantum)
               (zerop (mod extent packing-quantum)))
    (%runtime-reject :invalid-marksweep-space))
  (make-instance 'generational-mature-space
                 :name name :object-start-map object-start-map :marks marks
                 :extent extent :packing-quantum packing-quantum
                 :descriptor-capacity descriptor-capacity))

(defmethod component-constraints ((plan generational-plan))
  (list (make-construction-constraint
         plan :equal-extent
         (list (list :placement
                     (%space-placement-id (%gen-nursery-from plan)))
               (list :placement
                     (%space-placement-id (%gen-nursery-to plan))))
         :description "Generational nursery ranges have equal Q capacity")))

(defmethod component-resources ((plan generational-plan))
  (let* ((trace-capacity (%plan-trace-capacity plan))
         (descriptor-capacity
           (%marksweep-descriptor-capacity (%gen-mature plan)))
         (entries (+ (* 3 trace-capacity) (* 2 descriptor-capacity))))
    (append
     (call-next-method)
     (list (make-resource-contribution
            plan (%gen-state-resource-id plan) :runtime-index-vector
            :minimum-physical-bytes (+ 16 (* 8 entries))
            :logical-entry-bound entries :auxiliary-bytes 8192
            :allocation-context :construction-only
            :exhaustion-action :reject-before-publication)
           (make-resource-contribution
            plan (%gen-source-resource-id plan) :runtime-object-vector
            :minimum-physical-bytes (+ 16 (* 8 trace-capacity))
            :logical-entry-bound trace-capacity :auxiliary-bytes 1024
            :allocation-context :construction-only
            :exhaustion-action :reject-before-publication)))))

(defmethod component-barrier-contributions ((plan generational-plan))
  (%gen-barrier-descriptions plan))

(defmethod map-construction-auxiliary-storage
    ((plan generational-plan) function)
  (call-next-method)
  (dolist (description (%gen-barrier-descriptions plan))
    (funcall function description))
  (%map-construction-cons-storage (%gen-barrier-descriptions plan) function)
  (values))

(defun %gen-entry-count (plan)
  (+ (* 3 (%plan-trace-capacity plan))
     (* 2 (%marksweep-descriptor-capacity (%gen-mature plan)))))

(defmethod initialize-component :after
    ((plan generational-plan) construction)
  (let ((expected (%gen-entry-count plan))
        (trace-capacity (%plan-trace-capacity plan))
        (descriptor-capacity
          (%marksweep-descriptor-capacity (%gen-mature plan))))
    (multiple-value-bind (storage present-p physical entries auxiliary)
        (construction-resource construction (%gen-state-resource-id plan))
      (unless (and present-p (typep storage 'simple-vector)
                   (>= physical (+ 16 (* 8 expected)))
                   (>= entries expected) (>= (length storage) expected)
                   (>= auxiliary 8192))
        (%runtime-reject :resource-capacity-mismatch))
      (let ((offset 0))
        (labels ((view (count)
                   (prog1 (make-array count :displaced-to storage
                                      :displaced-index-offset offset)
                     (incf offset count))))
          (setf (%gen-promotion-addresses plan) (view trace-capacity)
                (%gen-promotion-present plan) (view trace-capacity)
                (%gen-promotion-destinations plan) (view trace-capacity)
                (%gen-scratch-starts plan) (view descriptor-capacity)
                (%gen-scratch-limits plan) (view descriptor-capacity)))
        (unless (= offset expected)
          (%runtime-reject :resource-capacity-mismatch)))
      (fill (%gen-promotion-addresses plan) 0)
      (fill (%gen-promotion-present plan) 0)
      (fill (%gen-promotion-destinations plan) 0)
      (fill (%gen-scratch-starts plan) 0)
      (fill (%gen-scratch-limits plan) 0)
      (setf (%gen-nursery-callback plan)
            (lambda (key value)
              (declare (ignore value))
              (%gen-reserve-nursery-start plan key))
            (%gen-mature-callback plan)
            (lambda (key value)
              (declare (ignore value))
              (%gen-visit-mature-start plan key)))
      (dolist (object (list (%gen-promotion-addresses plan)
                            (%gen-promotion-present plan)
                            (%gen-promotion-destinations plan)
                            (%gen-scratch-starts plan)
                            (%gen-scratch-limits plan)
                            (%gen-nursery-callback plan)
                            (%gen-mature-callback plan)))
        (%register-resource-auxiliary
         construction (%gen-state-resource-id plan) object)))
    (multiple-value-bind (objects present-p physical entries auxiliary)
        (construction-resource construction (%gen-source-resource-id plan))
      (unless (and present-p (typep objects 'simple-vector)
                   (>= physical (+ 16 (* 8 trace-capacity)))
                   (>= entries trace-capacity) (>= (length objects) trace-capacity)
                   (>= auxiliary 1024))
        (%runtime-reject :resource-capacity-mismatch))
      (setf (%gen-mature-source-starts plan)
            (make-array trace-capacity :displaced-to objects))
      (fill (%gen-mature-source-starts plan) nil)
      (%register-resource-auxiliary
       construction (%gen-source-resource-id plan)
       (%gen-mature-source-starts plan))))
  (values))

(defmethod validate-component :after
    ((plan generational-plan) configuration)
  (declare (ignore configuration))
  (let* ((from (%gen-nursery-from plan))
         (to (%gen-nursery-to plan))
         (mature (%gen-mature plan))
         (q (%plan-packing-quantum plan)))
    (unless (and (typep from 'generational-nursery-space)
                 (typep to 'generational-nursery-space)
                 (typep mature 'generational-mature-space)
                 (= (%space-extent from) (%space-extent to))
                 (= (%space-packing-quantum from) q)
                 (= (%space-packing-quantum to) q)
                 (= (%space-packing-quantum mature) q)
                 (eq (%semispace-role from) :allocation)
                 (eq (%semispace-role to) :reserve))
      (%runtime-reject :invalid-generational-spaces)))
  (values))

(defun make-generational-plan
    (&key nursery-from nursery-to mature root-client coordinator diagnostics
          registry trace-capacity conditional-capacity finalizer-capacity
          packing-quantum allocation-routes)
  (unless (and (typep nursery-from 'generational-nursery-space)
               (typep nursery-to 'generational-nursery-space)
               (typep mature 'generational-mature-space)
               (= (%space-extent nursery-from) (%space-extent nursery-to))
               (= (%space-packing-quantum nursery-from) packing-quantum)
               (= (%space-packing-quantum nursery-to) packing-quantum)
               (= (%space-packing-quantum mature) packing-quantum)
               (eq (%semispace-role nursery-from) :allocation)
               (eq (%semispace-role nursery-to) :reserve))
    (%runtime-reject :invalid-generational-spaces))
  (setf (%semispace-partner nursery-from) nursery-to
        (%semispace-partner nursery-to) nursery-from)
  (let ((plan
          (%make-common-plan-instance
           'generational-plan
           :nursery-from nursery-from :nursery-to nursery-to :mature mature
           :root-client root-client :coordinator coordinator
           :diagnostics diagnostics :registry registry
           :spaces (list nursery-from nursery-to mature)
           :trace-capacity trace-capacity
           :conditional-capacity conditional-capacity
           :finalizer-capacity finalizer-capacity
           :packing-quantum packing-quantum
           :allocation-routes
           (or allocation-routes
               (list (list :default nursery-from :minor)))
           :default-algorithm :generational
           :algorithms '(:generational))))
    (setf (%gen-barrier-descriptions plan)
          (list (make-instance 'generational-remembered-contribution
                               :plan plan)))
    plan))

;;; ------------------------------------------------------------------
;;; Fixed conservative remembered-set barrier.

(defmethod barrier-contribution-reserve
    ((contribution generational-remembered-contribution)
     context operation location)
  (declare (ignore context operation location))
  (values contribution :ready))

(defmethod barrier-contribution-admit
    ((contribution generational-remembered-contribution)
     reservation context operation location)
  (declare (ignore context operation location))
  (if (eq reservation contribution) :complete :retry))

(defmethod barrier-contribution-before-exposure
    ((contribution generational-remembered-contribution)
     reservation context operation location old final)
  (declare (ignore contribution reservation context operation location old final))
  (values))

(defmethod barrier-contribution-after-exposure
    ((contribution generational-remembered-contribution)
     reservation context operation location old final)
  (declare (ignore context operation location old final))
  (unless (eq reservation contribution)
    (%runtime-reject :fatal-invariant))
  (setf (%gen-remembered-dirty-p (%gen-contribution-plan contribution)) t)
  (values))

(defmethod barrier-contribution-cancel
    ((contribution generational-remembered-contribution) reservation)
  (unless (eq reservation contribution)
    (%runtime-reject :fatal-invariant))
  (values))

;;; ------------------------------------------------------------------
;;; Scope and bounded promotion reservation.

(defmethod %plan-stop-scope ((plan generational-plan) cycle)
  (declare (ignore plan cycle))
  ;; The hosted coordinator currently offers a complete global stop; this is
  ;; a conservative superset of the minor plan's declared mutator coverage.
  :all)

(defmethod %plan-scope-supported-p ((plan generational-plan) scope)
  (declare (ignore plan))
  (member scope '(:minor :all) :test #'eq))

(defun %gen-active-nursery (plan)
  (find :allocation
        (list (%gen-nursery-from plan) (%gen-nursery-to plan))
        :key #'%semispace-role :test #'eq))

(defun %gen-reserve-cell-index (plan source address)
  (let ((index (floor (- address (%space-base source))
                      (%space-packing-quantum source))))
    (and (<= 0 index) (< index (length (%gen-promotion-addresses plan)))
         index)))

(defun %gen-mature-cell-index (plan address)
  (let* ((mature (%gen-mature plan))
         (index (floor (- address (%space-base mature))
                       (%space-packing-quantum mature))))
    (and (<= 0 index) (< index (length (%gen-promotion-destinations plan)))
         index)))

(defun %gen-scratch-allocate (plan bytes alignment)
  (dotimes (index (%gen-scratch-count plan) (values nil nil))
    (let* ((old (aref (%gen-scratch-starts plan) index))
           (start (%align-up old alignment))
           (end (+ start bytes)))
      (when (and (= start old)
                 (>= end start)
                 (<= end (aref (%gen-scratch-limits plan) index)))
        (setf (aref (%gen-scratch-starts plan) index) end)
        (return (values start t))))))

(defun %gen-reserve-nursery-start (plan address)
  (when (%gen-reservation-failure plan) (return-from %gen-reserve-nursery-start))
  (let* ((source (%gen-active-nursery plan))
         (model (%space-model source))
         (start (runtime-start-reference model source address))
         (bytes (object-size model start))
         (alignment (object-alignment model start))
         (charged (%align-up bytes (%space-packing-quantum source)))
         (cell (%gen-reserve-cell-index plan source address)))
    (unless (and cell (%positive-power-of-two-p alignment)
                 (<= alignment (%space-packing-quantum source)))
      (setf (%gen-reservation-failure plan) :fatal-invariant)
      (return-from %gen-reserve-nursery-start))
    (multiple-value-bind (destination success-p)
        (%gen-scratch-allocate plan charged (%space-packing-quantum source))
      (unless success-p
        (setf (%gen-reservation-failure plan) :capacity-exhausted)
        (return-from %gen-reserve-nursery-start))
      (setf (aref (%gen-promotion-addresses plan) cell) destination
            (aref (%gen-promotion-present plan) cell) 1)
      (incf (%gen-nursery-object-count plan))))
  (values))

(defun %gen-snapshot-mature-start (plan address)
  (let ((index (%gen-mature-object-count plan)))
    (when (>= index (length (%gen-mature-source-starts plan)))
      (setf (%gen-reservation-failure plan) :capacity-exhausted)
      (return-from %gen-snapshot-mature-start))
    (let ((mature (%gen-mature plan)))
      (setf (aref (%gen-mature-source-starts plan) index)
            (runtime-start-reference (%space-model mature) mature address))
      (incf (%gen-mature-object-count plan))))
  (values))

(defun %gen-snapshot-mature-sources (plan cycle)
  (fill (%gen-mature-source-starts plan) nil)
  (setf (%gen-mature-object-count plan) 0
        (%gen-reservation-failure plan) nil
        (%gen-enumeration-cycle plan) cycle
        (%gen-enumeration-mode plan) :snapshot)
  (let ((mature (%gen-mature plan)))
    (metadata-map-present (%space-object-start-map mature)
                          (%space-range mature)
                          (%gen-mature-callback plan)))
  (if (%gen-reservation-failure plan)
      (values :failed (%gen-reservation-failure plan))
      (values :complete nil)))

(defun %gen-copy-active-free-list (plan)
  (let* ((allocator (%space-allocator (%gen-mature plan)))
         (count (%free-count allocator)))
    (when (> count (length (%gen-scratch-starts plan)))
      (return-from %gen-copy-active-free-list nil))
    (setf (%gen-scratch-count plan) count)
    (dotimes (index count)
      (setf (aref (%gen-scratch-starts plan) index)
            (aref (%free-starts allocator) index)
            (aref (%gen-scratch-limits plan) index)
            (aref (%free-limits allocator) index)))
    t))

(defun %gen-reserve-promotions (plan cycle)
  (fill (%gen-promotion-addresses plan) 0)
  (fill (%gen-promotion-present plan) 0)
  (fill (%gen-promotion-destinations plan) 0)
  (setf (%gen-nursery-object-count plan) 0
        (%gen-reservation-failure plan) nil
        (%gen-enumeration-cycle plan) cycle)
  (unless (%gen-copy-active-free-list plan)
    (return-from %gen-reserve-promotions (values :failed :capacity-exhausted)))
  (let ((source (%gen-active-nursery plan))
        (mature (%gen-mature plan)))
    (metadata-map-present (%space-object-start-map source) (%space-range source)
                          (%gen-nursery-callback plan))
    (when (%gen-reservation-failure plan)
      (return-from %gen-reserve-promotions
        (values :failed (%gen-reservation-failure plan))))
    ;; Any subset of the reserved objects can create at most one additional
    ;; free interval per possible nursery object.
    (when (> (1+ (+ (%gen-mature-object-count plan)
                    (%gen-nursery-object-count plan)))
             (%marksweep-descriptor-capacity mature))
      (return-from %gen-reserve-promotions
        (values :failed :capacity-exhausted))))
  (values :complete nil))

(defmethod %prepare-cycle-spaces ((plan generational-plan) cycle)
  (prepare-space (%gen-nursery-from plan) cycle)
  (prepare-space (%gen-nursery-to plan) cycle)
  (when (eq (%cycle-scope cycle) :all)
    (prepare-space (%gen-mature plan) cycle))
  (setf (%gen-remembered-candidate-p plan) nil)
  (multiple-value-bind (status reason)
      (%gen-snapshot-mature-sources plan cycle)
    (unless (eq status :complete)
      (return-from %prepare-cycle-spaces (values status reason))))
  (%gen-reserve-promotions plan cycle))

;;; ------------------------------------------------------------------
;;; Promotion and scope.

(defun %gen-promotion-destination (plan source start)
  (let* ((address (reference-address (%space-model source) start))
         (cell (%gen-reserve-cell-index plan source address)))
    (unless (and cell (eql 1 (aref (%gen-promotion-present plan) cell)))
      (%runtime-reject :fatal-invariant))
    (aref (%gen-promotion-addresses plan) cell)))

(defun %gen-current-promotion-destination-p (plan start)
  (let* ((mature (%gen-mature plan))
         (address (reference-address (%space-model mature) start))
         (cell (%gen-mature-cell-index plan address)))
    (and cell (eql 1 (aref (%gen-promotion-destinations plan) cell)))))

(defmethod %space-in-cycle-scope-p
    ((space generational-nursery-space) cycle start)
  (declare (ignore start))
  (and (member (%cycle-scope cycle) '(:minor :all) :test #'eq)
       (eq (%semispace-role space) :allocation)))

(defmethod %space-in-cycle-scope-p
    ((space generational-mature-space) cycle start)
  (let ((plan (%cycle-plan cycle)))
    (and (eq (%cycle-scope cycle) :all)
         (not (%gen-current-promotion-destination-p plan start)))))

(defmethod trace-object ((space generational-nursery-space)
                         (context sequential-trace-context) start)
  (multiple-value-bind (status claim reservation)
      (trace-claim-object context space start)
    (case status
      (:seen
       (unless (eq :complete (trace-await-claim context space start))
         (trace-fail context :fatal-invariant)
         (return-from trace-object start))
       (or (metadata-ref (%space-forwarding space)
                         (%forwarding-key space start))
           (progn (trace-fail context :fatal-invariant) start)))
      (:failed start)
      (:first
       (let* ((cycle (trace-context-cycle context))
              (plan (%cycle-plan cycle))
              (destination (%gen-mature plan))
              (model (%space-model space))
              (bytes (object-size model start))
              (alignment (object-alignment model start))
              (address (%gen-promotion-destination plan space start))
              (new nil)
              (destination-start-p nil)
              (destination-cell (%gen-mature-cell-index plan address)))
         (unless (and destination-cell (typep bytes '(integer 1 *))
                      (%positive-power-of-two-p alignment)
                      (<= alignment (%space-packing-quantum space)))
           (trace-abandon-object context claim reservation :fatal-invariant)
           (return-from trace-object start))
         (handler-case
             (let* ((kind (object-kind model start))
                    (descriptor (object-kind-descriptor model kind)))
               (setf new (initialize-object model address kind bytes descriptor))
               (copy-object-representation model start new)
               (metadata-set (%space-object-start-map destination) address 1)
               (setf destination-start-p t
                     (aref (%gen-promotion-destinations plan)
                           destination-cell) 1)
               (when (eq (%cycle-scope cycle) :all)
                 (metadata-set-bit (%space-marks destination) address))
               (metadata-set (%space-forwarding space)
                             (%forwarding-key space start) new)
               (setf (%cycle-forwarding-published-p cycle) t)
               (unless (%record-cycle-movement cycle start new)
                 (trace-fail context :post-publication-failure)
                 (return-from trace-object start))
               (%cycle-counter-incf cycle :bytes-moved bytes)
               (unless (eq :complete
                           (trace-commit-object context claim reservation
                                                destination new))
                 (trace-fail context :post-publication-failure)
                 (return-from trace-object start))
               new)
           (error ()
             (if (%cycle-forwarding-published-p cycle)
                 (trace-fail context :post-publication-failure)
                 (progn
                   (when destination-start-p
                     (metadata-reset (%space-object-start-map destination)
                                     address)
                     (setf (aref (%gen-promotion-destinations plan)
                                 destination-cell) 0))
                   (when new
                     (runtime-retire-object-representation model new))
                   (trace-abandon-object context claim reservation
                                         :preflight-failed)))
             start)))))))

;;; ------------------------------------------------------------------
;;; Mature remembered sources and conditional closure.

(defun %gen-visit-mature-start (plan address)
  (case (%gen-enumeration-mode plan)
    (:snapshot (%gen-snapshot-mature-start plan address))
    (otherwise
     (let* ((cycle (%gen-enumeration-cycle plan))
            (mature (%gen-mature plan))
            (model (%space-model mature))
            (start (runtime-start-reference model mature address)))
       (ecase (%gen-enumeration-mode plan)
         (:strong
          (map-reference-locations model start
                                   (%cycle-strong-callback cycle)))
         (:conditional
          (funcall (%gen-enumeration-function plan) mature start))
         (:free
          (let* ((bytes (object-size model start))
                 (end (+ address
                         (%align-up bytes
                                    (%space-packing-quantum mature)))))
            (unless (and (>= address (%marksweep-reclaim-cursor mature))
                         (> end address) (<= end (%space-limit mature)))
              (trace-fail (%cycle-trace cycle) :fatal-invariant)
              (return-from %gen-visit-mature-start))
            (unless (%marksweep-add-free
                     mature (%marksweep-reclaim-free-start mature) address)
              (trace-fail (%cycle-trace cycle) :capacity-exhausted)
              (return-from %gen-visit-mature-start))
            (setf (%marksweep-reclaim-cursor mature) end
                  (%marksweep-reclaim-free-start mature) end)))))))
  (values))

(defmethod %trace-plan-additional-roots ((plan generational-plan) cycle)
  (when (and (eq (%cycle-scope cycle) :minor)
             (%gen-remembered-dirty-p plan))
    (setf (%gen-enumeration-cycle plan) cycle
          (%gen-enumeration-mode plan) :strong)
    (dotimes (index (%gen-mature-object-count plan))
      (map-reference-locations
       (%space-model (%gen-mature plan))
       (aref (%gen-mature-source-starts plan) index)
       (%cycle-strong-callback cycle))))
  (if (%trace-failed-reason (%cycle-trace cycle))
      (values :failed (%trace-failed-reason (%cycle-trace cycle)))
      (values :complete nil)))

(defmethod %map-plan-conditional-sources
    ((plan generational-plan) cycle function)
  (if (eq (%cycle-scope cycle) :minor)
      (progn
        ;; Preexisting mature sources are snapshotted before any promotion, so
        ;; scanning them cannot mutate the metadata traversal being used.
        (dotimes (index (%gen-mature-object-count plan))
          (funcall function (%gen-mature plan)
                   (aref (%gen-mature-source-starts plan) index)))
        ;; Promoted destinations are ordinary trace discoveries and are not in
        ;; the preexisting mature snapshot.
        (call-next-method))
      (call-next-method))
  (values))

;;; ------------------------------------------------------------------
;;; Reclamation and closed publication.

(defun %gen-build-mature-free-candidate (plan cycle)
  (let ((mature (%gen-mature plan)))
    (setf (%marksweep-reclaim-cycle mature) cycle
          (%marksweep-reclaim-cursor mature) (%space-base mature)
          (%marksweep-reclaim-free-start mature) (%space-base mature)
          (%marksweep-candidate-count mature) 0
          (%marksweep-candidate-ready-p mature) nil
          (%gen-enumeration-cycle plan) cycle
          (%gen-enumeration-mode plan) :free)
    (metadata-map-present (%space-object-start-map mature)
                          (%space-range mature)
                          (%gen-mature-callback plan))
    (unless (%trace-failed-reason (%cycle-trace cycle))
      (unless (%marksweep-add-free
               mature (%marksweep-reclaim-free-start mature)
               (%space-limit mature))
        (trace-fail (%cycle-trace cycle) :capacity-exhausted)))
    (if (%trace-failed-reason (%cycle-trace cycle))
        (values :failed (%trace-failed-reason (%cycle-trace cycle)))
        (progn
          (setf (%marksweep-candidate-ready-p mature) t)
          (values :ready nil)))))

(defun %gen-cancel-ready (plan cycle spaces participants)
  (dotimes (index participants)
    (cancel-movement-participant
     (nth index (%plan-movement-participants plan)) cycle))
  (dolist (space spaces)
    (cancel-reclaim-space space cycle))
  (values))

(defmethod %prepare-plan-reclamation ((plan generational-plan) cycle)
  (let ((ready-spaces nil)
        (ready-participants 0))
    (dolist (space (list (%gen-nursery-from plan) (%gen-nursery-to plan)))
      (multiple-value-bind (status reason) (reclaim-space space cycle)
        (unless (eq status :ready)
          (%gen-cancel-ready plan cycle ready-spaces ready-participants)
          (return-from %prepare-plan-reclamation
            (values :failed (or reason :preflight-failed))))
        (push space ready-spaces)))
    (let ((mature (%gen-mature plan)))
      (multiple-value-bind (status reason)
          (if (eq (%cycle-scope cycle) :all)
              (reclaim-space mature cycle)
              (%gen-build-mature-free-candidate plan cycle))
        (unless (eq status :ready)
          (%gen-cancel-ready plan cycle ready-spaces ready-participants)
          (return-from %prepare-plan-reclamation
            (values :failed (or reason :preflight-failed))))
        (push mature ready-spaces)))
    (dolist (participant (%plan-movement-participants plan))
      (multiple-value-bind (status reason)
          (prepare-movement-participant participant cycle)
        (unless (eq status :ready)
          (%gen-cancel-ready plan cycle ready-spaces ready-participants)
          (return-from %prepare-plan-reclamation
            (values :failed (or reason :preflight-failed))))
        (incf ready-participants)))
    ;; Every reachable nursery object is promoted, and complete mature strong
    ;; and conditional sources were corrected.  The next nursery is empty.
    (setf (%gen-remembered-candidate-p plan) nil)
    (values :complete nil)))

(defun %gen-publish-mature-free-candidate (mature)
  (unless (%marksweep-candidate-ready-p mature)
    (%runtime-reject :fatal-invariant))
  (rotatef (%marksweep-active-starts mature)
           (%marksweep-candidate-starts mature))
  (rotatef (%marksweep-active-limits mature)
           (%marksweep-candidate-limits mature))
  (let ((allocator (%space-allocator mature)))
    (setf (%free-starts allocator) (%marksweep-active-starts mature)
          (%free-limits allocator) (%marksweep-active-limits mature)
          (%free-count allocator) (%marksweep-candidate-count mature)
          (%allocator-last-valid-p allocator) nil))
  (setf (%marksweep-candidate-ready-p mature) nil)
  (values))

(defmethod %finish-plan-reclamation ((plan generational-plan) cycle)
  (dolist (participant (%plan-movement-participants plan))
    (finish-movement-participant participant cycle))
  (finish-space (%gen-nursery-from plan) cycle)
  (finish-space (%gen-nursery-to plan) cycle)
  (if (eq (%cycle-scope cycle) :all)
      (finish-space (%gen-mature plan) cycle)
      (%gen-publish-mature-free-candidate (%gen-mature plan)))
  (setf (%gen-remembered-dirty-p plan)
        (%gen-remembered-candidate-p plan))
  (values :complete nil))
