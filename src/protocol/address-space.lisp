;;;; protocol/address-space.lisp -- clamsara-protocol.address-space.
;;;;
;;;; Normative sources: paper-v11/chapters/managed-layout.tex section 2
;;;; (client offer), section 5 (address-to-space resolution), and
;;;; client-protocols.tex section 5 (mapping protocol, an optional client
;;;; capability).  The architecture chapter's decomposition diagram hosts the
;;;; mapping mechanisms in this one address-space protocol system.
;;;; Depends on nothing but Common Lisp.

(defpackage #:clamsara-protocol.address-space
  (:use #:cl)
  (:export #:managed-arena-offer
           #:validate-managed-layout
           #:install-managed-layout
           #:space-of-reference
           #:update-space-ownership
           #:reserve-virtual-range
           #:map-logical-pages
           #:unmap-logical-pages
           #:remap-logical-pages
           #:protect-logical-pages
           #:flush-address-translations))

(in-package #:clamsara-protocol.address-space)

(defgeneric managed-arena-offer (address-space-client)
  (:documentation "The set of managed arenas and exclusions the client offers
to Clamsara (managed-layout.tex section 2).  Each arena describes base,
extent, alignment, page geometry, permitted access modes, and implementation
reservations.  Canonical-address restrictions, kernel windows, direct physical
maps, MMIO, DMA, active stacks, and page tables appear as exclusions or are
absent from the offer; Clamsara never guesses them."))

(defgeneric validate-managed-layout (address-space-client layout)
  (:documentation "The client validates the layout Clamsara derived
(managed-layout.tex section 1: the client validates and installs the
resulting map).  Signals a client-visible error on an invalid layout."))

(defgeneric install-managed-layout (address-space-client layout)
  (:documentation "Install the validated layout: reserve the virtual ranges
and construct logical ownership.  Installation reserves virtual ranges; a
volatile provider may back them eagerly, and a Wonderworld integration may
establish stable logical page ids and fault backing on demand
(managed-layout.tex section 4)."))

(defgeneric space-of-reference (layout reference)
  (:documentation "Resolve a managed reference to its owning space in bounded
time (managed-layout.tex section 5).  LAYOUT is the client's
address-to-space realization object; a dense space-function table, a two-level
table, address tags, page descriptors, or a bounded interval trie are valid
realizations.  A target deployment profile may require no allocation and no
generic dispatch in lookup."))

(defgeneric update-space-ownership (layout range owner)
  (:documentation "Reassign ownership of RANGE to OWNER.  Ownership updates
must be atomic with respect to any mutator or collector that can resolve the
range; a page cannot be returned, reassigned, or reused until all readers from
the old ownership epoch have quiesced (managed-layout.tex section 5)."))

(defgeneric reserve-virtual-range (mapping-client range)
  (:documentation "Optional mapping mechanism: reserve RANGE as allocated but
unmapped and protected virtual address space (client-protocols.tex section 5)."))

(defgeneric map-logical-pages (mapping-client range source access)
  (:documentation "Map the logical pages of RANGE from SOURCE with ACCESS.
The semantics of SOURCE are supplied by the volatile page provider or the
Wonderworld integration: a logical-page handle or a client-interpreted
descriptor, never a raw disk offset."))

(defgeneric unmap-logical-pages (mapping-client range)
  (:documentation "Unmap the logical pages of RANGE."))

(defgeneric remap-logical-pages (mapping-client source destination count)
  (:documentation "Change the mapping so COUNT logical pages starting at
DESTINATION are backed by the pages named by SOURCE.  This is the remapping
mover's mechanism: it changes the logical address or placement relation used
by the collector, which is distinct from Wonderworld eviction
(axes.tex section 4)."))

(defgeneric protect-logical-pages (mapping-client range access)
  (:documentation "Change the protection of RANGE to ACCESS; protection faults
against the range become observable."))

(defgeneric flush-address-translations (mapping-client range)
  (:documentation "Return after no processor in the stated scope can still
observe a stale translation for RANGE, or report a completion token when
visibility is asynchronous (client-protocols.tex section 5)."))
