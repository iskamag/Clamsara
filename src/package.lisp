;;;; package.lisp -- the CLAMSARA package.
;;;;
;;;; One package for the framework (nickname CL). The VM lives in the same
;;;; package: the simulator is the reference, and the spec keeps a single
;;;; surface. Internal helpers use the CLAMSARA-IMPL nickname-free home.

(defpackage #:clamsara
  (:use #:cl)
  (:shadow #:space #:gc #:alloc #:free #:copy #:mark #:trace)
  ;; paper-v11 client protocols (src/protocol/*.lisp).  The protocol systems
  ;; are the normative surface; CLAMSARA imports their generics so adapter
  ;; methods and migrated code name them without package qualifiers.
  (:import-from #:clamsara-protocol.object-model
   #:valid-reference-p #:object-start-p #:object-size #:object-kind
   #:map-reference-locations #:load-reference #:store-reference-raw
   #:initialize-object #:copy-object-representation #:reference-equal
   #:offered-metadata-fields #:field-read #:field-write #:field-cas)
  (:import-from #:clamsara-protocol.roots
   #:with-root-snapshot #:map-root-locations #:load-root #:store-root
   #:root-location-kind)
  (:import-from #:clamsara-protocol.coordination
   #:request-safepoint #:await-safepoint #:release-safepoint
   #:current-mutator #:begin-epoch #:await-epoch #:publish-fence)
  (:import-from #:clamsara-protocol.atomics
   #:atomic-load #:atomic-store #:atomic-cas #:atomic-fetch-add
   #:atomic-bit-set #:atomic-bit-clear #:fence)
  (:import-from #:clamsara-protocol.address-space
   #:managed-arena-offer #:validate-managed-layout #:install-managed-layout
   #:space-of-reference #:update-space-ownership
   #:reserve-virtual-range #:map-logical-pages #:unmap-logical-pages
   #:remap-logical-pages #:protect-logical-pages #:flush-address-translations)
  (:import-from #:clamsara-protocol.diagnostics
   #:monotonic-clock #:fatal-diagnostic)
  ;; paper-v11 committed kernels (src/core/*.lisp).  CLAMSARA consumes them
  ;; so collector construction runs through the reference component,
  ;; managed-layout, and metadata protocols instead of hand wiring.
  (:import-from #:clamsara-core
   #:component #:component-dependencies #:component-resources
   #:component-constraints #:validate-component #:initialize-component
   #:activate-component #:deactivate-component #:make-resource
   #:resource-name #:resource-start #:resource-extent #:resource-size
   #:resource-granularity #:resource-ownership #:resource-lifetime
   #:resource-atomicity #:resource-providers #:resource-consumers
   #:resource-sealed-p #:configuration #:configuration-components
   #:configuration-resources #:configuration-constraints
   #:configuration-layout #:configuration-state #:configuration-phases
   #:configuration-topological-order #:configuration-active-p
   #:find-resource #:component-bindings #:build-configuration
   #:deactivate-configuration #:context #:construction-error
   #:component-failure #:component-failure-phase #:component-failure-cause
   #:dependency-cycle #:resource-conflict #:missing-resource
   #:configuration-sealed)
  (:import-from #:clamsara-managed-layout
   #:address-space-offer #:make-address-space-offer
   #:offer-arenas #:offer-exclusions #:offer-address-width
   #:managed-arena #:make-managed-arena
   #:arena-name #:arena-base #:arena-extent #:arena-end #:arena-alignment
   #:arena-page-size #:arena-access-modes #:arena-reservations
   #:make-arena-reservation
   #:arena-reservation #:reservation-start #:reservation-extent
   #:reservation-kind
   #:exclusion #:make-exclusion
   #:resource-request #:make-resource-request
   #:request-name #:request-owner #:request-kind
   #:request-min-extent #:request-preferred-extent #:request-max-extent
   #:request-alignment #:request-page-granularity #:request-access
   #:request-atomicity #:request-lifetime #:request-returnable-pages-p
   #:request-mobility #:request-reclaimability
   #:request-adjacent-to #:request-separated-from #:request-alias-with
   #:request-near #:request-derive-from #:request-size-function
   #:build-managed-layout #:managed-layout #:solution-regions
   #:solution-arenas #:solution-free-intervals #:solution-work-capacity
   #:solution-installed-p #:find-solution-region #:layout-region
   #:region-name #:region-request #:region-owner #:region-kind
   #:region-arena-name #:region-start #:region-extent #:region-end
   #:region-access #:region-atomicity #:region-alias-partners
   #:region-stable-across-checkpoint-p #:region-effective-page
   #:free-interval #:free-arena-name #:free-start #:free-extent
   #:layout-space-at #:open-ownership-epoch #:quiesce-ownership-epoch
   #:ownership-epoch #:layout-rejection)
  (:import-from #:clamsara-metadata
   #:metadata-specification #:make-metadata-specification
   #:metadata-name #:metadata-domain #:metadata-cell-type #:metadata-width
   #:metadata-granularity #:metadata-default #:metadata-placement
   #:metadata-atomicity #:metadata-ownership #:metadata-lifetime
   #:metadata-writers #:metadata-order #:metadata-transfer-policy
   #:metadata-persistence #:metadata-reset-semantics #:metadata-kinds
   #:metadata-recompute #:metadata-merge-function
   #:make-contribution #:contribution-contributor
   #:contribution-specification #:merge-metadata #:metadata-registry
   #:registry-specifications #:find-metadata-specification
   #:bind-metadata #:metadata-binding #:binding-handles #:find-metadata
   #:side-request #:side-request-specification #:side-request-kind
   #:side-request-cells #:side-request-base #:side-request-granularity
   #:side-request-domain #:side-request-width #:make-side-storage
   #:metadata-table #:metadata-table-p #:make-metadata-table
   #:side-storage #:side-storage-vector #:side-storage-base
   #:side-storage-cells #:side-storage-atomics #:side-storage-places
   #:vector-storage #:vector-base #:vector-span #:vector-cells
   #:vector-granularity #:table-storage #:table-cells
   #:metadata-handle #:handle-specification #:handle-name
   #:handle-placement #:handle-cell-type #:handle-default
   #:handle-atomicity #:handle-order
   #:metadata-ref #:metadata-set #:metadata-cas #:metadata-reset
   #:metadata-set-bit #:metadata-clear-bit #:metadata-clear-range
   #:metadata-fold #:metadata-map-present #:metadata-project
   #:metadata-transfer
   #:metadata-error #:metadata-unsupported #:metadata-conflict
   #:metadata-invalid #:metadata-exhausted)
  ;; constants & types
  (:export #:+word-bits+ #:+word-bytes+ #:+log-word-bytes+
           #:+page-words+ #:+log-page-words+ #:+log-page-bytes+
           #:g-word #:g-line #:g-card #:g-block #:g-metablock #:g-superblock
           #:word-address #:word-address-p #:null-ref #:null-ref-p
           #:type-tag #:object #:cons #:array-object #:function-object
           #:hash-table-object #:struct-object
           #:+tag-object+ #:+tag-cons+ #:+tag-array+ #:+tag-function+
           #:+tag-hash-table+ #:+tag-struct+)
  ;; conditions
  (:export #:clamsara-condition #:heap-exhausted #:clamsara-error
           #:plan-incompatible #:barrier-incompatible #:gc-phase-error)
  ;; strata
  (:export #:stratum #:stratum-p #:make-stratum
           #:stratum-name #:stratum-granularity #:stratum-cell-type
           #:stratum-default #:stratum-storage #:stratum-cells
           #:matrix-stratum #:make-matrix-stratum
           #:matrix-stratum-p #:matrix-granularity #:matrix-direction
           #:matrix-regions #:matrix-cells
           #:s-get #:s-set #:s-cas #:s-test-bit #:s-set-bit #:s-clear-bit
           #:s-clear #:s-fold #:s-for-set-cells #:s-project #:s-refine
           #:s-popcount
            #:matrix-ref #:matrix-set #:matrix-clear #:matrix-row #:matrix-column
            #:matrix-row-into #:matrix-column-into
            #:matrix-closure #:matrix-closure-bounded
            #:matrix-peel #:matrix-peel-bounded
           #:stratum-address-range
           #:storage-contiguous #:storage-two-level #:storage-active-set)
  ;; page resources
  (:export #:page-resource #:page-resource-p
           #:pr-total-pages #:pr-allocated-p
           #:page-resource-get #:page-resource-release
           #:bitmap-page-resource #:monotone-page-resource
           #:free-list-page-resource)
  ;; VM protocol
  (:export #:clamsara-metaclass #:vm-metaclass #:vm-binding #:vm-binding-p
           #:vm-heap #:vm-heap-size
           #:vm-page-count #:vm-tier #:vm-has-feature-p
           #:virtual-memory-mixin #:ring0-mixin #:has-cas128-mixin
           #:coloured-pointer-mixin
           #:ref-u64 #:ref-word
           #:cas #:cas128 #:atomic-incf #:memory-fence
           #:vm-mprotect #:vm-map-alias #:vm-unmap #:mmu-arm #:mmu-disarm
           #:vm-page-dirty-p #:vm-clear-page-dirty
           #:vm-install-fault-handler #:vm-remap #:vm-flush-tlb
           #:vm-safepoint #:vm-mutator-poll #:vm-scan-roots #:vm-scan-object-references
           #:vm-stop-mutators #:vm-resume-mutators
           #:coordination-state #:coordination-state-p
           #:coordination-state-requested #:coordination-state-stopped
           #:coordination-state-epoch #:vm-coordination-state #:vm-coordination
           #:vm-coordination-requested #:vm-coordination-stopped
           #:vm-coordination-epoch #:vm-coordination-requested-p
           #:vm-coordination-stopped-p #:vm-safepoint-requested-p
           #:vm-mutators-stopped-p #:vm-stop-requested-p #:vm-stopped-p
           #:vm-safepoint-epoch
           #:ref-colour #:ref-set-colour #:ref-good-colour-p #:ref-strip
           #:software-mmu #:simulator-vm #:make-simulator-vm
           #:colour-remapped #:colour-marked0 #:colour-marked1
           #:colour-finalizable #:colour-good
           #:vm-heap-base #:vm-min-alignment-words #:vm-page-physical
           #:vm-root-regions #:vm-root-region-count #:vm-root-region-capacity
           #:register-root-region
           #:vm-register-stratum #:vm-stratum
           #:vm-object-header #:vm-object-reference #:vm-object-reference-count
           #:vm-object-total-words #:vm-object-type-tag #:vm-object-start-p
           #:vm-object-copy #:vm-object-has-children-p
           #:vm-object-is-marked-p #:vm-object-is-logged-p
           #:vm-object-is-public-p #:vm-object-age #:vm-object-rc
           #:vm-object-is-forwarded-p #:vm-object-forwarding-pointer
           #:vm-object-old-p #:vm-object-young-p
           #:vm-valid-reference-p #:vm-reference-p
           #:vm-allocate-object #:vm-root-set
           #:vm-reference-slots #:vm-map-reference-slots
           #:vm-heal-reference-slots
           ;; scheduler / work-packet / mutator-context protocol
           #:scheduler #:make-scheduler
           #:scheduler-vm #:scheduler-queue #:scheduler-head #:scheduler-tail
           #:scheduler-queue-size #:scheduler-capacity
           #:scheduler-enqueue #:scheduler-steal #:scheduler-drain
           #:work-packet #:make-work-packet
           #:work-packet-function #:work-packet-fn
           #:work-packet-region #:work-packet-region-start #:work-packet-start
           #:work-packet-region-end #:work-packet-end #:work-packet-data
           #:work-packet-owner #:work-packet-pool-index #:work-packet-state
           #:vm-scheduler #:vm-work-packet-pool #:vm-work-packet-free-stack
           #:initialize-vm-scheduler #:vm-work-packet-pool-size
           #:vm-work-packet #:vm-allocate-work-packet #:vm-make-work-packet
           #:release-work-packet
           #:mutator-context #:make-mutator-context
           #:mutator-context-plan #:mutator-context-vm
           #:mutator-context-tlab-cursor #:mutator-context-tlab-limit
           #:mutator-context-allocator #:mutator-context-barrier
           #:plan-mutator-context #:plan-mutator-contexts
           #:slot-map #:register-slot-map #:slot-map-for
            #:vm-add-root #:vm-remove-root #:vm-remove-root-at-index #:vm-clear-roots
           #:vm-set-reference)
  ;; heap / spaces / allocators
  (:export #:space #:space-p #:space-name #:space-start-page #:space-page-count
           #:space-allocator #:space-page-resource #:space-policy #:space-moving
           #:space-constraints #:space-metaclass #:allocator-metaclass
           #:space-contains-p #:space-trace-object #:space-prepare
           #:space-release #:space-reclaim #:space-occupancy
           #:space-default-p #:space-partner
           #:copy-space #:mark-sweep-space #:immix-space #:private-immix-space
           #:claimore-nursery-space
           #:los-space #:cons-space #:immortal-space #:superblock-space
           #:space-constraints #:accepts-copies #:mixed-age #:scope #:immortal
           #:alloc #:free #:coalesce
           #:bump-allocator #:free-list-allocator #:immix-allocator
           #:los-allocator #:cons-allocator #:monotone-allocator
           #:hierarchical-allocator #:sb-fine-metablocks
           #:superblock-map #:sb-map-pages
           #:claimore-nursery-matrix #:claimore-nursery-occupied
           #:claimore-nursery-dirty #:claimore-nursery-last-action
           #:plan-build-sft #:plan-space-for-address
           #:page-index #:page-start-address #:address-page)
  ;; tracer
  (:export #:tracer #:make-tracer #:tracer-enqueue #:tracer-drain
           #:tracer-reset #:tracer-empty-p #:tracer-size)
  ;; barriers
  (:export #:barrier-rule #:make-barrier-rule
           #:barrier-rule-metadatum #:barrier-rule-trigger #:barrier-rule-transfer
           #:barrier #:make-barrier #:barrier-rules
           #:barrier-note-write #:barrier-note-read
           #:barrier-metaclass #:no-barrier
           #:publication-strategy #:publish #:publish-sealed
           #:publication-read-rule
           #:eager-closure #:lazy-read-barrier #:trap-error-copy-a
           #:trap-error-copy-b
           #:strategy-read-guarded-p #:strategy-published-roots
           #:publication-epoch #:publication-state #:publication-active
           #:publication-open-p #:publication-sealed-p
           #:publication-enter #:publication-leave #:publication-seal
           #:publication-open #:compact-published-roots
           #:published-roots #:make-published-roots
           #:record-published-edge #:drain-published-roots
           #:published-roots-count #:published-edge-recorded-p
           #:copy-closure-to-public
           #:card-barrier-rule #:sticky-dirty-barrier-rule
           #:satb-barrier-rule #:rc-barrier-rule
           #:publication-barrier-rule
           #:shade-mark-barrier-rule)
  ;; plan / metaclass / compile
  (:export #:plan #:plan-p #:plan-name #:plan-vm #:plan-spaces #:plan-barrier
           #:plan-publication #:plan-constraints #:plan-page-resource
           #:plan-stats #:plan-function-table #:plan-sft
           #:plan-metaclass
           #:plan-constraints #:constraints-generational #:constraints-scope
           #:constraints-write-barrier #:constraints-read-barrier
           #:constraints-forwarding #:constraints-concurrency
           #:constraints-requires-tier
           #:constraints-max-non-los-bytes
           #:plan-marking-active-p
           #:plan-collect #:plan-allocate #:plan-get-space
           #:plan-handle-allocation-failure #:plan-collect-phase
           #:plan-default-cycle-kind
           #:plan-collect-hook
           #:with-plan-collect-hook
           #:gc-phase #:+gc-phase-order+
           #:weak-phase #:weak-pointer-p #:register-weak-pointer
           #:finalization-trait #:initialize-finalization
           #:register-finalizer #:process-finalizers
           #:pending-finalizer-count #:drain-pending-finalizers
           #:cycle-kind #:default-space
           #:defplan
           #:compile-to-functions #:boot-gc
           #:make-plan #:finalize-plan)
  ;; collectors (plans)
  (:export #:nogc-plan #:semispace-plan #:marksweep-plan #:immix-plan
           #:gencopy-plan #:genms-plan #:genimmix-plan
           #:stickyimmix-plan #:stickyms-plan
           #:iso-plan #:zgcish-plan #:claimore-plan)
  ;; stats / sanity
  (:export #:plan-stats #:make-stats #:stats-event #:stats-sample
           #:stats-get #:stats-reset #:stats-snapshot
           #:sanity-check #:sanity-errors
           #:gc-event-checkpoint
           #:persistent-allocator #:persistence-log #:make-persistence-log
           #:persistence-log-base-image #:persistence-log-base-timestamp
           #:persistence-log-base-checksum #:persistence-log-segments
           #:persistence-segment #:write-segment #:verify-segment
           #:collector-dirty-set #:collector-clear-dirty
           #:mark-pages-cow #:persistent-plan #:plan-persistence-log
           #:checkpoint-heap
           #:replay-segment #:replay-segments #:replay-log
           #:replay-persistence-log #:recover-last-intact-snapshot)
  ;; public api
  (:export #:with-clamsara #:clamsara-allocate-object
           #:make-collector
           #:clamsara-register-root #:clamsara-gc #:clamsara-write
           #:clamsara-read #:clamsara-plan
           #:*clamsara-plan* #:*clamsara-vm*
           #:run-test-suite))
