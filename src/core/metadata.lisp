;;;; core/metadata.lisp -- clamsara-metadata: logical metadata specification,
;;;; binding, and stratum operations.
;;;;
;;;; Normative sources (paper-v11/chapters/):
;;;;   strata.tex            -- logical metadata facts, merge and binding,
;;;;                            stratum operations, authority and transfer,
;;;;                            concurrency, persistence interaction.
;;;;   composition.tex       -- merge conflicts with provenance; construction
;;;;                            reports every conflict; silent fallback is
;;;;                            non-conforming.
;;;;   client-protocols.tex  -- section 1: offered physical metadata fields,
;;;;                            and the rule that copy-object-representation
;;;;                            must not decide mark/age/publication/
;;;;                            forwarding transfer.
;;;;
;;;; Package discipline: CLAMSARA-METADATA depends on Common Lisp and
;;;; the object-model and atomic client protocols only.
;;;;
;;;; RECORD SHAPES ARE IMPLEMENTATION INTERFACES.  paper-v11 specifies the
;;;; facts a logical metadatum carries, the merge/binding semantics, and the
;;;; stratum operation protocol; it does not specify record layouts.
;;;; METADATA-SPECIFICATION, METADATA-REGISTRY, METADATA-HANDLE,
;;;; SIDE-REQUEST, and SIDE-STORAGE are this implementation's documented
;;;; records.
;;;;
;;;; Closed vocabularies (each derived from the cited paper text):
;;;;   domain       :object :word :line :page :region :pair   (strata.tex 1)
;;;;   cell-type    :bit :integer :reference                   (strata.tex 1)
;;;;   placement    :offered-field :side-vector :side-table    (strata.tex 1)
;;;;   atomicity    :plain :bit-atomic :cas :exclusive :sealed-log
;;;;                (strata.tex 5: idempotent 0->1 still requires a
;;;;                language-level atomic operation when writers race;
;;;;                multi-bit cells require CAS, exclusive ownership, or a
;;;;                sealed log)
;;;;   writers      :single :owner :concurrent                 (strata.tex 5)
;;;;   order        :relaxed :acquire :release :sequential     (strata.tex 5)
;;;;   transfer     :copy :clear :merge :retain-region :recompute :discard
;;;;                (strata.tex 3: "copy, clear, merge, retain at region
;;;;                granularity, recompute, or intentionally discard")
;;;;   persistence  :authoritative :reconstructible :ephemeral (strata.tex 6)
;;;;   reset        :default :recompute :forbidden             (strata.tex 6:
;;;;                recovery restores an authoritative datum from the same
;;;;                consistent checkpoint or runs its declared
;;;;                reconstruction before allocation and reclamation resume)

(defpackage :clamsara-metadata
  (:use :cl)
  (:import-from :clamsara-protocol.atomics
   #:atomic-load #:atomic-store #:atomic-cas)
  (:import-from :clamsara-protocol.object-model
   #:offered-metadata-fields
   #:field-read
   #:field-write
   #:field-cas)
  (:export #:metadata-specification
           #:make-metadata-specification
           #:metadata-name
           #:metadata-domain
           #:metadata-cell-type
           #:metadata-width
           #:metadata-granularity
           #:metadata-default
           #:metadata-placement
           #:metadata-atomicity
           #:metadata-ownership
           #:metadata-lifetime
           #:metadata-writers
           #:metadata-order
           #:metadata-transfer-policy
           #:metadata-persistence
           #:metadata-reset-semantics
           #:metadata-kinds
           #:metadata-recompute
           #:metadata-merge-function
           ;; contributions and merge
           #:metadata-contribution
           #:make-contribution
           #:contribution-contributor
           #:contribution-specification
           #:merge-metadata
           #:metadata-registry
           #:registry-specifications
           #:find-metadata-specification
           #:specification-providers
           ;; binding
           #:bind-metadata
           #:metadata-binding
           #:binding-handles
           #:find-metadata
           #:side-request
           #:side-request-specification
           #:side-request-kind
           #:side-request-cells
           #:side-request-base
           #:side-request-granularity
           #:side-request-domain
           #:side-request-width
           #:make-side-storage
           #:metadata-table #:metadata-table-p #:make-metadata-table
           #:metadata-table-count
           #:side-storage
           #:side-storage-vector
           #:side-storage-base
           #:side-storage-cells
           #:side-storage-atomics
           #:side-storage-places
           ;; realization readers (documented implementation record
           ;; shapes; the contract test verifies boot-supplied storage
           ;; identity and declared capacity through them)
           #:vector-storage
           #:vector-base
           #:vector-span
           #:vector-cells
           #:vector-granularity
           #:table-storage
           #:table-cells
           ;; handles
           #:metadata-handle
           #:handle-specification
           #:handle-name
           #:handle-placement
           #:handle-cell-type
           #:handle-default
           #:handle-atomicity
           #:handle-order
           ;; stratum operations (strata.tex 2 protocol plus reset/transfer)
           #:metadata-ref
           #:metadata-set
           #:metadata-cas
           #:metadata-reset
           #:metadata-set-bit
           #:metadata-clear-bit
           #:metadata-clear-range
           #:metadata-fold
           #:metadata-map-present
           #:metadata-project
           #:metadata-transfer
           ;; conditions
           #:metadata-error
           #:metadata-error-component
           #:metadata-error-fact
           #:metadata-error-contributors
           #:metadata-invalid
           #:metadata-conflict
           #:metadata-unsupported
           #:metadata-key-error
           #:metadata-exhausted))

(in-package :clamsara-metadata)

;;; ---------------------------------------------------------------------
;;; Conditions.
;;;
;;; Every failure names the requiring component (a contribution contributor
;;; or the specification name), the offending FACT as a plist, and the full
;;; contributor provenance.  Silent fallback is non-conforming
;;; (composition.tex, "Constraints and diagnostics").

(define-condition metadata-error (error)
  ((component :initarg :component :initform nil
              :reader metadata-error-component)
   (fact :initarg :fact :initform nil
         :reader metadata-error-fact)
   (contributors :initarg :contributors :initform ()
                 :reader metadata-error-contributors))
  (:documentation "Base condition for logical-metadata construction and
operation failures.  COMPONENT names the contributor whose declaration or
operation failed; FACT is a plist describing the violated requirement;
CONTRIBUTORS is the merged datum's full provenance."))

(define-condition metadata-invalid (metadata-error)
  ()
  (:documentation "A single specification violates a declaration rule:
unknown vocabulary, a granularity/width contradiction, a concurrency rule
(strata.tex 5), or a transfer/reset rule whose required function is
missing."))

(define-condition metadata-conflict (metadata-error)
  ()
  (:documentation "Two identically named specifications disagree.  The FACT
plist names :SPECIFICATION, the conflicting :ATTRIBUTE, :EXISTING and
:OFFENDING values, :EXISTING-PROVIDERS, and :OFFENDING-PROVIDER."))

(define-condition metadata-unsupported (metadata-error)
  ()
  (:documentation "No legal binding exists: no declared placement
alternative can satisfy the declared guarantees, the layout callback refused
or undersupplied side storage, or the client's operations are weaker than
the specification requires (client-protocols.tex section 4: construction
rejects a client that only provides weaker operations)."))

(define-condition metadata-key-error (metadata-error)
  ()
  (:documentation "A stratum operation received a key or range the bound
realization cannot name, or an operation the realization does not provide
(for example CAS on a realization without an atomic primitive)."))

(define-condition metadata-exhausted (metadata-error)
  ()
  (:documentation "A runtime write needs a side-storage cell beyond the
declared boot size.  Side storage is boot-sized once and never grows at
runtime; exhaustion is explicit and names the datum, the realization, and
the declared capacity.  Saturation may conservatively reduce precision but
may never silently lose a cell used for reclamation (strata.tex section 2;
composition.tex: every reachable spill path is preallocated or fails before
entry)."))

;;; ---------------------------------------------------------------------
;;; Specification record.
;;;
;;; The paper's required facts (strata.tex section 1 listing plus the
;;; granularity, concurrency, transfer, and persistence prose), one slot per
;;; fact.  NIL means "unspecified" for OWNERSHIP, LIFETIME, KINDS, RECOMPUTE,
;;; and MERGE-FUNCTION; the remaining facts are mandatory closed-vocabulary
;;; values.

(defclass metadata-specification ()
  ((name :initarg :name :reader metadata-name)
   (domain :initarg :domain :reader metadata-domain)
   (cell-type :initarg :cell-type :reader metadata-cell-type)
   (width :initarg :width :reader metadata-width)
   (granularity :initarg :granularity :reader metadata-granularity)
   (default :initarg :default :reader metadata-default)
   (placement :initarg :placement :reader metadata-placement)
   (atomicity :initarg :atomicity :reader metadata-atomicity)
   (ownership :initarg :ownership :reader metadata-ownership)
   (lifetime :initarg :lifetime :reader metadata-lifetime)
   (writers :initarg :writers :reader metadata-writers)
   (order :initarg :order :reader metadata-order)
   (transfer :initarg :transfer :reader metadata-transfer-policy)
   (persistence :initarg :persistence :reader metadata-persistence)
   (reset :initarg :reset :reader metadata-reset-semantics)
   (kinds :initarg :kinds :reader metadata-kinds)
   (recompute :initarg :recompute :reader metadata-recompute)
   (merge-function :initarg :merge-function :reader metadata-merge-function)
   (providers :initform () :accessor specification-providers))
  (:documentation "Implementation record for one logical metadatum.

Facts (paper-v11 strata.tex): NAME is the logical key collectors use instead
of a client method whose name assumes the policy; DOMAIN selects the cell
addressing class; CELL-TYPE and WIDTH describe the cell; GRANULARITY is the
bytes-per-cell constant g of the scalar stratum formula cell = floor((a-b)/g)
for address-derived domains; DEFAULT is the cell value before any write and
after reset; PLACEMENT lists the acceptable placement classes (alternatives);
ATOMICITY lists acceptable mechanisms, never one mechanism; OWNERSHIP and
LIFETIME are the paper's declaration attributes; WRITERS and ORDER are the
declared writer domains and memory order (strata.tex 5); TRANSFER is the
movement transfer policy (strata.tex 3); PERSISTENCE is the checkpoint
classification recovery validation consumes (strata.tex 6); RESET says what
a reset does; KINDS names the object kinds carrying the datum (empty means
every declared kind); RECOMPUTE is the declared reconstruction/recompute
function of (key value); MERGE-FUNCTION is the merge function of
(destination-value source-value) required by transfer :MERGE.

Record shape is an implementation interface; the paper specifies the facts,
not this layout."))

(defun make-metadata-specification
    (&key name domain cell-type (width nil width-p)
       granularity default placement atomicity
       ownership lifetime (writers :single) (order :relaxed)
       transfer (persistence :ephemeral) (reset :default)
       kinds recompute merge-function)
  "Declare one logical metadatum.  WIDTH defaults to 1 for :bit cells and is
mandatory otherwise.  See METADATA-SPECIFICATION for the fact vocabulary."
  (let ((w (cond (width-p width)
                 ((eq cell-type :bit) 1)
                 (t nil))))
    (make-instance 'metadata-specification
                   :name name :domain domain :cell-type cell-type :width w
                   :granularity granularity :default default
                   :placement placement :atomicity atomicity
                   :ownership ownership :lifetime lifetime
                   :writers writers :order order :transfer transfer
                   :persistence persistence :reset reset :kinds kinds
                   :recompute recompute :merge-function merge-function)))

(defmethod initialize-instance :after ((spec metadata-specification) &key)
  (%validate-specification spec))

;;; Declaration validation: the paper's construction checks.  Closed
;;; vocabularies, the scalar-stratum granularity requirement, the
;;; concurrency rules of strata.tex 5, placement/domain compatibility, and
;;; transfer/reset function requirements.

(defparameter *domains* '(:object :word :line :page :region :pair))
(defparameter *cell-types* '(:bit :integer :reference))
(defparameter *placements* '(:offered-field :side-vector :side-table))
(defparameter *atomicities* '(:plain :bit-atomic :cas :exclusive :sealed-log))
(defparameter *writer-domains* '(:single :owner :concurrent))
(defparameter *orders* '(:relaxed :acquire :release :sequential))
(defparameter *transfers* '(:copy :clear :merge :retain-region :recompute
                            :discard))
(defparameter *persistences* '(:authoritative :reconstructible :ephemeral))
(defparameter *resets* '(:default :recompute :forbidden))
(defparameter *address-domains* '(:word :line :page))

(defun %invalid (spec fact)
  (error 'metadata-invalid
         :component (metadata-name spec)
         :fact fact
         :contributors (specification-providers spec)))

(defun %validate-specification (spec)
  (unless (metadata-name spec)
    (%invalid spec (list :reason :specification-requires-name)))
  (unless (member (metadata-domain spec) *domains*)
    (%invalid spec (list :bad-domain (metadata-domain spec))))
  (unless (member (metadata-cell-type spec) *cell-types*)
    (%invalid spec (list :bad-cell-type (metadata-cell-type spec))))
  (unless (and (metadata-width spec)
               (typep (metadata-width spec) '(integer 1 *))
               (or (not (eq (metadata-cell-type spec) :bit))
                   (= (metadata-width spec) 1)))
    (%invalid spec (list :bad-width (metadata-width spec)
                         :cell-type (metadata-cell-type spec))))
  (when (member (metadata-domain spec) *address-domains*)
    (unless (typep (metadata-granularity spec) '(integer 1 *))
      (%invalid spec (list :granularity-required-for-address-domain
                           (metadata-domain spec)
                           :granularity (metadata-granularity spec)))))
  ;; The default must be an admissible cell value.
  (let ((default (metadata-default spec)))
    (ecase (metadata-cell-type spec)
      (:bit
       (unless (member default '(0 1) :test #'eql)
         (%invalid spec (list :bad-default default :cell-type :bit))))
      (:integer
       (unless (and (typep default '(integer 0 *))
                    (<= (integer-length default) (metadata-width spec)))
         (%invalid spec (list :bad-default default :cell-type :integer))))
      (:reference nil)))
  (let ((placement (metadata-placement spec)))
    (unless (and (consp placement)
                 (dolist (p placement t)
                   (unless (member p *placements*)
                     (%invalid spec (list :bad-placement p))))
                 ;; An offered field is per-object addressing
                 ;; (client-protocols.tex section 1).
                 (or (not (member :offered-field placement))
                     (eq (metadata-domain spec) :object))
                 ;; Dense tables cannot address interior cells of
                 ;; address-derived strata; tables key object references.
                 (or (eq (metadata-domain spec) :object)
                     (not (member :side-table placement)))
                 ;; Dense vectors cannot index opaque object references.
                 (or (not (member :side-vector placement))
                     (not (eq (metadata-domain spec) :object))))
      (%invalid spec (list :bad-placement placement
                           :domain (metadata-domain spec)))))
  (let ((atomicity (metadata-atomicity spec)))
    (unless (and (consp atomicity)
                 (dolist (a atomicity t)
                   (unless (member a *atomicities*)
                     (%invalid spec (list :bad-atomicity a)))))
      (%invalid spec (list :bad-atomicity atomicity))))
  ;; Concurrency rules (strata.tex section 5).
  (unless (member (metadata-writers spec) *writer-domains*)
    (%invalid spec (list :bad-writers (metadata-writers spec))))
  (unless (member (metadata-order spec) *orders*)
    (%invalid spec (list :bad-order (metadata-order spec))))
  (when (eq (metadata-writers spec) :concurrent)
    (if (= (metadata-width spec) 1)
        (unless (or (member :bit-atomic (metadata-atomicity spec))
                    (member :cas (metadata-atomicity spec)))
          ;; Idempotent 0->1 semantics still require a language-level
          ;; atomic operation when writers race.
          (%invalid spec (list :racing-bit-requires-atomic-operation
                               (metadata-atomicity spec))))
        (unless (or (member :cas (metadata-atomicity spec))
                    (member :exclusive (metadata-atomicity spec))
                    (member :sealed-log (metadata-atomicity spec)))
          ;; Multi-bit cells require CAS, exclusive ownership, or a
          ;; sealed log.
          (%invalid spec (list :multi-bit-requires-cas-or-exclusive
                               (metadata-atomicity spec))))))
  (unless (member (metadata-transfer-policy spec) *transfers*)
    (%invalid spec (list :bad-transfer (metadata-transfer-policy spec))))
  ;; Retaining at region granularity is a region-keyed fact.
  (when (eq (metadata-transfer-policy spec) :retain-region)
    (unless (member (metadata-domain spec) '(:region :pair))
      (%invalid spec (list :retain-region-requires-region-domain
                           (metadata-domain spec)))))
  (when (eq (metadata-transfer-policy spec) :merge)
    (unless (functionp (metadata-merge-function spec))
      (%invalid spec (list :reason :merge-requires-merge-function))))
  (when (and (eq (metadata-transfer-policy spec) :discard)
             (eq (metadata-reset-semantics spec) :forbidden))
    ;; :discard performs the declared reset at both keys (strata.tex 3:
    ;; "intentionally discard"); a datum that forbids reset cannot
    ;; declare that policy.
    (%invalid spec (list :discard-requires-runnable-reset
                         (metadata-reset-semantics spec))))
  (when (eq (metadata-transfer-policy spec) :recompute)
    (unless (functionp (metadata-recompute spec))
      (%invalid spec (list :reason :recompute-transfer-requires-recompute-function))))
  (unless (member (metadata-persistence spec) *persistences*)
    (%invalid spec (list :bad-persistence (metadata-persistence spec))))
  ;; Recovery must either restore the datum from the same consistent
  ;; checkpoint or run its declared reconstruction before allocation and
  ;; reclamation resume (strata.tex 6).
  (when (eq (metadata-persistence spec) :reconstructible)
    (unless (functionp (metadata-recompute spec))
      (%invalid spec (list :reason :reconstructible-requires-reconstruction))))
  (unless (member (metadata-reset-semantics spec) *resets*)
    (%invalid spec (list :bad-reset (metadata-reset-semantics spec))))
  (when (eq (metadata-reset-semantics spec) :recompute)
    (unless (functionp (metadata-recompute spec))
      (%invalid spec (list :reason :recompute-reset-requires-recompute-function))))
  (when (metadata-kinds spec)
    (unless (and (listp (metadata-kinds spec))
                 (every #'symbolp (metadata-kinds spec)))
      (%invalid spec (list :bad-kinds (metadata-kinds spec))))))

;;; ---------------------------------------------------------------------
;;; Contributions and deterministic compatible merge.

(defclass metadata-contribution ()
  ((contributor :initarg :contributor :reader contribution-contributor)
   (specification :initarg :specification :reader contribution-specification))
  (:documentation "One component's contribution of a specification during
discovery (strata.tex 1: components contribute specifications during
discovery)."))

(defun make-contribution (contributor specification)
  (make-instance 'metadata-contribution
                 :contributor contributor :specification specification))

(defclass metadata-registry ()
  ((specifications :initarg :specifications :reader registry-specifications)
   (table :initarg :table :reader registry-table))
  (:documentation "Merged logical metadata: one canonical specification per
logical key, in deterministic first-mention order, each carrying contributor
provenance (composition.tex merge phase: unify compatible logical resources
and report all conflicts with provenance)."))

(defun find-metadata-specification (registry name)
  "The merged specification for logical key NAME, or NIL."
  (gethash name (registry-table registry)))

(defun %agree (a b)
  "EQUAL agreement with NIL as an unspecified value either side may refine."
  (or (equal a b) (null a) (null b)))

(defun %narrow (a b)
  "Narrow two alternative sets.  NIL means universal.  Returns the merged
set, or NIL when the alternatives are disjoint (a conflict)."
  (cond ((null a) b)
        ((null b) a)
        ((intersection a b) (remove-if-not (lambda (x) (member x b)) a))
        (t nil)))

;;; Each merge attribute names its reader generic (what conflict reports
;;; quote) and its storage slot (what a refinement writes).
(defparameter *agreement-attributes*
  '((domain metadata-domain domain)
    (cell-type metadata-cell-type cell-type)
    (width metadata-width width)
    (granularity metadata-granularity granularity)
    (default metadata-default default)
    (ownership metadata-ownership ownership)
    (lifetime metadata-lifetime lifetime)
    (writers metadata-writers writers)
    (order metadata-order order)
    (transfer-policy metadata-transfer-policy transfer)
    (persistence metadata-persistence persistence)
    (reset-semantics metadata-reset-semantics reset)
    (recompute metadata-recompute recompute)
    (merge-function metadata-merge-function merge-function)))

(defun %attribute-reader (attribute)
  (or (cadr (find attribute *agreement-attributes* :key #'car))
      (ecase attribute
        (placement 'metadata-placement)
        (atomicity 'metadata-atomicity)
        (kinds 'metadata-kinds))))

(defun %attribute-slot (attribute)
  (or (caddr (find attribute *agreement-attributes* :key #'car))
      (ecase attribute
        (placement 'placement)
        (atomicity 'atomicity)
        (kinds 'kinds))))

(defun %attribute-value (spec attribute)
  (funcall (%attribute-reader attribute) spec))

(defun %conflict (existing new contributor attribute)
  (error 'metadata-conflict
         :component contributor
         :fact (list :specification (metadata-name existing)
                     :attribute (intern (symbol-name attribute) :keyword)
                     :existing (%attribute-value existing attribute)
                     :offending (%attribute-value new attribute)
                     :existing-providers (specification-providers existing)
                     :offending-provider contributor)
         :contributors (append (specification-providers existing)
                               (list contributor))))

(defun %merge-specification (existing new contributor)
  "Merge NEW into canonical EXISTING.  Agreement attributes must agree under
EQUAL; NIL is an unspecified value that a compatible later provider refines,
and the refined value is stored.  Alternative sets (placement, atomicity,
kind coverage) narrow by intersection.  Merging can only narrow what a later
binding may choose, so it can never weaken atomicity, checkpoint, or
placement behavior; disagreement is a conflict with provenance, never a
silent fallback."
  (dolist (entry *agreement-attributes*)
    (let ((attribute (car entry)))
      (let ((existing-value (%attribute-value existing attribute))
            (new-value (%attribute-value new attribute)))
        (cond ((equal existing-value new-value))
              ;; A NIL value is unspecified: a compatible later provider
              ;; refines it, and the refined value is stored.
              ((and (null existing-value)
                    (member attribute '(ownership lifetime recompute merge-function)))
               (setf (slot-value existing (%attribute-slot attribute))
                     new-value))
              ((and (null new-value)
                    (member attribute '(ownership lifetime recompute merge-function))) nil)
              (t (%conflict existing new contributor attribute))))))
  (dolist (attribute '(placement atomicity))
    (let ((narrowed (%narrow (%attribute-value existing attribute)
                             (%attribute-value new attribute))))
      (unless narrowed
        (%conflict existing new contributor attribute))
      (setf (slot-value existing (%attribute-slot attribute)) narrowed)))
  ;; KINDS is required coverage, not a choice of placement.  A shared fact
  ;; must cover every kind used by either contributor; NIL means all kinds.
  (let ((ek (metadata-kinds existing)) (nk (metadata-kinds new)))
    (setf (slot-value existing 'kinds)
          (and ek nk (append ek (remove-if (lambda (k) (member k ek)) nk)))))
  (unless (%agree (metadata-recompute existing) (metadata-recompute new))
    (%conflict existing new contributor 'recompute))
  (unless (%agree (metadata-merge-function existing)
                  (metadata-merge-function new))
    (%conflict existing new contributor 'merge-function))
  (unless (member contributor (specification-providers existing) :test #'eq)
    (setf (specification-providers existing)
          (append (specification-providers existing) (list contributor))))
  existing)

(defun %copy-specification (spec)
  (make-instance 'metadata-specification
                 :name (metadata-name spec)
                 :domain (metadata-domain spec)
                 :cell-type (metadata-cell-type spec)
                 :width (metadata-width spec)
                 :granularity (metadata-granularity spec)
                 :default (metadata-default spec)
                 :placement (metadata-placement spec)
                 :atomicity (metadata-atomicity spec)
                 :ownership (metadata-ownership spec)
                 :lifetime (metadata-lifetime spec)
                 :writers (metadata-writers spec)
                 :order (metadata-order spec)
                 :transfer (metadata-transfer-policy spec)
                 :persistence (metadata-persistence spec)
                 :reset (metadata-reset-semantics spec)
                 :kinds (metadata-kinds spec)
                 :recompute (metadata-recompute spec)
                 :merge-function (metadata-merge-function spec)))

(defun merge-metadata (contributions)
  "Merge CONTRIBUTIONS (a list of contribution records, merged in list
order) into a registry holding one canonical specification per logical key.
Identical re-contributions deduplicate; compatible contributions refine
unspecified attributes and narrow alternative sets; any disagreement
signals METADATA-CONFLICT naming the key and both providers.  Equivalent
inputs produce an equivalent registry."
  (let ((table (make-hash-table :test #'eq)) (ordered ()))
    (dolist (contribution contributions)
      (let ((contributor (contribution-contributor contribution))
            (spec (contribution-specification contribution)))
        (unless (typep spec 'metadata-specification)
          (error 'metadata-invalid :component contributor
                 :fact (list :not-a-specification spec)))
        (%validate-specification spec)
        (let ((existing (gethash (metadata-name spec) table)))
          (if existing
              (%merge-specification existing spec contributor)
              (let ((merged (%copy-specification spec)))
                (setf (specification-providers merged) (list contributor))
                (push merged ordered)
                (setf (gethash (metadata-name spec) table) merged))))))
    (make-instance 'metadata-registry
                   :specifications (nreverse ordered)
                   :table table)))

;;; ---------------------------------------------------------------------
;;; Side-storage requests and supplies.
;;;
;;; strata.tex 1: construction "adds any side-storage request to the managed
;;; layout".  The layout callback owns geometry; this layer states what it
;;; needs and validates what comes back.  Supplies are boot-sized once;
;;; this layer never grows storage.

(defstruct (metadata-table (:constructor %make-metadata-table)
                           (:conc-name %mt-))
  "Fixed-capacity EQ table. Keys, values and occupancy are allocated once.
Lookup is a bounded linear scan; insertion, deletion and reuse never grow it."
  (keys #() :type simple-vector :read-only t)
  (values #() :type simple-vector :read-only t)
  (occupied #* :type simple-bit-vector :read-only t)
  (count 0 :type fixnum))

(defun make-metadata-table (capacity)
  "Allocate all storage for CAPACITY entries during plan construction."
  (unless (and (typep capacity '(integer 0 *))
               (< capacity array-dimension-limit)
               (<= capacity most-positive-fixnum))
    (error 'metadata-invalid :component :side-table
           :fact (list :invalid-capacity capacity)))
  (%make-metadata-table :keys (make-array capacity :initial-element nil)
                        :values (make-array capacity :initial-element nil)
                        :occupied (make-array capacity :element-type 'bit
                                                      :initial-element 0)))

(defun metadata-table-count (table) (%mt-count table))

(defun %table-index (table key)
  (dotimes (i (length (%mt-keys table)))
    (when (and (= 1 (sbit (%mt-occupied table) i))
               (eq key (svref (%mt-keys table) i)))
      (return i))))

(defun %table-ref (table key default)
  (let ((i (%table-index table key)))
    (if i (svref (%mt-values table) i) default)))

(defun %table-delete (table key)
  (let ((i (%table-index table key)))
    (when i
      (setf (sbit (%mt-occupied table) i) 0
            (svref (%mt-keys table) i) nil
            (svref (%mt-values table) i) nil)
      (decf (%mt-count table)))))

(defclass side-request ()
  ((specification :initarg :specification :reader side-request-specification)
   (kind :initarg :kind :reader side-request-kind)
   (cells :initarg :cells :reader side-request-cells)
   (base :initarg :base :reader side-request-base)
   (granularity :initarg :granularity :reader side-request-granularity)
   (domain :initarg :domain :reader side-request-domain)
   (width :initarg :width :reader side-request-width))
  (:documentation "One side-storage request handed to the layout callback:
KIND is :VECTOR (dense simple-vector, one cell per floor((a-b)/g)) or :TABLE
(fixed-capacity METADATA-TABLE keyed by normalized object reference)."))

(defclass side-storage ()
  ((vector :initarg :vector :reader side-storage-vector)
   (base :initarg :base :reader side-storage-base)
   (cells :initarg :cells :reader side-storage-cells)
   (atomics :initarg :atomics :initform nil :reader side-storage-atomics)
   (places :initarg :places :initform nil :reader side-storage-places))
  (:documentation "A boot-sized supply from the layout callback.  For a
:VECTOR request, VECTOR is a SIMPLE-VECTOR holding at least CELLS cells and
BASE is the bound range base b of the scalar stratum formula.  For a :TABLE
request, VECTOR is a METADATA-TABLE preallocated for at least CELLS
entries; BASE and CELLS restate the declared boot size.  Atomic vectors also
supply ATOMICS, a client providing relaxed load/store/CAS, and PLACES, a
simple-vector of prebuilt opaque places naming the same VECTOR cells.
Without that client the vector supports only coordinated plain access."))

(defun make-side-storage (&key vector (base 0) cells atomics places)
  (make-instance 'side-storage :vector vector :base base :cells cells
                 :atomics atomics :places places))

;;; ---------------------------------------------------------------------
;;; Handles.
;;;
;;; strata.tex 3: "Each datum declares one authoritative handle."  The
;;; binding produces exactly one handle per logical key; collector methods
;;; use the handle, not a client method whose name assumes the policy.

(defclass metadata-handle ()
  ((specification :initarg :specification :reader handle-specification)
   (placement :initarg :placement :reader handle-placement)
   (provided-atomicity :initarg :provided-atomicity :reader handle-atomicity)
   (provided-order :initarg :provided-order :reader handle-order))
  (:documentation "One authoritative bound handle for one logical key."))

(defclass field-metadata-handle (metadata-handle)
  ((object-model :initarg :object-model :reader field-object-model)
   (field :initarg :field :reader field-field)
   (default :initarg :default :reader handle-default)
   (cell-type :initarg :cell-type :reader handle-cell-type))
  (:documentation "Authoritative handle backed by a client-offered physical
metadata field (client-protocols.tex section 1).  Selected only when every
declared guarantee matched the specification.  DEFAULT and CELL-TYPE carry
the bound specification facts so reset and the bit operations run on the
field like on every other realization."))

(defclass vector-metadata-handle (metadata-handle)
  ((storage :initarg :storage :reader vector-storage)
   (atomics :initarg :atomics :reader vector-atomics)
   (places :initarg :places :reader vector-places)
   (base :initarg :base :reader vector-base)
   (span :initarg :span :reader vector-span)
   (granularity :initarg :granularity :reader vector-granularity)
   (cells :initarg :cells :reader vector-cells)
   (default :initarg :default :reader handle-default)
   (cell-type :initarg :cell-type :reader handle-cell-type)
   (integer-limit :initarg :integer-limit :reader vector-integer-limit))
  (:documentation "Authoritative handle backed by a boot-sized dense side
vector supplied by the layout callback.  The cell for byte address a is
floor((a - base) / granularity) (strata.tex 1).  REGION- and PAIR-domain
handles use base 0, granularity 1, and integer keys (for :pair the caller
supplies i*region-count+j)."))

(defclass table-metadata-handle (metadata-handle)
  ((storage :initarg :storage :reader table-storage)
   (cells :initarg :cells :reader table-cells)
   (default :initarg :default :reader handle-default)
   (cell-type :initarg :cell-type :reader handle-cell-type)
   (integer-limit :initarg :integer-limit :reader table-integer-limit))
  (:documentation "Authoritative handle backed by a boot-sized EQ metadata table
supplied by the layout callback.  Absent entries read as the declared
default, so reset clears a cell and live size tracks distinct non-default
cells.  Values compare under EQL.  The table holds at most TABLE-CELLS
entries -- the declared boot size; runtime growth is not provided, and a
write that would exceed the declared capacity signals METADATA-EXHAUSTED."))

;;; ---------------------------------------------------------------------
;;; Stratum operations (strata.tex section 2 protocol, plus reset and
;;; movement transfer).  Ref/set/cas/reset are the prebound hot operations:
;;; allocation measurements cover warmed hosted calls only.  First-call
;;; supervisor safety is a separate deployment obligation.

(defgeneric metadata-ref (handle key)
  (:documentation "Read the cell named by KEY."))
(defgeneric metadata-set (handle key value)
  (:documentation "Write VALUE to the cell named by KEY."))
(defgeneric metadata-cas (handle key old new)
  (:documentation "Compare the cell with OLD; if equal, store NEW.  Returns
the previous value.  Atomic vectors use the supplied client primitive;
plain vectors and tables compare under EQL with the caller's coordination."))
(defgeneric metadata-reset (handle key)
  (:documentation "Run the declared reset for KEY: restore the default, run
the declared recompute, or signal for :forbidden resets."))
(defgeneric metadata-set-bit (handle key)
  (:documentation "Set a bit cell (strata.tex 2 protocol)."))
(defgeneric metadata-clear-bit (handle key)
  (:documentation "Clear a bit cell (strata.tex 2 protocol)."))
(defgeneric metadata-clear-range (handle range)
  (:documentation "Reset every cell of RANGE to the default.  RANGE is a
(start . end) key interval for dense handles and NIL for whole-table
handles."))
(defgeneric metadata-fold (handle range function initial-value)
  (:documentation "Fold FUNCTION over the cells of RANGE; FUNCTION receives
(value accumulator) and returns the new accumulator."))
(defgeneric metadata-map-present (handle range function)
  (:documentation "Call FUNCTION on every present (non-default) cell of
RANGE; FUNCTION receives (key value)."))
(defgeneric metadata-project (source destination reducer)
  (:documentation "Project SOURCE into DESTINATION cell-wise; REDUCER
receives (source-value destination-value) and returns the new destination
value."))
(defgeneric metadata-transfer (handle source-key destination-key)
  (:documentation "Perform the datum's declared movement transfer policy
between SOURCE-KEY and DESTINATION-KEY (strata.tex 3: movement supplies a
transfer operation for every selected datum).  The client's
copy-object-representation transfers none of these by implication."))

;;; ---------------------------------------------------------------------
;;; Binding.
;;;
;;; strata.tex 1: construction "merges identically named facts, chooses a
;;; legal placement, adds any side-storage request to the managed layout,
;;; and binds a metadata handle."  Binding selects a client-offered field
;;; only when every declared guarantee matches; otherwise it requests
;;; boot-sized side storage from the layout callback.  A guarantee that does
;;; not match rejects the field -- it is never silently weakened -- and an
;;; unusable composition fails construction instead of falling back.

(defclass metadata-binding ()
  ((handles :initform () :accessor binding-handles)
   (table :initform (make-hash-table :test #'eq) :reader binding-table))
  (:documentation "The bound metadata set: exactly one authoritative handle
per logical key, in registry order.  FIND-METADATA returns the same (EQ)
handle for every lookup of a key."))

(defun find-metadata (binding name)
  "The one authoritative handle for logical key NAME, or NIL."
  (gethash name (binding-table binding)))

(defun %unsupported (spec fact contributors)
  (error 'metadata-unsupported
         :component (metadata-name spec) :fact fact
         :contributors contributors))

(defun %binding-input (spec key value contributors)
  (unless value
    (%unsupported spec (list :missing-binding-input key) contributors))
  value)

;;; Cell-count derivation with the paper's overflow checks (strata.tex 1:
;;; "Construction checks subtraction, multiplication, and rounding for
;;; overflow and ensures that every object start maps to a legal cell").

(defun %checked-cells (spec count contributors)
  (unless (typep count '(integer 0 *))
    (%unsupported spec (list :reason :arithmetic-overflow :cells count) contributors))
  (unless (and (< count array-dimension-limit)
               (<= count most-positive-fixnum))
    (%unsupported spec (list :reason :arithmetic-overflow :cells count) contributors))
  count)

(defun %required-vector-cells (spec base extent region-count contributors)
  (unless (and (typep base '(integer 0 *))
               (if (member (metadata-domain spec) *address-domains*)
                   (typep extent '(integer 0 *))
                   (and (zerop base)
                        (eql (metadata-granularity spec) 1)
                        (typep region-count '(integer 0 *)))))
    (%unsupported spec (list :reason :invalid-geometry :base base :extent extent
                            :region-count region-count) contributors))
  (let* ((domain (metadata-domain spec))
         (cells (ecase domain
                  (:word (%checked-cells
                          spec (ceiling extent (metadata-granularity spec))
                          contributors))
                  (:line (%checked-cells
                          spec (ceiling extent (metadata-granularity spec))
                          contributors))
                  (:page (%checked-cells
                          spec (ceiling extent (metadata-granularity spec))
                          contributors))
                  (:region (%checked-cells spec region-count contributors))
                  (:pair (%checked-cells
                          spec (* region-count region-count)
                          contributors)))))
    ;; The span the handle will accept must stay fixnum-addressable, and
    ;; base + span must not wrap (subtraction and multiplication checks).
    (let ((span (* cells (max 1 (or (metadata-granularity spec) 1)))))
      (unless (and (typep span '(integer 0 *))
                   (<= span most-positive-fixnum)
                   (<= (+ base span) most-positive-fixnum))
        (%unsupported spec (list :reason :arithmetic-overflow :span span)
                      contributors)))
    cells))

;;; Provided atomicity and memory order of this slice's realizations.
;;; Dense vectors use an explicitly supplied atomic client for shared access;
;;; this realization currently admits only :relaxed order.
;;; The boot table offers plain access only, so it hosts only :plain facts.

(defun %provided-atomicity (placement &optional atomics)
  ;; PLACEMENT is the placement-class keyword; the :offered-field case is
  ;; decided per field from its declared guarantees.
  (ecase placement
    (:side-vector
     (if atomics '(:plain :bit-atomic :cas) '(:plain)))
    (:side-table '(:plain))
    (:offered-field nil)))

(defun %provided-order (placement)
  (ecase placement
    ((:side-vector :side-table) :relaxed)
    (:offered-field nil)))

(defun %order-admits-p (required provided)
  (ecase required
    (:relaxed t)
    (:acquire (member provided '(:acquire :sequential)))
    (:release (member provided '(:release :sequential)))
    (:sequential (eq provided :sequential))))

(defun %side-atomicity-ok-p (spec kind contributors &optional atomics)
  ;; Never silently weaken atomicity: the realization must provide a
  ;; mechanism the specification accepts (client-protocols.tex section 4:
  ;; construction rejects a client that only provides weaker operations).
  (let ((provided (%provided-atomicity kind atomics)))
    (unless (and (intersection provided (metadata-atomicity spec))
                 (or atomics (not (eq (metadata-writers spec) :concurrent))))
      (%unsupported spec
                    (list :reason :atomicity-unavailable
                          :required (metadata-atomicity spec)
                          :provided provided
                          :realization kind)
                    contributors))
    (unless (%order-admits-p (metadata-order spec)
                             (%provided-order kind))
      (%unsupported spec
                    (list :reason :order-unavailable
                          :required (metadata-order spec)
                          :provided (%provided-order kind)
                          :realization kind)
                    contributors))))

;;; Offered-field guarantee matching.  The guarantee plist is a documented
;;; implementation seam (the paper declares which facts a field carries but
;;; names no accessor for them, so the client maps each offered field to):
;;;   (:width w :values vals :atomicity a :order o :copy c :checkpoint k
;;;    :kinds kinds)
;;; :width a positive integer; :values the admissible values (NIL =
;;; unchecked); :atomicity one of :plain/:bit-atomic/:cas; :order the
;;; field's documented memory order (default :relaxed); :copy :copies or
;;; :clears (what copy-object-representation does to the field);
;;; :checkpoint :preserved or :lost (what consistent checkpoint recovery
;;; does); :kinds the object kinds possessing the field (empty = all).

(defun %field-accepts-p (spec guarantees)
  "Return NIL when every declared guarantee matches, or a reason keyword
naming the first mismatch.  Any mismatch rejects the field."
  (unless (and (listp guarantees) (getf guarantees :width))
    (return-from %field-accepts-p :missing-guarantees))
  (let ((width (getf guarantees :width))
        (values (getf guarantees :values))
        (atomicity (getf guarantees :atomicity))
        (order (getf guarantees :order :relaxed))
        (copy (getf guarantees :copy))
        (checkpoint (getf guarantees :checkpoint))
        (kinds (getf guarantees :kinds)))
    ;; Width: the field must be at least as wide as the datum.
    (unless (and (typep width '(integer 1 *))
                 (>= width (metadata-width spec)))
      (return-from %field-accepts-p :width))
    ;; Admissible values must admit the declared default.
    (when (and values
               (not (member (metadata-default spec) values :test #'equal)))
      (return-from %field-accepts-p :values))
    ;; Atomicity: the field's mechanism must be one the specification
    ;; accepts.  A weaker field is a mismatch, never a candidate.
    (unless (and (member atomicity *atomicities*)
                 (member atomicity (metadata-atomicity spec)))
      (return-from %field-accepts-p :atomicity))
    ;; Memory order must not be weaker than declared.
    (unless (%order-admits-p (metadata-order spec) order)
      (return-from %field-accepts-p :order))
    ;; Copy interaction must match the declared movement transfer policy:
    ;; the client's raw copy must not decide mark/age/publication/forwarding
    ;; transfer (client-protocols.tex section 1).  A raw copy that
    ;; duplicates the field may host only a :copy-transfer fact; every
    ;; other policy requires a field the raw copy clears.
    (unless (if (eq (metadata-transfer-policy spec) :copy)
                (eq copy :copies)
                (eq copy :clears))
      (return-from %field-accepts-p :copy-transfer))
    ;; Checkpoint interaction must not weaken the declared classification
    ;; (strata.tex 6).  An authoritative datum must survive recovery.  A
    ;; datum recovery does not restore must be ephemeral in storage that
    ;; loses it, or reconstructible with a declared reconstruction that
    ;; invalidates the stale field value before reclamation resumes.
    (ecase (metadata-persistence spec)
      (:authoritative
       (unless (eq checkpoint :preserved)
         (return-from %field-accepts-p :checkpoint)))
      (:reconstructible
       (unless (or (eq checkpoint :lost)
                   (and (eq checkpoint :preserved)
                        (eq (metadata-reset-semantics spec) :recompute)))
         (return-from %field-accepts-p :checkpoint)))
      (:ephemeral
       (unless (eq checkpoint :lost)
         (return-from %field-accepts-p :checkpoint))))
    ;; Kind coverage: the field must be possessed by every kind the
    ;; specification declares; a universal specification requires a
    ;; universal field.
    (let ((sk (metadata-kinds spec)))
      (if (null sk)
          (unless (null kinds)
            (return-from %field-accepts-p :kinds))
          (unless (or (null kinds) (subsetp sk kinds :test #'eq))
            (return-from %field-accepts-p :kinds)))))
  nil)

(defun %select-field (spec object-model field-guarantees contributors)
  "Scan the client's offered fields in client order and return the first
field whose declared guarantees all match, or a plist of rejection reasons."
  (declare (ignore contributors))
  (let ((rejections ()))
    (dolist (field (offered-metadata-fields object-model))
      (let ((reason (%field-accepts-p spec (funcall field-guarantees field))))
        (if reason
            (push (list :field field :reason reason) rejections)
            (return-from %select-field (values field nil)))))
    (values nil (nreverse rejections))))

(defun %bind-field (spec object-model field-guarantees contributors)
  (unless (and object-model field-guarantees)
    (return-from %bind-field
      (values nil (list :reason :no-object-model-or-guarantee-function))))
  (multiple-value-bind (field rejections)
      (%select-field spec object-model field-guarantees contributors)
    (if field
        (let ((guarantees (funcall field-guarantees field)))
          (values
           (make-instance
            'field-metadata-handle
            :specification spec :placement :offered-field
            :provided-atomicity (getf guarantees :atomicity)
            :provided-order (getf guarantees :order :relaxed)
            :default (metadata-default spec)
            :cell-type (metadata-cell-type spec)
            :object-model object-model :field field)
           nil))
        (values nil (list :no-acceptable-field rejections)))))

(defun %bind-vector (spec layout base extent region-count contributors)
  (let* ((cells (%required-vector-cells spec base extent region-count
                                        contributors))
         (request (make-instance
                   'side-request
                   :specification spec :kind :vector :cells cells
                   :base base :granularity (or (metadata-granularity spec) 1)
                   :domain (metadata-domain spec)
                   :width (metadata-width spec))))
    (unless layout
      (return-from %bind-vector
        (values nil (list :reason :no-layout-callback))))
    (let ((supply (funcall layout request)))
      (unless (typep supply 'side-storage)
        (return-from %bind-vector
          (values nil (list :side-storage-missing supply))))
      (let ((vector (side-storage-vector supply))
            (supply-cells (side-storage-cells supply))
            (atomics (side-storage-atomics supply))
            (places (side-storage-places supply)))
        (unless (and (simple-vector-p vector)
                     (typep supply-cells '(integer 0 *))
                     (>= supply-cells cells)
                     (<= supply-cells (length vector))
                     (eql base (side-storage-base supply))
                     (if atomics
                         (and (simple-vector-p places)
                              (>= (length places) cells))
                         (null places)))
          (return-from %bind-vector
            (values nil (list :reason :side-storage-invalid
                              :simple-vector-p (simple-vector-p vector)
                              :declared-cells supply-cells
                              :required-cells cells))))
        (%side-atomicity-ok-p spec :side-vector contributors atomics)
        (values
         (make-instance
          'vector-metadata-handle
          :specification spec :placement :side-vector
          :provided-atomicity (%provided-atomicity :side-vector atomics)
          :provided-order (%provided-order :side-vector)
          :storage vector
          :atomics atomics :places places
          :base base
          :span (if (member (metadata-domain spec) *address-domains*)
                    extent cells)
          :granularity (max 1 (or (metadata-granularity spec) 1))
          :cells cells
          :default (metadata-default spec)
          :cell-type (metadata-cell-type spec)
          :integer-limit (ash 1 (metadata-width spec)))
         nil)))))

(defun %bind-table (spec layout object-cells contributors)
  (let* ((cells (%checked-cells spec object-cells contributors))
         (request (make-instance
                   'side-request
                   :specification spec :kind :table :cells cells
                   :base 0 :granularity 1
                   :domain (metadata-domain spec)
                   :width (metadata-width spec))))
    (unless layout
      (return-from %bind-table (values nil (list :reason :no-layout-callback))))
    (let ((supply (funcall layout request)))
      (unless (typep supply 'side-storage)
        (return-from %bind-table
          (values nil (list :side-storage-missing supply))))
      (let ((table (side-storage-vector supply))
          (supply-cells (side-storage-cells supply)))
        ;; The supply must be a fixed EQ table that declares at least the
        ;; requested boot size; anything else is an unusable composition,
        ;; never a silent acceptance of smaller storage.
        (unless (and (metadata-table-p table)
                     (typep supply-cells '(integer 0 *))
                     (>= supply-cells cells)
                     (<= supply-cells (length (%mt-keys table)))
                     (<= (metadata-table-count table) cells))
          (return-from %bind-table
            (values nil (list :reason :side-storage-invalid
                              :metadata-table-p (metadata-table-p table)
                              :declared-cells supply-cells
                              :required-cells cells))))
        (values
         (make-instance
          'table-metadata-handle
          :specification spec :placement :side-table
          :provided-atomicity (%provided-atomicity :side-table)
          :provided-order (%provided-order :side-table)
          :storage table
          :cells cells
          :default (metadata-default spec)
          :cell-type (metadata-cell-type spec)
          :integer-limit (ash 1 (metadata-width spec)))
         nil)))))

(defun %bind-one (spec object-model field-guarantees layout
                   base extent object-cells region-count contributors)
  "Try the specification's placement alternatives in declared order.
Each alternative either fully satisfies the declared guarantees or is
rejected; an unusable composition fails with every attempt recorded."
  (let ((attempts ()))
    (dolist (alternative (metadata-placement spec))
      (multiple-value-bind (handle reason)
          (ecase alternative
            (:offered-field
             (%bind-field spec object-model field-guarantees contributors))
            (:side-vector
             (%bind-vector spec layout base extent region-count
                           contributors))
            (:side-table
             (%side-atomicity-ok-p spec :side-table contributors)
             (%bind-table spec layout object-cells contributors)))
        (when handle
          (return-from %bind-one handle))
        (push (list :alternative alternative :reason reason) attempts)))
    (%unsupported spec
                  (list :reason :no-legal-placement
                         :attempts (nreverse attempts))
                  contributors)))

;;; ---------------------------------------------------------------------
;;; Dense-vector realization.

(declaim (inline %vector-cell))

(defun %vector-cell (handle key)
  "Cell index for KEY by the scalar stratum formula cell = floor((a-b)/g),
with the paper's range check: every mapped cell must be a legal cell."
  (if (typep key 'integer)
      (let ((d (- key (vector-base handle))))
        (if (and (typep d '(integer 0 *)) (< d (vector-span handle)))
            (let ((cell (floor d (vector-granularity handle))))
              (if (< cell (vector-cells handle))
                  cell
                  (error 'metadata-key-error
                         :component (handle-name handle)
                         :fact (list :key-out-of-range key
                                     :base (vector-base handle)
                                     :cells (vector-cells handle)))))
            (error 'metadata-key-error
                   :component (handle-name handle)
                   :fact (list :key-before-base key
                               :base (vector-base handle)))))
      (error 'metadata-key-error
             :component (handle-name handle)
             :fact (list :key-not-an-integer key
                         :domain (metadata-domain
                                  (handle-specification handle))))))

(defun bind-metadata (registry &key object-model field-guarantees layout
                                 (base 0) extent object-cells region-count)
  "Bind every merged specification of REGISTRY to exactly one authoritative
handle.  OBJECT-MODEL and FIELD-GUARANTEES enable :offered-field placement
(FIELD-GUARANTEES is a function of one field returning its guarantee plist).
LAYOUT is the layout callback; it receives each SIDE-REQUEST and returns a
SIDE-STORAGE supply.  BASE and EXTENT bound the address-derived ranges;
REGION-COUNT sizes :region and :pair strata; OBJECT-CELLS sizes boot
tables.  Binding does not execute runtime operations or recompute hooks.
Returns a METADATA-BINDING;
every unusable composition signals METADATA-UNSUPPORTED."
  (let ((binding (make-instance 'metadata-binding)))
    (dolist (spec (registry-specifications registry))
      (let ((handle (%bind-one spec object-model field-guarantees layout
                               base extent object-cells region-count
                               (specification-providers spec))))
        (setf (gethash (metadata-name spec) (binding-table binding))
              handle)
        (push handle (slot-value binding 'handles))))
    (setf (slot-value binding 'handles)
          (nreverse (slot-value binding 'handles)))
    binding))

(defun %check-integer-value (handle value)
  (unless (and (typep value '(integer 0 *))
               (< value (vector-integer-limit handle)))
    (error 'metadata-key-error
           :component (handle-name handle)
           :fact (list :value-out-of-cell-range value
                       :width (metadata-width
                               (handle-specification handle))))))

(defmethod metadata-ref ((handle vector-metadata-handle) key)
  (%vector-read handle (%vector-cell handle key)))

(defun %vector-read (handle cell)
  (if (vector-atomics handle)
      (atomic-load (vector-atomics handle) (svref (vector-places handle) cell)
                   :relaxed)
      (svref (vector-storage handle) cell)))

(defun %vector-write (handle cell value)
  (if (vector-atomics handle)
      (atomic-store (vector-atomics handle) (svref (vector-places handle) cell)
                    value :relaxed)
      (setf (svref (vector-storage handle) cell) value))
  value)

(defun %vector-cas (handle cell old new)
  (if (vector-atomics handle)
      (atomic-cas (vector-atomics handle) (svref (vector-places handle) cell)
                  old new :relaxed)
      (let ((previous (svref (vector-storage handle) cell)))
        (when (eql previous old)
          (setf (svref (vector-storage handle) cell) new))
        previous)))

(defmethod metadata-set ((handle vector-metadata-handle) key value)
  (ecase (handle-cell-type handle)
    (:bit (unless (or (eql value 0) (eql value 1))
            (error 'metadata-key-error
                   :component (handle-name handle)
                   :fact (list :value-out-of-cell-range value
                               :cell-type :bit))))
    (:integer (%check-integer-value handle value))
    (:reference nil))
  (%vector-write handle (%vector-cell handle key) value)
  value)

(defmethod metadata-cas ((handle vector-metadata-handle) key old new)
  (unless (eq (handle-cell-type handle) :reference)
    (%check-integer-value handle new))
  (%vector-cas handle (%vector-cell handle key) old new))

(defmethod metadata-reset ((handle vector-metadata-handle) key)
  (let ((spec (handle-specification handle)))
    (ecase (metadata-reset-semantics spec)
      (:default
       (metadata-set handle key (handle-default handle)))
      (:recompute
       (metadata-set handle key
                     (funcall (metadata-recompute spec) key
                              (metadata-ref handle key))))
      (:forbidden
       (error 'metadata-key-error
              :component (handle-name handle)
              :fact (list :reset-forbidden (metadata-name spec)))))))

(defmethod metadata-set-bit ((handle vector-metadata-handle) key)
  (unless (eq (handle-cell-type handle) :bit)
    (error 'metadata-key-error
           :component (handle-name handle)
           :fact (list :bit-operation-on-non-bit-cell
                       (handle-cell-type handle))))
  (%vector-cas handle (%vector-cell handle key) 0 1))

(defmethod metadata-clear-bit ((handle vector-metadata-handle) key)
  (unless (eq (handle-cell-type handle) :bit)
    (error 'metadata-key-error
           :component (handle-name handle)
           :fact (list :bit-operation-on-non-bit-cell
                       (handle-cell-type handle))))
  (%vector-cas handle (%vector-cell handle key) 1 0))

;;; Range helpers: RANGE is (start . end) with start included and end
;;; excluded, in the handle's key space.

(defun %dense-cell-range (handle range)
  (unless (and (consp range) (typep (car range) 'integer)
               (typep (cdr range) 'integer))
    (error 'metadata-key-error
           :component (handle-name handle)
           :fact (list :bad-range range)))
  (let* ((start (%vector-cell-or-edge handle (car range)))
         (end (%vector-cell-or-edge handle (cdr range))))
    (unless (<= (car range) (cdr range))
      (error 'metadata-key-error
             :component (handle-name handle)
             :fact (list :bad-range range)))
    (values start end)))

(defun %vector-cell-or-edge (handle key)
  (if (= key (+ (vector-base handle) (vector-span handle)))
      (vector-cells handle)
      (%vector-cell handle key)))

(defmethod metadata-clear-range ((handle vector-metadata-handle) range)
  (multiple-value-bind (start end) (%dense-cell-range handle range)
    (do ((cell start (1+ cell)))
        ((>= cell end))
      (metadata-reset handle (+ (vector-base handle)
                                (* cell (vector-granularity handle)))))
    handle))

(defmethod metadata-fold ((handle vector-metadata-handle) range function
                          initial-value)
  (multiple-value-bind (start end) (%dense-cell-range handle range)
    (let ((acc initial-value))
      (do ((cell start (1+ cell)))
          ((>= cell end) acc)
        (setf acc (funcall function (%vector-read handle cell) acc))))))

(defmethod metadata-map-present ((handle vector-metadata-handle) range
                                 function)
  (multiple-value-bind (start end) (%dense-cell-range handle range)
    (let ((default (handle-default handle))
          (base (vector-base handle))
          (g (vector-granularity handle)))
      (do ((cell start (1+ cell)))
          ((>= cell end) handle)
        (let ((value (%vector-read handle cell)))
          (unless (eql value default)
            (funcall function (+ base (* cell g)) value)))))))

(defmethod metadata-project ((source vector-metadata-handle)
                             (destination vector-metadata-handle) reducer)
  (unless (and (= (vector-base source) (vector-base destination))
               (= (vector-cells source) (vector-cells destination))
               (= (vector-granularity source) (vector-granularity destination)))
    (error 'metadata-unsupported
           :component (handle-name source)
           :fact (list :reason :project-incompatible
                       :source (handle-name source)
                       :destination (handle-name destination))))
  (do ((cell 0 (1+ cell)))
        ((>= cell (vector-cells destination)) destination)
      (metadata-set destination
                    (+ (vector-base destination)
                       (* cell (vector-granularity destination)))
                    (funcall reducer (%vector-read source cell)
                             (%vector-read destination cell)))))

;;; ---------------------------------------------------------------------
;;; Boot-table realization.

(defun %check-table-value (handle value)
  (ecase (handle-cell-type handle)
    (:bit (unless (or (eql value 0) (eql value 1))
            (error 'metadata-key-error
                   :component (handle-name handle)
                   :fact (list :value-out-of-cell-range value
                               :cell-type :bit))))
    (:integer (unless (and (typep value '(integer 0 *))
                           (< value (table-integer-limit handle)))
                (error 'metadata-key-error
                       :component (handle-name handle)
                       :fact (list :value-out-of-cell-range value
                                   :width (metadata-width
                                           (handle-specification handle))))))
    (:reference nil)))

(defmethod metadata-ref ((handle table-metadata-handle) key)
  (%table-ref (table-storage handle) key (handle-default handle)))

;;; Admission discipline for boot-table writes.  The table stores only
;;; distinct non-default cells (absent entries read as the default), so a
;;; write of the default removes the entry, and a fresh key is admitted
;;; only under the declared boot capacity.  Runtime growth is not
;;; provided: exhaustion is explicit (METADATA-EXHAUSTED) and names the
;;; datum, the capacity, and the rejected key.  Saturation never silently
;;; loses a cell (strata.tex section 2).
(defun %table-store (handle key value)
  (let ((table (table-storage handle)))
    (if (eql value (handle-default handle))
        (%table-delete table key)
        (let ((index (%table-index table key)))
          (unless index
            (let ((limit (table-cells handle)))
              (when (>= (metadata-table-count table) limit)
                (error 'metadata-exhausted
                       :component (handle-name handle)
                       :fact (list :reason :side-storage-exhausted
                                   :realization :side-table
                                   :capacity limit
                                   :live (metadata-table-count table)
                                   :key key)
                       :contributors (specification-providers
                                      (handle-specification handle)))))
            (setf index (position 0 (%mt-occupied table)))
            (setf (svref (%mt-keys table) index) key
                  (sbit (%mt-occupied table) index) 1)
            (incf (%mt-count table)))
          (setf (svref (%mt-values table) index) value))))
  value)

(defmethod metadata-set ((handle table-metadata-handle) key value)
  (%check-table-value handle value)
  (%table-store handle key value)
  value)

(defmethod metadata-cas ((handle table-metadata-handle) key old new)
  ;; EQL comparison under the caller's coordination; this realization
  ;; provides :plain atomicity only, and construction refuses facts
  ;; requiring more (see %SIDE-ATOMICITY-OK-P).
  (%check-table-value handle new)
  (let ((previous (%table-ref (table-storage handle) key (handle-default handle))))
    (when (eql previous old)
      (%table-store handle key new))
    previous))

(defmethod metadata-reset ((handle table-metadata-handle) key)
  (let ((spec (handle-specification handle)))
    (ecase (metadata-reset-semantics spec)
      (:default (%table-delete (table-storage handle) key))
      (:recompute
       (metadata-set handle key
                     (funcall (metadata-recompute spec) key
                              (%table-ref (table-storage handle) key
                                          (handle-default handle)))))
      (:forbidden
       (error 'metadata-key-error
              :component (handle-name handle)
              :fact (list :reset-forbidden (metadata-name spec)))))))

(defmethod metadata-set-bit ((handle table-metadata-handle) key)
  (unless (eq (handle-cell-type handle) :bit)
    (error 'metadata-key-error
           :component (handle-name handle)
           :fact (list :bit-operation-on-non-bit-cell
                       (handle-cell-type handle))))
  (%table-store handle key 1)
  1)

(defmethod metadata-clear-bit ((handle table-metadata-handle) key)
  (unless (eq (handle-cell-type handle) :bit)
    (error 'metadata-key-error
           :component (handle-name handle)
           :fact (list :bit-operation-on-non-bit-cell
                       (handle-cell-type handle))))
  (%table-store handle key 0)
  0)

(defmethod metadata-clear-range ((handle table-metadata-handle) range)
  (unless (null range)
    (error 'metadata-key-error
           :component (handle-name handle)
           :fact (list :reason :range-not-nameable :realization :side-table)))
  (unless (eq (metadata-reset-semantics (handle-specification handle)) :default)
    (error 'metadata-key-error :component (handle-name handle)
           :fact (list :reason :whole-table-reset-requires-default)))
  (let ((table (table-storage handle)))
    (fill (%mt-keys table) nil)
    (fill (%mt-values table) nil)
    (fill (%mt-occupied table) 0)
    (setf (%mt-count table) 0))
  handle)

(defmethod metadata-fold ((handle table-metadata-handle) range function
                          initial-value)
  (unless (null range)
    (error 'metadata-key-error
           :component (handle-name handle)
           :fact (list :reason :range-not-nameable :realization :side-table)))
  (let ((acc initial-value) (table (table-storage handle)))
    (dotimes (i (length (%mt-keys table)) acc)
      (when (= 1 (sbit (%mt-occupied table) i))
        (setf acc (funcall function (svref (%mt-values table) i) acc))))))

(defmethod metadata-map-present ((handle table-metadata-handle) range
                                 function)
  (unless (null range)
    (error 'metadata-key-error
           :component (handle-name handle)
           :fact (list :reason :range-not-nameable :realization :side-table)))
  (let ((table (table-storage handle)))
    (dotimes (i (length (%mt-keys table)))
      (when (= 1 (sbit (%mt-occupied table) i))
        (funcall function (svref (%mt-keys table) i)
                         (svref (%mt-values table) i)))))
  handle)

(defmethod metadata-project ((source table-metadata-handle)
                             (destination table-metadata-handle) reducer)
  (unless (eq (handle-cell-type source) (handle-cell-type destination))
    (error 'metadata-unsupported
           :component (handle-name source)
           :fact (list :reason :project-incompatible
                       :source (handle-name source)
                       :destination (handle-name destination))))
  (let ((table (table-storage source)))
    (dotimes (i (length (%mt-keys table)))
      (when (= 1 (sbit (%mt-occupied table) i))
        (let ((key (svref (%mt-keys table) i)))
          (metadata-set destination key
                        (funcall reducer (svref (%mt-values table) i)
                                 (metadata-ref destination key)))))))
  destination)

;;; ---------------------------------------------------------------------
;;; Offered-field realization.

(defmethod metadata-ref ((handle field-metadata-handle) key)
  (field-read (field-object-model handle) (field-field handle) key))

(defmethod metadata-set ((handle field-metadata-handle) key value)
  (field-write (field-object-model handle) (field-field handle) key value)
  value)

(defmethod metadata-cas ((handle field-metadata-handle) key old new)
  (field-cas (field-object-model handle) (field-field handle) key old new))

(defmethod metadata-reset ((handle field-metadata-handle) key)
  (let ((spec (handle-specification handle)))
    (ecase (metadata-reset-semantics spec)
      (:default
       (field-write (field-object-model handle) (field-field handle) key
                    (handle-default handle)))
      (:recompute
       (field-write
        (field-object-model handle) (field-field handle) key
        (funcall (metadata-recompute spec) key
                 (field-read (field-object-model handle)
                             (field-field handle) key))))
      (:forbidden
       (error 'metadata-key-error
              :component (handle-name handle)
              :fact (list :reset-forbidden (metadata-name spec)))))))

(defmethod metadata-set-bit ((handle field-metadata-handle) key)
  (unless (eq (handle-cell-type handle) :bit)
    (error 'metadata-key-error
           :component (handle-name handle)
           :fact (list :bit-operation-on-non-bit-cell
                       (handle-cell-type handle))))
  ;; An atomic field sets its bit through the field's CAS; a plain field
  ;; through a plain write (client-protocols.tex section 1).
  (if (eq (handle-atomicity handle) :plain)
      (progn (field-write (field-object-model handle) (field-field handle)
                          key 1)
             1)
      (field-cas (field-object-model handle) (field-field handle) key 0 1)))

(defmethod metadata-clear-bit ((handle field-metadata-handle) key)
  (unless (eq (handle-cell-type handle) :bit)
    (error 'metadata-key-error
           :component (handle-name handle)
           :fact (list :bit-operation-on-non-bit-cell
                       (handle-cell-type handle))))
  (if (eq (handle-atomicity handle) :plain)
      (progn (field-write (field-object-model handle) (field-field handle)
                          key 0)
             0)
      (field-cas (field-object-model handle) (field-field handle) key 1 0)))

;;; ---------------------------------------------------------------------
;;; Operations a realization cannot name reject explicitly.  Offered
;;; fields are per-object: the realization has no key enumeration, so
;;; range and whole-structure operations have no legal key set.  Silent
;;; fallback is non-conforming (composition.tex), so every handle answers
;;; every stratum-protocol operation with either the operation or this
;;; explicit rejection.
(defmethod metadata-clear-range ((handle metadata-handle) range)
  (declare (ignore range))
  (error 'metadata-key-error
         :component (handle-name handle)
         :fact (list :reason :operation-unavailable
                     :operation :clear-range
                     :realization (handle-placement handle))))

(defmethod metadata-fold ((handle metadata-handle) range function
                          initial-value)
  (declare (ignore range function initial-value))
  (error 'metadata-key-error
         :component (handle-name handle)
         :fact (list :reason :operation-unavailable
                     :operation :fold
                     :realization (handle-placement handle))))

(defmethod metadata-map-present ((handle metadata-handle) range function)
  (declare (ignore range function))
  (error 'metadata-key-error
         :component (handle-name handle)
         :fact (list :reason :operation-unavailable
                     :operation :map-present
                     :realization (handle-placement handle))))

(defmethod metadata-project ((source metadata-handle)
                             (destination metadata-handle) reducer)
  (declare (ignore reducer))
  (error 'metadata-key-error
         :component (handle-name source)
         :fact (list :reason :operation-unavailable
                     :operation :project
                     :source (handle-placement source)
                     :destination (handle-placement destination))))

;;; ---------------------------------------------------------------------
;;; Movement transfer (strata.tex 3).
;;;
;;; One method over the authoritative handle: every realization moves the
;;; logical datum according to the declared policy.  The client's raw
;;; copy-object-representation transfers none of these by implication.

(defmethod metadata-transfer ((handle metadata-handle) source-key
                              destination-key)
  (let ((spec (handle-specification handle)))
    (ecase (metadata-transfer-policy spec)
      ;; Mark state normally transfers to the destination during a live
      ;; move (strata.tex 3).
      (:copy
       (metadata-set handle destination-key (metadata-ref handle source-key)))
      ;; The fact is cleared at the destination, not carried.
      (:clear
       (metadata-set handle destination-key (handle-default handle)))
      ;; Relation-style merge through the declared merge function.
      (:merge
       (metadata-set handle destination-key
                     (funcall (metadata-merge-function spec)
                              (metadata-ref handle destination-key)
                              (metadata-ref handle source-key))))
      ;; Retain at region granularity: a region-keyed datum survives object
      ;; movement unchanged.
      (:retain-region nil)
      ;; Recompute at the destination through the declared function (age may
      ;; increment or reset according to promotion policy).
      (:recompute
       (metadata-set handle destination-key
                     (funcall (metadata-recompute spec) destination-key
                              (metadata-ref handle destination-key))))
      ;; Intentionally discard: neither side keeps the datum.
      (:discard
       (metadata-reset handle destination-key)
       (metadata-reset handle source-key)))
    handle))

;;; ---------------------------------------------------------------------
;;; Handle accessors shared by all realizations.

(defun handle-name (handle)
  "The logical key of HANDLE's datum (strata.tex 3: collectors use the
handle, not a client method whose name assumes the policy)."
  (metadata-name (handle-specification handle)))
