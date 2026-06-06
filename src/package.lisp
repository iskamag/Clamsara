(defpackage #:clamsara
  (:use #:cl #:closer-mop)
  (:shadowing-import-from #:closer-mop #:defgeneric #:defmethod #:standard-generic-function)
  (:shadow #:space)
  (:export
   ;; Types & constants
   #:address #:address= #:address+ #:address- #:address-index
   #:make-object-header #:header-size #:header-type-tag
   #:header-flag-set-p
   #:+type-tag-object+ #:+type-tag-cons+ #:+type-tag-array+
   #:+type-tag-struct+ #:+type-tag-function+
    #:+flag-forwarded+ #:+flag-pinned+
    #:+flag-has-young+ #:+flag-logged+
    #:+forwarded-flag-bit+
   #:+page-size-words+ #:+card-size-words+
   #:address<= #:address>= #:address< #:address> #:address-min #:address-max
    ;; Heap
    #:heap-ref #:page-table-ref #:page-free-p #:page-allocated-p
    #:allocate-pages #:free-pages #:ensure-heap #:card-index
    ;; Space
    #:space #:space-name #:space-kind
    #:space-start-page #:space-page-count
    #:space-contains-p #:space-address-range
    #:space-allocator #:space-vm
    #:space-reset-to-empty
    #:make-space
    #:immix-space-blocks #:immix-space-line-mark-state
   ;; Allocator
   #:bump-allocator #:free-list-allocator #:make-bump-allocator
   #:alloc #:mark-object-start
   ;; Object model
   #:vm-object-start-p #:vm-object-type-tag
   #:vm-object-header #:vm-object-reference-count
   #:vm-object-reference #:vm-valid-reference-p
    #:vm-object-is-marked-p #:vm-object-is-forwarded-p
    #:vm-object-is-logged-p #:vm-object-is-pinned-p
    #:vm-object-generation #:vm-object-age
   #:vm-object-forwarding-pointer
   #:vm-object-header-flags #:vm-object-header-size
   #:vm-object-copy #:vm-object-total-words
   #:vm-object-has-children-p
   ;; Metadata
   #:metadata-words #:metadata-offset
   #:object-start-p #:mark-object-start
    ;; Barrier
    #:barrier-note-write #:barrier-note-read
    #:barrier-card-scan #:barrier-clear-all
    #:*barrier-selectors*
    #:no-barrier #:make-no-barrier
    #:object-barrier #:make-object-barrier
    #:satb-barrier #:make-satb-barrier
    #:satb-enqueue #:satb-drain
    #:barrier-nursery-start #:barrier-nursery-end #:barrier-card-table
   #:barrier-card-table-cards
   #:card-table #:card-table-cards #:ensure-card-table
   #:card-table-card-dirty-p #:barrier-scan-cards
    ;; Tracer
    #:tracer #:make-tracer #:tracer-empty-p
    #:tracer-enqueue #:tracer-dequeue
    #:tracer-process-queue #:tracer-visit-count
    #:tracer-process-roots #:tracer-trace-fn-enqueues-p
    ;; Plan
    #:plan #:plan-vm #:plan-spaces
    #:plan-get-space #:plan-from-space #:plan-to-space
    #:plan-barrier #:plan-collect #:plan-allocate
    #:plan-generational-p #:plan-major-required-p
    #:plan-card-size-words
    #:plan-nursery-kind #:plan-num-generations
    #:plan-constraints #:plan-page-resource
    #:plan-nursery #:plan-nursery-from #:plan-nursery-to
    #:plan-mature-from #:plan-mature-to
    #:plan-live-young-bytes #:plan-dead-mature-bytes
    #:sticky-nursery-collect
    #:make-semispace-plan #:make-marksweep-plan
   #:make-immix-plan #:make-gencopy-plan #:make-genms-plan
   #:make-genimmix-plan #:make-stickyimmix-plan #:make-stickyms-plan
   ;; Collector state
   #:collector-state #:collector-state-plan #:collector-state-phase
   #:collector-state-forwarding
    ;; VM
    #:vm #:root-set #:rs-static-roots #:vm-root-set
    #:vm-scan-roots #:vm-object-reference-store
    #:vm-stop-mutator #:vm-resume-mutator
    #:vm-space-usage #:vm-gc-stats
    #:vm-metadata-region #:vm-forwarding-table #:vm-mutators
    #:vm-has-feature-p #:vm-page-size-words #:vm-cards-per-page
    #:vm-card-object-start-offset #:immediatep
   ;; Simulator VM
   #:simulator-vm #:make-simulator-vm
   #:simulator-vm-heap
   #:simulator-vm-metadata-words
   #:simulator-vm-forwarding-pointers
   #:simulator-vm-page-table
   ;; Weak / Finalization
   #:weak-pointer #:weak-pointer-referent
   #:make-weak-pointer
   ;; Sanity
   #:sanity-check-after-gc
   ;; Convenience
   #:with-clamsara #:clamsara-gc
   #:clamsara-register-root
   #:*active-plan* #:*active-vm*
   ;; Metaclasses
   #:clamsara-metaclass
   #:plan-metaclass
   #:space-metaclass
   #:allocator-metaclass
   #:barrier-metaclass
   #:vm-metaclass
   #:validate-plan-constraints
   #:make-plan
   ;; Traits
   #:space-trait
   #:allocator-trait
   #:barrier-trait
   #:generational-trait
   #:concurrent-marking-trait
   #:concurrent-collector-trait
   #:line-marking-trait
   #:weak-reference-trait
   #:finalization-trait
   ;; Compile framework
   #:gc-phase
   #:plan-collect-phase
   #:boot-gc
   #:compile-to-functions
   #:plan-function-table
   #:plan-initialize-spaces
    ;; Stats
    #:plan-stats
    #:plan-stats-gc-count
    #:plan-stats-gc-time
    #:*gc-count* #:*gc-pause-time*
   ;; Plan classes (for typep in tests)
   #:nogc-plan #:semispace-plan #:marksweep-plan #:immix-plan
   #:gencopy-plan #:genms-plan #:genimmix-plan #:stickyimmix-plan #:stickyms-plan
   ;; Conditions
   #:heap-exhausted #:no-active-plan
   ;; Sanity (test support)
   #:compute-live-set #:make-random-object-graph #:random-mutator-step
   ;; Allocator
   #:free
   ;; Maclina
   #:clamsara-maclina-client
   #:*clamsara-maclina-client* #:*clamsara-maclina-env*
   #:setup-clamsara-maclina-environment))

(in-package #:clamsara)
