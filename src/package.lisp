(cl:defpackage #:clamsara
  (:use #:cl)
  (:shadow #:space)
  (:export
   ;; Types / Addresses
   #:address-index
   #:address=
   #:make-address
   #:address+
   #:address-
   #:+page-size-words+
   #:+card-size-words+
   #:+cards-per-page+
   ;; Object model
   #:+type-tag-object+
   #:+type-tag-cons+
   #:+type-tag-array+
   #:+type-tag-function+
   #:+type-tag-hash-table+
   #:+type-tag-struct+
   #:+flag-marked+
   #:+flag-forwarded+
   #:+flag-pinned+
   #:+flag-has-young+
   #:make-object-header
   #:object-header
   #:object-size
   #:object-type-tag
   #:object-flags
   #:object-reference
   #:object-reference-count
   #:object-total-words
   #:object-start-p
   #:object-flag-set-p
   #:set-object-flag
   #:clear-object-flag
   #:write-object-header
   #:header-size
   #:header-type-tag
   #:header-flags
   #:header-flag-set-p
   ;; Conditions
   #:heap-exhausted
   #:no-active-plan
   ;; Heap
   #:*heap*
   #:*heap-size*
   #:ensure-heap
   #:heap-ref
   ;; Metadata
   #:*metadata-words*
   #:*forwarding-pointers*
   #:ensure-metadata
   #:object-marked-p
   #:mark-object
   #:unmark-object
   #:clear-all-mark-bits
   #:object-forwarded-p
   #:object-forwarding-address
   #:set-object-forwarding
   #:clear-object-forwarding
   #:clear-all-forwarding
   #:object-logged-p
   #:log-object
   #:unlog-object
   #:clear-all-log-bits
   #:object-pinned-p
   #:pin-object
   #:unpin-object
   #:object-age
   #:mark-object-start
   #:ensure-forwarding-pointers
   ;; Page table
   #:*page-table*
   #:ensure-page-table
   #:page-for-address
   #:page
   #:make-page
   #:page-space
   #:page-generation
   #:page-kind
   #:page-used-words
   #:page-free-p
   #:page-allocate
   #:page-reset
   ;; Card table
   #:card-table
   #:make-card-table
   #:card-table-cards
   #:ensure-card-table
   #:card-index
   #:card-dirty-p
   #:mark-card-dirty
   #:clear-card-dirty
   #:clear-all-cards
   ;; VM binding
   #:vm-binding
   #:vm-heap-base
   #:vm-heap-size
   #:vm-card-table
   #:vm-root-set
   #:vm-barrier
   #:vm-object-header
   #:vm-object-reference
   #:vm-object-reference-count
   #:vm-object-total-words
   #:vm-object-type-tag
   #:vm-object-start-p
   #:vm-object-is-marked-p
   #:vm-object-is-forwarded-p
   #:vm-object-forwarding-pointer
   #:vm-object-is-pinned-p
   #:vm-object-is-logged-p
   #:vm-object-generation
   #:vm-object-age
   #:vm-object-copy
   #:vm-compute-header
   #:vm-address-index
   #:vm-address-in-space-p
   #:vm-address-generation
   #:vm-address-young-p
   #:vm-address-old-p
   #:vm-find-space-for-address
   #:vm-scan-roots
   #:vm-scan-object-references
   #:vm-update-roots-forwarded
   #:vm-stop-mutators
   #:vm-resume-mutators
   #:vm-block-for-gc
   #:vm-post-gc-cleanup
   #:vm-clear-all-forwarding
   #:vm-clear-all-mark-bits
   #:vm-clear-all-log-bits
   #:vm-heap-usage
   #:vm-valid-reference-p
   #:vm-object-reference-store
   #:vm-object-copy
   ;; Simulator VM
   #:simulator-vm
   #:make-simulator-vm
   #:*simulated-stack*
   #:*simulated-thread-id*
   #:push-stack-frame
   #:pop-stack-frame
   #:clear-simulated-stack
   ;; Space
   #:space
   #:space-name
   #:space-kind
   #:space-start-page
   #:space-page-count
   #:space-allocator
   #:space-page-resource
   #:space-constraints
   #:space-moves-objects-p
   #:space-accepts-copies-p
   #:space-mixed-age-p
   #:space-immortal-p
   #:space-contains-p
   #:space-trace-object
   #:space-prepare
   #:space-release
   #:space-sweep
   #:collectable-space
   #:copying-space-trait
   #:marksweep-space-trait
   #:immix-space-trait
   #:copy-space
   #:mark-sweep-space
   #:immix-space
   #:make-copy-space
   #:make-space
   #:space-address-range
   ;; Allocators
   #:bump-allocator
   #:free-list-allocator
   #:large-object-allocator
   #:immix-allocator
   #:alloc
   #:free
   #:allocator-cursor
   #:allocator-limit
   #:make-bump-allocator
   #:make-free-list-allocator
   #:bump-allocator-reset
   #:free-list-allocator-add-page
   #:free-list-allocator-clear
   ;; Immix
   #:immix-block
   #:immix-space-blocks
   #:immix-space-recycled-blocks
   #:immix-space-current-block
   #:immix-space-line-mark-state
   #:+immix-lines-per-block+
   #:+immix-line-size-words+
   #:+immix-block-size-words+
   #:make-immix-space
   #:make-immix-allocator
   #:immix-mark-object-lines
   ;; Page resource
   #:page-resource
   #:page-resource-get
   #:page-resource-release
   #:make-page-resource
   #:initialize-page-resource
   ;; Plans
   #:plan
   #:plan-name
   #:plan-vm
   #:plan-spaces
   #:plan-constraints
   #:plan-barrier
   #:plan-function-table
   #:plan-collect
   #:plan-allocate
   #:plan-get-space
   #:plan-handle-allocation-failure
   #:plan-request-gc
   #:plan-add-space
   #:plan-find-space
   #:initialize-plan-heap
   #:plan-tracer
   ;; Generational
   #:generational-plan-trait
   #:plan-survivor-threshold
   #:plan-minor-gc-count
   #:plan-major-gc-count
   #:gen-minor-collect
   #:gen-major-collect
   ;; Barrier
   #:barrier
   #:no-barrier
   #:object-barrier
   #:satb-barrier
   #:barrier-note-write
   #:barrier-note-read
   #:barrier-card-scan
   #:barrier-clear-all
   #:make-no-barrier
   #:make-object-barrier
   #:make-satb-barrier
   ;; Tracer
   #:tracer
   #:make-tracer
   #:tracer-enqueue
   #:tracer-process-queue
   #:tracer-process-roots
   #:tracer-empty-p
   #:tracer-dequeue
   #:tracer-visit-count
   ;; Mutator
   #:mutator-context
   #:make-mutator
   #:mutator-id
   #:mutator-tlab-cursor
   #:mutator-tlab-limit
   #:mutator-barrier
   #:mutator-alloc
   ;; Roots
   #:root-set
   #:make-root-set
   #:rs-static-roots
   #:rs-thread-roots
   #:register-root
   #:unregister-root
   #:root-set-all-roots
   #:root-set-clear
   #:update-root-set-forwarded
   ;; Scheduler
   #:gc-work-scheduler
   #:make-gc-work-scheduler
   #:scheduler-buckets
   #:scheduler-run-all
   #:scheduler-schedule-collection
   ;; Weak references
   #:weak-reference-trait
   #:plan-weak-pointers
   #:make-weak-pointer
   #:update-weak-pointer-referents
   #:process-weak-references
   ;; Finalization
   #:finalization-trait
   #:plan-known-finalizers
   #:plan-pending-finalizers
   ;; Copy config
   #:copy-semantics
   #:copy-config
   ;; Stats
   #:*gc-count*
   #:*gc-pause-time*
   #:reset-gc-stats
   #:gc-stats
   ;; Sanity checker
   #:compute-live-set
   #:sanity-check-after-gc
   #:make-random-object-graph
   #:random-mutator-step
   #:run-sanity-stress
   ;; Options
   #:plan-selector
   ;; API
   #:with-clamsara
   #:*active-plan*
   #:*active-vm*
   #:select-plan
   #:clamsara-gc
   #:clamsara-allocate
   #:clamsara-allocate-object
   #:clamsara-register-root
   #:clamsara-cons
   #:clamsara-car
   #:clamsara-cdr
   #:clamsara-heap-usage
   ;; Concrete plans
   #:nogc-plan
   #:semispace-plan
   #:marksweep-plan
   #:immix-plan
   #:gencopy-plan
   #:genms-plan
   #:genimmix-plan
   #:stickyimmix-plan
   #:stickyms-plan
   #:make-plan
   #:plan-from-space
   #:plan-to-space
   ;; Maclina VM
   #:maclina-vm
   #:make-maclina-vm
   #:clamsara-maclina-client
   #:maclina-client-plan
   #:with-clamsara-maclina
   #:setup-clamsara-maclina-environment
   #:*clamsara-maclina-client*
   #:*clamsara-maclina-env*
   #:clamsara-maclina-eval
   #:clamsara-maclina-eval-string
   #:clamsara-read-from-string
   #:scan-maclina-stack-roots
   #:scan-maclina-dynenv-roots
   #:scan-maclina-closure-roots))

(in-package #:clamsara)
