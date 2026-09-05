;;;; src/core/managed-layout.lisp -- paper-v11 managed layout kernel.
;;;;
;;;; Normative source: paper-v11/chapters/managed-layout.tex (sections 1-6),
;;;; read together with composition.tex (construction phases, "Lay out") and
;;;; client-protocols.tex (the address-space client seams this kernel calls).
;;;;
;;;; Scope and honest limits:
;;;;   * This kernel implements the deterministic interval allocator, the
;;;;     checked layout solution, and the installed ownership geometry with
;;;;     bounded no-allocation lookup and epoch-guarded updates.
;;;;   * It does NOT implement initial-image construction
;;;;     (managed-layout.tex section 7) and makes no deployment-profile or
;;;;     initial-image conformance claim.  It is one portable realization
;;;;     of the layout semantics, not a conformance statement.
;;;;
;;;; Load order: this file requires the address-space protocol
;;;; (src/protocol/address-space.lisp, system clamsara/protocol/address-space)
;;;; to be loaded first; the package imports its client generics.
;;;;
;;;; Record shapes: the paper specifies the SEMANTICS of the client offer,
;;;; resource requests, and the layout solution, but not their record
;;;; layouts.  Every defstruct below is this implementation's documented
;;;; choice for those semantics.

(defpackage #:clamsara-managed-layout
  (:use #:cl)
  (:import-from #:clamsara-protocol.address-space
                #:managed-arena-offer
                #:validate-managed-layout
                #:install-managed-layout
                #:space-of-reference
                #:update-space-ownership)
  (:export
   ;; address-space offer (managed-layout.tex section 2)
   #:address-space-offer #:make-address-space-offer
   #:offer-arenas #:offer-exclusions #:offer-address-width
   #:managed-arena #:make-managed-arena
   #:arena-name #:arena-base #:arena-extent #:arena-end
   #:arena-alignment #:arena-page-size #:arena-access-modes
   #:arena-reservations #:arena-checkpoint-volatile-p
   #:arena-reservation #:make-arena-reservation
   #:reservation-start #:reservation-extent #:reservation-kind
   #:exclusion #:make-exclusion
   #:exclusion-start #:exclusion-extent #:exclusion-kind
   ;; resource requests (managed-layout.tex section 3)
   #:resource-request #:make-resource-request
   #:request-name #:request-owner #:request-kind
   #:request-min-extent #:request-preferred-extent #:request-max-extent
   #:request-alignment #:request-page-granularity
   #:request-access #:request-atomicity
   #:request-lifetime #:request-returnable-pages-p
   #:request-mobility #:request-reclaimability
   #:request-stable-across-checkpoint-p
   #:request-adjacent-to #:request-separated-from
   #:request-alias-with #:request-near
   #:request-derive-from #:request-size-function
   ;; placement constraints
   #:adjacency-constraint #:make-adjacency-constraint
   #:adjacency-target #:adjacency-direction #:adjacency-constraint-p
   #:separation-constraint #:make-separation-constraint
   #:separation-target #:separation-min-gap #:separation-constraint-p
   #:near-constraint #:make-near-constraint
   #:near-target #:near-reach #:near-reason #:near-constraint-p
   ;; layout solution (managed-layout.tex section 4)
   #:build-managed-layout
   #:managed-layout
   #:solution-regions #:solution-arenas #:solution-free-intervals
   #:solution-work-capacity #:solution-installed-p
   #:find-solution-region
   #:layout-region
   #:region-name #:region-request #:region-owner #:region-kind
   #:region-arena-name #:region-start #:region-extent #:region-end
   #:region-access #:region-atomicity #:region-alias-partners
   #:region-stable-across-checkpoint-p #:region-effective-page
   #:free-interval #:free-arena-name #:free-start #:free-extent
   ;; metadata derivation report (checked callback argument)
   #:derivation-source #:source-name #:source-start #:source-extent
   #:layout-derivation #:derivation-sources
   ;; address-to-space resolution (managed-layout.tex section 5)
   #:layout-space-at
   #:open-ownership-epoch #:quiesce-ownership-epoch
   #:ownership-epoch #:epoch-layout #:epoch-quiesced-p #:epoch-consumed-p
   ;; checked arithmetic helpers
   #:interval-gap
   ;; rejection conditions
   #:layout-rejection
   #:layout-rejection-reason #:layout-rejection-resource
   #:layout-rejection-constraint #:layout-rejection-provider
   #:layout-rejection-owner #:layout-rejection-detail
   #:ownership-epoch-required #:stale-ownership-epoch))

(in-package #:clamsara-managed-layout)

;;; ---------------------------------------------------------------------
;;; Rejection conditions.
;;;
;;; Every failed composition rejects with LAYOUT-REJECTION carrying the
;;; resource name, the constraint record, the provider (arena) context,
;;; the owning component, and a detail string.  composition.tex
;;; ("Constraints and diagnostics"): construction errors must name the
;;; requiring component, the missing or conflicting fact, and the path.
;;; Silent fallback is non-conforming.

(define-condition layout-rejection (error)
  ((reason :initarg :reason :initform :unspecified
           :reader layout-rejection-reason)
   (resource :initarg :resource :initform nil
             :reader layout-rejection-resource)
   (constraint :initarg :constraint :initform nil
               :reader layout-rejection-constraint)
   (provider :initarg :provider :initform nil
             :reader layout-rejection-provider)
   (owner :initarg :owner :initform nil
          :reader layout-rejection-owner)
   (detail :initarg :detail :initform nil
           :reader layout-rejection-detail))
  (:report (lambda (condition stream)
             (format stream "~&managed layout rejected (~s)"
                     (layout-rejection-reason condition))
             (when (layout-rejection-resource condition)
               (format stream " resource ~s" (layout-rejection-resource condition)))
             (when (layout-rejection-owner condition)
               (format stream " owner ~s" (layout-rejection-owner condition)))
             (when (layout-rejection-provider condition)
               (format stream " provider ~s" (layout-rejection-provider condition)))
             (when (layout-rejection-constraint condition)
               (format stream " constraint ~s" (layout-rejection-constraint condition)))
             (when (layout-rejection-detail condition)
               (format stream ": ~a" (layout-rejection-detail condition))))))

;; Ownership-epoch discipline (managed-layout.tex section 5): an update
;; without a quiesced epoch token is refused, never raced silently.
(define-condition ownership-epoch-required (layout-rejection) ())
(define-condition stale-ownership-epoch (layout-rejection) ())

(defun reject (reason &key resource constraint provider owner detail)
  (error 'layout-rejection
         :reason reason :resource resource :constraint constraint
         :provider provider :owner owner :detail detail))

;;; ---------------------------------------------------------------------
;;; Checked integer helpers.  Common Lisp bignums never wrap, so "checked
;;; arithmetic" here means: every sum stays inside the client's declared
;;; address width and inside the fixnum index range this realization's
;;; dense page tables require; every alignment modulus is a positive
;;; integer; every extent is an honest page multiple.

(declaim (inline align-up align-down interval-gap))

(defun align-up (value modulus)
  (the (integer 0 *) (* (ceiling value modulus) modulus)))

(defun align-down (value modulus)
  (the (integer 0 *) (* (floor value modulus) modulus)))

(defun interval-gap (a-start a-end b-start b-end)
  "Distance between intervals [A-START,A-END) and [B-START,B-END); zero
when they overlap or abut."
  (cond ((<= a-end b-start) (- b-start a-end))
        ((<= b-end a-start) (- a-start b-end))
        (t 0)))

(defun %sort-vector (vector predicate &key key)
  "Deterministic in-place insertion sort of VECTOR by PREDICATE (a
total order on the key values -- every comparator this kernel uses is
total because semantic names are unique).  Every kernel sort goes
through this one implementation so ordering never depends on the host
SORT algorithm."
  (let* ((n (length vector))
         (keys (if key
                   (map 'vector (lambda (x) (funcall key x)) vector)
                   vector)))
    (do ((i 1 (1+ i)))
        ((>= i n))
      (let ((value (aref vector i))
            (k (aref keys i)))
        ;; shift keys greater than K right, then drop K into the hole
        (do ((j i (1- j)))
            ((or (zerop j)
                 (not (funcall predicate k (aref keys (1- j)))))
             (setf (aref vector j) value
                   (aref keys j) k))
          (setf (aref vector j) (aref vector (1- j))
                (aref keys j) (aref keys (1- j)))))))
  vector)

(defun %sort-list (list predicate &key key)
  "Sort LIST by PREDICATE (total order) via %SORT-VECTOR; returns a list."
  (coerce (%sort-vector (coerce list 'vector) predicate :key key) 'list))


;;; ---------------------------------------------------------------------
;;; Client offer records (managed-layout.tex section 2).
;;;
;;; The paper: "Each arena describes base, extent, alignment, page
;;; geometry, permitted access modes, and implementation reservations",
;;; and "Canonical-address restrictions, kernel windows, ... appear as
;;; exclusions".  The slot layout below is an implementation choice.

(defstruct (address-space-offer
            (:conc-name offer-)
            (:constructor make-address-space-offer
                (&key arenas exclusions (address-width 64))))
  "Implementation record of the client's address-space offer: ARENAS is
a list of MANAGED-ARENA, EXCLUSIONS a list of EXCLUSION (machine ranges
no managed region may enter, whatever their cause: kernel windows,
MMIO, DMA, stacks, page tables).  ADDRESS-WIDTH is the client's machine
address width in bits; every computed range end must stay below
2^ADDRESS-WIDTH.  Implementation choice: the paper fixes none of these
shapes."
  (arenas nil :type list)
  (exclusions nil :type list)
  (address-width 64 :type (integer 1 *)))

(defstruct (managed-arena
            (:conc-name arena-)
            (:constructor make-managed-arena
                (&key name base extent
                      (alignment 1) (page-size 1)
                      (access-modes '(:read :write))
                      reservations
                      (checkpoint-volatile-p nil))))
  "One managed arena offered to Clamsara.  BASE/EXTENT are byte ranges
in the machine address space; ALIGNMENT is the arena's minimum
assignment alignment in bytes; PAGE-SIZE is the logical page geometry
(the unit of address-space ownership and storage identity; a logical
page is not a resident physical frame).  ACCESS-MODES lists the
permitted access modes (members of :READ/:WRITE/:EXECUTE).
RESERVATIONS lists ARENA-RESERVATION records:
implementation-reserved intervals inside this arena that managed
regions must not enter.  CHECKPOINT-VOLATILE-P marks an arena whose
ranges the client rebuilds across checkpoint recovery (e.g. scratch): a
request requiring checkpoint-stable addresses must never land there.
Implementation choice: the paper names the facts, not the record."
  (name nil)
  (base 0 :type (integer 0 *))
  (extent 0 :type (integer 0 *))
  (alignment 1 :type (integer 1 *))
  (page-size 1 :type (integer 1 *))
  (access-modes '(:read :write) :type list)
  (reservations nil :type list)
  (checkpoint-volatile-p nil :type boolean))

(defun arena-end (arena)
  "First address past ARENA (exclusive)."
  (+ (arena-base arena) (arena-extent arena)))

(defstruct (arena-reservation
            (:conc-name reservation-)
            (:constructor make-arena-reservation
                (&key start extent (kind :client-reserved))))
  "Implementation-reserved interval [START, START+EXTENT) inside one
arena.  KIND is a client documentation symbol (e.g. :page-tables,
:boot-stack).  Implementation choice."
  (start 0 :type (integer 0 *))
  (extent 0 :type (integer 1 *))
  (kind :client-reserved))

(defstruct (exclusion
            (:conc-name exclusion-)
            (:constructor make-exclusion (&key start extent (kind :unspecified))))
  "Machine range [START, START+EXTENT) excluded from every arena:
canonical-address restrictions, kernel windows, direct physical maps,
MMIO, DMA, active stacks, page tables (managed-layout.tex section 2).
Clamsara never guesses these; the client reports them.  Implementation
choice for the record shape."
  (start 0 :type (integer 0 *))
  (extent 0 :type (integer 1 *))
  (kind :unspecified))

(defparameter *known-access-modes* '(:read :write :execute)
  "Access mode names this kernel understands.  A client offering or
requesting anything else is rejected rather than guessed at.")

;;; ---------------------------------------------------------------------
;;; Placement constraint records (managed-layout.tex section 3).

(defstruct (adjacency-constraint
            (:conc-name adjacency-)
            (:constructor make-adjacency-constraint
                (&key target (direction :after))))
  "This region must abut TARGET's region with zero gap: DIRECTION :after
means this region starts exactly at TARGET's end; :before means it ends
exactly at TARGET's start.  Implementation choice for the record."
  (target nil)
  (direction :after :type (member :after :before)))

(defstruct (separation-constraint
            (:conc-name separation-)
            (:constructor make-separation-constraint (&key target (min-gap nil))))
  "This region and TARGET's region must be separated by at least
MIN-GAP bytes of unassigned space (NIL: the arena's logical page size,
this implementation's default).  Separation between regions of
different arenas is trivially satisfied.  Implementation choice for the
default."
  (target nil)
  (min-gap nil :type (or null (integer 0 *))))

(defstruct (near-constraint
            (:conc-name near-)
            (:constructor make-near-constraint (&key target reach reason)))
  "Relative placement: the gap between this region and TARGET's region
must not exceed REACH bytes.  REACH is the numeric reachability
constraint the placement serves; managed-layout.tex section 3 requires
a 'near' request to state it, so a missing or non-numeric REACH is a
rejected composition, never a guessed default.  REASON documents what
the reach serves.  Implementation choice for the record."
  (target nil)
  (reach nil)
  (reason nil))

;;; ---------------------------------------------------------------------
;;; Resource requests (managed-layout.tex section 3).
;;;
;;; "A managed resource request contains: stable semantic name and owning
;;; component; kind; minimum, preferred, and maximum extent; alignment
;;; and logical-page granularity; adjacency, separation, alias, or
;;; relative-placement constraints; lifetime and whether logical pages
;;; can be returned; object mobility and collector reclaimability facts;
;;; access/atomicity requirements; whether addresses must remain stable
;;; across checkpoint recovery."
;;;
;;; There is deliberately NO fixed-address slot: "Fixed addresses are
;;; client constraints or explicit plan requirements, never a default
;;; field copied into every space."  Every slot below is this
;;; implementation's record choice for the listed facts.

(defstruct (resource-request
            (:conc-name request-)
            (:constructor make-resource-request
                (&key name owner kind
                      min-extent preferred-extent max-extent
                      (alignment 1) page-granularity
                      (access '(:read :write)) (atomicity :none)
                      (lifetime :plan) (returnable-pages-p nil)
                      (mobility :movable) (reclaimability :reclaimable)
                      (stable-across-checkpoint-p nil)
                      (adjacent-to nil) (separated-from nil)
                      (alias-with nil) (near nil)
                      (derive-from nil) (size-function nil))))
  "Implementation record for one managed resource request.  NAME is the
stable semantic name (symbol); OWNER the owning component designator;
KIND one of :OBJECT-SPACE, :METADATA, :WORK-STORAGE,
:CODE-INDEPENDENT-TABLE, :RESERVED-GROWTH.  MIN-/PREFERRED-/MAX-EXTENT
are bytes (preferred defaults to minimum, maximum to preferred).
ALIGNMENT in bytes; PAGE-GRANULARITY the request's logical-page
granularity (NIL: the arena's page size).  ACCESS lists required modes;
ATOMICITY names the requirement fact (:none, :cas, :atomic-bit-set,
...), carried for plan validation.  LIFETIME is a client symbol (e.g.
:plan, :phase); RETURNABLE-PAGES-P whether logical pages can be
returned; MOBILITY and RECLAIMABILITY carry the object-mobility and
collector-reclaimability facts (e.g. :movable/:immovable,
:reclaimable/:non-reclaimable).  STABLE-ACROSS-CHECKPOINT-P requires
addresses stable across checkpoint recovery: such a request is never
placed in a checkpoint-volatile arena.  ADJACENT-TO, SEPARATED-FROM,
NEAR take the constraint records above; ALIAS-WITH names intentional
alias partners.  DERIVE-FROM names the object-space requests whose
ASSIGNED ranges size this metadata; SIZE-FUNCTION is the checked
callback receiving a LAYOUT-DERIVATION report and returning bytes.
Implementation choice for the record."
  (name nil)
  (owner nil)
  (kind nil)
  (min-extent nil)
  (preferred-extent nil)
  (max-extent nil)
  (alignment 1 :type (integer 1 *))
  (page-granularity nil)
  (access '(:read :write) :type list)
  (atomicity :none)
  (lifetime :plan)
  (returnable-pages-p nil :type boolean)
  (mobility :movable)
  (reclaimability :reclaimable)
  (stable-across-checkpoint-p nil :type boolean)
  ;; constraint slots accept a single record/name or a list; normalized
  ;; by %VALIDATE-REQUEST before solving
  (adjacent-to nil)
  (separated-from nil)
  (alias-with nil)
  (near nil)
  (derive-from nil)
  (size-function nil))

;;; ---------------------------------------------------------------------
;;; Solution records (managed-layout.tex sections 4-5).

(defstruct (layout-region (:conc-name region-))
  "One assigned managed region of a solved layout.  All slots are fixed
at construction; region geometry is immutable after installation.
ALIAS-PARTNERS lists the semantic names this region intentionally
shares its interval with (mutually declared).  Implementation choice."
  (name nil :read-only t)
  (request nil :read-only t)
  (owner nil :read-only t)
  (kind nil :read-only t)
  (arena-name nil :read-only t)
  (start nil :read-only t)
  (extent nil :read-only t)
  (access nil :read-only t)
  (atomicity nil :read-only t)
  (alias-partners nil :read-only t)
  (stable-across-checkpoint-p nil :read-only t)
  (effective-page nil :read-only t))

(defun region-end (region)
  "First address past REGION (exclusive)."
  (+ (region-start region) (region-extent region)))

(defstruct (free-interval (:conc-name free-))
  "Explicitly reported unassigned span inside one arena.  Growth
capacity appears either as an assigned :RESERVED-GROWTH region or as
one of these reported intervals; the solution never hides slack.
Implementation choice."
  (arena-name nil :read-only t)
  (start 0 :read-only t :type (integer 0 *))
  (extent 0 :read-only t :type (integer 0 *)))

(defstruct (derivation-source (:conc-name source-))
  "One assigned range a metadata size was derived from.  Implementation
choice for the checked callback argument."
  (name nil :read-only t)
  (start 0 :read-only t :type (integer 0 *))
  (extent 0 :read-only t :type (integer 0 *)))

(defstruct (layout-derivation (:conc-name derivation-))
  "Argument handed to a metadata SIZE-FUNCTION callback: the ASSIGNED
object ranges (not requested sizes) the metadata is derived from.
Implementation choice."
  (sources nil :read-only t :type list))

(defstruct (arena-index-entry (:conc-name %aix-))
  "Internal: one arena's ownership geometry.  PAGE-TABLE is a dense
fixnum vector, one entry per logical page of the arena; zero means no
owner, otherwise a region id (1-based index into the layout's region
vector).  This is the dense page-descriptor realization family of
managed-layout.tex section 5, bounded to the OFFERED arenas -- never to
the whole machine address space."
  (arena nil :read-only t)
  (base 0 :read-only t :type fixnum)
  (end 0 :read-only t :type fixnum)
  (page-size 1 :read-only t :type fixnum)
  (page-count 0 :read-only t :type fixnum)
  (page-table nil :read-only t))

(defstruct (ownership-epoch (:conc-name epoch-))
  "Ownership epoch token.  An ownership update is accepted only under a
token that has been explicitly quiesced and not yet consumed; one
quiesced token authorizes exactly one update.  This implements
managed-layout.tex section 5: 'A page cannot be returned, reassigned,
or reused until all readers from the old ownership epoch have
quiesced.'"
  (layout nil :read-only t)
  (quiesced-p nil :type boolean)
  (consumed-p nil :type boolean))

(defstruct (managed-layout (:conc-name solution-))
  "A complete layout solution / installed ownership geometry.  The
solution contains no physical frame identifiers anywhere: installation
reserves virtual ranges and constructs logical ownership
(managed-layout.tex section 4); backing and residency belong to the
client's providers."
  (offer nil :read-only t)
  (regions nil :read-only t)          ; list sorted by (start, name)
  (region-vector nil :read-only t)    ; simple-vector, id = position + 1
  (arenas nil :read-only t)           ; offered arenas, offer order
  (arena-index nil :read-only t)      ; simple-vector of entries by base
  (free-intervals nil :read-only t)
  (work-capacity 0 :read-only t :type (integer 0 *))
  (installed-p nil)                   ; flips once install-managed-layout returns
  (open-epoch nil)                    ; currently open epoch token
  (authorized-epoch nil)              ; quiesced, unconsumed token
  (update-count 0))

(defun find-solution-region (layout name)
  "Region of LAYOUT whose semantic name is NAME (compared by
symbol-name), or NIL."
  (let ((string (symbol-name name)))
    (dolist (region (solution-regions layout) nil)
      (when (string= (symbol-name (region-name region)) string)
        (return region)))))

;;; ---------------------------------------------------------------------
;;; Address-to-space resolution, direct realization
;;; (managed-layout.tex section 5).
;;;
;;; LAYOUT-SPACE-AT is the deployment-profile entry point: an ordinary
;;; function, no CLOS generic dispatch in its body, bounded binary arena
;;; search plus one dense page-table reference, zero consing after first
;;; call.  SPACE-OF-REFERENCE (protocol generic) delegates to it for
;;; clients that want the generic seam; a profile that forbids generic
;;; dispatch in lookup calls LAYOUT-SPACE-AT directly.  This realization
;;; requires arena spans (and page counts) to fit the host fixnum range;
;;; a builder rejecting an offer on those grounds is the honest boundary
;;; of THIS realization, not of the specification, which explicitly
;;; allows other realizations (two-level tables, tags, interval tries).

(declaim (ftype (function (managed-layout (integer 0 *))
                          (values (or layout-region null) &optional))
                layout-space-at))

(defun layout-space-at (layout address)
  "Resolve machine ADDRESS in LAYOUT to its owning region, or NIL when
the page is unowned or the address outside every offered arena.
Bounded time (binary search over arenas plus one table reference), no
allocation, no generic dispatch."
  (declare (optimize (speed 3)))
  ;; Validated layouts are bounded by MOST-POSITIVE-FIXNUM.  Reject a
  ;; bignum or negative probe before entering the typed hot search.
  (when (and (typep address 'fixnum)
             (not (minusp (the fixnum address))))
    (let ((index (solution-arena-index layout)))
      (declare (simple-vector index)
               (fixnum address))
    (let ((lo 0)
          (hi (the fixnum (1- (the fixnum (length index)))))
          (entry nil))
      (declare (fixnum lo hi))
      (loop (when (> lo hi) (return))
            (let* ((mid (ash (+ lo hi) -1))
                   (candidate (svref index mid)))
              (declare (type arena-index-entry candidate))
              (cond ((< address (the fixnum (%aix-base candidate)))
                     (setf hi (1- mid)))
                    ((>= address (the fixnum (%aix-end candidate)))
                     (setf lo (1+ mid)))
                    (t (setf entry candidate) (return)))))
      (when entry
        (let* ((base (%aix-base entry))
               (page-size (%aix-page-size entry))
               (table (%aix-page-table entry))
               ;; the search above guarantees base <= address < end and
               ;; end <= most-positive-fixnum, so this stays fixnum
               (page (floor (the fixnum (- address base)) page-size)))
          (declare (fixnum base page-size page))
          (let ((id (aref (the (simple-array fixnum (*)) table) page)))
            (declare (fixnum id))
            (when (plusp id)
              (svref (the simple-vector (solution-region-vector layout))
                     (1- id))))))))))

(defmethod clamsara-protocol.address-space:space-of-reference
    ((layout managed-layout) (reference integer))
  "Generic seam (managed-layout.tex section 5).  This kernel's
realization resolves machine addresses; normalization of tagged or
interior references belongs to the object-model client
(client-protocols.tex section 1)."
  (layout-space-at layout reference))

;;; ---------------------------------------------------------------------
;;; Ownership updates under explicit quiesced epochs.

(defun open-ownership-epoch (layout)
  "Open an ownership epoch on LAYOUT.  Exactly one epoch may be open at
a time; the token must be quiesced (QUIESCE-OWNERSHIP-EPOCH) before it
authorizes an update, and one quiesced token authorizes exactly one
update."
  (when (solution-open-epoch layout)
    (error 'stale-ownership-epoch
           :reason :epoch-open
           :detail "an ownership epoch is already open; quiesce and consume it before opening another"))
  (let ((token (make-ownership-epoch :layout layout)))
    (setf (solution-open-epoch layout) token)
    token))

(defun quiesce-ownership-epoch (layout token)
  "Mark TOKEN quiesced: all readers from the old ownership epoch have
quiesced, so the next (single) ownership update may proceed."
  (unless (and (ownership-epoch-p token)
               (eq (epoch-layout token) layout)
               (eq token (solution-open-epoch layout)))
    (error 'stale-ownership-epoch
           :reason :stale-token
           :provider (and (ownership-epoch-p token) (epoch-layout token))
           :detail "quiesce-ownership-epoch: token is not this layout's open epoch"))
  (when (epoch-consumed-p token)
    (error 'stale-ownership-epoch
           :reason :stale-token
           :resource :ownership-epoch
           :detail "token already consumed"))
  (setf (epoch-quiesced-p token) t
        (solution-authorized-epoch layout) token)
  token)

(defun %authorized-epoch (layout)
  (let ((token (solution-authorized-epoch layout)))
    (cond ((null token)
           (error 'ownership-epoch-required
                  :reason :ownership-epoch-required
                  :detail "ownership update requires an explicitly quiesced ownership epoch token; racing updates are refused"))
          ((not (epoch-quiesced-p token))
           (error 'ownership-epoch-required
                  :reason :ownership-epoch-required
                  :detail "epoch token is open but not quiesced"))
          ((epoch-consumed-p token)
           (error 'stale-ownership-epoch
                  :reason :stale-token
                  :resource :ownership-epoch
                  :detail "epoch token is stale (already consumed)"))
          (t token))))

(defun %resolve-owner (layout owner)
  (let ((region (etypecase owner
                  (layout-region owner)
                  (symbol (find-solution-region layout owner)))))
    (unless (and region (find region (solution-region-vector layout) :test #'eq))
      (reject :invalid-request :owner owner
              :detail "owner is neither a region of this layout nor a region name"))
    region))

(defmethod clamsara-protocol.address-space:update-space-ownership
    ((layout managed-layout) range owner)
  "Reassign ownership of RANGE = (START . EXTENT) (bytes, arena-page
aligned, inside one arena) to OWNER (a region of this layout or its
name).  Requires an installed layout and a quiesced, unconsumed
ownership epoch token (OPEN-OWNERSHIP-EPOCH +
QUIESCE-OWNERSHIP-EPOCH); the token is consumed by the update.  The
page-table stores are single-word in-place writes: the update is atomic
per page and never allocates."
  (unless (solution-installed-p layout)
    (reject :invalid-request
            :detail "ownership updates require an installed layout"))
  (let ((token (%authorized-epoch layout)))
    (declare (ignorable token))
    (unless (and (consp range)
                 (typep (car range) '(integer 0 *))
                 (typep (cdr range) '(integer 1 *)))
      (reject :invalid-request
              :owner (and (symbolp owner) owner)
              :detail "range must be (START . EXTENT) with positive byte extent"))
    (let* ((start (car range))
         (extent (cdr range))
         (owner-region (%resolve-owner layout owner))
         (index (solution-arena-index layout))
         (entry (let ((found nil))
                  (dotimes (k (length index) found)
                    (let ((e (svref index k)))
                      (when (<= (%aix-base e) start)
                        (setf found e))))))
         ;; entry: the LAST arena whose base is <= start; range checks follow
         (within (and entry
                      (< start (+ (%aix-base entry) (%aix-extent* entry))))))
    (declare (type (or null arena-index-entry) entry))
    (unless within
      (reject :invalid-request
              :resource (region-name owner-region)
              :owner (region-owner owner-region)
              :detail "ownership-update range is outside every offered arena"))
    (let* ((base (%aix-base entry))
           (page-size (%aix-page-size entry))
           (table (%aix-page-table entry))
           (offset (- start base))
           (pages (floor extent page-size)))
      (unless (and (zerop (mod offset page-size))
                   (zerop (mod extent page-size))
                   (<= (+ offset extent) (%aix-extent* entry)))
        (reject :invalid-request
                :resource (region-name owner-region)
                :owner (region-owner owner-region)
                :provider (arena-name (%aix-arena entry))
                :detail "ownership-update range must be arena-page aligned and inside one arena"))
      (let ((first (floor offset page-size)))
        (when (> (+ first pages) (length table))
          (reject :overflow
                  :resource (region-name owner-region)
                  :provider (arena-name (%aix-arena entry))
                  :detail "ownership-update range exceeds the arena page table"))
        (let ((id (1+ (position owner-region
                                (solution-region-vector layout)))))
          (loop for k from first below (+ first pages)
                do (setf (aref table k) id))
          (incf (solution-update-count layout))
          ;; consume the token: one quiesced epoch authorizes one update
          (setf (epoch-consumed-p token) t
                (solution-authorized-epoch layout) nil
                (solution-open-epoch layout) nil)
          owner-region))))))

(defun %aix-extent* (entry)
  "Arena byte extent of ENTRY (the page table covers exactly this)."
  (* (%aix-page-size entry) (%aix-page-count entry)))

;;; ---------------------------------------------------------------------
;;; Offer and request validation.

(defun %check-int (value what resource owner &key (min 0))
  (unless (and (integerp value) (>= value min))
    (reject :invalid-request :resource resource :owner owner
            :detail (format nil "~a must be an integer >= ~d, got ~s"
                            what min value))))

(defun %normalize-once (x)
  "Normalize a constraint slot: a single record becomes a one-element
list; a list passes through."
  (cond ((null x) nil)
        ((consp x) x)
        (t (list x))))

(defun %normalize-request (request)
  "Return a copy of REQUEST with constraint slots normalized to lists and
extent defaults refined (preferred := min, max := preferred)."
  (let ((min (request-min-extent request))
        (preferred (or (request-preferred-extent request)
                       (request-min-extent request)))
        (maximum (or (request-max-extent request)
                     (or (request-preferred-extent request)
                         (request-min-extent request)))))
    (make-resource-request
     :name (request-name request)
     :owner (request-owner request)
     :kind (request-kind request)
     :min-extent min
     :preferred-extent preferred
     :max-extent maximum
     :alignment (request-alignment request)
     :page-granularity (request-page-granularity request)
     :access (request-access request)
     :atomicity (request-atomicity request)
     :lifetime (request-lifetime request)
     :returnable-pages-p (request-returnable-pages-p request)
     :mobility (request-mobility request)
     :reclaimability (request-reclaimability request)
     :stable-across-checkpoint-p (request-stable-across-checkpoint-p request)
     :adjacent-to (%normalize-once (request-adjacent-to request))
     :separated-from (%normalize-once (request-separated-from request))
     :alias-with (let ((a (request-alias-with request)))
                   (cond ((null a) nil)
                         ((symbolp a) (list a))
                         (t (copy-list a))))
     :near (%normalize-once (request-near request))
     :derive-from (let ((d (request-derive-from request)))
                    (cond ((null d) nil)
                          ((symbolp d) (list d))
                          (t (copy-list d))))
     :size-function (request-size-function request))))

(defun %validate-request (request)
  "Validate one request in isolation; signal LAYOUT-REJECTION on any
malformed fact.  Returns the normalized copy (constraint slots as
lists, extent defaults refined preferred := min, max := preferred).
Validation runs on the normalized copy so defaults are checked."
  (setq request (%normalize-request request))
  (let ((name (request-name request))
        (owner (request-owner request))
        (kind (request-kind request)))
    (unless (and (symbolp name) (not (null name)))
      (reject :invalid-request :resource name :owner owner
              :detail "resource request requires a stable semantic name (non-nil symbol)"))
    (unless owner
      (reject :invalid-request :resource name
              :detail "resource request requires an owning component"))
    (unless (member kind '(:object-space :metadata :work-storage
                           :code-independent-table :reserved-growth))
      (reject :invalid-request :resource name :owner owner
              :detail (format nil "unknown resource kind ~s" kind)))
    (%check-int (request-min-extent request) "min-extent" name owner :min 1)
    (%check-int (request-preferred-extent request) "preferred-extent" name owner :min 1)
    (%check-int (request-max-extent request) "max-extent" name owner :min 1)
    (%check-int (request-alignment request) "alignment" name owner :min 1)
    (when (request-page-granularity request)
      (%check-int (request-page-granularity request) "page-granularity" name owner :min 1))
    (unless (<= (request-min-extent request)
                (request-preferred-extent request)
                (request-max-extent request))
      (reject :invalid-request :resource name :owner owner
              :detail (format nil "extents must satisfy min <= preferred <= max, got ~s"
                              (list (request-min-extent request)
                                    (request-preferred-extent request)
                                    (request-max-extent request)))))
    (dolist (mode (request-access request))
      (unless (member mode *known-access-modes*)
        (reject :invalid-request :resource name :owner owner
                :detail (format nil "unknown access mode ~s" mode))))
    (when (null (request-access request))
      (reject :invalid-request :resource name :owner owner
              :detail "a request must state its access requirement"))
    ;; kind :work-storage reserves collection-time capacity; a zero
    ;; minimum reserves nothing and is exactly the "hidden emergency
    ;; allocation" invariant 6 forbids.
    (when (and (eq kind :work-storage)
               (zerop (request-min-extent request)))
      (reject :invalid-request :resource name :owner owner
              :detail "work-storage with zero minimum reserves no collection-time capacity; hidden emergency allocation is forbidden"))
    (dolist (c (request-near request))
      (unless (near-constraint-p c)
        (reject :invalid-request :resource name :owner owner
                :detail "near constraint must be a NEAR-CONSTRAINT record"))
      (unless (and (integerp (near-reach c)) (>= (near-reach c) 0))
        (reject :invalid-request :resource name :owner owner :constraint c
                :detail "a 'near' request must state the numeric reachability constraint it serves (non-negative integer REACH)")))
    (dolist (c (request-adjacent-to request))
      (unless (adjacency-constraint-p c)
        (reject :invalid-request :resource name :owner owner
                :detail "adjacency constraint must be an ADJACENCY-CONSTRAINT record")))
    (dolist (c (request-separated-from request))
      (unless (separation-constraint-p c)
        (reject :invalid-request :resource name :owner owner
                :detail "separation constraint must be a SEPARATION-CONSTRAINT record"))
      (when (separation-min-gap c)
        (%check-int (separation-min-gap c) "separation min-gap" name owner :min 0)))
    (dolist (target (request-alias-with request))
      (unless (symbolp target)
        (reject :invalid-request :resource name :owner owner
                :detail "alias partners must be named by symbol"))
      (when (string= (symbol-name target) (symbol-name name))
        (reject :ambiguous :resource name :owner owner
                :detail "a resource cannot intentionally alias itself")))
    (when (and (request-derive-from request)
               (not (eq kind :metadata)))
      (reject :invalid-request :resource name :owner owner
              :detail "only :metadata requests derive their extent from assigned object ranges"))
    (when (request-derive-from request)
      (unless (request-size-function request)
        (reject :invalid-request :resource name :owner owner
                :detail "derived metadata requires a SIZE-FUNCTION callback")))
    (when (and (request-size-function request)
               (not (request-derive-from request)))
      (reject :invalid-request :resource name :owner owner
              :detail "SIZE-FUNCTION given without DERIVE-FROM"))
    request))

(defun %validate-requests (requests)
  "Validate every request; reject duplicate semantic names (composition
ambiguity).  Returns the normalized request list."
  (let ((seen (make-hash-table :test 'equal))
        (normalized nil))
    (dolist (request requests)
      (setq normalized (cons (%validate-request request) normalized)))
    (setq normalized (nreverse normalized))
    (dolist (request normalized)
      (let ((string (symbol-name (request-name request))))
        (when (gethash string seen)
          (reject :ambiguous :resource (request-name request)
                  :provider (gethash string seen)
                  :detail "two requests share one semantic name; the composition is ambiguous"))
        (setf (gethash string seen) (request-owner request))))
    normalized))

(defstruct (arena-state)
  "Internal: per-arena solver state."
  arena
  name
  (static-blocks nil)   ; reservations + clipped exclusions, sorted (start . end)
  (placements nil))     ; placed regions, kept sorted by start

(defun %validate-offer (offer)
  "Validate the offer's arenas and exclusions; returns a list of
ARENA-STATE records in offer order, each with its static blocks
(implementation reservations plus clipped exclusions) precomputed."
  (let ((states nil)
        (address-limit (expt 2 (offer-address-width offer))))
    (dolist (arena (offer-arenas offer))
      (unless (managed-arena-p arena)
        (reject :invalid-request
                :provider arena
                :detail "offer arenas must be MANAGED-ARENA records")))
    (dolist (arena (offer-arenas offer))
      (let ((name (arena-name arena)))
        (%check-int (arena-base arena) "arena base" name nil :min 0)
        (%check-int (arena-extent arena) "arena extent" name nil :min 1)
        (%check-int (arena-alignment arena) "arena alignment" name nil :min 1)
        (%check-int (arena-page-size arena) "arena page size" name nil :min 1)
        (unless (symbolp name)
          (reject :invalid-request :provider arena
                  :detail "an arena requires a name symbol"))
        (unless (zerop (mod (arena-base arena) (arena-page-size arena)))
          (reject :overflow :provider name
                  :detail (format nil "arena base ~s is not aligned to its logical page size ~s"
                                  (arena-base arena) (arena-page-size arena))))
        (unless (zerop (mod (arena-extent arena) (arena-page-size arena)))
          (reject :overflow :provider name
                  :detail (format nil "arena extent ~s is not a multiple of its logical page size ~s"
                                  (arena-extent arena) (arena-page-size arena))))
        (dolist (mode (arena-access-modes arena))
          (unless (member mode *known-access-modes*)
            (reject :invalid-request :provider name
                    :detail (format nil "arena offers unknown access mode ~s" mode))))
        (let ((end (arena-end arena)))
          (when (> end address-limit)
            (reject :overflow :provider name
                    :detail (format nil "arena end ~s exceeds the client's ~s-bit address width"
                                    end (offer-address-width offer))))
          (when (> end most-positive-fixnum)
            (reject :overflow :provider name
                    :detail "arena span exceeds this realization's fixnum page-table index range; a two-level realization is required (managed-layout.tex section 5 names the alternatives)"))
          (let ((page-count (/ (arena-extent arena) (arena-page-size arena))))
            (when (> page-count most-positive-fixnum)
              (reject :overflow :provider name
                      :detail "arena page count exceeds fixnum range")))
          (dolist (reservation (arena-reservations arena))
            (unless (arena-reservation-p reservation)
              (reject :invalid-request :provider name
                      :detail "arena reservations must be ARENA-RESERVATION records"))
            (%check-int (reservation-start reservation) "reservation start" name nil :min 0)
            (%check-int (reservation-extent reservation) "reservation extent" name nil :min 1)
            (unless (and (>= (reservation-start reservation) (arena-base arena))
                         (<= (+ (reservation-start reservation)
                                (reservation-extent reservation))
                             end))
              (reject :invalid-request :provider name
                      :detail "an arena reservation must lie inside its own arena"))))
        ;; static blocks: implementation reservations inside the arena plus
        ;; the offer's exclusions clipped to this arena
        (let ((blocks nil))
          (dolist (reservation (arena-reservations arena))
            (push (cons (reservation-start reservation)
                        (+ (reservation-start reservation)
                           (reservation-extent reservation)))
                  blocks))
          (dolist (exclusion (offer-exclusions offer))
            (let ((s (max (exclusion-start exclusion) (arena-base arena)))
                  (e (min (+ (exclusion-start exclusion)
                             (exclusion-extent exclusion))
                          (arena-end arena))))
              (when (< s e)
                (push (cons s e) blocks))))
          (push (make-arena-state
                 :arena arena :name name
                 :static-blocks (%clip-merge-blocks blocks
                                                    (arena-base arena)
                                                    (arena-end arena)))
                states))))
    (setq states (nreverse states))
    ;; overlapping arenas are ambiguous: one address would map into two
    ;; page tables
    (let ((sorted (%sort-list states #'<
                              :key (lambda (s)
                                     (arena-base (arena-state-arena s))))))
      (do ((rest sorted (cdr rest)))
          ((null (cdr rest)))
        (let ((a (arena-state-arena (car rest)))
              (b (arena-state-arena (cadr rest))))
          (when (> (arena-end a) (arena-base b))
            (reject :ambiguous
                    :provider (list (arena-name a) (arena-name b))
                    :detail "offered arenas overlap; ownership of the shared addresses is ambiguous")))))
    (dolist (exclusion (offer-exclusions offer))
      (unless (exclusion-p exclusion)
        (reject :invalid-request
                :detail "offer exclusions must be EXCLUSION records"))
      (%check-int (exclusion-start exclusion) "exclusion start" nil nil :min 0)
      (%check-int (exclusion-extent exclusion) "exclusion extent" nil nil :min 1))
    states))

(defun %request-deps (request)
  "Names this request must be placed after.  For intentional aliases the
partner with the lexicographically smaller semantic name is the anchor
(a deterministic tie-break that keeps a mutually declared alias
cycle-free: the larger-named request is placed after the anchor and
shares its interval)."
  (append (mapcar #'adjacency-target (request-adjacent-to request))
          (mapcar #'near-target (request-near request))
          (let ((me (symbol-name (request-name request))))
            (remove-if-not (lambda (partner)
                             (string< (symbol-name partner) me))
                           (request-alias-with request)))
          (request-derive-from request)))

(defun %depth-table (requests)
  "Depth of each request in the placement-dependency DAG; rejects
cycles and unknown targets (ambiguous compositions)."
  (let ((by-name (make-hash-table :test 'equal))
        (depth (make-hash-table :test 'equal))
        (state (make-hash-table :test 'equal))) ; 0 fresh 1 active 2 done
    (dolist (r requests)
      (setf (gethash (symbol-name (request-name r)) by-name) r))
    (labels ((depth-of (name path)
               (let ((key name))
                 (cond ((gethash key depth)
                        (gethash key depth))
                       ((eql (gethash key state) 1)
                        (reject :ambiguous
                                :resource (request-name (gethash key by-name))
                                :constraint (first path)
                                :detail (format nil "placement constraint cycle through ~s" key)))
                       (t
                        (setf (gethash key state) 1)
                        (let* ((request (gethash key by-name)))
                          (unless request
                            (reject :ambiguous
                                    :resource key
                                    :constraint (first path)
                                    :detail "constraint names an unknown request"))
                          (let ((best 0))
                            (dolist (dep (%request-deps request))
                              (let ((d (depth-of (symbol-name dep) (append (request-adjacent-to request)
                                                                            (request-near request)))))
                                (setf best (max best (1+ d)))))
                            (setf (gethash key depth) best
                                  (gethash key state) 2)
                            best)))))))
      (dolist (r requests)
        (depth-of (symbol-name (request-name r)) nil)))
    depth))

(defun %ordered-requests (requests depth)
  "Total deterministic order: depth asc, alignment desc, name asc."
  (%sort-list requests
              (lambda (a b)
                (let ((da (gethash (symbol-name (request-name a)) depth 0))
                      (db (gethash (symbol-name (request-name b)) depth 0)))
                  (cond ((< da db) t)
                        ((> da db) nil)
                        ((> (request-alignment a) (request-alignment b)) t)
                        ((< (request-alignment a) (request-alignment b)) nil)
                        (t (string< (symbol-name (request-name a))
                                    (symbol-name (request-name b)))))))))

(defun %constraint-order (ordered)
  "Deterministic linearization: a request that names another through
adjacency, near, or intentional alias is placed immediately after its
anchor, before unrelated requests can consume the space the constraint
needs.  The input is the total %ORDERED-REQUESTS order; the relative
order of unrelated requests is preserved.  Metadata derivation is not a
following relation: derived metadata may be placed anywhere later."
  (let ((dependents (make-hash-table :test 'equal))
        (emitted (make-hash-table :test 'equal))
        (result nil))
    (dolist (r ordered)
      (dolist (dep (%request-deps r))
        ;; only adjacency/near/alias edges create a following relation
        (when (or (find dep (request-adjacent-to r)
                        :key (lambda (c) (symbol-name (adjacency-target c)))
                        :test #'string=)
                  (find dep (request-near r)
                        :key (lambda (c) (symbol-name (near-target c)))
                        :test #'string=)
                  (member dep (request-alias-with r)
                          :key #'symbol-name :test #'string=))
          (push r (gethash (symbol-name dep) dependents)))))
    (labels ((emit (r)
               (unless (gethash (symbol-name (request-name r)) emitted)
                 (setf (gethash (symbol-name (request-name r)) emitted) t)
                 (push r result)
                 ;; dependents were pushed in ordered order; walk reversed
                 (dolist (d (reverse (gethash (symbol-name (request-name r))
                                              dependents)))
                   (emit d)))))
      (dolist (r ordered)
        (emit r)))
    (nreverse result)))

(defstruct (placement
            (:conc-name placement-))
  "Internal: one solved region before record construction."
  request
  name
  arena-state     ; back-pointer to the solver state of its arena
  arena-name
  start
  extent
  eff-page
  alias-anchor    ; placement of the alias anchor when this is an aliaser
  region)         ; final region record, filled at solution assembly

(defun placement-end (p) (+ (placement-start p) (placement-extent p)))


;;; ---------------------------------------------------------------------
;;; Free-space bookkeeping.

(defun %clip-merge-blocks (blocks lo hi)
  "Clip BLOCKS ((start . end) intervals) to [LO,HI), sort and merge."
  (let ((clipped nil))
    (dolist (b blocks)
      (let ((s (max lo (car b)))
            (e (min hi (cdr b))))
        (when (< s e) (push (cons s e) clipped))))
    (let ((sorted (%sort-list clipped #'< :key #'car))
          (merged nil))
      (dolist (b sorted)
        (if (and merged (<= (car b) (cdr (car merged))))
            (setf (cdr (car merged)) (max (cdr (car merged)) (cdr b)))
            (push (copy-list b) merged)))
      (nreverse merged))))

(defun %arena-blocks (state)
  "All occupied intervals of STATE (static blocks plus placements),
sorted and merged."
  (let ((blocks (copy-list (arena-state-static-blocks state))))
    (dolist (p (arena-state-placements state))
      (push (cons (placement-start p) (placement-end p)) blocks))
    (%clip-merge-blocks blocks
                        (arena-base (arena-state-arena state))
                        (arena-end (arena-state-arena state)))))

(defun %free-intervals (state)
  "Complement of the occupied intervals within the arena, as
\(start . end) pairs, ascending."
  (let* ((arena (arena-state-arena state))
         (lo (arena-base arena))
         (hi (arena-end arena))
         (blocks (%arena-blocks state))
         (free nil))
    (dolist (b blocks)
      (when (< lo (car b))
        (push (cons lo (car b)) free))
      (setf lo (max lo (cdr b))))
    (when (< lo hi)
      (push (cons lo hi) free))
    (nreverse free)))

(defun %interval-containing (intervals point)
  "First interval [s,e) with s <= point < e, or NIL."
  (dolist (i intervals nil)
    (when (and (<= (car i) point) (< point (cdr i)))
      (return i))))

;;; ---------------------------------------------------------------------
;;; Extent arithmetic for one candidate position.

(defun %arena-compatible-p (request arena)
  "Access modes permitted, checkpoint stability honored."
  (and (every (lambda (mode) (member mode (arena-access-modes arena)))
              (request-access request))
       (or (not (request-stable-across-checkpoint-p request))
           (not (arena-checkpoint-volatile-p arena)))))

(defun %effective-page (request arena)
  "Assignment extent quantum: a multiple of both the arena's logical
page size and the request's declared page granularity."
  (lcm (arena-page-size arena)
       (or (request-page-granularity request)
           (arena-page-size arena))))

(defun %effective-alignment (request arena eff-page)
  (lcm (request-alignment request)
       (lcm (arena-alignment arena) eff-page)))

(defun %extent-for (request available eff-page ideal-page)
  "The assigned extent for AVAILABLE bytes of space: IDEAL-PAGE (the
client's preferred extent or a derived metadata extent, page-rounded)
honestly shrunk toward the minimum when the gap forces it, never past
the declared maximum, never below the minimum.  Returns an integer or
NIL when the minimum cannot be honored in this space.  Preferred
rounds UP to the page quantum, maximum rounds DOWN: the maximum is a
hard ceiling, the preferred is a wish."
  (let* ((min-page (align-up (request-min-extent request) eff-page))
         (max-page (align-down (request-max-extent request) eff-page))
         (cap (min ideal-page max-page)))
    (when (< max-page min-page)
      (return-from %extent-for nil))
    (let ((extent (min cap (align-down available eff-page))))
      (when (>= extent min-page)
        extent))))

(defun %derived-ideal-extent (request arena eff-page placed-by-name)
  "Call the checked metadata size callback on the assigned object
ranges and return the page-rounded ideal extent.  Callbacks that
signal arithmetic errors, return non-integers, or demand more than the
declared maximum reject the composition with full context -- metadata
sizing is derived and checked before installation (managed-layout.tex
section 4, invariant 5)."
  (let ((sources nil))
    (dolist (name (request-derive-from request))
      (let ((p (gethash (symbol-name name) placed-by-name)))
        (unless p
          (reject :ambiguous :resource (request-name request)
                  :owner (request-owner request)
                  :detail (format nil "derivation source ~s is not an assigned object range" name)))
        (push (make-derivation-source
               :name (placement-name p)
               :start (placement-start p)
               :extent (placement-extent p))
              sources)))
    (setq sources (nreverse sources))
    (let ((raw (handler-case
                   (funcall (request-size-function request)
                            (make-layout-derivation :sources sources))
                 (arithmetic-error (e)
                   (reject :overflow
                           :resource (request-name request)
                           :owner (request-owner request)
                           :constraint (mapcar #'source-name sources)
                           :detail (format nil "metadata size callback signalled arithmetic error: ~a" e)))
                 (error (e)
                   (reject :invalid-request
                           :resource (request-name request)
                           :owner (request-owner request)
                           :constraint (mapcar #'source-name sources)
                           :detail (format nil "metadata size callback failed: ~a" e))))))
      (unless (and (integerp raw) (>= raw 0))
        (reject :invalid-request
                :resource (request-name request)
                :owner (request-owner request)
                :detail (format nil "metadata size callback returned ~s; a byte extent is required" raw)))
      (let ((ideal (align-up raw eff-page))
            (max-page (align-down (request-max-extent request) eff-page)))
        (when (> ideal max-page)
          (reject :overflow
                  :resource (request-name request)
                  :owner (request-owner request)
                  :provider (arena-name (arena-state-arena arena))
                  :detail (format nil "derived metadata extent ~s (callback returned ~s) exceeds the declared maximum ~s"
                                  ideal raw (request-max-extent request))))
        ideal))))

;;; ---------------------------------------------------------------------
;;; Constraint checking between a candidate placement and the regions
;;; already placed in the same arena.  Separation and numeric reach are
;;; checked in both directions (a constraint whose target is placed
;;; later is checked when that target is placed); adjacency and alias
;;; fix the position instead and are enforced by the strategies.

(defun %sep-min-gap (constraint other-placement)
  (or (separation-min-gap constraint)
      (arena-page-size
       (arena-state-arena (placement-arena-state other-placement)))))

(defun %first-violated-constraint (request start end placed-by-name placements)
  "Return the first constraint the candidate interval [START,END)
violates, or NIL.  Checks REQUEST's own outgoing separation/near
constraints against already-placed targets, and every placed region's
constraints that name REQUEST."
  (let ((my-name (request-name request)))
    (dolist (c (request-separated-from request))
      (let ((target (gethash (symbol-name (separation-target c)) placed-by-name)))
        (when target
          (let ((gap (interval-gap start end
                                   (placement-start target)
                                   (placement-end target)))
                (min-gap (%sep-min-gap c target)))
            (when (< gap min-gap)
              (return-from %first-violated-constraint c)))))) 
    (dolist (c (request-near request))
      (let ((target (gethash (symbol-name (near-target c)) placed-by-name)))
        (when target
          (let ((gap (interval-gap start end
                                   (placement-start target)
                                   (placement-end target))))
            (when (> gap (near-reach c))
              (return-from %first-violated-constraint c)))))) 
    (dolist (p placements)
      (let ((other (placement-request p)))
        (dolist (c (request-separated-from other))
          (when (string= (symbol-name (separation-target c)) (symbol-name my-name))
            (let ((gap (interval-gap start end (placement-start p) (placement-end p)))
                  (min-gap (%sep-min-gap c p)))
              (when (< gap min-gap)
                (return-from %first-violated-constraint c)))))
        (dolist (c (request-near other))
          (when (string= (symbol-name (near-target c)) (symbol-name my-name))
            (let ((gap (interval-gap start end (placement-start p) (placement-end p))))
              (when (> gap (near-reach c))
                (return-from %first-violated-constraint c))))))))
  nil)

;;; ---------------------------------------------------------------------
;;; Placement strategies.  A constrained request (adjacency, alias, or
;;; near) is placed in its anchor's arena; unconstrained requests try
;;; the offered arenas in offer order.  Within an arena, candidates are
;;; generated in ascending address order (first fit); the assigned
;;; extent is the honest fallback of minimum/preferred/maximum.

(defun %anchor-arena (request placed-by-name)
  "The single arena all placement anchors (adjacency, alias, near) of
REQUEST live in, or NIL for unconstrained requests.  Metadata
derivation is NOT an arena constraint: metadata may live in a
different arena than the object range it sizes."
  (let ((arenas nil))
    (dolist (c (request-adjacent-to request))
      (let ((p (gethash (symbol-name (adjacency-target c)) placed-by-name)))
        (pushnew (placement-arena-state p) arenas)))
    (dolist (c (request-near request))
      (let ((p (gethash (symbol-name (near-target c)) placed-by-name)))
        (pushnew (placement-arena-state p) arenas)))
    ;; alias: only the anchor (lexicographically smallest partner) is a
    ;; placement dependency; other partners are placed after this one
    (let ((anchor-name (%alias-anchor-name request)))
      (when anchor-name
        (let ((p (gethash (symbol-name anchor-name) placed-by-name)))
          (when p
            (pushnew (placement-arena-state p) arenas)))))
    (when (> (length arenas) 1)
      (reject :ambiguous :resource (request-name request)
              :owner (request-owner request)
              :detail "placement constraints name anchors in different arenas"))
    (car arenas)))

(defun %required-extent (request eff-page ideal-page)
  "The one non-negotiable extent for a derived request (metadata never
silently shrinks: the sizing was derived and checked before placement),
or NIL for shrinkable requests."
  (when (request-derive-from request)
    (max (align-up (request-min-extent request) eff-page)
         ideal-page)))

(defun %candidate-ok (request start end state placed-by-name)
  (null (%first-violated-constraint request start end placed-by-name
                                    (arena-state-placements state))))

(defun %make-placement (request state start extent eff-page alias-anchor)
  (make-placement :request request
                  :name (request-name request)
                  :arena-state state
                  :arena-name (arena-name (arena-state-arena state))
                  :start start
                  :extent extent
                  :eff-page eff-page
                  :alias-anchor alias-anchor))

(defun %register-placement (state placement)
  ;; keep the placement list sorted by start
  (setf (arena-state-placements state)
        (%sort-list (cons placement (arena-state-placements state))
                    #'< :key #'placement-start))
  placement)

(defun %alias-anchor-name (request)
  "The alias partner that anchors this request: the lexicographically
smallest declared partner (deterministic, cycle-free)."
  (car (%sort-list (request-alias-with request) #'string< :key #'symbol-name)))

(defun %alias-strategy (request state ideal-page eff-page eff-align placed-by-name)
  "An intentional aliaser shares its anchor's interval exactly (both
sides declare it; checked at composition validation).  The anchor is
the alias partner with the lexicographically smaller semantic name --
the same deterministic choice the ordering uses."
  (declare (ignore ideal-page))
  (let* ((anchor-name (%alias-anchor-name request))
         (anchor (gethash (symbol-name anchor-name) placed-by-name))
         (start (placement-start anchor))
         (extent (placement-extent anchor)))
    (unless (and (zerop (mod start eff-align))
                 (zerop (mod extent eff-page)))
      (reject :unsatisfiable
              :resource (request-name request)
              :owner (request-owner request)
              :constraint (car (request-alias-with request))
              :provider (placement-arena-name anchor)
              :detail "alias anchor interval does not satisfy this request's alignment/page geometry"))
    ;; any adjacency constraint must agree with the aliased position
    (dolist (c (request-adjacent-to request))
      (let ((target (gethash (symbol-name (adjacency-target c)) placed-by-name)))
        (unless (if (eq (adjacency-direction c) :after)
                    (= start (placement-end target))
                    (= (+ start extent) (placement-start target)))
          (reject :constraint-violation
                  :resource (request-name request)
                  :owner (request-owner request)
                  :constraint c
                  :provider (placement-arena-name anchor)
                  :detail "alias fixes this region's interval; the adjacency demand contradicts it"))))
    (unless (%candidate-ok request start (+ start extent) state placed-by-name)
      (reject :constraint-violation
              :resource (request-name request)
              :owner (request-owner request)
              :constraint (car (request-near request))
              :provider (placement-arena-name anchor)
              :detail "aliased interval violates a separation or reach constraint"))
    (%make-placement request state start extent eff-page anchor)))

(defun %adjacency-strategy (request state ideal-page eff-page eff-align placed-by-name)
  "Exact abutment: :after starts at the anchor's end; :before ends at
the anchor's start.  Both directions are exact; a composition whose
anchor geometry cannot honor them is rejected, never padded."
  (let* ((c (car (request-adjacent-to request)))
         (anchor (gethash (symbol-name (adjacency-target c)) placed-by-name))
         (anchor-start (placement-start anchor))
         (anchor-end (placement-end anchor))
         (free (%free-intervals state))
         (shrinkable (null (request-derive-from request))))
    (if (eq (adjacency-direction c) :after)
        (let ((start anchor-end))
          (unless (zerop (mod start eff-align))
            (reject :unsatisfiable
                    :resource (request-name request)
                    :owner (request-owner request)
                    :constraint c
                    :provider (placement-arena-name anchor)
                    :detail (format nil "adjacent-after anchor end ~s is not aligned to ~s; align the anchor's extent"
                                    start eff-align)))
          (let ((interval (%interval-containing free start)))
            (unless (and interval (= (car interval) start))
              (reject :unsatisfiable
                      :resource (request-name request)
                      :owner (request-owner request)
                      :constraint c
                      :provider (placement-arena-name anchor)
                      :detail "the anchor's end is not the start of free space"))
            (let* ((available (- (cdr interval) start))
                   (extent (if shrinkable
                               (%extent-for request available eff-page ideal-page)
                               (and (>= available ideal-page) ideal-page))))
              (unless extent
                (reject :unsatisfiable
                        :resource (request-name request)
                        :owner (request-owner request)
                        :constraint c
                        :provider (placement-arena-name anchor)
                        :detail (format nil "only ~s bytes free after the anchor; minimum ~s cannot be honored"
                                        available (request-min-extent request))))
              (unless (%candidate-ok request start (+ start extent) state placed-by-name)
                (reject :constraint-violation
                        :resource (request-name request)
                        :owner (request-owner request)
                        :constraint c
                        :provider (placement-arena-name anchor)
                        :detail "adjacent position violates a separation or reach constraint"))
              (%make-placement request state start extent eff-page nil))))
        ;; direction :before: end exactly at the anchor's start
        (let ((interval (find anchor-start free :key #'cdr :test #'=)))
          (unless interval
            (reject :unsatisfiable
                    :resource (request-name request)
                    :owner (request-owner request)
                    :constraint c
                    :provider (placement-arena-name anchor)
                    :detail "no free space directly before the anchor"))
          (unless (zerop (mod anchor-start eff-page))
            (reject :unsatisfiable
                    :resource (request-name request)
                    :owner (request-owner request)
                    :constraint c
                    :provider (placement-arena-name anchor)
                    :detail "anchor start is not a multiple of this request's page quantum; exact adjacency is impossible"))
          (let* ((space (- anchor-start (car interval)))
                 (required (and (not shrinkable) ideal-page))
                 (extent
                   (if shrinkable
                       (let ((top (min ideal-page space)))
                         ;; largest extent <= TOP congruent to the
                         ;; anchor's start modulo the alignment quantum
                         (let ((e (- top (mod (- top anchor-start) eff-align))))
                           (and (>= e (align-up (request-min-extent request) eff-page))
                                e)))
                       (and (>= space required)
                            (zerop (mod (- required anchor-start) eff-align))
                            required))))
            (unless extent
              (reject :unsatisfiable
                      :resource (request-name request)
                      :owner (request-owner request)
                      :constraint c
                      :provider (placement-arena-name anchor)
                      :detail "exact adjacent-before placement cannot honor the request's extents and alignment"))
            (let ((start (- anchor-start extent)))
              (unless (%candidate-ok request start (+ start extent) state placed-by-name)
                (reject :constraint-violation
                        :resource (request-name request)
                        :owner (request-owner request)
                        :constraint c
                        :provider (placement-arena-name anchor)
                        :detail "adjacent position violates a separation or reach constraint"))
              (%make-placement request state start extent eff-page nil)))))))

(defun %scan-interval (request state interval ideal-page eff-page eff-align
                       placed-by-name reach)
  "Scan one free interval ascending for the first position satisfying
extent, reach (when REACH is non-NIL), and separation.  Returns a
placement or NIL."
  (let* ((fs (car interval))
         (fe (cdr interval))
         (shrinkable (null (request-derive-from request)))
         (required (and (not shrinkable)
                        (%required-extent request eff-page ideal-page)))
         (p (align-up fs eff-align)))
    (block scan
      (loop
        (when (>= p fe) (return-from scan nil))
        (let* ((available (- fe p))
               (extent (if shrinkable
                           (%extent-for request available eff-page ideal-page)
                           (and (>= available required) required))))
          (cond
            ((null extent)
             ;; does not fit here; for shrinkable requests the achievable
             ;; extent only shrinks as p grows, so this interval is done
             (return-from scan nil))
            (reach
             (let* ((target (gethash (symbol-name (near-target reach))
                                     placed-by-name))
                    (gap (interval-gap p (+ p extent)
                                       (placement-start target)
                                       (placement-end target))))
               (cond
                 ((> p (placement-end target))
                  ;; past the target and out of reach: forward only
                  ;; makes it worse
                  (return-from scan nil))
                 ((> gap (near-reach reach))
                  ;; too far: jump into the reach window ahead
                  (let ((window (- (placement-start target)
                                   (near-reach reach)
                                   ideal-page)))
                    (setf p (max (+ p eff-page)
                                 (if (> window p)
                                     (align-up window eff-align)
                                     (+ p eff-page))))))
                 ((%candidate-ok request p (+ p extent) state placed-by-name)
                  (return-from scan
                    (%make-placement request state p extent eff-page nil)))
                 (t
                  (setf p (+ p eff-page))))))
            ((%candidate-ok request p (+ p extent) state placed-by-name)
             (return-from scan
               (%make-placement request state p extent eff-page nil)))
            (t
             (setf p (+ p eff-page)))))))))

(defun %first-fit-strategy (request state ideal-page eff-page eff-align placed-by-name)
  (dolist (interval (%free-intervals state) nil)
    (let ((placement (%scan-interval request state interval ideal-page
                                     eff-page eff-align placed-by-name nil)))
      (when placement
        (return placement)))))

(defun %near-strategy (request state ideal-page eff-page eff-align placed-by-name)
  ;; the first near constraint drives the scan; any remaining near or
  ;; separation constraints are checked per candidate
  (dolist (interval (%free-intervals state) nil)
    (let ((placement (%scan-interval request state interval ideal-page
                                     eff-page eff-align placed-by-name
                                     (car (request-near request)))))
      (when placement
        (return placement)))))

;;; ---------------------------------------------------------------------
;;; Composition-level validation, audits, geometry, and the builder.

(defun %validate-composition (requests by-name)
  "Cross-request facts: alias must be mutual, alias and separation
contradict each other, and every constraint target must name a known
request (also checked by the depth walk)."
  (dolist (r requests)
    (dolist (target (request-alias-with r))
      (let ((other (gethash (symbol-name target) by-name)))
        (unless other
          (reject :ambiguous :resource (request-name r)
                  :owner (request-owner r)
                  :detail (format nil "alias partner ~s names no request" target)))
        (unless (member (request-name r)
                        (request-alias-with other)
                        :key (lambda (s) (symbol-name s))
                        :test #'string=)
          (reject :ambiguous
                  :resource (request-name r)
                  :owner (request-owner r)
                  :constraint target
                  :detail "intentional alias must be declared by both partners")))
      ;; alias with separation against the same partner can never hold
      (dolist (c (request-separated-from r))
        (when (string= (symbol-name (separation-target c)) (symbol-name target))
          (reject :ambiguous :resource (request-name r)
                  :owner (request-owner r)
                  :constraint c
                  :detail "separation against an intentional alias partner is contradictory"))))))

(defun %work-pre-pass-p (request by-name)
  "Collection-time work capacity is reserved before any other placement
(managed-layout.tex section 4, invariant 6: the layout must include
capacity for all state required while collection cannot allocate).  A
work-storage request chained to a non-work anchor waits for the main
pass; independent work capacity is reserved first."
  (and (eq (request-kind request) :work-storage)
       (let ((deps (%request-deps request)))
         (dolist (name deps t)
           (let ((dep (gethash (symbol-name name) by-name)))
             (unless (eq (request-kind dep) :work-storage)
               (return-from %work-pre-pass-p nil)))))))

(defun %audit-solution (placements offer)
  "Defensive full-solution audit before anything is validated or
installed.  Any failure here is a rejected composition, never a
published partial map."
  (let ((address-limit (expt 2 (offer-address-width offer)))
        (by-name (make-hash-table :test 'equal)))
    (dolist (p placements)
      (setf (gethash (symbol-name (placement-name p)) by-name) p))
    ;; overlap: no two resources overlap unless both declare the same
    ;; intentional alias (managed-layout.tex section 4, invariant 2)
    (let ((sorted (%sort-list placements #'< :key #'placement-start)))
      (do ((rest sorted (cdr rest)))
          ((null (cdr rest)))
        (let ((a (car rest))
              (b (car (cdr rest))))
          (when (< (placement-start b) (placement-end a))
            (unless (and (= (placement-start a) (placement-start b))
                         (= (placement-end a) (placement-end b))
                         (member (placement-name b)
                                 (request-alias-with (placement-request a))
                                 :key #'symbol-name :test #'string=)
                         (member (placement-name a)
                                 (request-alias-with (placement-request b))
                                 :key #'symbol-name :test #'string=))
              (reject :overlap
                      :resource (placement-name b)
                      :provider (list (placement-arena-name a) (placement-arena-name b))
                      :detail (format nil "regions ~s and ~s overlap without a declared intentional alias"
                                      (placement-name a) (placement-name b))))))))
    (dolist (p placements)
      (let* ((request (placement-request p))
             (state (placement-arena-state p))
             (arena (arena-state-arena state))
             (start (placement-start p))
             (extent (placement-extent p))
             (end (+ start extent)))
        ;; invariant 1: inside one arena, outside every exclusion and
        ;; every implementation reservation
        (unless (and (>= start (arena-base arena))
                     (<= end (arena-end arena)))
          (reject :unsatisfiable :resource (placement-name p)
                  :provider (placement-arena-name p)
                  :detail "assigned range leaves its arena"))
        (dolist (block (arena-state-static-blocks state))
          (unless (or (<= end (car block)) (>= start (cdr block)))
            (reject :unsatisfiable :resource (placement-name p)
                    :provider (placement-arena-name p)
                    :detail "assigned range enters a reservation or exclusion")))
        ;; invariant 3: alignment and page geometry hold exactly, and
        ;; every computed end stays inside the client's address width
        (let ((eff-align (%effective-alignment request arena (placement-eff-page p))))
          (unless (and (zerop (mod start eff-align))
                       (zerop (mod extent (placement-eff-page p))))
            (reject :overflow :resource (placement-name p)
                    :provider (placement-arena-name p)
                    :detail "assigned geometry violates its alignment or page quantum"))
          (when (>= end address-limit)
            (reject :overflow :resource (placement-name p)
                    :provider (placement-arena-name p)
                    :detail (format nil "assigned end ~s exceeds the client's ~s-bit address width"
                                    end (offer-address-width offer)))))))
    ;; invariant 3 (cont.): adjacency, reach, separation, alias exactly
    (dolist (p placements)
      (let ((request (placement-request p)))
        (dolist (c (request-adjacent-to request))
          (let* ((target (gethash (symbol-name (adjacency-target c)) by-name))
                 (ok (if (eq (adjacency-direction c) :after)
                         (= (placement-start p) (placement-end target))
                         (= (placement-end p) (placement-start target)))))
            (unless ok
              (reject :constraint-violation :resource (placement-name p)
                      :owner (request-owner request)
                      :constraint c
                      :detail "adjacency does not abut exactly"))))
        (dolist (c (request-near request))
          (let* ((target (gethash (symbol-name (near-target c)) by-name))
                 (gap (interval-gap (placement-start p) (placement-end p)
                                    (placement-start target) (placement-end target))))
            (when (> gap (near-reach c))
              (reject :constraint-violation :resource (placement-name p)
                      :owner (request-owner request)
                      :constraint c
                      :provider (placement-arena-name p)
                      :detail (format nil "reach ~s exceeded: gap is ~s" (near-reach c) gap))))))
      (let ((target (gethash (symbol-name (car (request-alias-with (placement-request p)))) by-name)))
        (when target
          (unless (and (= (placement-start p) (placement-start target))
                       (= (placement-end p) (placement-end target)))
            (reject :constraint-violation :resource (placement-name p)
                    :detail "aliased regions must share one interval")))))))

(defun %build-regions (placements)
  "Final immutable region records, ordered by (start, name); region ids
are 1-based positions in this order."
  (let ((sorted (%sort-list placements
                            (lambda (a b)
                              (let ((sa (placement-start a)) (sb (placement-start b)))
                                (if (= sa sb)
                                    (string< (symbol-name (placement-name a))
                                             (symbol-name (placement-name b)))
                                    (< sa sb)))))))
    (mapcar (lambda (p)
              (let* ((request (placement-request p))
                     (region (make-layout-region
                              :name (placement-name p)
                              :request request
                              :owner (request-owner request)
                              :kind (request-kind request)
                              :arena-name (placement-arena-name p)
                              :start (placement-start p)
                              :extent (placement-extent p)
                              :access (request-access request)
                              :atomicity (request-atomicity request)
                              :alias-partners (request-alias-with request)
                              :stable-across-checkpoint-p (request-stable-across-checkpoint-p request)
                              :effective-page (placement-eff-page p))))
                (setf (placement-region p) region)
                region))
            sorted)))

(defun %build-geometry (regions states)
  "Dense per-arena page tables and the sorted arena index: the bounded,
in-place-updatable ownership geometry.  Aliased pages resolve to the
alias anchor (the partner region is reachable through its record)."
  (let ((region-vector (make-array (length regions) :initial-contents regions))
        (entries nil))
    (dolist (state states)
      (let* ((arena (arena-state-arena state))
             (page-size (arena-page-size arena))
             (page-count (/ (arena-extent arena) page-size))
             (table (make-array page-count :element-type 'fixnum :initial-element 0)))
        (dolist (p (arena-state-placements state))
          (unless (placement-alias-anchor p)
            (let* ((region (placement-region p))
                   (id (1+ (position region regions)))
                   (offset (- (placement-start p) (arena-base arena)))
                   (first-page (/ offset page-size))
                   (pages (/ (placement-extent p) page-size)))
              (loop for k from first-page below (+ first-page pages)
                    do (setf (aref table k) id)))))
        (push (make-arena-index-entry :arena arena
                                      :base (arena-base arena)
                                      :end (arena-end arena)
                                      :page-size page-size
                                      :page-count page-count
                                      :page-table table)
              entries)))
    (values region-vector
            (coerce (%sort-vector (coerce (nreverse entries) 'vector)
                                  #'< :key #'%aix-base)
                    'simple-vector))))

(defun %solution-free-intervals (states)
  (let ((result nil))
    (dolist (state states)
      (dolist (interval (%free-intervals state))
        (push (make-free-interval
               :arena-name (arena-name (arena-state-arena state))
               :start (car interval)
               :extent (- (cdr interval) (car interval)))
              result)))
    (nreverse result)))

;;; ---------------------------------------------------------------------
;;; Placement driver and the builder
;;; (managed-layout.tex sections 1 and 4).
;;;
;;; Composition boundary: the client offers arenas and exclusions; the
;;; selected plan contributes requests; Clamsara assigns every managed
;;; resource; the client validates and installs the resulting map.  The
;;; address-space validate/install protocol is called ONLY after the
;;; complete solution succeeds; a rejected composition never reaches the
;;; client, and nothing partial is ever published.

(defun %place-request (request states placed-by-name)
  "Place REQUEST in its anchor's arena (constrained requests) or the
first compatible arena with a feasible position (unconstrained).
Returns the placement, or NIL when every candidate arena failed on
extents/free space."
  (let* ((anchor-state (%anchor-arena request placed-by-name))
         (candidates (if anchor-state (list anchor-state) states)))
    (dolist (state candidates nil)
      (let* ((arena (arena-state-arena state))
             (eff-page (%effective-page request arena))
             (eff-align (%effective-alignment request arena eff-page))
             ;; metadata derivation is checked per candidate arena's
             ;; geometry; the callback must be pure (it may run once per
             ;; candidate arena during construction)
             (ideal-page (if (request-derive-from request)
                             (%derived-ideal-extent request state eff-page
                                                    placed-by-name)
                             (align-up (request-preferred-extent request)
                                       eff-page))))
        (when (%arena-compatible-p request arena)
          (let ((placement
                  (cond ((and (request-alias-with request)
                              (gethash (symbol-name (%alias-anchor-name request))
                                       placed-by-name))
                         (%alias-strategy request state ideal-page eff-page
                                          eff-align placed-by-name))

                        ((request-adjacent-to request)
                         (%adjacency-strategy request state ideal-page eff-page
                                              eff-align placed-by-name))
                        ((request-near request)
                         (%near-strategy request state ideal-page eff-page
                                         eff-align placed-by-name))
                        (t
                         (%first-fit-strategy request state ideal-page eff-page
                                              eff-align placed-by-name)))))
            (when placement
              (%register-placement state placement)
              (setf (gethash (symbol-name (request-name request)) placed-by-name)
                    placement)
              (return placement))))))))

(defun %resolve-offer (client)
  "Ask the address-space client for its offer record (or accept a bare
list of arena and exclusion records, wrapping it in one)."
  (let ((offered (managed-arena-offer client)))
    (typecase offered
      (address-space-offer offered)
      (list (make-address-space-offer
             :arenas (remove-if #'exclusion-p offered)
             :exclusions (remove-if-not #'exclusion-p offered)))
      (t (reject :invalid-request
                 :provider client
                 :detail "managed-arena-offer must supply an ADDRESS-SPACE-OFFER (or arena/exclusion records)")))))

(defun build-managed-layout (client requests)
  "Solve the deterministic managed layout for REQUESTS inside the
arenas and exclusions the address-space CLIENT offers, validate the
complete solution with the client, install it with the client, and
return the installed LAYOUT.  CLIENT must be a client object
implementing the address-space protocol; a rejected composition
signals LAYOUT-REJECTION carrying reason, resource, constraint,
provider, and owner context.  Allocation is expected during solving
and construction; the installed geometry's lookup is direct and
allocation-free."
  (when (typep client 'address-space-offer)
    (reject :invalid-request
            :detail "build-managed-layout requires an address-space client object: the client validates and installs the resulting map (managed-layout.tex section 1); passing a bare offer would leave no one to validate or install"))
  (let* ((offer (%resolve-offer client))
         (states (%validate-offer offer))
         (requests (%validate-requests requests))
         (by-name (make-hash-table :test 'equal)))
    (dolist (r requests)
      (setf (gethash (symbol-name (request-name r)) by-name) r))
    (%validate-composition requests by-name)
    (let* ((depth (%depth-table requests))
           (ordered (%ordered-requests requests depth))
           ;; collection-time work capacity is reserved before anything
           ;; else competes for space (invariant 6)
           (pre-pass (%constraint-order
                      (remove-if-not (lambda (r) (%work-pre-pass-p r by-name))
                                     ordered)))
           (main-pass (%constraint-order
                       (remove-if (lambda (r) (%work-pre-pass-p r by-name))
                                  ordered)))
           (placed-by-name (make-hash-table :test 'equal)))
      (dolist (r pre-pass)
        (unless (%place-request r states placed-by-name)
          (reject :unsatisfiable
                  :resource (request-name r)
                  :owner (request-owner r)
                  :provider (mapcar (lambda (s)
                                      (arena-name (arena-state-arena s)))
                                    states)
                  :detail "collection-time work capacity cannot be reserved; the composition is unsatisfiable")))
      (dolist (r main-pass)
        (unless (%place-request r states placed-by-name)
          (reject :unsatisfiable
                  :resource (request-name r)
                  :owner (request-owner r)
                  :constraint (or (car (request-near r))
                                  (car (request-adjacent-to r))
                                  (car (request-separated-from r)))
                  :provider (mapcar (lambda (s)
                                      (arena-name (arena-state-arena s)))
                                    states)
                  :detail "no offered arena can honor this request's extents and constraints")))
      (let ((placements nil))
        (dolist (state states)
          (dolist (p (arena-state-placements state))
            (push p placements)))
        (%audit-solution placements offer)
        (let* ((regions (%build-regions placements)))
          (multiple-value-bind (region-vector arena-index)
              (%build-geometry regions states)
            (let ((layout (make-managed-layout
                           :offer offer
                           :regions regions
                           :region-vector region-vector
                           :arenas (mapcar #'arena-state-arena states)
                           :arena-index arena-index
                           :free-intervals (%solution-free-intervals states)
                           :work-capacity (let ((total 0))
                                            (dolist (p placements total)
                                              (when (eq (request-kind (placement-request p))
                                                        :work-storage)
                                                (incf total (placement-extent p))))))))
              ;; the complete solution exists; only now does the client
              ;; see it -- validate, then install, then publish
              (validate-managed-layout client layout)
              (install-managed-layout client layout)
              (setf (solution-installed-p layout) t)
              layout)))))))
