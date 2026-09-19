;;;; protocol/adapters.lisp -- paper-v11 protocol adapters over the simulator.
;;;;
;;;; The protocol systems (src/protocol/*.lisp) define the reference
;;;; generics of paper-v11/chapters/client-protocols.tex and
;;;; managed-layout.tex with no dependencies.  This file, part of the
;;;; :clamsara system, implements those generics for the simulator client
;;;; (vm-binding / simulator-vm / plan) by delegating to the existing
;;;; mechanics.  Design rules:
;;;;
;;;;   - Delegate only where semantics are EXACTLY preserved; every honest
;;;;     unsupported boundary signals CLAMSARA-ERROR instead of faking.
;;;;   - Allocation discipline, scoped honestly: the location seams
;;;;     (MAP-REFERENCE-LOCATIONS, LOAD-REFERENCE, STORE-REFERENCE-RAW, the
;;;;     WITH-ROOT-SNAPSHOT / MAP-ROOT-LOCATIONS walk, BEGIN-EPOCH /
;;;;     AWAIT-EPOCH) never cons per visit, and V11-ADAPTERS-NO-ALLOCATION
;;;;     measures that over 100 locations.  Other adapters carry no such
;;;;     claim.  In particular FATAL-DIAGNOSTIC below is an ALLOCATING
;;;;     portable implementation and is a recorded conformance blocker (see
;;;;     V11-IMPLEMENTATION.md), not a satisfied obligation.  A reference
;;;;     location is the raw simulator heap word address of the slot (a
;;;;     fixnum, opaque to core).  A root location packs a root-vector id and
;;;;     cell index into one fixnum.  A root snapshot is the client object
;;;;     itself (see WITH-ROOT-SNAPSHOT).  Only MANAGED-ARENA-OFFER, a boot-
;;;;     time description, builds a record.
;;;;   - COPY-OBJECT-REPRESENTATION deliberately does NOT delegate to
;;;;     VM-OBJECT-COPY: the v8 seam also carries side metadata (mark, age,
;;;;     public, log, weak), which paper-v11 assigns to the movement
;;;;     component (client-protocols.tex section 1; strata.tex section 3).
;;;;     The v8 seam stays for the existing collectors and migrates later.
;;;;
;;;; EPOCH TOKENS: the VM-owned coordination-state record is the opaque epoch
;;;; token.  It identifies the client and its single coordination domain, so
;;;; a token from another client rejects on EQ, and no process-global counter
;;;; can leak an epoch across clients.  The simulator keeps at most one epoch
;;;; open per client (single stream); a second BEGIN-EPOCH re-opens the same
;;;; domain.

(in-package #:clamsara)

;;;; ---- location and snapshot encodings (allocation-free) -----------------
;;;;
;;;; REFERENCE LOCATION: the absolute simulator heap word address of the
;;;; reference-bearing slot.  For a headered object at ADDR this is
;;;; (+ ADDR 1 SLOT); for a headerless cons at ADDR it is (+ ADDR SLOT) --
;;;; exactly the words VM-OBJECT-REFERENCE reads and writes.
;;;;
;;;; ROOT LOCATION: (LOGIOR (ASH VECTOR-ID 40) CELL-INDEX) where VECTOR-ID 0
;;;; is the simulator's global root vector and VECTOR-ID (1+ R) is registered
;;;; root region R.  CELL-INDEX must stay below 2^40 and VECTOR-ID below 2^20
;;;; so the packing remains a fixnum; both hold for every realizable
;;;; simulator heap.

(declaim (inline %encode-root-location %root-location-vector-id
                 %root-location-cell-index))
(defun %encode-root-location (vector-id cell-index)
  (logior (ash vector-id 40) cell-index))
(defun %root-location-vector-id (location)
  (ash location -40))
(defun %root-location-cell-index (location)
  (logand location (1- (ash 1 40))))

(defun %check-heap-word (vm place what)
  (unless (and (typep place 'fixnum) (>= place 0) (< place (vm-heap-size vm)))
    (error 'clamsara-error
           :message (format nil "~a: ~s is not a word address in the simulator heap" what place)))
  place)

(defun %check-object-reference (vm reference what)
  (unless (and (vm-valid-reference-p vm reference)
               (vm-direct-object-start-p vm (ref-strip-or-self vm reference)))
    (error 'clamsara-error
           :message (format nil "~a: ~s does not name an object start" what reference)))
  (ref-strip-or-self vm reference))

(defun %root-location-vector (vm location what)
  "Resolve LOCATION to its backing vector, or signal.  Validation matches the
registration state; no allocation."
  (let ((vector-id (%root-location-vector-id location))
        (index (%root-location-cell-index location)))
    (cond ((zerop vector-id)
           (let ((roots (vm-root-vector vm)))
             (unless (< -1 index (length roots))
               (error 'clamsara-error
                      :message (format nil "~a: root location ~s is outside the root vector" what location)))
             roots))
          (t
           (let* ((r (1- vector-id))
                  (regions (vm-root-regions vm)))
             (unless (< -1 r (vm-root-region-count vm))
               (error 'clamsara-error
                      :message (format nil "~a: root location ~s names unregistered region" what location)))
             (let ((vector (root-region-vector (aref regions r))))
               (unless (< -1 index (length vector))
                 (error 'clamsara-error
                        :message (format nil "~a: root location ~s is outside its region vector" what location)))
               vector))))))

(defun %check-atomic-place (vm place)
  (%check-heap-word vm place "atomic operation"))

;;;; ---- object-model protocol (client-protocols.tex section 1) -----------
;;;;
;;;; MAP-REFERENCE-LOCATIONS visits the same slots VM-MAP-REFERENCE-SLOTS
;;;; would scan, but it visits LOCATIONS, not values: a null-valued slot is
;;;; still a strong reference location and is reported, exactly as the paper
;;;; requires of the authoritative seam.

(defmethod valid-reference-p ((vm vm-binding) reference)
  (vm-valid-reference-p vm reference))

(defmethod object-start-p ((vm vm-binding) reference)
  (and (vm-valid-reference-p vm reference)
       (vm-direct-object-start-p vm (ref-strip-or-self vm reference))))

(defmethod object-size ((vm vm-binding) reference)
  ;; bytes, checked (paper-v11 listing comment)
  (* (vm-object-total-words vm (%check-object-reference vm reference "object-size"))
     +word-bytes+))

(defmethod object-kind ((vm vm-binding) reference)
  (vm-object-type-tag vm (%check-object-reference vm reference "object-kind")))

(defmethod map-reference-locations ((vm vm-binding) reference function)
  ;; Same location set as VM-MAP-REFERENCE-SLOTS (per-layout slot maps, weak
  ;; referent slot excluded), passing the raw slot word address.  Fixnums
  ;; only: no allocation per visited slot.
  (let ((addr (%check-object-reference vm reference "map-reference-locations"))
        (slots (vm-reference-slots vm reference))
        (weak-p (weak-pointer-p vm reference)))
    (flet ((emit (slot)
             (unless (and weak-p (zerop slot))
               (funcall function
                        (if (vm-address-cons-p vm addr)
                            (+ addr slot)
                            (+ addr 1 slot))))))
      (if slots
          (loop for slot across slots do (emit slot))
          (dotimes (slot (vm-direct-object-reference-count vm addr))
            (emit slot)))))
  reference)

(defmethod load-reference ((vm vm-binding) location)
  ;; LOCATION is the slot word address; read it exactly as
  ;; VM-OBJECT-REFERENCE would.
  (%check-heap-word vm location "load-reference")
  (vm-direct-ref-u64 vm location))

(defmethod store-reference-raw ((vm vm-binding) location new-reference)
  (%check-heap-word vm location "store-reference-raw")
  (vm-direct-set-ref-u64 vm location new-reference)
  new-reference)

(defmethod initialize-object ((vm vm-binding) destination kind size descriptor)
  ;; SIZE is total object size in bytes, matching OBJECT-SIZE.  Headerless
  ;; cons cells are initialized by their allocator, not by this seam.
  (let ((addr (ref-strip-or-self vm destination)))
    (when (eql kind +tag-cons+)
      (error 'clamsara-error
             :message "initialize-object: cons cells are headerless in the simulator; the cons allocator initializes them"))
    (unless (and (typep size 'fixnum) (plusp size) (zerop (mod size +word-bytes+)))
      (error 'clamsara-error
             :message (format nil "initialize-object: size ~s is not a positive whole word count" size)))
    (%check-heap-word vm addr "initialize-object")
    (vm-write-header vm addr kind (1- (truncate size +word-bytes+)) descriptor)
    addr))

(defmethod copy-object-representation ((vm vm-binding) source destination)
  ;; Representation copy ONLY (payload + ABI words).  Logical collector
  ;; metadata transfer is the movement component's obligation; this adapter
  ;; therefore neither touches the side strata nor the object-start datum.
  (let ((src (%check-object-reference vm source "copy-object-representation"))
        (dst (ref-strip-or-self vm destination))
        (stats (%stats-for-vm vm)))
    (%check-heap-word vm dst "copy-object-representation")
    (let ((n (vm-direct-object-total-words vm src)))
      (unless (<= (+ dst n) (vm-heap-size vm))
        (error 'clamsara-error
               :message (format nil "copy-object-representation: destination ~s overruns the heap" dst)))
      (dotimes (k n)
        (vm-direct-set-ref-u64 vm (+ dst k) (vm-direct-ref-u64 vm (+ src k))))
      (when stats (stats-event stats :words-copied n)))
    dst))

(defmethod reference-equal ((vm vm-binding) left right)
  (eql (ref-strip-or-self vm left) (ref-strip-or-self vm right)))

(defmethod offered-metadata-fields ((vm vm-binding))
  ;; The simulator advertises no physical metadata fields: header gc-flags
  ;; and the coloured-pointer field are not offered as named field objects.
  nil)

(defmethod field-read ((vm vm-binding) field object-or-reference)
  (declare (ignore field object-or-reference))
  (error 'clamsara-error
         :message "field-read: the simulator offers no physical metadata fields"))

(defmethod field-write ((vm vm-binding) field object-or-reference value)
  (declare (ignore field object-or-reference value))
  (error 'clamsara-error
         :message "field-write: the simulator offers no physical metadata fields"))

(defmethod field-cas ((vm vm-binding) field object-or-reference old new)
  (declare (ignore field object-or-reference old new))
  (error 'clamsara-error
         :message "field-cas: the simulator offers no physical metadata fields"))

;;;; ---- root protocol (client-protocols.tex section 2) --------------------
;;;;
;;;; The simulator's snapshot VALUE is the client object itself.  Justification
;;;; (an honest boundary, not a fake): the client has exactly one execution
;;;; stream, so the root set cannot change between WITH-ROOT-SNAPSHOT and
;;;; MAP-ROOT-LOCATIONS except through the caller itself; a distinct snapshot
;;;; object would carry no information, and building one would allocate on a
;;;; collection path.  The snapshot's epoch is the client's coordination epoch
;;;; at snapshot time, readable with VM-SAFEPOINT-EPOCH.
;;;;
;;;; Scope values: the paper names "all mutators" and "globals" among others.
;;;; The single-stream simulator supports :ALL and :GLOBAL (they coincide:
;;;; every root is global); owner and request scopes would require mutator
;;;; identity the simulator does not have and are rejected.

(defun %check-snapshot-scope (scope what)
  (unless (member scope '(:all :global))
    (error 'clamsara-error
           :message (format nil "~a: simulator supports only :ALL and :GLOBAL scopes, got ~s" what scope)))
  scope)

(defun %map-root-cells (vm function)
  ;; Visit exactly the cells VM-SCAN-ROOTS visits: every root-vector entry,
  ;; then per registered region either its mapped indices or its full range.
  ;; Fixnum locations only; no allocation.
  (let ((roots (vm-root-vector vm)))
    (dotimes (i (length roots))
      (funcall function (%encode-root-location 0 i))))
  (let ((regions (vm-root-regions vm)))
    (dotimes (r (vm-root-region-count vm))
      (let* ((descriptor (aref regions r))
             (mapped (root-region-mapped-indices descriptor)))
        (if mapped
            (dotimes (k (length mapped))
              (funcall function (%encode-root-location (1+ r) (aref mapped k))))
            (loop for index from (root-region-start descriptor)
                  below (root-region-end descriptor)
                  do (funcall function (%encode-root-location (1+ r) index)))))))
  vm)

(defmethod with-root-snapshot ((vm vm-binding) scope function)
  (%check-snapshot-scope scope "with-root-snapshot")
  (funcall function vm))

(defmethod map-root-locations ((vm vm-binding) function)
  (%map-root-cells vm function)
  vm)

(defmethod load-root ((vm vm-binding) root-location)
  (unless (typep root-location 'fixnum)
    (error 'clamsara-error :message "load-root: root location is not a fixnum"))
  (aref (%root-location-vector vm root-location "load-root")
        (%root-location-cell-index root-location)))

(defmethod store-root ((vm vm-binding) root-location reference)
  (unless (typep root-location 'fixnum)
    (error 'clamsara-error :message "store-root: root location is not a fixnum"))
  (let ((vector (%root-location-vector vm root-location "store-root")))
    (setf (aref vector (%root-location-cell-index root-location)) reference))
  reference)

(defmethod root-location-kind ((vm vm-binding) root-location)
  (unless (typep root-location 'fixnum)
    (error 'clamsara-error :message "root-location-kind: root location is not a fixnum"))
  (if (zerop (%root-location-vector-id root-location))
      :root-vector
      :root-region))

;;;; ---- coordination protocol (client-protocols.tex section 3) ------------
;;;;
;;;; The simulator has one execution stream, so a stop request reaches the
;;;; only mutator synchronously (VM-STOP-MUTATORS documents the same fact).
;;;; The stop token is the VM's coordination-state record: it identifies the
;;;; stopped set and carries the stop epoch.  An epoch token is a fixnum from
;;;; a simulator-local counter; awaiting it is exact because no other stream
;;;; exists.  A concurrent backend replaces all of this.

(defmethod request-safepoint ((vm vm-binding) scope reason)
  (declare (ignore reason))
  (%check-snapshot-scope scope "request-safepoint")
  (vm-stop-mutators vm)
  (vm-coordination-state vm))

(defmethod await-safepoint ((vm vm-binding) token)
  ;; The token must be this client's coordination-state record AND name an
  ;; active stop interval: a stale token (one whose interval was released)
  ;; rejects instead of being awaited again.
  (unless (eq token (vm-coordination-state vm))
    (error 'clamsara-error :message "await-safepoint: token is not this client's stop token"))
  (unless (and (coordination-state-requested token)
               (coordination-state-stopped token))
    (error 'clamsara-error :message "await-safepoint: stop token is stale (no active stop interval)"))
  (vm-coordination-epoch vm))

(defmethod release-safepoint ((vm vm-binding) token)
  ;; Same discipline: a released (stale) token rejects instead of resuming
  ;; the mutators a second time.  A repeated REQUEST for the same active
  ;; stop remains documented idempotent: VM-STOP-MUTATORS does not re-open
  ;; or re-number the current interval while it is outstanding.
  (unless (eq token (vm-coordination-state vm))
    (error 'clamsara-error :message "release-safepoint: token is not this client's stop token"))
  (unless (coordination-state-requested token)
    (error 'clamsara-error :message "release-safepoint: stop token is stale (no active stop interval)"))
  (vm-resume-mutators vm))

(defmethod current-mutator ((vm vm-binding))
  ;; One anonymous stream; a stable keyword, not an allocated identity.
  :single-mutator)

(defmethod begin-epoch ((vm vm-binding) domain)
  ;; One outstanding epoch per client.  The token is the VM-owned
  ;; coordination-state record: it binds the token to its client (a foreign
  ;; token rejects on EQ) and costs no allocation.  BEGIN rejects while an
  ;; epoch is open instead of silently reopening the same interval, bumps the
  ;; epoch, and marks the domain open.
  (unless (member domain '(:default))
    (error 'clamsara-error
           :message (format nil "begin-epoch: simulator supports only the :DEFAULT domain, got ~s" domain)))
  (let ((state (vm-coordination-state vm)))
    (when (coordination-state-epoch-open state)
      (error 'clamsara-error
             :message "begin-epoch: an epoch is already open; the simulator keeps one outstanding epoch per client"))
    (setf (coordination-state-epoch state)
          (let ((e (coordination-state-epoch state)))
            (if (= e most-positive-fixnum) 0 (1+ e)))
          (coordination-state-epoch-open state) t))
  (vm-coordination-state vm))

(defmethod await-epoch ((vm vm-binding) epoch)
  ;; Requires the client's own token AND an open epoch; establishes
  ;; quiescence, then closes.  Quiescence is exact for the single-stream
  ;; simulator: the only mutator is the caller, so every operation admitted
  ;; before the epoch has quiesced by the time it awaits.  A stale token (an
  ;; epoch already closed) or a foreign token signals instead of accepting.
  (let ((state (vm-coordination-state vm)))
    (unless (eq epoch state)
      (error 'clamsara-error
             :message "await-epoch: token does not identify this client's coordination domain"))
    (unless (coordination-state-epoch-open state)
      (error 'clamsara-error
             :message "await-epoch: epoch token is stale or already closed"))
    (setf (coordination-state-epoch-open state) nil))
  (vm-coordination-epoch vm))

(defmethod publish-fence ((vm vm-binding))
  (memory-fence vm))

;;;; ---- atomic protocol (client-protocols.tex section 4) ------------------
;;;;
;;;; PLACE is a simulator heap word address (a fixnum, the same address space
;;;; the memory-order-free REF-WORD uses).  ORDER is validated against each
;;;; operation's admissible set by %CHECK-MEMORY-ORDER (allocation-free on
;;;; the success path): loads reject release, stores reject acquire, and a
;;;; :RELAXED fence is rejected as meaningless.  The single-threaded
;;;; simulator then gives every admitted order the same observable semantics;
;;;; a target documents and implements real orderings.  Atomicity is that of
;;;; the existing CAS / ATOMIC-INCF methods (SBCL atomics where available),
;;;; matching the simulator's own memory model.

(defparameter +atomics-load-orders+ '(:relaxed :acquire :seq-cst))
(defparameter +atomics-store-orders+ '(:relaxed :release :seq-cst))
(defparameter +atomics-rmw-orders+ '(:relaxed :acquire :release :acq-rel :seq-cst))
(defparameter +atomics-fence-orders+ '(:acquire :release :acq-rel :seq-cst))

(defun %check-memory-order (order what admitted)
  ;; Membership test only: no allocation on the success path.  Nonsense or
  ;; weaker-than-advertised orders are rejected, never silently accepted.
  (unless (member order admitted)
    (error 'clamsara-error
           :message (format nil "~a: memory order ~s is not admitted (admits ~s)"
                            what order admitted)))
  order)

(defmethod atomic-load ((vm vm-binding) place order)
  (%check-memory-order order "atomic-load" +atomics-load-orders+)
  (%check-atomic-place vm place)
  (ref-word vm place))

(defmethod atomic-store ((vm vm-binding) place value order)
  (%check-memory-order order "atomic-store" +atomics-store-orders+)
  (%check-atomic-place vm place)
  (setf (ref-word vm place) value)
  value)

(defmethod atomic-cas ((vm vm-binding) place old new order)
  (%check-memory-order order "atomic-cas" +atomics-rmw-orders+)
  (%check-atomic-place vm place)
  ;; CAS returns success; the protocol returns the previous value.  Exact in
  ;; the single-threaded simulator (no concurrent writer can intervene).
  (if (cas vm place old new) old (ref-word vm place)))

(defmethod atomic-fetch-add ((vm vm-binding) place delta order)
  (%check-memory-order order "atomic-fetch-add" +atomics-rmw-orders+)
  (%check-atomic-place vm place)
  (atomic-incf vm place delta))

(defmethod atomic-bit-set ((vm vm-binding) place index order)
  (%check-memory-order order "atomic-bit-set" +atomics-rmw-orders+)
  (%check-atomic-place vm place)
  (loop
    (let* ((word (ref-word vm place))
           (previous (logbitp index word)))
      (if previous
          (return t)
          (when (cas vm place word (logior word (ash 1 index)))
            (return nil))))))

(defmethod atomic-bit-clear ((vm vm-binding) place index order)
  (%check-memory-order order "atomic-bit-clear" +atomics-rmw-orders+)
  (%check-atomic-place vm place)
  (loop
    (let* ((word (ref-word vm place))
           (previous (logbitp index word)))
      (if (not previous)
          (return nil)
          (when (cas vm place word (logandc2 word (ash 1 index)))
            (return t))))))

(defmethod fence ((vm vm-binding) order)
  ;; A relaxed fence would be a silently weaker promise than the protocol
  ;; documents, so it is rejected like any other nonsense order.
  (%check-memory-order order "fence" +atomics-fence-orders+)
  (memory-fence vm))

;;;; ---- address-space protocol (managed-layout.tex sections 2, 5) ---------
;;;;
;;;; The simulator client offers its whole word-addressed heap as one managed
;;;; arena (one machine address unit = one simulator word).  Page 0 carries the
;;;; null sentinel, so it enters the offer as an implementation reservation,
;;;; never as an exclusion Clamsara would have to guess.  validate/install
;;;; consume the kernel's LAYOUT solution record: validation re-checks the
;;;; regions against the heap, installation records the solution as the VM's
;;;; ownership geometry (LAYOUT-SPACE-AT / epoch-guarded UPDATE-SPACE-
;;;; OWNERSHIP live in the kernel).

(defmethod managed-arena-offer ((vm simulator-vm))
  ;; Whole backed pages only: a trailing partial page cannot host logical
  ;; pages, so it never enters the offered machine range.
  (let ((backed-pages (floor (vm-heap-size vm) +page-words+)))
    (make-address-space-offer
     :arenas (list (make-managed-arena
                    :name :simulator-heap
                    :base (vm-heap-base vm)
                    :extent (* backed-pages +page-words+)
                    :alignment (max 1 (vm-min-alignment-words vm))
                    :page-size +page-words+
                    :access-modes '(:read :write)
                    :reservations
                    (list (make-arena-reservation
                           :start 0 :extent +page-words+ :kind :null-sentinel))))
     :exclusions '())))

(defun %layout-region-list (layout)
  (mapcar (lambda (region)
            (list (region-name region)
                  (region-start region)
                  (region-extent region)))
          (solution-regions layout)))

(defmethod validate-managed-layout ((vm simulator-vm) layout)
  ;; The kernel audited the solution; the client check is its own contract:
  ;; every assigned region must lie inside the word-addressed arena, aligned
  ;; to the logical page geometry, and non-overlapping in ascending order.
  (let ((limit (* (floor (vm-heap-size vm) +page-words+) +page-words+))
        (end-so-far 0))
    (dolist (entry (%layout-region-list layout) t)
      (destructuring-bind (name start extent) entry
        (declare (ignore name))
        (unless (and (typep start 'fixnum) (typep extent 'fixnum)
                     (>= start 0) (plusp extent)
                     (<= (+ start extent) limit)
                     (zerop (mod start +page-words+))
                     (zerop (mod extent +page-words+)))
          (error 'clamsara-error
                 :message (format nil
                                  "validate-managed-layout: region ~s is outside the simulator arena or unaligned"
                                  entry)))
        (unless (>= start end-so-far)
          (error 'clamsara-error
                 :message (format nil
                                  "validate-managed-layout: region ~s overlaps an earlier region"
                                  entry)))
        (setf end-so-far (+ start extent))))))

(defmethod install-managed-layout ((vm simulator-vm) layout)
  ;; Volatile eager backing: the simulator heap already backs every address,
  ;; so installation is validation plus recording the solution as the VM's
  ;; ownership geometry.  Nothing is fabricated.
  (validate-managed-layout vm layout)
  (setf (vm-managed-layout vm) layout)
  layout)

;;;; ---- metadata side-storage provisioning (strata.tex section 1) ---------
;;;;
;;;; The bind-metadata layout callback receives each side-storage request
;;;; and supplies boot-sized storage.  This is the simulator client's
;;;; provisioning: :FORWARDING and :RC adopt the VM's boot tables (the
;;;; client provisioned them at VM construction, so the binding becomes
;;;; their authority instead of allocating a second table), every other
;;;; datum receives a fresh host vector, and facts with concurrent writer
;;;; domains receive the vector-atomic client and a place vector.

(defun simulator-field-guarantees (field)
  "Guarantees of the simulator's offered fields.  The simulator offers no
  physical metadata fields (OFFERED-METADATA-FIELDS on VM-BINDING), so no
  field can match any specification and every placement resolves to side
  storage.  Extending the offer means stating these facts, not widening
  this function."
  (declare (ignore field))
  nil)

(defun simulator-side-storage (vm request)
  "Provision one side-storage REQUEST for this client (the bind-metadata
layout callback).  :FORWARDING and :RC adopt the VM's boot tables (the
client provisioned them at VM construction, so the binding becomes their
authority instead of allocating a second table).  Single-writer :BIT facts
receive the packed bit-vector realization; every other fact receives a
boxed simple-vector, and concurrent-writer facts also receive the
vector-atomic client and a place vector."
  (let* ((spec (side-request-specification request))
         (cells (side-request-cells request))
         (name (metadata-name spec)))
    (flet ((adopt (table)
             (make-side-storage :vector table
                                :base (side-request-base request)
                                :cells (length table))))
      (cond ((and (eq name :forwarding)
                  (eq (side-request-kind request) :vector))
             (adopt (vm-fwd-table vm)))
            ((and (eq name :rc)
                  (eq (side-request-kind request) :vector))
             (adopt (vm-rc-table vm)))
            ((and (eq (metadata-cell-type spec) :bit)
                  (eq (metadata-writers spec) :single))
             (make-side-storage
              :vector (make-array cells :element-type 'bit
                                  :initial-element
                                  (ldb (byte 1 0) (metadata-default spec)))
              :base (side-request-base request)
              :cells cells))
            (t
             (let ((vector (make-array cells
                                       :initial-element
                                       (metadata-default spec))))
               (if (eq (metadata-writers spec) :concurrent)
                   (make-side-storage
                    :vector vector
                    :base (side-request-base request)
                    :cells cells
                    :atomics (make-instance 'vector-atomic-client
                                           :vector vector)
                    :places (identity-places cells))
                   (make-side-storage
                    :vector vector
                    :base (side-request-base request)
                    :cells cells))))))))

(defun simulator-metadata-supply (vm)
  "The bind-metadata layout callback for this client."
  (lambda (request) (simulator-side-storage vm request)))

(defmethod space-of-reference ((plan plan) reference)
  ;; The plan's SFT is the current address-to-space realization (glossary:
  ;; "Address-to-space realization ... an SFT is one possible representation"),
  ;; derived from the installed managed-layout solution at construction.
  ;; Same resolution, same result, as PLAN-SPACE-FOR-ADDRESS.
  (plan-space-for-address plan (ref-strip-or-self (plan-vm plan) reference)))

(defmethod update-space-ownership ((plan plan) range owner)
  ;; Ownership reassignment belongs to the installed layout solution, under
  ;; its epoch discipline (managed-layout.tex section 5): an update requires
  ;; OPEN-OWNERSHIP-EPOCH + QUIESCE-OWNERSHIP-EPOCH, and one quiesced token
  ;; authorizes exactly one update.
  (let ((layout (vm-managed-layout (plan-vm plan))))
    (if layout
        (update-space-ownership layout range owner)
        (error 'clamsara-error
               :message "update-space-ownership: no managed layout is installed on this VM"))))

;;;; ---- mapping protocol, optional capability
;;;;      (client-protocols.tex section 5) ---------------------------------
;;;;
;;;; RANGE is a cons (FIRST-PAGE . PAGE-COUNT).  SOURCE names physical
;;;; backing pages in the simulator's volatile provider (the heap array
;;;; itself); there is no disk offset to fake.  Mapping changes take effect
;;;; for loads and stores once the software MMU is armed, the same arming
;;;; discipline the T1/T2 collectors already use.

(defmethod reserve-virtual-range ((vm simulator-vm) range)
  (let ((start (car range)) (count (cdr range)))
    (unless (and (typep start 'fixnum) (typep count 'fixnum) (>= start 0) (plusp count))
      (error 'clamsara-error :message "reserve-virtual-range: range must be (FIRST-PAGE . PAGE-COUNT)"))
    (%mmu-ensure-capacity vm (+ start count))
    (loop for k below count
          do (let ((entry (aref (mmu-vpt vm) (+ start k))))
               (setf (car entry) 0 (cdr entry) :none))))
  range)

(defmethod map-logical-pages ((vm simulator-vm) range source access)
  ;; Map SOURCE (physical page where the contents live) at RANGE with ACCESS.
  (let ((start (car range)) (count (cdr range)))
    (vm-map-alias vm source start count)
    (unless (eq access :read-write)
      (vm-mprotect vm start count access)))
  range)

(defmethod unmap-logical-pages ((vm simulator-vm) range)
  (vm-unmap vm (car range) (cdr range))
  range)

(defmethod remap-logical-pages ((vm simulator-vm) source destination count)
  ;; DESTINATION's backing becomes the pages named by SOURCE -- the same
  ;; argument order VM-REMAP uses for Claimore's map operation.
  (vm-remap vm destination source count)
  destination)

(defmethod protect-logical-pages ((vm simulator-vm) range access)
  (vm-mprotect vm (car range) (cdr range) access)
  range)

(defmethod flush-address-translations ((vm simulator-vm) range)
  ;; The software TLB is always consistent, so this returns immediately:
  ;; synchronous visibility in the stated (single) scope.
  (declare (ignore range))
  (vm-flush-tlb vm)
  nil)

;;;; ---- diagnostics seam (implementation names; see protocol/diagnostics) -

(defmethod monotonic-clock ((vm vm-binding))
  ;; CPU run time, not wall clock: correctness never depends on progress.
  (get-internal-run-time))

(defmethod fatal-diagnostic ((vm vm-binding) reason)
  ;; V11 LEDGER BLOCKER, do not fake: this portable/simulator implementation
  ;; signals CLAMSARA-ERROR through a FORMAT message, so it ALLOCATES and
  ;; dispatches through CLOS.  It satisfies the diagnostic CONTENT obligation
  ;; (report the violated invariant) but NOT the supervisor deployment's
  ;; allocation-free fatal-path obligation (client-protocols.tex section 6).
  ;; A deployed profile must lower this generic to a direct, preallocated
  ;; fatal sink and measure that on FIRST CALL; nothing here pretends that
  ;; lowering has happened.
  (error 'clamsara-error
         :message (format nil "clamsara fatal diagnostic: ~s" reason)))