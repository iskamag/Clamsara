;;;; composition.lisp -- the paper-v11 composition vocabulary over the
;;;; collectors (composition.tex, strata.tex, managed-layout.tex).
;;;;
;;;; This module defines the seams a collector's components speak during
;;;; construction; the construction engine itself is construction.lisp:
;;;;
;;;;   COMPONENT-PLACEMENT-REQUESTS  -- what a component asks the managed
;;;;                                     layout to place for it
;;;;   COMPONENT-METADATA-SPECIFICATIONS -- the logical metadata a
;;;;                                     component contributes at discovery
;;;;
;;;; and the shared realization machinery for bound metadata: the atomic
;;;; side-vector client, the stratum realization over a bound supply, and
;;;; the runtime registration of a finished binding.
;;;;
;;;; Nothing here names a concrete plan or collector: shared metadata
;;;; facts are expressed once as specification constructors, and every
;;;; plan assembles its own set.  The simulator client's provisioning
;;;; (which storage a binding receives) lives in protocol/adapters.lisp
;;;; with the other client seams.

(in-package #:clamsara)

;;; ---------------------------------------------------------------------
;;; Discovery seams.

(defgeneric component-placement-requests (component)
  (:documentation "Managed-layout placement requests CONTRIBUTED by
  COMPONENT during construction (managed-layout.tex section 3: the plan
  contributes requirements; the layout builder solves them within the
  client-offered arenas).  A list of RESOURCE-REQUEST records; the default
  contributes nothing.")
  (:method ((component t)) nil))

(defgeneric component-metadata-specifications (component)
  (:documentation "Logical metadata specifications CONTRIBUTED by COMPONENT
  during discovery (strata.tex section 1: components contribute
  specifications during discovery; construction merges identically named
  facts, chooses a legal placement, adds side-storage requests, and binds
  a metadata handle).  A list of METADATA-SPECIFICATION records; the
  default contributes nothing.")
  (:method ((component t)) nil))

;;; ---------------------------------------------------------------------
;;; Shared metadata-fact constructors.  Each states the facts the runtime
;;; realizes for a plan-independent datum; plans combine them through
;;; COMPONENT-METADATA-SPECIFICATIONS, so a fact is declared exactly once.

(defun %word-granularity (vm)
  ;; Address-derived word-granularity cells; the simulator aligns objects
  ;; to single words.
  (vm-min-alignment-words vm))

(defun mark-specification (vm &key (writers :single)
                                (atomicity '(:plain :bit-atomic)))
  "Liveness mark.  A live move copies the mark to the destination
  (strata.tex section 3); the mark is ephemeral state cleared between
  cycles."
  (make-metadata-specification
   :name :mark :domain :word :cell-type :bit
   :granularity (%word-granularity vm) :default 0
   :placement '(:side-vector) :atomicity atomicity
   :writers writers :order :relaxed
   :transfer :copy :persistence :ephemeral :reset :default))

(defun forwarding-specification (vm)
  "Movement forwarding result (destination, 0 = none).  The datum stays at
  the source until the old range is retired; the destination is cleared,
  not carried."
  (make-metadata-specification
   :name :forwarding :domain :word :cell-type :reference :width 64
   :granularity 1 :default 0
   :placement '(:side-vector) :atomicity '(:plain)
   :writers :single :order :relaxed
   :transfer :clear :persistence :ephemeral :reset :default))

(defun weak-specification (vm)
  "Weak-pointer identity.  vm-object-copy carries it, so a moved weak
  pointer does not silently become a strong one."
  (make-metadata-specification
   :name :weak :domain :word :cell-type :bit
   :granularity (%word-granularity vm) :default 0
   :placement '(:side-vector) :atomicity '(:plain)
   :writers :single :order :relaxed
   :transfer :copy :persistence :ephemeral :reset :default))

(defun age-specification (vm)
  "Generational age.  Movement recomputes: promotion may increment or
  reset the destination's age (strata.tex section 3)."
  (make-metadata-specification
   :name :age :domain :word :cell-type :integer :width 4
   :granularity (%word-granularity vm) :default 0
   :placement '(:side-vector) :atomicity '(:plain)
   :writers :single :order :relaxed
   :transfer :recompute
   :recompute (lambda (key value)
                (declare (ignore key))
                (min 15 (1+ value)))
   :persistence :ephemeral :reset :default))

(defun card-specification (vm)
  "Mature-to-young remembered card.  Mutator stores set it while the
  collector reads and clears it, so the writers race and the bit needs an
  atomic set.  Cards are rebuilt wholesale, so movement clears rather
  than carries them."
  (make-metadata-specification
   :name :card :domain :word :cell-type :bit
   :granularity (g-card) :default 0
   :placement '(:side-vector) :atomicity '(:bit-atomic)
   :writers :concurrent :order :relaxed
   :transfer :clear :persistence :ephemeral :reset :default))

(defun log-specification (vm)
  "Sticky-dirty object log.  Mutator stores set it between minors; the
  collector consumes it at the stop boundary."
  (make-metadata-specification
   :name :log :domain :word :cell-type :bit
   :granularity (%word-granularity vm) :default 0
   :placement '(:side-vector) :atomicity '(:bit-atomic)
   :writers :concurrent :order :relaxed
   :transfer :copy :persistence :ephemeral :reset :default))

(defun public-specification (vm)
  "Publication visibility.  Mutator publication sets it; the collector's
  public-root scans read it.  vm-object-copy carries it."
  (make-metadata-specification
   :name :public :domain :word :cell-type :bit
   :granularity (%word-granularity vm) :default 0
   :placement '(:side-vector) :atomicity '(:bit-atomic)
   :writers :concurrent :order :relaxed
   :transfer :copy :persistence :ephemeral :reset :default))

;;; ---------------------------------------------------------------------
;;; Atomic side-vector client (clamsara-protocol.atomics over a host
;;; simple-vector).  A PLACE is the cell index; the client holds the
;;; storage.  Side vectors with concurrent writer domains require an
;;; atomics client at binding (strata.tex section 5); this is the
;;; simulator's: relaxed order, single stream.

(defclass vector-atomic-client ()
  ((vector :initarg :vector :reader vector-atomic-vector)))

(defun %check-vector-atomic-order (order what)
  (unless (eq order :relaxed)
    (error 'clamsara-error
           :message (format nil
                            "vector side storage provides :relaxed order only (~a got ~s)"
                            what order))))

(defmethod atomic-load ((client vector-atomic-client) place order)
  (%check-vector-atomic-order order "atomic-load")
  (svref (vector-atomic-vector client) place))

(defmethod atomic-store ((client vector-atomic-client) place value order)
  (%check-vector-atomic-order order "atomic-store")
  (setf (svref (vector-atomic-vector client) place) value)
  value)

(defmethod atomic-cas ((client vector-atomic-client) place old new order)
  (%check-vector-atomic-order order "atomic-cas")
  (let ((previous (svref (vector-atomic-vector client) place)))
    (when (eql previous old)
      (setf (svref (vector-atomic-vector client) place) new))
    previous))

(defun identity-places (cells)
  "PLACE vector for a vector-atomic-client: index i names cell i."
  (let ((places (make-array cells)))
    (dotimes (i cells places)
      (setf (svref places i) i))))

;;; ---------------------------------------------------------------------
;;; Bound-metadata realization.

(defun stratum-from-handle (handle)
  "Wrap a bound side-vector handle's storage as the runtime stratum
  realization.  One storage, one authority: the handle is the bound
  metadatum, the stratum is the dense realization over the same cells."
  (let* ((spec (handle-specification handle))
         (width (metadata-width spec))
         (cell-type (ecase (metadata-cell-type spec)
                      (:bit :bit)
                      (:reference :ref)
                      (:integer (cond ((<= width 4) :u4)
                                       ((<= width 8) :u8)
                                       ((<= width 16) :u16)
                                       (t :ref))))))
    (make-instance
     'stratum
     :name (handle-name handle)
     :granularity (vector-granularity handle)
     :cell-type cell-type
     :default (handle-default handle)
     :storage :contiguous
     :heap-base (vector-base handle)
     :heap-words (vector-span handle)
     :cells (vector-storage handle))))

(defgeneric metadata-runtime (vm name)
  (:documentation "How the object model's runtime serves the bound datum
  NAME: :STRATUM (dense side-vector realization registered under the
  datum's name) or :VM-TABLE (a dense per-address table the object model
  accesses directly).  This is object-model knowledge -- which access
  path realizes each logical datum -- never collector policy.")
  (:method ((vm t) name)
    (declare (ignore name))
    :stratum))

(defmethod metadata-runtime ((vm vm-binding) (name (eql :forwarding)))
  ;; The simulator's off-object forwarding table (binding.lisp).
  :vm-table)

(defmethod metadata-runtime ((vm vm-binding) (name (eql :rc)))
  ;; The simulator's off-object reference-count table (binding.lisp).
  :vm-table)

(defun install-bound-metadata (vm binding)
  "Register a finished binding on the VM's runtime registry: locations for
  the dispatching data, strata or adopted tables for the realizations.
  The binding remains the authority; the VM registry is the
  allocation-free lookup the runtime uses."
  (dolist (handle (binding-handles binding))
    (let ((name (handle-name handle)))
      (ecase (metadata-runtime vm name)
        (:stratum
         (when (eq (handle-placement handle) :side-vector)
           (vm-register-stratum vm name (stratum-from-handle handle)))
         (when (eq name :mark)
           (vm-set-location vm :mark :side)))
        (:vm-table
         ;; The simulator object model accesses forwarding and reference
         ;; counts through its own boot tables; the binding adopted them
         ;; as the authoritative storage, which installation asserts.
         (let ((adopted (case name
                          (:forwarding (vm-fwd-table vm))
                          (:rc (vm-rc-table vm)))))
           (unless (eq (vector-storage handle) adopted)
             (error 'clamsara-error
                    :message (format nil
                                     "bound ~a storage is not the VM's boot table"
                                     name))))
         (vm-set-location vm name :off-heap)))))
  binding)
