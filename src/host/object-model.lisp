;;;; src/host/object-model.lisp -- dense serialized hosted object ABI.
;;;;
;;;; The authoritative object-start metadata owned by the installed layout is
;;;; the only allocation/liveness map.  This file owns representation storage:
;;;; one byte arena, one Lisp-word plane, compact per-start descriptor planes,
;;;; immutable per-cell base encodings, and bounded pools for all other opaque
;;;; runtime records.

(in-package #:clamsara)

;;; Construction descriptions ------------------------------------------------

(defstruct (host-slot-description
            (:constructor make-host-slot-description (&key identity offset)))
  identity offset)

(defstruct (host-ephemeron-location-description
            (:constructor make-host-ephemeron-location-description
                (&key identity key-offset value-offset)))
  identity key-offset value-offset)

(defstruct (host-variable-size-rule
            (:constructor make-host-variable-size-rule
                (&key (header-bytes 0) (element-bytes 8)
                      (minimum-elements 0) maximum-elements
                      (element-kind :reference))))
  "Private hosted variable-representation rule.
ELEMENT-KIND is :REFERENCE or :NUMERIC.  The descriptor plane retains the
actual admitted element count; no per-object layout vector is made."
  header-bytes element-bytes minimum-elements maximum-elements element-kind)

(defstruct (host-indexed-layout
            (:constructor make-host-indexed-layout
                (&key (identity-function #'identity) (identity-base 0)
                      (base-offset 0) (element-word-bytes 8)
                      (element-strength :strong))))
  "Private hosted strong layout for a dense indexed reference payload."
  identity-function identity-base base-offset element-word-bytes
  element-strength)

(defstruct (host-object-kind-description
            (:constructor %make-host-kind
                (&key name size-rule alignment-rule strong-layout
                      weak-descriptions ephemeron-descriptions index)))
  name size-rule alignment-rule strong-layout weak-descriptions
  ephemeron-descriptions index)

(defstruct (host-weak-location-description
            (:constructor %make-host-weak
                (&key identity referent-kind cleared-value offset)))
  identity referent-kind cleared-value offset)

(defstruct (host-ephemeron-description
            (:constructor %make-host-ephemeron
                (&key identity clear-key-p cleared-key cleared-value
                      key-offset value-offset)))
  identity clear-key-p cleared-key cleared-value key-offset value-offset)

;;; Bound representation records ---------------------------------------------

(defstruct (host-reference
            (:constructor %make-host-reference
                (&key model descriptor address kind (tag 0) (displacement 0))))
  ;; Once returned or stored, these fields are never changed.  A cell's base
  ;; encoding has the same address bits across ordinary address reuse, as a
  ;; native pointer would.  Allocation generation belongs to locations/handles.
  model descriptor address kind tag displacement)

(defstruct (host-route
            (:constructor %make-host-route
                (&key parent space map base limit granularity cell-count
                      descriptor-offset arena-offset generation)))
  parent space map base limit granularity cell-count descriptor-offset
  arena-offset generation)

(defstruct (host-binding
            (:constructor %make-host-binding
                (&key model space metadata base limit granularity generation)))
  model space metadata base limit granularity generation)

(defstruct (host-reference-location
            (:constructor %make-host-location (&key model)))
  model descriptor generation word-index identity strength active
  stage stage-generation)

(defstruct (host-location-handle
            (:constructor %make-host-handle ()))
  model active descriptor generation identity strength word-index
  stage stage-generation)

(defstruct (host-staged-object
            (:constructor %make-host-stage
                (&key model bytes words)))
  model (state :free) (generation 0) source destination size alignment kind
  descriptor descriptor-index descriptor-generation bytes words)

(defclass host-object-model ()
  ((profile :initarg :profile :initform :sequential-host
            :reader host-model-profile)
   ;; Maximum simultaneously active object representations.  Descriptor
   ;; addressing itself is per possible start quantum and is independent of it.
   (capacity :initarg :capacity :reader host-model-capacity)
   (max-object-bytes :initarg :max-object-bytes
                     :reader host-model-max-object-bytes)
   (variant-capacity :initarg :variant-capacity
                     :reader host-model-variant-capacity)
   (location-capacity :initarg :location-capacity
                      :reader host-model-location-capacity)
   (handle-capacity :initarg :handle-capacity
                    :reader host-model-handle-capacity)
   (stage-capacity :initarg :stage-capacity
                   :reader host-model-stage-capacity)
   (max-interior-displacement :initarg :max-interior-displacement
                              :reader host-model-max-interior-displacement)
   (tag-capacity :initarg :tag-capacity :reader host-model-tag-capacity)
   (kind-capacity :initarg :kind-capacity :reader host-model-kind-capacity)
   (slot-capacity :initarg :slot-capacity :reader host-model-slot-capacity)
   ;; Public opaque allocation tokens stay stable. Execution uses the separate
   ;; binding-owned catalogue and never rereads mutable offered rule fields.
   (kinds :initarg :kinds :reader host-model-kinds)
   (kind-snapshots :initarg :kind-snapshots :initform nil
                   :reader host-model-kind-snapshots)
   (description-snapshots :initarg :description-snapshots :initform nil
                          :reader host-model-description-snapshots)
   (kind-count :initarg :kind-count :initform 0
               :accessor host-model-kind-count)
   (layout :initarg :layout :initform nil :reader host-model-layout)
   (bindings :initarg :bindings :initform #() :reader host-model-bindings)
   (routes :initarg :routes :initform #() :accessor host-model-routes)
   ;; Dense payload planes.
   (arena :initarg :arena :initform nil :reader host-model-arena)
   (words :initarg :words :initform nil :reader host-model-words)
   ;; Parallel per-possible-start descriptor planes.  SIZE=0 is inactive.
   (sizes :initarg :sizes :initform nil :reader host-model-sizes)
   (alignments :initarg :alignments :initform nil
               :reader host-model-alignments)
   (descriptor-kinds :initarg :descriptor-kinds :initform nil
                     :reader host-model-descriptor-kinds)
   (descriptor-generations :initarg :descriptor-generations :initform nil
                           :reader host-model-descriptor-generations)
   (descriptor-counts :initarg :descriptor-counts :initform nil
                      :reader host-model-descriptor-counts)
   (base-references :initarg :base-references :initform nil
                    :reader host-model-base-references)
   (live-count :initform 0 :accessor host-model-live-count)
   ;; Immutable nonbase encodings, provisioned in complete code rows over the
   ;; fixed descriptor domain. COUNT includes reserved, permanently unusable
   ;; cells; no returned record is recycled or retargeted.
   (variants :initarg :variants :initform nil :reader host-model-variants)
   (variant-count :initform 0 :accessor host-model-variant-count)
   (variant-code-keys :initarg :variant-code-keys :initform nil
                      :reader host-model-variant-code-keys)
   (variant-code-rows :initarg :variant-code-rows :initform nil
                      :reader host-model-variant-code-rows)
   (variant-publishing-p :initform nil :accessor host-model-variant-publishing-p)
   ;; Bounded borrowed/runtime pools.
   (locations :initarg :locations :initform nil :reader host-model-locations)
   (handles :initarg :handles :initform nil :reader host-model-handles)
   (handle-count :initform 0 :accessor host-model-handle-count)
   (stages :initarg :stages :initform nil :reader host-model-stages)
   (bound-p :initarg :bound-p :initform nil :reader host-model-bound-p)))

(defclass host-bound-object-model (host-object-model) ())

(defun make-host-object-model
    (&key (capacity 65536) (max-object-bytes 65536)
       (variant-capacity 1024) (location-capacity 8)
       (handle-capacity 1024) (stage-capacity 4)
       (max-interior-displacement 64) max-displacement
       (tag-capacity 8) (kind-capacity 64) (slot-capacity 64)
       (profile :sequential-host))
  "Make the construction-time hosted model offer.
CAPACITY must cover all descriptor cells in the installed layout, including
reserve ranges, at the actual object-start map granularities. Binding rejects
an insufficient explicit offer; it never raises CAPACITY or enlarges a heap.
VARIANT-CAPACITY is the exact number H of preallocated immutable nonbase records.
Zero offers only base encodings. Otherwise H must cover at least one complete
row of C installed descriptor cells. Each canonical nonbase code reserves C
records before its first value escapes; at most FLOOR(H/C) historical codes
are admitted. Nonbase rows require fixnum addresses and 46-bit fixnum codes.
MAX-DISPLACEMENT is accepted only as a compatibility alias; the established
caller ABI is MAX-INTERIOR-DISPLACEMENT."
  (let ((maximum-displacement
          (if max-displacement max-displacement max-interior-displacement)))
    (unless (member profile '(:sequential-host :sequential) :test #'eq)
      (error "Unsupported hosted object-model profile ~S" profile))
    (unless (and (every (lambda (value)
                          (and (integerp value) (plusp value)))
                        (list capacity max-object-bytes
                              location-capacity handle-capacity stage-capacity
                              kind-capacity slot-capacity))
                 (typep variant-capacity '(integer 0 #.most-positive-fixnum))
                 (integerp maximum-displacement)
                 (<= 0 maximum-displacement)
                 (integerp tag-capacity) (<= 0 tag-capacity))
      (error "Invalid hosted object-model capacity"))
    (make-instance 'host-object-model
      :profile profile :capacity capacity :max-object-bytes max-object-bytes
      :variant-capacity variant-capacity
      :location-capacity location-capacity
      :handle-capacity handle-capacity :stage-capacity stage-capacity
      :max-interior-displacement maximum-displacement
      :tag-capacity tag-capacity :kind-capacity kind-capacity
      :slot-capacity slot-capacity :kinds (make-array kind-capacity))))

(defun %host-model (model)
  (unless (typep model 'host-object-model)
    (error "Not a hosted object model"))
  model)

(defun %host-bound-model (model)
  (%host-model model)
  (unless (host-model-bound-p model)
    (error "Object-model operation requires a bound model"))
  model)

(defun %host-copy-vector (vector)
  (let ((copy (make-array (length vector))))
    (replace copy vector)
    copy))

(defun %host-positive-rule-value (rule argument label)
  (let ((value (if (functionp rule) (funcall rule argument) rule)))
    (unless (and (integerp value) (plusp value))
      (error "Invalid ~A rule value ~S" label value))
    value))

(defun %host-positive-power-of-two-p (value)
  (and (integerp value) (plusp value)
       (zerop (logand value (1- value)))))

(defun %host-slot-parts (value default-offset)
  (cond ((typep value 'host-slot-description)
         (values (host-slot-description-identity value)
                 (host-slot-description-offset value)))
        ((and (consp value) (keywordp (car value)))
         (values (getf value :identity)
                 (getf value :offset default-offset)))
        (t (values value default-offset))))

(defun %host-normalize-strong-layout (layout)
  (cond ((typep layout 'host-indexed-layout)
         (let ((word-bytes (host-indexed-layout-element-word-bytes layout))
               (offset (host-indexed-layout-base-offset layout))
               (identity-function
                 (host-indexed-layout-identity-function layout))
               (strength (host-indexed-layout-element-strength layout)))
           (unless (and (eql word-bytes 8) (integerp offset) (<= 0 offset)
                        (zerop (mod offset 8)) (functionp identity-function)
                        (eq strength :strong))
             (error "Invalid hosted indexed reference layout"))
           (copy-host-indexed-layout layout)))
        ;; A deliberately narrow literal spelling is accepted for setup code
        ;; that cannot conveniently retain the private structure constructor.
        ((and (consp layout) (eq (car layout) :indexed))
         (make-host-indexed-layout
          :identity-function (or (getf (cdr layout) :identity-function)
                                 #'identity)
          :identity-base (or (getf (cdr layout) :identity-base) 0)
          :base-offset (or (getf (cdr layout) :base-offset) 0)
          :element-word-bytes (or (getf (cdr layout) :element-word)
                                  (getf (cdr layout) :element-word-bytes)
                                  8)
          :element-strength (or (getf (cdr layout) :element-strength)
                                :strong)))
        (t
         (let* ((source (coerce (or layout '()) 'vector))
                (answer (make-array (length source))))
           (dotimes (index (length source) answer)
             (multiple-value-bind (identity offset)
                 (%host-slot-parts (aref source index) (* index 8))
               (unless (and identity (integerp offset) (<= 0 offset)
                            (zerop (mod offset 8)))
                 (error "Invalid strong location description"))
               (setf (aref answer index)
                     (make-host-slot-description
                      :identity identity :offset offset))))))))

(defun %host-kind-description (model designator)
  (let ((snapshots (host-model-kind-snapshots model)))
    (or (and (typep designator 'host-object-kind-description)
             (if snapshots
                 (gethash designator (host-model-description-snapshots model))
                 (find designator (host-model-kinds model) :test #'eq
                       :end (host-model-kind-count model))))
        (loop for index below (host-model-kind-count model)
              for description = (aref (or snapshots (host-model-kinds model)) index)
              when (equal designator (host-object-kind-description-name description))
                do (return description)))))

(defun %host-kind-allocation-token (model kind)
  (if (host-model-kind-snapshots model)
      (aref (host-model-kinds model) (host-object-kind-description-index kind))
      kind))

(defun %host-kind-description! (model designator)
  (or (%host-kind-description model designator)
      (error "Unknown/foreign object kind ~S" designator)))

(defun %host-check-kind-key-unique (seen strength identity)
  (unless identity (error "NIL object location identity"))
  (let ((key (cons strength identity)))
    ;; Construction only.  EQL is the normative identity relation.
    (when (find key seen :test
                (lambda (left right)
                  (and (eq (car left) (car right))
                       (eql (cdr left) (cdr right)))))
      (error "Duplicate object location identity ~S/~S" strength identity))
    (push key seen)))

(defun %host-validate-size-layout-rule (size-rule strong)
  (let ((indexed-p (typep strong 'host-indexed-layout)))
    (when (typep size-rule 'host-variable-size-rule)
      (let ((header (host-variable-size-rule-header-bytes size-rule))
            (element (host-variable-size-rule-element-bytes size-rule))
            (minimum (host-variable-size-rule-minimum-elements size-rule))
            (maximum (host-variable-size-rule-maximum-elements size-rule))
            (element-kind (host-variable-size-rule-element-kind size-rule)))
        (unless (and (integerp header) (<= 0 header)
                     (integerp element) (plusp element)
                     (integerp minimum) (<= 0 minimum)
                     (or (null maximum)
                         (and (integerp maximum) (>= maximum minimum)))
                     (member element-kind '(:reference :numeric) :test #'eq))
          (error "Invalid hosted variable-size rule"))
        (when indexed-p
          (unless (and (eq element-kind :reference)
                       (= header (host-indexed-layout-base-offset strong))
                       (= element
                          (host-indexed-layout-element-word-bytes strong)))
            (error "Indexed layout and variable-size rule disagree")))))
    (unless (or (typep size-rule 'host-variable-size-rule)
                (integerp size-rule) (functionp size-rule))
      (error "Invalid object size rule"))
    (values)))

(defmethod make-object-kind-description
    ((model host-object-model) name
     &key size-rule alignment-rule strong-layout weak-descriptions
       ephemeron-descriptions)
  (%host-model model)
  (when (or (null name) (%host-kind-description model name))
    (error "Duplicate or empty object kind ~S" name))
  (when (>= (host-model-kind-count model) (host-model-kind-capacity model))
    (error "Object-kind capacity exhausted"))
  (let* ((strong (%host-normalize-strong-layout strong-layout))
         (weak (%host-copy-vector (coerce (or weak-descriptions '()) 'vector)))
         (ephemerons
           (%host-copy-vector (coerce (or ephemeron-descriptions '()) 'vector)))
         (indexed-p (typep strong 'host-indexed-layout))
         (fixed-strong-count (if indexed-p 0 (length strong)))
         (seen nil))
    (when (and indexed-p (or (plusp (length weak))
                             (plusp (length ephemerons))))
      (error "Indexed strong layouts cannot mix conditional locations"))
    (when (> (+ fixed-strong-count (length weak) (* 2 (length ephemerons)))
             (host-model-slot-capacity model))
      (error "Fixed object location capacity exhausted"))
    (when (and (plusp (length ephemerons))
               (< (host-model-location-capacity model) 2))
      (error "Ephemeron mapping needs two borrowed locations"))
    (unless indexed-p
      (dotimes (index (length strong))
        (let ((slot (aref strong index)))
          (setf seen (%host-check-kind-key-unique
                      seen :strong (host-slot-description-identity slot))))))
    (dotimes (index (length weak))
      (let ((description (aref weak index)))
        (unless (typep description 'host-weak-location-description)
          (error "Foreign weak location description"))
        (setf seen (%host-check-kind-key-unique
                    seen :weak
                    (host-weak-location-description-identity description)))))
    (dotimes (index (length ephemerons))
      (let ((description (aref ephemerons index)))
        (unless (typep description 'host-ephemeron-description)
          (error "Foreign ephemeron description"))
        (setf seen (%host-check-kind-key-unique
                    seen :ephemeron
                    (host-ephemeron-description-identity description)))))
    (%host-validate-size-layout-rule size-rule strong)
    (let ((description
            (%make-host-kind
             :name name :size-rule size-rule
             :alignment-rule alignment-rule :strong-layout strong
             :weak-descriptions weak :ephemeron-descriptions ephemerons
             :index (host-model-kind-count model))))
      (setf (aref (host-model-kinds model)
                  (host-model-kind-count model)) description)
      (incf (host-model-kind-count model))
      description)))

(defmethod describe-object-kind
    ((model host-object-model) description)
  (%host-model model)
  (let ((kind (%host-kind-description! model description)))
    (values (host-object-kind-description-name kind)
            (host-object-kind-description-size-rule kind)
            (host-object-kind-description-alignment-rule kind)
            (host-object-kind-description-strong-layout kind)
            (host-object-kind-description-weak-descriptions kind)
            (host-object-kind-description-ephemeron-descriptions kind))))

(defun %host-admitted-immediate-value-p (value)
  "Return true only for represented non-reference word values."
  (or (symbolp value) (typep value 'fixnum) (characterp value)
      (typep value 'single-float)))

(defun %host-admitted-reference-value-p (model value)
  (or (valid-reference-p model value)
      (%host-admitted-immediate-value-p value)))

(defmethod make-weak-location-description
    ((model host-object-model) identity referent-kind cleared-value)
  (%host-model model)
  (unless (and (%host-admitted-immediate-value-p cleared-value)
               (not (valid-reference-p model cleared-value)))
    (error "Weak cleared value must be an admitted immediate value"))
  (multiple-value-bind (actual-identity offset) (%host-slot-parts identity 0)
    (unless (and actual-identity (integerp offset) (<= 0 offset)
                 (zerop (mod offset 8)))
      (error "Invalid weak location description"))
    (%make-host-weak :identity actual-identity :referent-kind referent-kind
                     :cleared-value cleared-value :offset offset)))

(defmethod describe-weak-location
    ((model host-object-model) description)
  (%host-model model)
  (unless (typep description 'host-weak-location-description)
    (error "Foreign weak location description"))
  (values (host-weak-location-description-identity description)
          (host-weak-location-description-referent-kind description)
          (host-weak-location-description-cleared-value description)))

(defmethod make-ephemeron-description
    ((model host-object-model) identity clear-key-p cleared-key cleared-value)
  (%host-model model)
  (unless (and (%host-admitted-immediate-value-p cleared-key)
               (%host-admitted-immediate-value-p cleared-value)
               (not (valid-reference-p model cleared-key))
               (not (valid-reference-p model cleared-value)))
    (error "Ephemeron cleared values must be admitted immediate values"))
  (let ((actual-identity identity) (key-offset 0) (value-offset 8))
    (when (typep identity 'host-ephemeron-location-description)
      (setf actual-identity
            (host-ephemeron-location-description-identity identity)
            key-offset
            (host-ephemeron-location-description-key-offset identity)
            value-offset
            (host-ephemeron-location-description-value-offset identity)))
    (unless (and actual-identity
                 (integerp key-offset) (<= 0 key-offset)
                 (zerop (mod key-offset 8))
                 (integerp value-offset) (<= 0 value-offset)
                 (zerop (mod value-offset 8)))
      (error "Invalid ephemeron location description"))
    (%make-host-ephemeron
     :identity actual-identity :clear-key-p (not (null clear-key-p))
     :cleared-key cleared-key :cleared-value cleared-value
     :key-offset key-offset :value-offset value-offset)))

(defmethod describe-ephemeron
    ((model host-object-model) description)
  (%host-model model)
  (unless (typep description 'host-ephemeron-description)
    (error "Foreign ephemeron description"))
  (values (host-ephemeron-description-identity description)
          (host-ephemeron-description-clear-key-p description)
          (host-ephemeron-description-cleared-key description)
          (host-ephemeron-description-cleared-value description)))

;;; Installed layout/binding adapter -----------------------------------------

(defun %host-function (name)
  (let ((symbol (find-symbol name :clamsara)))
    (and symbol (fboundp symbol) (symbol-function symbol))))

(defun %host-layout-ranges (layout)
  (let ((function (%host-function "SIMULATOR-LAYOUT-RANGES")))
    (unless function (error "Installed-layout range service is unavailable"))
    (coerce (funcall function layout) 'vector)))

(defun %host-range-field (range suffix)
  (let ((function
          (%host-function (format nil "%SIMULATOR-LAYOUT-RANGE-~A" suffix))))
    (unless function
      (error "Installed-layout range accessor ~A is unavailable" suffix))
    (funcall function range)))

(defun %host-metadata-geometry (metadata)
  (multiple-value-bind (base limit granularity) (metadata-bounds metadata)
    (unless (and (integerp base) (integerp limit) (<= base limit)
                 (integerp granularity) (plusp granularity))
      (error "Invalid object-start metadata geometry"))
    (values base limit granularity)))

(defmethod make-object-start-binding
    ((model host-object-model) space metadata)
  (%host-model model)
  (multiple-value-bind (base limit granularity) (%host-metadata-geometry metadata)
    (%make-host-binding :model model :space space :metadata metadata
                        :base base :limit limit :granularity granularity
                        :generation 0)))

(defmethod describe-object-start-binding
    ((model host-object-model) binding)
  (%host-model model)
  (unless (and (typep binding 'host-binding)
               (eq model (host-binding-model binding)))
    (error "Foreign object-start binding"))
  (values (host-binding-space binding) (host-binding-metadata binding)))

(defun %host-binding-matches-range-p (binding range)
  (and (eq (host-binding-space binding) (%host-range-field range "SPACE"))
       (eq (host-binding-metadata binding) (%host-range-field range "MAP"))))

(defun %host-next-power-of-two (minimum)
  (let ((value 1))
    (loop while (< value minimum) do (setf value (ash value 1)))
    value))

;;; Binding-owned executable allocation geometry -----------------------------

(defun %host-snapshot-conditional-description (model original snapshots ephemeron-p)
  (or (gethash original snapshots)
      (let ((snapshot
              (if ephemeron-p
                  (multiple-value-bind (identity clear-key-p cleared-key cleared-value)
                      (describe-ephemeron model original)
                    (%make-host-ephemeron
                     :identity identity :clear-key-p clear-key-p
                     :cleared-key cleared-key :cleared-value cleared-value
                     :key-offset (host-ephemeron-description-key-offset original)
                     :value-offset (host-ephemeron-description-value-offset original)))
                  (multiple-value-bind (identity referent-kind cleared)
                      (describe-weak-location model original)
                    (%make-host-weak
                     :identity identity :referent-kind referent-kind
                     :cleared-value cleared
                     :offset (host-weak-location-description-offset original))))))
        (setf (gethash original snapshots) snapshot
              (gethash snapshot snapshots) snapshot)
        snapshot)))

(defun %host-snapshot-kind-catalogue (model)
  ;; Construction only. Fixed function rules take the kind, not an allocation:
  ;; evaluate once here instead of retaining a live closure in the executable
  ;; ABI. Arbitrary closure environments are not copied.
  (let* ((count (host-model-kind-count model))
         (kinds (make-array count))
         (snapshots (make-hash-table :test #'eq :size (max 1 (* 2 count)))))
    (dotimes (index count)
      (let ((original (aref (host-model-kinds model) index)))
        (multiple-value-bind (name size-rule alignment-rule strong weak ephemerons)
            (describe-object-kind model original)
          (let ((snapshot
                  (%make-host-kind
                   :name (if (stringp name) (copy-seq name) name)
                   :size-rule
                   (cond ((functionp size-rule)
                          (%host-positive-rule-value size-rule original "size"))
                         ((typep size-rule 'host-variable-size-rule)
                          (copy-host-variable-size-rule size-rule))
                         (t size-rule))
                   :alignment-rule
                   (if (functionp alignment-rule)
                       (%host-positive-rule-value alignment-rule original "alignment")
                       alignment-rule)
                   :strong-layout (%host-normalize-strong-layout strong)
                   :weak-descriptions
                   (map 'vector
                        (lambda (description)
                          (%host-snapshot-conditional-description model description snapshots nil))
                        weak)
                   :ephemeron-descriptions
                   (map 'vector
                        (lambda (description)
                          (%host-snapshot-conditional-description model description snapshots t))
                        ephemerons)
                   :index index)))
            (%host-validate-size-layout-rule
             (host-object-kind-description-size-rule snapshot)
             (host-object-kind-description-strong-layout snapshot))
            (setf (aref kinds index) snapshot
                  (gethash original snapshots) snapshot
                  (gethash snapshot snapshots) snapshot)))))
    (values kinds snapshots)))

(defmethod bind-object-model
    ((model host-object-model) layout object-start-bindings)
  (%host-model model)
  (let ((installed-class (find-class 'simulator-installed-layout nil)))
    (unless (and installed-class (typep layout installed-class))
      (error "Not a simulator installed layout")))
  (let* ((parent-ranges (%host-layout-ranges layout))
         (bindings (coerce object-start-bindings 'vector)))
    (unless (= (length parent-ranges) (length bindings))
      (error "Object-start binding coverage mismatch"))
    ;; Construction-only EQ indexes make exact one-to-one coverage linear in
    ;; the number of routes.  No lookup table survives in the bound model.
    (let ((ranges-by-space (make-hash-table :test #'eq)))
      (dotimes (range-index (length parent-ranges))
        (let* ((range (aref parent-ranges range-index))
               (space (%host-range-field range "SPACE"))
               (map (%host-range-field range "MAP"))
               (maps (or (gethash space ranges-by-space)
                         (setf (gethash space ranges-by-space)
                               (make-hash-table :test #'eq)))))
          (multiple-value-bind (old present-p) (gethash map maps)
            (declare (ignore old))
            (when present-p
              (error "Installed layout has duplicate space/map routes"))
            (setf (gethash map maps) :unmatched))))
      (dotimes (binding-index (length bindings))
        (let ((binding (aref bindings binding-index)))
          (unless (and (typep binding 'host-binding)
                       (eq model (host-binding-model binding)))
            (error "Foreign object-start binding"))
          (let ((maps (gethash (host-binding-space binding)
                               ranges-by-space)))
            (unless maps
              (error "Foreign object-start binding"))
            (multiple-value-bind (state present-p)
                (gethash (host-binding-metadata binding) maps)
              (unless present-p
                (error "Foreign object-start binding"))
              (unless (eq state :unmatched)
                (error "Duplicate object-start binding"))
              (setf (gethash (host-binding-metadata binding) maps)
                    :matched))))))
    (let ((total-bytes 0) (total-cells 0))
      (dotimes (index (length parent-ranges))
        (let* ((range (aref parent-ranges index))
               (base (%host-range-field range "BASE"))
               (limit (%host-range-field range "LIMIT"))
               (map (%host-range-field range "MAP")))
          (multiple-value-bind (map-base map-limit granularity)
              (%host-metadata-geometry map)
            (unless (and (integerp base) (integerp limit) (< base limit)
                         (<= map-base base) (<= limit map-limit)
                         (zerop (mod (- base map-base) granularity))
                         (zerop (mod (- limit base) granularity))
                         (zerop (mod total-bytes 8))
                         (zerop (mod base 8)))
              (error "Installed route and authoritative map geometry disagree"))
            (incf total-bytes (- limit base))
            (incf total-cells (ceiling (- limit base) granularity)))))
      (unless (and (typep total-bytes '(integer 1 #.most-positive-fixnum))
                   (typep total-cells '(integer 1 #.most-positive-fixnum)))
        (error "Hosted model extent is not representable"))
      ;; Each initialized representation occupies a distinct descriptor cell,
      ;; including old sources and unexposed copy destinations.  Cover every
      ;; installed cell before binding: a free destination then cannot exhaust
      ;; the live-count ceiling, regardless of reachability or collection scope.
      ;; This is an admission requirement, never an implicit capacity increase.
      (when (< (host-model-capacity model) total-cells)
        (error "Hosted representation capacity ~D is below required ~D"
               (host-model-capacity model) total-cells))
      (when (plusp (host-model-variant-capacity model))
        (when (< (host-model-variant-capacity model) total-cells)
          (error "Hosted variant capacity ~D is below one complete code row ~D"
                 (host-model-variant-capacity model) total-cells))
        ;; Group publication does only bounded fixnum arithmetic and writes to
        ;; existing records. Do not introduce retained boxed address arithmetic.
        (unless (typep #x3fffffffffff 'fixnum)
          (error "Hosted nonbase codes require 46-bit fixnums"))
        (dotimes (index (length parent-ranges))
          (let ((range (aref parent-ranges index)))
            (unless (and (typep (%host-range-field range "BASE")
                                '(integer 0 #.most-positive-fixnum))
                         (typep (%host-range-field range "LIMIT")
                                '(integer 0 #.most-positive-fixnum)))
              (error "Hosted nonbase code rows require fixnum address bounds")))))
      (let* ((snapshot-data (multiple-value-list (%host-snapshot-kind-catalogue model)))
             (kind-snapshots (first snapshot-data))
             (description-snapshots (second snapshot-data))
             (arena (make-array total-bytes :element-type '(unsigned-byte 8)
                                :initial-element 0))
             (words (make-array (ceiling total-bytes 8) :initial-element nil))
             (sizes (make-array total-cells :initial-element 0))
             (alignments (make-array total-cells :initial-element 0))
             (descriptor-kinds (make-array total-cells :initial-element nil))
             (generations (make-array total-cells :initial-element 0))
             (counts (make-array total-cells :initial-element 0))
             (base-references (make-array total-cells))
             (variants (make-array (host-model-variant-capacity model)))
             (code-capacity (floor (host-model-variant-capacity model) total-cells))
             (hash-size (%host-next-power-of-two (max 4 (* 2 code-capacity))))
             (code-keys (make-array hash-size :initial-element -1))
             (code-rows (make-array hash-size :initial-element -1))
             (locations (make-array (host-model-location-capacity model)))
             (handles (make-array (host-model-handle-capacity model)))
             (stages (make-array (host-model-stage-capacity model)))
             (kind-count (host-model-kind-count model))
             (kinds (make-array kind-count))
             (bound
               (make-instance 'host-bound-object-model
                 :profile (host-model-profile model)
                 :capacity (host-model-capacity model)
                 :max-object-bytes (host-model-max-object-bytes model)
                 :variant-capacity (host-model-variant-capacity model)
                 :location-capacity (host-model-location-capacity model)
                 :handle-capacity (host-model-handle-capacity model)
                 :stage-capacity (host-model-stage-capacity model)
                 :max-interior-displacement
                 (host-model-max-interior-displacement model)
                 :tag-capacity (host-model-tag-capacity model)
                 :kind-capacity (host-model-kind-capacity model)
                 :slot-capacity (host-model-slot-capacity model)
                 :kinds kinds :kind-count kind-count
                 :kind-snapshots kind-snapshots :description-snapshots description-snapshots
                 :layout layout
                 :bindings bindings :arena arena :words words
                 :sizes sizes :alignments alignments
                 :descriptor-kinds descriptor-kinds
                 :descriptor-generations generations
                 :descriptor-counts counts :base-references base-references
                 :variants variants
                 :variant-code-keys code-keys
                 :variant-code-rows code-rows
                 :locations locations :handles handles :stages stages
                 :bound-p t)))
        (replace kinds (host-model-kinds model) :end2 kind-count)
        (dotimes (index (length variants))
          ;; Mutated exactly once, before first publication by REBUILD-REFERENCE.
          (setf (aref variants index)
                (%make-host-reference :model bound :descriptor -1 :address 0
                                      :kind :unpublished)))
        (dotimes (index (length locations))
          (setf (aref locations index) (%make-host-location :model bound)))
        (dotimes (index (length handles))
          (setf (aref handles index) (%make-host-handle)))
        (dotimes (index (length stages))
          (setf (aref stages index)
                (%make-host-stage
                 :model bound
                 :bytes (make-array (host-model-max-object-bytes bound)
                                    :element-type '(unsigned-byte 8)
                                    :initial-element 0)
                 :words (make-array
                         (ceiling (host-model-max-object-bytes bound) 8)
                         :initial-element nil))))
        (let ((routes (make-array (length parent-ranges)))
              (descriptor-offset 0) (arena-offset 0))
          (dotimes (index (length parent-ranges))
            (let* ((parent (aref parent-ranges index))
                   (base (%host-range-field parent "BASE"))
                   (limit (%host-range-field parent "LIMIT"))
                   (map (%host-range-field parent "MAP")))
              (multiple-value-bind (map-base map-limit granularity)
                  (%host-metadata-geometry map)
                (declare (ignore map-base map-limit))
                (let* ((cell-count (ceiling (- limit base) granularity))
                       (route
                         (%make-host-route
                          :parent parent
                          :space (%host-range-field parent "SPACE") :map map
                          :base base :limit limit :granularity granularity
                          :cell-count cell-count
                          :descriptor-offset descriptor-offset
                          :arena-offset arena-offset
                          :generation (%host-range-field parent "GENERATION"))))
                  (setf (aref routes index) route)
                  (dotimes (cell cell-count)
                    (let* ((descriptor (+ descriptor-offset cell))
                           (address (+ base (* cell granularity))))
                      (setf (aref base-references descriptor)
                            (%make-host-reference
                             :model bound :descriptor descriptor
                             :address address :kind :base
                             :tag 0 :displacement 0))))
                  (incf descriptor-offset cell-count)
                  (incf arena-offset (- limit base))))))
          (setf (host-model-routes bound) routes))
        bound))))

;;; Dense descriptor/address helpers -----------------------------------------

(defun %host-refresh-route (route)
  (let ((parent (host-route-parent route)))
    (setf (host-route-space route) (%host-range-field parent "SPACE")
          (host-route-map route) (%host-range-field parent "MAP")
          (host-route-generation route) (%host-range-field parent "GENERATION")))
  route)

(defun %host-route-at-address (model address)
  (when (integerp address)
    (loop for route across (host-model-routes model)
          when (and (<= (host-route-base route) address)
                    (< address (host-route-limit route)))
            do (return (%host-refresh-route route)))))

(defun %host-descriptor-index-at-start (route address)
  (when (and (<= (host-route-base route) address)
             (< address (host-route-limit route))
             (zerop (mod (- address (host-route-base route))
                         (host-route-granularity route))))
    (+ (host-route-descriptor-offset route)
       (floor (- address (host-route-base route))
              (host-route-granularity route)))))

(defun %host-descriptor-active-p (model descriptor)
  (and (integerp descriptor) (<= 0 descriptor)
       (< descriptor (length (host-model-sizes model)))
       (plusp (aref (host-model-sizes model) descriptor))))

(defun %host-base-reference-by-index (model descriptor)
  (and (integerp descriptor) (<= 0 descriptor)
       (< descriptor (length (host-model-base-references model)))
       (aref (host-model-base-references model) descriptor)))

(defun %host-base-reference-at-address (model address)
  (let ((route (%host-route-at-address model address)))
    (and route
         (let ((descriptor (%host-descriptor-index-at-start route address)))
           (and descriptor
                (%host-base-reference-by-index model descriptor))))))

(defun %host-descriptor-start (model descriptor)
  (let ((reference (%host-base-reference-by-index model descriptor)))
    (and reference (host-reference-address reference))))

(defun %host-arena-byte-index (route address)
  (+ (host-route-arena-offset route) (- address (host-route-base route))))

(defun %host-arena-byte-index-at-address (model address)
  (let ((route (%host-route-at-address model address)))
    (unless route (error "Address is outside installed model routes"))
    (%host-arena-byte-index route address)))

(defun %host-arena-word-index-at-address (model address)
  (let ((byte-index (%host-arena-byte-index-at-address model address)))
    (unless (zerop (mod byte-index 8))
      (error "Reference word address is not aligned"))
    (floor byte-index 8)))

(defun %host-map-start-value-p (value address)
  (or (eql value 1) (eql value t) (eql value address)))

(defun %host-route-start-p (route address)
  (%host-map-start-value-p (metadata-ref (host-route-map route) address) address))

(defun %host-canonical-start-from-route (model route address)
  ;; Interior reference forms were admitted with this displacement bound.  The
  ;; lookup reads only the installed authoritative map and cannot become a
  ;; second writable allocation directory.
  (multiple-value-bind (map-base map-limit granularity)
      (%host-metadata-geometry (host-route-map route))
    (declare (ignore map-limit))
    (let* ((aligned (+ map-base
                       (* (floor (- address map-base) granularity)
                          granularity)))
           (minimum (max (host-route-base route)
                         (- aligned
                            (* (ceiling
                                (host-model-max-interior-displacement model)
                                granularity)
                               granularity)))))
      (loop for candidate from aligned downto minimum by granularity
            when (%host-route-start-p route candidate)
              do (return candidate)))))

(defun %host-reference-form-valid-p (reference start size)
  (let ((address (host-reference-address reference))
        (kind (host-reference-kind reference))
        (displacement (host-reference-displacement reference)))
    (and (integerp displacement) (<= 0 displacement)
         (= address (+ start displacement))
         (< displacement size)
         (case kind
           (:base (and (zerop displacement)
                       (zerop (host-reference-tag reference))))
           (:interior (zerop (host-reference-tag reference)))
           (:tagged-base (zerop displacement))
           (:tagged-interior (plusp displacement))
           (otherwise nil)))))

(defun %host-unpublished-base-descriptor (model reference)
  (when (and (valid-reference-p model reference)
             (eq (host-reference-kind reference) :base))
    (let* ((descriptor (host-reference-descriptor reference))
           (base (%host-base-reference-by-index model descriptor)))
      (and (eq reference base)
           (%host-descriptor-active-p model descriptor)
           descriptor))))

(defun %host-published-descriptor-at-start (model start)
  (let* ((route (%host-route-at-address model start))
         (descriptor (and route (%host-descriptor-index-at-start route start))))
    (and descriptor (%host-descriptor-active-p model descriptor)
         (%host-route-start-p route start) descriptor)))

(defun simulator-reference-address (reference)
  "Pure hosted reference decoder used by the installed address-space route."
  (and (typep reference 'host-reference)
       (host-reference-address reference)))

(defun %simulator-model-layout (model)
  (and (typep model 'host-bound-object-model)
       (host-model-layout model)))

;;; References and object facts ----------------------------------------------

(defmethod valid-reference-p ((model host-object-model) value)
  (and (typep value 'host-reference)
       (eq model (host-reference-model value))))

(defmethod normalize-reference ((model host-object-model) reference)
  (%host-bound-model model)
  (unless (valid-reference-p model reference)
    (error "Immediate or foreign reference"))
  (let* ((address (host-reference-address reference))
         (route (%host-route-at-address model address))
         (start (and route (%host-canonical-start-from-route model route address)))
         (descriptor (and start (%host-descriptor-index-at-start route start))))
    (unless (and descriptor (%host-descriptor-active-p model descriptor)
                 (= descriptor (host-reference-descriptor reference))
                 (%host-reference-form-valid-p
                  reference start (aref (host-model-sizes model) descriptor)))
      (error "Stale or corrupt hosted reference"))
    (let ((base (%host-base-reference-by-index model descriptor)))
      (values
       base
       (case (host-reference-kind reference)
         (:base 0)
         (:interior (+ #x10000000
                       (host-reference-displacement reference)))
         (:tagged-base (+ #x20000000 (host-reference-tag reference)))
         (:tagged-interior
          (+ #x30000000
             (ash (host-reference-tag reference) 20)
             (host-reference-displacement reference))))))))

(defun %host-decode-reference-descriptor (descriptor)
  (cond ((eql descriptor 0) (values :base 0 0))
        ((and (integerp descriptor)
              (<= #x10000000 descriptor) (< descriptor #x20000000))
         (values :interior 0 (- descriptor #x10000000)))
        ((and (integerp descriptor)
              (<= #x20000000 descriptor) (< descriptor #x30000000))
         (values :tagged-base (logand descriptor #xffff) 0))
        ((and (integerp descriptor)
              (<= #x30000000 descriptor) (< descriptor #x40000000))
         (let ((payload (- descriptor #x30000000)))
           (values :tagged-interior
                   (ldb (byte 12 20) payload)
                   (logand payload (1- (ash 1 20))))))
        (t (error "Malformed reference reconstruction descriptor"))))

(defun %host-variant-code (kind tag displacement)
  (+ (case kind
       (:interior 1) (:tagged-base 2) (:tagged-interior 3)
       (otherwise 0))
     (ash tag 2) (ash displacement 18)))

(defun %host-variant-code-slot (keys code)
  (let* ((mask (1- (length keys)))
         (initial (logand (logxor code (ash code -18)) mask)))
    (dotimes (probe (length keys))
      (let* ((slot (logand (+ initial probe) mask))
             (seen (aref keys slot)))
        (when (or (= seen -1) (= seen code))
          (return-from %host-variant-code-slot slot))))
    nil))

(defun %host-find-or-publish-variant
    (model descriptor kind tag displacement)
  ;; This profile is serialized. Row filling invokes no client callback or
  ;; collection entry and allocates no representation storage. A partial row
  ;; is never directory-visible; this is not target CLOS/allocation admission.
  (when (host-model-variant-publishing-p model)
    (error "Reference encoding row publication is already active"))
  (let* ((code (%host-variant-code kind tag displacement))
         (keys (host-model-variant-code-keys model))
         (rows (host-model-variant-code-rows model))
         (variants (host-model-variants model))
         (slot (%host-variant-code-slot keys code)))
    (unless slot (error "Reference code directory exhausted"))
    (if (/= (aref keys slot) -1)
        (aref variants (+ (aref rows slot) descriptor))
        (let* ((start (host-model-variant-count model))
               (bases (host-model-base-references model))
               (cells (length bases)))
          ;; Check the whole row before changing any record/count/directory.
          ;; Keys has >=2*FLOOR(H/C) entries, so admitted rows never fill it.
          (when (> cells (- (length variants) start))
            (error "Reference encoding code-row capacity exhausted"))
          (setf (host-model-variant-publishing-p model) t)
          (unwind-protect
               (progn
                 (loop for route across (host-model-routes model)
                       do (let ((first (host-route-descriptor-offset route))
                                (limit (host-route-limit route)))
                            (dotimes (local (host-route-cell-count route))
                              (let* ((index (+ first local))
                                     (address (host-reference-address
                                               (aref bases index))))
                                ;; Skip only a permanently impossible offset,
                                ;; never an inactive/reserve/currently small cell.
                                ;; The subtraction also proves ADDRESS+DISPLACEMENT
                                ;; fits the admitted fixnum address domain.
                                (when (< displacement (- limit address))
                                  (let ((reference (aref variants (+ start index))))
                                    (setf (host-reference-descriptor reference) index
                                          (host-reference-address reference)
                                          (+ address displacement)
                                          (host-reference-kind reference) kind
                                          (host-reference-tag reference) tag
                                          (host-reference-displacement reference)
                                          displacement)))))))
                 ;; All records are ready. These non-failing writes publish one
                 ;; canonical code atomically with respect to admitted callers.
                 (setf (aref rows slot) start
                       (host-model-variant-count model) (+ start cells)
                       (aref keys slot) code)
                 (aref variants (+ start descriptor)))
            (setf (host-model-variant-publishing-p model) nil))))))

(defmethod rebuild-reference
    ((model host-object-model) new-start descriptor)
  (%host-bound-model model)
  (let ((descriptor-index (%host-unpublished-base-descriptor model new-start)))
    (unless descriptor-index
      (error "Reference rebuild destination is not an active base encoding"))
    (multiple-value-bind (kind tag displacement)
        (%host-decode-reference-descriptor descriptor)
      (let ((size (aref (host-model-sizes model) descriptor-index)))
        (unless (and (< displacement size)
                     (<= displacement
                         (host-model-max-interior-displacement model))
                     (case kind
                       (:base (and (zerop tag) (zerop displacement)))
                       (:interior (and (zerop tag) (plusp displacement)))
                       (:tagged-base
                        (and (plusp tag)
                             (<= tag (host-model-tag-capacity model))
                             (zerop displacement)))
                       (:tagged-interior
                        (and (plusp tag)
                             (<= tag (host-model-tag-capacity model))
                             (plusp displacement)))
                       (otherwise nil)))
          (error "Reference descriptor is outside the admitted domain"))
        (if (eq kind :base)
            new-start
            (%host-find-or-publish-variant
             model descriptor-index kind tag displacement))))))

(defmethod reference-address ((model host-object-model) start)
  (%host-bound-model model)
  (unless (%host-unpublished-base-descriptor model start)
    (error "Reference-address requires an active canonical base"))
  (host-reference-address start))

(defun %host-normalized-descriptor-index (model start)
  (multiple-value-bind (base descriptor) (normalize-reference model start)
    (declare (ignore descriptor))
    (host-reference-descriptor base)))

(defmethod object-size ((model host-object-model) start)
  (aref (host-model-sizes model) (%host-normalized-descriptor-index model start)))

(defmethod object-alignment ((model host-object-model) start)
  (aref (host-model-alignments model)
        (%host-normalized-descriptor-index model start)))

(defmethod object-kind ((model host-object-model) start)
  (%host-kind-allocation-token
   model (aref (host-model-descriptor-kinds model)
               (%host-normalized-descriptor-index model start))))

(defmethod object-kind-descriptor ((model host-object-model) kind)
  (%host-kind-allocation-token model (%host-kind-description! model kind)))

(defmethod reference-encoding-equal-p
    ((model host-object-model) left right)
  (%host-model model)
  (eql left right))

(defmethod reference-equal ((model host-object-model) left right)
  (cond ((and (not (valid-reference-p model left))
              (not (valid-reference-p model right)))
         (eql left right))
        ((or (not (valid-reference-p model left))
             (not (valid-reference-p model right))) nil)
        (t
         (multiple-value-bind (left-base left-descriptor)
             (normalize-reference model left)
           (declare (ignore left-descriptor))
           (multiple-value-bind (right-base right-descriptor)
               (normalize-reference model right)
             (declare (ignore right-descriptor))
             (eq left-base right-base))))))

;;; Object initialization, payload and copy ----------------------------------

(defun %host-kind-size-count (kind size)
  (let ((rule (host-object-kind-description-size-rule kind)))
    (if (typep rule 'host-variable-size-rule)
        (let* ((header (host-variable-size-rule-header-bytes rule))
               (element (host-variable-size-rule-element-bytes rule))
               (payload (- size header)))
          (if (and (>= payload 0) (zerop (mod payload element)))
              (let ((count (floor payload element)))
                (values
                 (and (>= count
                          (host-variable-size-rule-minimum-elements rule))
                      (or (null
                           (host-variable-size-rule-maximum-elements rule))
                          (<= count
                              (host-variable-size-rule-maximum-elements rule))))
                 count))
              (values nil 0)))
        (values (= size (%host-positive-rule-value rule kind "size")) 0))))

(defun %host-kind-offsets-fit-p (kind size)
  (let ((strong (host-object-kind-description-strong-layout kind)))
    (and
     (if (typep strong 'host-indexed-layout)
         (<= (host-indexed-layout-base-offset strong) size)
         (loop for slot across strong
               always (<= (host-slot-description-offset slot) (- size 8))))
     (loop for description across
           (host-object-kind-description-weak-descriptions kind)
           always (<= (host-weak-location-description-offset description)
                      (- size 8)))
     (loop for description across
           (host-object-kind-description-ephemeron-descriptions kind)
           always (and (<= (host-ephemeron-description-key-offset description)
                           (- size 8))
                       (<= (host-ephemeron-description-value-offset description)
                           (- size 8)))))))

(defun runtime-object-allocation-rejection (model descriptor bytes alignment)
  ;; Private hosted runtime bridge, like RUNTIME-START-REFERENCE.  Rule
  ;; interpretation belongs to the model, not to the allocator or plan.
  (%host-bound-model model)
  (let ((kind (%host-kind-description! model descriptor)))
    (unless (handler-case
                (and (<= bytes (host-model-max-object-bytes model))
                     (%host-kind-size-count kind bytes)
                     (%host-kind-offsets-fit-p kind bytes))
              (error () nil))
      (return-from runtime-object-allocation-rejection :invalid-size))
    (unless (handler-case
                (let ((required
                        (%host-positive-rule-value
                         (host-object-kind-description-alignment-rule kind)
                         kind "alignment")))
                  (and (%host-positive-power-of-two-p required)
                       (>= alignment required)))
              (error () nil))
      (return-from runtime-object-allocation-rejection :invalid-alignment))
    nil))

(defun %host-clear-object-planes (model route address size)
  (let ((byte-start (%host-arena-byte-index route address))
        (word-start (%host-arena-word-index-at-address model address)))
    (fill (host-model-arena model) 0 :start byte-start :end (+ byte-start size))
    (fill (host-model-words model) nil :start word-start
          :end (+ word-start (ceiling size 8)))))

(defun %host-initialize-conditional-values (model descriptor kind)
  (let* ((start (%host-descriptor-start model descriptor))
         (word-start (%host-arena-word-index-at-address model start)))
    (loop for description across
          (host-object-kind-description-weak-descriptions kind)
          do (setf (aref (host-model-words model)
                         (+ word-start
                            (floor
                             (host-weak-location-description-offset description)
                             8)))
                   (host-weak-location-description-cleared-value description)))
    (loop for description across
          (host-object-kind-description-ephemeron-descriptions kind)
          do (setf (aref (host-model-words model)
                         (+ word-start
                            (floor
                             (host-ephemeron-description-key-offset description)
                             8)))
                   (host-ephemeron-description-cleared-key description)
                   (aref (host-model-words model)
                         (+ word-start
                            (floor
                             (host-ephemeron-description-value-offset description)
                             8)))
                   (host-ephemeron-description-cleared-value description)))))

(defmethod initialize-object
    ((model host-object-model) address kind size descriptor)
  (%host-bound-model model)
  (unless (and (integerp address) (integerp size) (plusp size))
    (error "Invalid hosted object address/size"))
  (let* ((kind-description (%host-kind-description! model kind))
         (alignment
           (%host-positive-rule-value
            (host-object-kind-description-alignment-rule kind-description)
            kind-description "alignment"))
         (route (%host-route-at-address model address))
         (descriptor-index
           (and route (%host-descriptor-index-at-start route address))))
    (multiple-value-bind (valid-size-p element-count)
        (%host-kind-size-count kind-description size)
      (unless (and valid-size-p
                   (typep descriptor 'host-object-kind-description)
                   (eq (gethash descriptor (host-model-description-snapshots model))
                       kind-description)
                   (%host-positive-power-of-two-p alignment)
                   (zerop (mod address alignment))
                   route descriptor-index
                   (zerop (mod (- address (host-route-base route))
                               (host-route-granularity route)))
                   (<= (+ address size) (host-route-limit route))
                   (<= size (host-model-max-object-bytes model))
                   (zerop (aref (host-model-sizes model) descriptor-index))
                   (not (%host-route-start-p route address))
                   (< (host-model-live-count model)
                      (host-model-capacity model))
                   (%host-kind-offsets-fit-p kind-description size))
        (error "Invalid hosted object initialization"))
      (let ((old-generation
              (aref (host-model-descriptor-generations model)
                    descriptor-index)))
        (when (= old-generation most-positive-fixnum)
          (error "Hosted object generation exhausted"))
        ;; All failure checks precede these bounded non-failing writes.
        (%host-clear-object-planes model route address size)
        (setf (aref (host-model-alignments model) descriptor-index) alignment
              (aref (host-model-descriptor-kinds model) descriptor-index)
              kind-description
              (aref (host-model-descriptor-counts model) descriptor-index)
              element-count
              (aref (host-model-descriptor-generations model) descriptor-index)
              (1+ old-generation)
              ;; SIZE publishes representation existence last.  The installed
              ;; authoritative start remains absent until runtime publication.
              (aref (host-model-sizes model) descriptor-index) size)
        (incf (host-model-live-count model))
        (%host-initialize-conditional-values
         model descriptor-index kind-description)
        (%host-base-reference-by-index model descriptor-index)))))

(defun %host-active-destination-descriptor (model destination)
  (cond ((valid-reference-p model destination)
         (%host-unpublished-base-descriptor model destination))
        ((integerp destination)
         (let ((reference (%host-base-reference-at-address model destination)))
           (and reference (%host-unpublished-base-descriptor model reference))))
        (t nil)))

(defmethod copy-object-representation
    ((model host-object-model) source destination)
  (%host-bound-model model)
  (let* ((source-descriptor (%host-normalized-descriptor-index model source))
         (destination-descriptor
           (%host-active-destination-descriptor model destination)))
    (unless destination-descriptor
      (error "Invalid copy destination"))
    (let* ((source-size (aref (host-model-sizes model) source-descriptor))
           (destination-size
             (aref (host-model-sizes model) destination-descriptor))
           (source-kind
             (aref (host-model-descriptor-kinds model) source-descriptor))
           (destination-kind
             (aref (host-model-descriptor-kinds model)
                   destination-descriptor)))
      (unless (and (= source-size destination-size)
                   (eq source-kind destination-kind))
        (error "Copy source and destination representations disagree"))
      (let* ((source-start (%host-descriptor-start model source-descriptor))
             (destination-start
               (%host-descriptor-start model destination-descriptor))
             (source-byte (%host-arena-byte-index-at-address model source-start))
             (destination-byte
               (%host-arena-byte-index-at-address model destination-start))
             (source-word
               (%host-arena-word-index-at-address model source-start))
             (destination-word
               (%host-arena-word-index-at-address model destination-start)))
        ;; Explicit memmove order; no temporary object is allocated.
        (if (< source-byte destination-byte)
            (loop for index downfrom (1- source-size) to 0
                  do (setf (aref (host-model-arena model)
                                 (+ destination-byte index))
                           (aref (host-model-arena model)
                                 (+ source-byte index))))
            (dotimes (index source-size)
              (setf (aref (host-model-arena model)
                          (+ destination-byte index))
                    (aref (host-model-arena model)
                          (+ source-byte index)))))
        (let ((words (ceiling source-size 8)))
          (if (< source-word destination-word)
              (loop for index downfrom (1- words) to 0
                    do (setf (aref (host-model-words model)
                                   (+ destination-word index))
                             (aref (host-model-words model)
                                   (+ source-word index))))
              (dotimes (index words)
                (setf (aref (host-model-words model)
                            (+ destination-word index))
                      (aref (host-model-words model)
                            (+ source-word index)))))))
      destination)))

(defun host-object-payload-read (model start offset)
  (%host-bound-model model)
  (let* ((descriptor (%host-normalized-descriptor-index model start))
         (size (aref (host-model-sizes model) descriptor)))
    (unless (and (integerp offset) (<= 0 offset) (< offset size))
      (error "Hosted payload offset is out of bounds"))
    (aref (host-model-arena model)
          (+ (%host-arena-byte-index-at-address
              model (%host-descriptor-start model descriptor))
             offset))))

(defun host-object-payload-write (model start offset value)
  (%host-bound-model model)
  (unless (typep value '(unsigned-byte 8))
    (error "Hosted payload byte is invalid"))
  (let* ((descriptor (%host-normalized-descriptor-index model start))
         (size (aref (host-model-sizes model) descriptor)))
    (unless (and (integerp offset) (<= 0 offset) (< offset size))
      (error "Hosted payload offset is out of bounds"))
    (setf (aref (host-model-arena model)
                (+ (%host-arena-byte-index-at-address
                    model (%host-descriptor-start model descriptor))
                   offset))
          value)))

;;; Borrowed locations --------------------------------------------------------

(defun %host-borrow-location
    (model descriptor generation word-index identity strength
     &optional stage stage-generation)
  (let ((location
          (loop for candidate across (host-model-locations model)
                unless (host-reference-location-active candidate)
                  do (return candidate))))
    (unless location (error "Borrowed reference-location capacity exhausted"))
    (setf (host-reference-location-descriptor location) descriptor
          (host-reference-location-generation location) generation
          (host-reference-location-word-index location) word-index
          (host-reference-location-identity location) identity
          (host-reference-location-strength location) strength
          (host-reference-location-stage location) stage
          (host-reference-location-stage-generation location) stage-generation
          (host-reference-location-active location) t)
    location))

(defun %host-release-location (location)
  (setf (host-reference-location-active location) nil
        (host-reference-location-stage location) nil)
  (values))

(defun %host-descriptor-published-p (model descriptor)
  (and (%host-descriptor-active-p model descriptor)
       (let* ((start (%host-descriptor-start model descriptor))
              (route (%host-route-at-address model start)))
         (and route (%host-route-start-p route start)))))

(defun %host-validate-location (model location)
  (unless (and (typep location 'host-reference-location)
               (eq model (host-reference-location-model location))
               (host-reference-location-active location))
    (error "Invalid or expired borrowed reference location"))
  (let ((stage (host-reference-location-stage location)))
    (if stage
        (unless (and (typep stage 'host-staged-object)
                     (eq model (host-staged-object-model stage))
                     (eq :active (host-staged-object-state stage))
                     (= (host-reference-location-stage-generation location)
                        (host-staged-object-generation stage)))
          (error "Stale staged reference location"))
        (let ((descriptor (host-reference-location-descriptor location)))
          (unless (and (%host-descriptor-published-p model descriptor)
                       (= (host-reference-location-generation location)
                          (aref (host-model-descriptor-generations model)
                                descriptor)))
            (error "Stale object reference location")))))
  location)

(defun %host-location-value (location)
  (let ((stage (host-reference-location-stage location))
        (index (host-reference-location-word-index location)))
    (if stage
        (aref (host-staged-object-words stage) index)
        (aref (host-model-words (host-reference-location-model location))
              index))))

(defun (setf %host-location-value) (value location)
  (let ((stage (host-reference-location-stage location))
        (index (host-reference-location-word-index location)))
    (if stage
        (setf (aref (host-staged-object-words stage) index) value)
        (setf (aref (host-model-words
                     (host-reference-location-model location)) index)
              value)))
  value)

(defun %host-validate-reference-order (order)
  (unless (case order
            ((:relaxed :acquire :release :acq-rel :sequential) t)
            (otherwise nil))
    (error "Invalid reference memory order ~S" order))
  order)

(defun %host-validate-raw-value (model location value)
  "Validate VALUE before any persistent hosted word-plane write."
  (unless (if (eq (host-reference-location-strength location) :numeric)
              ;; These are the only scalar forms with a hosted raw numeric
              ;; representation.  In particular, reject DOUBLE-FLOAT and all
              ;; arbitrary host containers rather than retaining host boxes.
              (or (typep value 'fixnum) (typep value 'single-float))
              (%host-admitted-reference-value-p model value))
    (error "Value ~S has no admitted hosted word representation" value))
  value)

(defmethod load-reference
    ((model host-object-model) location &optional (order :relaxed))
  (%host-validate-reference-order order)
  (%host-location-value (%host-validate-location model location)))

(defmethod store-reference-raw
    ((model host-object-model) location value &optional (order :relaxed))
  (%host-validate-reference-order order)
  (let ((validated (%host-validate-location model location)))
    (%host-validate-raw-value model validated value)
    (setf (%host-location-value validated) value)))

(defmethod cas-reference-raw
    ((model host-object-model) location old new order)
  (%host-validate-reference-order order)
  (let ((validated (%host-validate-location model location)))
    ;; Validate both operands before the possible persistent write.  Current
    ;; contents were admitted by the same boundary.
    (%host-validate-raw-value model validated old)
    (%host-validate-raw-value model validated new)
    (let ((observed (%host-location-value validated)))
      (if (reference-encoding-equal-p model observed old)
          (progn (setf (%host-location-value validated) new)
                 (values observed t))
          (values observed nil)))))

(defun %host-fixed-strong-offset (kind identity)
  (let ((layout (host-object-kind-description-strong-layout kind)))
    (unless (typep layout 'host-indexed-layout)
      (loop for slot across layout
            when (eql identity (host-slot-description-identity slot))
              do (return (values (host-slot-description-offset slot) t))))))

(defun %host-indexed-element-offset (model descriptor identity)
  (let* ((kind (aref (host-model-descriptor-kinds model) descriptor))
         (layout (host-object-kind-description-strong-layout kind)))
    (when (and (typep layout 'host-indexed-layout)
               (integerp identity))
      (let ((index (- identity (host-indexed-layout-identity-base layout)))
            (count (aref (host-model-descriptor-counts model) descriptor)))
        (when (and (<= 0 index) (< index count))
          (+ (host-indexed-layout-base-offset layout)
             (* index (host-indexed-layout-element-word-bytes layout))))))))

(defun %host-object-word-index (model descriptor offset)
  (+ (%host-arena-word-index-at-address model (%host-descriptor-start model descriptor))
     (floor offset 8)))

(defun %host-call-with-borrowed-object-location
    (model descriptor identity strength offset function)
  (let* ((generation
           (aref (host-model-descriptor-generations model) descriptor))
         (location
           (%host-borrow-location model descriptor generation
                             (%host-object-word-index model descriptor offset)
                             identity strength)))
    (unwind-protect (funcall function location)
      (%host-release-location location))))

(defmethod map-reference-locations
    ((model host-object-model) start function)
  (%host-bound-model model)
  (unless (functionp function) (error "Reference mapper is not callable"))
  (let* ((descriptor (%host-normalized-descriptor-index model start))
         (kind (aref (host-model-descriptor-kinds model) descriptor))
         (layout (host-object-kind-description-strong-layout kind)))
    (if (typep layout 'host-indexed-layout)
        (let ((count (aref (host-model-descriptor-counts model) descriptor))
              (identity-base (host-indexed-layout-identity-base layout))
              (identity-function
                (host-indexed-layout-identity-function layout))
              (base-offset (host-indexed-layout-base-offset layout))
              (stride (host-indexed-layout-element-word-bytes layout)))
          (dotimes (index count)
            (let ((identity
                    (funcall identity-function (+ identity-base index))))
              (%host-call-with-borrowed-object-location
               model descriptor identity :strong (+ base-offset (* index stride))
               (lambda (location) (funcall function identity location))))))
        (loop for slot across layout
              do (let ((identity (host-slot-description-identity slot)))
                   (%host-call-with-borrowed-object-location
                    model descriptor identity :strong
                    (host-slot-description-offset slot)
                    (lambda (location)
                      (funcall function identity location)))))))
  (values))

(defmethod map-weak-descriptors
    ((model host-object-model) start function)
  (%host-bound-model model)
  (unless (functionp function) (error "Weak mapper is not callable"))
  (let* ((descriptor (%host-normalized-descriptor-index model start))
         (kind (aref (host-model-descriptor-kinds model) descriptor)))
    (loop for description across
          (host-object-kind-description-weak-descriptions kind)
          do (let ((identity
                     (host-weak-location-description-identity description)))
               (%host-call-with-borrowed-object-location
                model descriptor identity :weak
                (host-weak-location-description-offset description)
                (lambda (location)
                  (funcall function identity location
                           (host-weak-location-description-cleared-value
                            description)))))))
  (values))

(defmethod map-ephemeron-descriptors
    ((model host-object-model) start function)
  (%host-bound-model model)
  (unless (functionp function) (error "Ephemeron mapper is not callable"))
  (let* ((descriptor (%host-normalized-descriptor-index model start))
         (kind (aref (host-model-descriptor-kinds model) descriptor))
         (generation
           (aref (host-model-descriptor-generations model) descriptor)))
    (loop for description across
          (host-object-kind-description-ephemeron-descriptions kind)
          do (let* ((identity
                      (host-ephemeron-description-identity description))
                    (key
                      (%host-borrow-location
                       model descriptor generation
                       (%host-object-word-index
                        model descriptor
                        (host-ephemeron-description-key-offset description))
                       identity :ephemeron-key))
                    (value nil))
               (unwind-protect
                    (progn
                      (setf value
                            (%host-borrow-location
                             model descriptor generation
                             (%host-object-word-index
                              model descriptor
                              (host-ephemeron-description-value-offset
                               description))
                             identity :ephemeron-value))
                      (funcall
                       function identity key value
                       (host-ephemeron-description-clear-key-p description)
                       (host-ephemeron-description-cleared-key description)
                       (host-ephemeron-description-cleared-value description)))
                 (when value (%host-release-location value))
                 (%host-release-location key)))))
  (values))

(defun %host-maybe-normalized-descriptor-index (model start)
  (handler-case
      (values (%host-normalized-descriptor-index model start) t)
    (error () (values nil nil))))

(defun %call-with-simulator-reference-location
    (model start strength identity function)
  "Private O(1) hosted workload resolver for one declared strong location."
  (%host-bound-model model)
  (unless (functionp function)
    (error "Indexed reference-location callback is not callable"))
  (multiple-value-bind (descriptor valid-p)
      (%host-maybe-normalized-descriptor-index model start)
    (unless valid-p
      (return-from %call-with-simulator-reference-location
        (values nil :stale :invalid-object)))
    (let* ((kind (aref (host-model-descriptor-kinds model) descriptor))
           (offset
             (and (eq strength :strong)
                  (or (%host-indexed-element-offset model descriptor identity)
                      (multiple-value-bind (fixed found-p)
                          (%host-fixed-strong-offset kind identity)
                        (and found-p fixed))))))
      (if (null offset)
          (values nil :stale :unknown-location)
          ;; Callback faults are client faults, not stale-object results.
          (values
           (%host-call-with-borrowed-object-location
            model descriptor identity strength offset function)
           :present nil)))))

(defun %host-numeric-element-offset (model descriptor index)
  (let* ((kind (aref (host-model-descriptor-kinds model) descriptor))
         (rule (host-object-kind-description-size-rule kind)))
    (when (and (typep rule 'host-variable-size-rule)
               (eq (host-variable-size-rule-element-kind rule) :numeric)
               (integerp index) (<= 0 index)
               (< index (aref (host-model-descriptor-counts model) descriptor)))
      (+ (host-variable-size-rule-header-bytes rule)
         (* index (host-variable-size-rule-element-bytes rule))))))

(defun %call-with-simulator-array-element (model start index function)
  "Private O(1) hosted workload resolver for one raw numeric array word."
  (%host-bound-model model)
  (unless (functionp function)
    (error "Array-element callback is not callable"))
  (multiple-value-bind (descriptor valid-p)
      (%host-maybe-normalized-descriptor-index model start)
    (unless valid-p
      (return-from %call-with-simulator-array-element
        (values nil :stale :invalid-object)))
    (let ((offset (%host-numeric-element-offset model descriptor index)))
      (if (or (null offset) (not (zerop (mod offset 8))))
          (values nil :stale :invalid-index)
          ;; Callback faults propagate and the borrowed location still expires.
          (values
           (%host-call-with-borrowed-object-location
            model descriptor index :numeric offset function)
           :present nil)))))

;;; Stable location handles ---------------------------------------------------

(defun %host-allocate-handle (model)
  (let ((index (host-model-handle-count model)))
    (when (< index (length (host-model-handles model)))
      (incf (host-model-handle-count model))
      (aref (host-model-handles model) index))))

(defmethod make-reference-location-handle
    ((model host-object-model) source-start location)
  (%host-bound-model model)
  (unless (and (typep location 'host-reference-location)
               (eq model (host-reference-location-model location))
               (host-reference-location-active location)
               (null (host-reference-location-stage location)))
    (return-from make-reference-location-handle
      (values nil :failed :invalid-location)))
  (handler-case
      (let* ((descriptor (%host-normalized-descriptor-index model source-start))
             (generation
               (aref (host-model-descriptor-generations model) descriptor)))
        (unless (and (= descriptor
                        (host-reference-location-descriptor location))
                     (= generation
                        (host-reference-location-generation location)))
          (return-from make-reference-location-handle
            (values nil :failed :invalid-location)))
        (let ((handle (%host-allocate-handle model)))
          (unless handle
            (return-from make-reference-location-handle
              (values nil :retry :capacity-exhausted)))
          (setf (host-location-handle-model handle) model
                (host-location-handle-active handle) t
                (host-location-handle-descriptor handle) descriptor
                (host-location-handle-generation handle) generation
                (host-location-handle-identity handle)
                (host-reference-location-identity location)
                (host-location-handle-strength handle)
                (host-reference-location-strength location)
                (host-location-handle-word-index handle)
                (host-reference-location-word-index location)
                (host-location-handle-stage handle) nil
                (host-location-handle-stage-generation handle) 0)
          (values handle :complete nil)))
    (error (condition)
      (declare (ignore condition))
      (values nil :failed :invalid-location))))

(defun %host-handle-resolvable-p (model handle)
  (and (typep handle 'host-location-handle)
       (host-location-handle-active handle)
       (eq model (host-location-handle-model handle))
       (%host-descriptor-published-p
        model (host-location-handle-descriptor handle))
       (= (host-location-handle-generation handle)
          (aref (host-model-descriptor-generations model)
                (host-location-handle-descriptor handle)))
       (let ((stage (host-location-handle-stage handle)))
         (or (null stage)
             (and (eq (host-staged-object-state stage) :installed)
                  (= (host-location-handle-stage-generation handle)
                     (host-staged-object-generation stage)))))))

(defmethod call-with-reference-location
    ((model host-object-model) handle function)
  (%host-bound-model model)
  (unless (functionp function) (error "Handle callback is not callable"))
  (if (%host-handle-resolvable-p model handle)
      (let ((location
              (%host-borrow-location
               model (host-location-handle-descriptor handle)
               (host-location-handle-generation handle)
               (host-location-handle-word-index handle)
               (host-location-handle-identity handle)
               (host-location-handle-strength handle))))
        (unwind-protect
             (progn (funcall function location) :present)
          (%host-release-location location)))
      :stale))

;;; Staged representation facility -------------------------------------------

(defun %host-available-stage (model)
  (loop for stage across (host-model-stages model)
        unless (eq (host-staged-object-state stage) :active)
          do (return stage)))

(defmethod copy-object-to-staging
    ((model host-object-model) source address byte-capacity)
  (%host-bound-model model)
  (let* ((descriptor (%host-normalized-descriptor-index model source))
         (size (aref (host-model-sizes model) descriptor))
         (stage (%host-available-stage model)))
    (unless (and stage (integerp address)
                 (integerp byte-capacity) (>= byte-capacity size)
                 (<= size (length (host-staged-object-bytes stage))))
      (error "Staged representation capacity exhausted"))
    (when (= (host-staged-object-generation stage) most-positive-fixnum)
      (error "Staged representation generation exhausted"))
    (let* ((start (%host-descriptor-start model descriptor))
           (byte-start (%host-arena-byte-index-at-address model start))
           (word-start (%host-arena-word-index-at-address model start)))
      (dotimes (index size)
        (setf (aref (host-staged-object-bytes stage) index)
              (aref (host-model-arena model) (+ byte-start index))))
      (dotimes (index (ceiling size 8))
        (setf (aref (host-staged-object-words stage) index)
              (aref (host-model-words model) (+ word-start index))))
      (setf (host-staged-object-generation stage)
            (1+ (host-staged-object-generation stage))
            (host-staged-object-source stage) start
            (host-staged-object-destination stage) address
            (host-staged-object-size stage) size
            (host-staged-object-alignment stage)
            (aref (host-model-alignments model) descriptor)
            (host-staged-object-kind stage)
            (aref (host-model-descriptor-kinds model) descriptor)
            (host-staged-object-descriptor stage)
            (aref (host-model-descriptor-kinds model) descriptor)
            (host-staged-object-descriptor-index stage) descriptor
            (host-staged-object-descriptor-generation stage)
            (aref (host-model-descriptor-generations model) descriptor)
            (host-staged-object-state stage) :active)
      (values stage size))))

(defun %host-validate-active-stage (model stage)
  (unless (and (typep stage 'host-staged-object)
               (eq model (host-staged-object-model stage))
               (eq :active (host-staged-object-state stage)))
    (error "Foreign or inactive staged representation"))
  stage)

(defun %host-call-with-staged-location
    (model stage identity strength offset function)
  (let ((location
          (%host-borrow-location
           model (host-staged-object-descriptor-index stage)
           (host-staged-object-descriptor-generation stage)
           (floor offset 8) identity strength stage
           (host-staged-object-generation stage))))
    (unwind-protect (funcall function location)
      (%host-release-location location))))

(defmethod map-staged-reference-locations
    ((model host-object-model) stage function)
  (%host-bound-model model)
  (%host-validate-active-stage model stage)
  (unless (functionp function) (error "Staged mapper is not callable"))
  (let* ((kind (host-staged-object-kind stage))
         (layout (host-object-kind-description-strong-layout kind))
         (size (host-staged-object-size stage)))
    (if (typep layout 'host-indexed-layout)
        (let* ((base-offset (host-indexed-layout-base-offset layout))
               (stride (host-indexed-layout-element-word-bytes layout))
               (count (floor (- size base-offset) stride))
               (identity-base (host-indexed-layout-identity-base layout))
               (identity-function
                 (host-indexed-layout-identity-function layout)))
          (dotimes (index count)
            (let ((identity
                    (funcall identity-function (+ identity-base index))))
              (%host-call-with-staged-location
               model stage identity :strong (+ base-offset (* index stride))
               (lambda (location) (funcall function identity location))))))
        (loop for slot across layout
              do (let ((identity (host-slot-description-identity slot)))
                   (%host-call-with-staged-location
                    model stage identity :strong
                    (host-slot-description-offset slot)
                    (lambda (location)
                      (funcall function identity location)))))))
  (values))

(defmethod map-staged-weak-descriptors
    ((model host-object-model) stage function)
  (%host-bound-model model)
  (%host-validate-active-stage model stage)
  (unless (functionp function) (error "Staged weak mapper is not callable"))
  (loop for description across
        (host-object-kind-description-weak-descriptions
         (host-staged-object-kind stage))
        do (let ((identity
                   (host-weak-location-description-identity description)))
             (%host-call-with-staged-location
              model stage identity :weak
              (host-weak-location-description-offset description)
              (lambda (location)
                (funcall function identity location
                         (host-weak-location-description-cleared-value
                          description))))))
  (values))

(defmethod map-staged-ephemeron-descriptors
    ((model host-object-model) stage function)
  (%host-bound-model model)
  (%host-validate-active-stage model stage)
  (unless (functionp function)
    (error "Staged ephemeron mapper is not callable"))
  (loop for description across
        (host-object-kind-description-ephemeron-descriptions
         (host-staged-object-kind stage))
        do (let* ((identity
                    (host-ephemeron-description-identity description))
                  (key
                    (%host-borrow-location
                     model (host-staged-object-descriptor-index stage)
                     (host-staged-object-descriptor-generation stage)
                     (floor (host-ephemeron-description-key-offset description)
                            8)
                     identity :ephemeron-key stage
                     (host-staged-object-generation stage)))
                  (value nil))
             (unwind-protect
                  (progn
                    (setf value
                          (%host-borrow-location
                           model (host-staged-object-descriptor-index stage)
                           (host-staged-object-descriptor-generation stage)
                           (floor
                            (host-ephemeron-description-value-offset description)
                            8)
                           identity :ephemeron-value stage
                           (host-staged-object-generation stage)))
                    (funcall
                     function identity key value
                     (host-ephemeron-description-clear-key-p description)
                     (host-ephemeron-description-cleared-key description)
                     (host-ephemeron-description-cleared-value description)))
               (when value (%host-release-location value))
               (%host-release-location key))))
  (values))

(defmethod install-staged-object
    ((model host-object-model) stage destination)
  (%host-bound-model model)
  (%host-validate-active-stage model stage)
  (let ((descriptor (%host-active-destination-descriptor model destination)))
    (unless descriptor (error "Invalid staged install destination"))
    (unless (and (= (aref (host-model-sizes model) descriptor)
                    (host-staged-object-size stage))
                 (eq (aref (host-model-descriptor-kinds model) descriptor)
                     (host-staged-object-kind stage)))
      (error "Staged install representation mismatch"))
    (let* ((start (%host-descriptor-start model descriptor))
           (byte-start (%host-arena-byte-index-at-address model start))
           (word-start (%host-arena-word-index-at-address model start))
           (size (host-staged-object-size stage)))
      (dotimes (index size)
        (setf (aref (host-model-arena model) (+ byte-start index))
              (aref (host-staged-object-bytes stage) index)))
      (dotimes (index (ceiling size 8))
        (setf (aref (host-model-words model) (+ word-start index))
              (aref (host-staged-object-words stage) index)))
      (setf (host-staged-object-destination stage) start
            (host-staged-object-state stage) :installed)
      (values))))

(defun %host-descriptor-location-offset (kind strength identity)
  (case strength
    (:strong
     (let ((layout (host-object-kind-description-strong-layout kind)))
       (unless (typep layout 'host-indexed-layout)
         (multiple-value-bind (offset found-p)
             (%host-fixed-strong-offset kind identity)
           (and found-p offset)))))
    (:weak
     (loop for description across
           (host-object-kind-description-weak-descriptions kind)
           when (eql identity
                     (host-weak-location-description-identity description))
             do (return
                  (host-weak-location-description-offset description))))
    (:ephemeron-key
     (loop for description across
           (host-object-kind-description-ephemeron-descriptions kind)
           when (eql identity
                     (host-ephemeron-description-identity description))
             do (return
                  (host-ephemeron-description-key-offset description))))
    (:ephemeron-value
     (loop for description across
           (host-object-kind-description-ephemeron-descriptions kind)
           when (eql identity
                     (host-ephemeron-description-identity description))
             do (return
                  (host-ephemeron-description-value-offset description))))
    (otherwise nil)))

(defmethod make-staged-reference-location-handle
    ((model host-object-model) staged-object descriptor-strength
     descriptor-identity future-start)
  (%host-bound-model model)
  (unless (and (typep staged-object 'host-staged-object)
               (eq model (host-staged-object-model staged-object))
               (eq :active (host-staged-object-state staged-object)))
    (return-from make-staged-reference-location-handle
      (values nil :failed :invalid-location)))
  (let* ((future-descriptor
           (%host-unpublished-base-descriptor model future-start))
         (kind (host-staged-object-kind staged-object))
         (offset
           (%host-descriptor-location-offset
            kind descriptor-strength descriptor-identity)))
    (unless (and future-descriptor offset
                 (eq kind
                     (aref (host-model-descriptor-kinds model)
                           future-descriptor)))
      (return-from make-staged-reference-location-handle
        (values nil :failed :invalid-location)))
    (let ((handle (%host-allocate-handle model)))
      (unless handle
        (return-from make-staged-reference-location-handle
          (values nil :retry :capacity-exhausted)))
      (setf (host-location-handle-model handle) model
            (host-location-handle-active handle) t
            (host-location-handle-descriptor handle) future-descriptor
            (host-location-handle-generation handle)
            (aref (host-model-descriptor-generations model)
                  future-descriptor)
            (host-location-handle-identity handle) descriptor-identity
            (host-location-handle-strength handle) descriptor-strength
            (host-location-handle-word-index handle)
            (%host-object-word-index model future-descriptor offset)
            (host-location-handle-stage handle) staged-object
            (host-location-handle-stage-generation handle)
            (host-staged-object-generation staged-object))
      (values handle :complete nil))))

;;; Runtime publication/retirement seams -------------------------------------

(defun runtime-start-reference (model space address)
  (%host-bound-model model)
  (let* ((route (%host-route-at-address model address))
         (descriptor
           (and route (eq space (host-route-space route))
                (%host-descriptor-index-at-start route address))))
    (and descriptor (%host-descriptor-active-p model descriptor)
         (%host-route-start-p route address)
         (%host-base-reference-by-index model descriptor))))

(defun runtime-retire-object-representation (model start)
  "Retire one representation after its authoritative start was cleared."
  (%host-bound-model model)
  (unless (and (valid-reference-p model start)
               (eq (host-reference-kind start) :base))
    (error "Representation retirement requires a canonical base encoding"))
  (let* ((descriptor (host-reference-descriptor start))
         (base (%host-base-reference-by-index model descriptor))
         (address (and base (host-reference-address base)))
         (route (and address (%host-route-at-address model address))))
    (unless (and (eq start base) route
                 (%host-descriptor-active-p model descriptor)
                 (not (%host-route-start-p route address)))
      (error "Representation retirement requires a cleared authoritative start"))
    ;; Handles retain the old generation and therefore become stale.  Stable
    ;; pointer encodings remain immutable address forms, as native pointers do.
    (setf (aref (host-model-sizes model) descriptor) 0
          (aref (host-model-alignments model) descriptor) 0
          (aref (host-model-descriptor-kinds model) descriptor) nil
          (aref (host-model-descriptor-counts model) descriptor) 0)
    (decf (host-model-live-count model))
    (values)))

(defun host-retire-object (model start)
  ;; Compatibility name retained for existing host tests/runtime adapters.
  (runtime-retire-object-representation model start))

(defun %map-host-kind-catalogue-storage (kinds count function snapshot-p)
  (dotimes (index count)
    (let* ((kind (aref kinds index))
           (size-rule (host-object-kind-description-size-rule kind))
           (alignment-rule
             (host-object-kind-description-alignment-rule kind))
           (strong (host-object-kind-description-strong-layout kind))
           (weak (host-object-kind-description-weak-descriptions kind))
           (ephemerons
             (host-object-kind-description-ephemeron-descriptions kind)))
      (funcall function kind)
      (when (and snapshot-p
                 (stringp (host-object-kind-description-name kind)))
        (funcall function (host-object-kind-description-name kind)))
      (cond ((typep size-rule 'host-variable-size-rule)
             (funcall function size-rule))
            ((functionp size-rule) (funcall function size-rule)))
      (when (functionp alignment-rule) (funcall function alignment-rule))
      (if (typep strong 'host-indexed-layout)
          (progn
            (funcall function strong)
            (funcall function
                     (host-indexed-layout-identity-function strong)))
          (progn
            (funcall function strong)
            (dotimes (slot (length strong))
              (funcall function (aref strong slot)))))
      (funcall function weak)
      (dotimes (slot (length weak))
        (funcall function (aref weak slot)))
      (funcall function ephemerons)
      (dotimes (slot (length ephemerons))
        (funcall function (aref ephemerons slot)))))
  (values))

(defmethod map-construction-auxiliary-storage
    ((model host-object-model) function)
  "Enumerate original opaque tokens and binding-owned executable storage."
  (unless (functionp function)
    (error "Construction auxiliary-storage mapper is not callable"))
  (call-next-method)
  (funcall function (host-model-kinds model))
  (%map-host-kind-catalogue-storage
   (host-model-kinds model) (host-model-kind-count model) function nil)
  (when (host-model-kind-snapshots model)
    (funcall function (host-model-kind-snapshots model))
    (funcall function (host-model-description-snapshots model))
    (%map-host-kind-catalogue-storage
     (host-model-kind-snapshots model) (host-model-kind-count model) function t))
  (values))

;;; Explicit resource manifest ------------------------------------------------

(defun %register-bound-object-model-auxiliary (construction model identity)
  "Register the complete persistent hosted model graph before manifest close."
  (%host-bound-model model)
  (labels ((register (object)
             (when object
               (%register-resource-auxiliary construction identity object)))
           (register-vector (vector &optional elements-p)
             (register vector)
             (when elements-p
               (dotimes (index (length vector))
                 (register (aref vector index))))))
    (register model)
    (register-vector (host-model-bindings model) t)
    (register-vector (host-model-routes model) t)
    ;; Tokens retain their original declarative graph even though execution
    ;; selects private snapshots. Both graphs require explicit ownership.
    (map-construction-auxiliary-storage model #'register)
    (register (host-model-arena model))
    (register (host-model-words model))
    (register (host-model-sizes model))
    (register (host-model-alignments model))
    (register (host-model-descriptor-kinds model))
    (register (host-model-descriptor-generations model))
    (register (host-model-descriptor-counts model))
    (register-vector (host-model-base-references model) t)
    (register-vector (host-model-variants model) t)
    (register (host-model-variant-code-keys model))
    (register (host-model-variant-code-rows model))
    (register-vector (host-model-locations model) t)
    (register-vector (host-model-handles model) t)
    (register-vector (host-model-stages model) t)
    (dotimes (index (length (host-model-stages model)))
      (let ((stage (aref (host-model-stages model) index)))
        (register (host-staged-object-bytes stage))
        (register (host-staged-object-words stage)))))
  (values))
