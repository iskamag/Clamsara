(defpackage #:clamsara
  (:use #:cl #:closer-mop)
  (:shadowing-import-from #:closer-mop #:defgeneric #:defmethod #:standard-generic-function)
  (:shadow #:space)
  (:export
   ;; Types & constants
    #:address #:address= #:address-equal #:address+ #:address- #:address-index
   #:make-object-header #:header-size #:header-type-tag
   #:header-flag-set-p
   #:+type-tag-object+ #:+type-tag-cons+ #:+type-tag-array+
   #:+type-tag-struct+ #:+type-tag-function+
    #:+flag-forwarded+ #:+flag-pinned+
    #:+flag-has-young+ #:+flag-logged+
    #:+forwarded-flag-bit+
    #:+page-size-words+ #:+card-size-words+
    #:+cards-per-page+
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
    #:space-occupancy
    #:make-space
    #:immortal-allocator #:make-immortal-allocator
    #:compute-immortal-space
    #:immix-space-blocks #:immix-space-line-mark-state
   ;; Allocator
    #:bump-allocator #:free-list-allocator #:make-bump-allocator
    #:alloc #:coalesce #:mark-line #:mark-object-start
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
    #:satb-queue #:satb-queue-head #:satb-queue-tail #:satb-queue-capacity
    #:barrier-nursery-start #:barrier-nursery-end #:barrier-card-table
   #:barrier-card-table-cards
   #:card-table #:card-table-cards #:ensure-card-table

    ;; Tracer
    #:tracer #:make-tracer #:tracer-empty-p
    #:tracer-enqueue #:tracer-dequeue
    #:tracer-process-queue #:tracer-visit-count
    #:tracer-process-roots #:tracer-trace-fn-enqueues-p
    #:tracer-cycle-kind #:tracer-trace-kind
    ;; Mutator
    #:mutator-context #:make-mutator #:mutator-alloc
    #:tlab-alloc #:tlab-refill #:mutator-tlab-occupancy
    ;; Plan
    #:plan #:plan-vm #:plan-spaces
    #:plan-get-space #:plan-from-space #:plan-to-space
    #:plan-barrier #:plan-collect #:plan-allocate
    #:plan-generational-p #:plan-major-required-p
    #:plan-card-size-words
    #:plan-nursery-kind #:plan-num-generations
    #:plan-max-non-los-alloc-bytes
    #:plan-constraints #:plan-page-resource
    #:plan-nursery #:plan-nursery-from #:plan-nursery-to
    #:plan-mature-from #:plan-mature-to
    #:plan-live-young-bytes #:plan-dead-mature-bytes
    #:space-live-young-bytes #:space-dead-mature-bytes
    #:sticky-space-metrics
    #:plan-sft #:plan-build-sft
    #:should-promote-p
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
    #:vm-heap-usage #:vm-space-usage #:vm-gc-stats
    #:vm-metadata-region #:vm-forwarding-table #:vm-mutators
    #:vm-has-feature-p #:vm-page-size-words #:vm-cards-per-page
    #:vm-card-object-start-offset #:immediatep
    #:ref-u64 #:ref-word #:cas #:cas128 #:atomic-incf
    #:memory-fence #:atomic-swap
   ;; Simulator VM
   #:simulator-vm #:make-simulator-vm
   ;; Weak / Finalization
   #:weak-pointer #:weak-pointer-referent
   #:make-weak-pointer
   ;; Sanity
   #:sanity-check-after-gc
    ;; Convenience
    #:with-clamsara #:clamsara-gc
    #:clamsara-register-root
    #:clamsara-allocate-object #:clamsara-allocate
     #:*active-plan* #:*active-vm*
     #:clamsara-cons #:clamsara-car #:clamsara-cdr
     #:clamsara-heap-usage
     #:with-active-plan #:with-active-vm #:with-active-gc
   ;; Metaclasses
   #:clamsara-metaclass
   #:plan-metaclass
   #:space-metaclass
   #:allocator-metaclass
   #:barrier-metaclass
    #:vm-metaclass
    #:validate-plan-constraints
    #:make-plan
    #:defvm-feature #:define-trait-optimized-function
    ;; Traits
    #:weak-reference-trait
    #:finalization-trait
    #:concurrent-marking-trait
    #:concurrent-collector-trait
    #:cons-space-trait #:cons-space
    #:large-object-space-trait #:large-object-space
    #:nogc-space
    #:cm-start-concurrent-mark #:cm-drain-mark-buffers
    #:cm-is-marking-active-p
    #:cc-enter-concurrent-mode #:cc-enter-stw-mode
     ;; Compile framework
     #:gc-phase
     #:plan-collect-phase
     #:boot-gc
     #:compile-to-functions
     #:lookup-compiled-function
     #:plan-function-table
     #:plan-initialize-spaces
     #:compile-bump-alloc-cas
    ;; Stats
    #:plan-stats
    #:plan-stats-gc-count
    #:plan-stats-gc-time
    #:gc-stats #:reset-gc-stats
    ;; Scheduler
    #:gc-work-scheduler #:make-gc-work-scheduler
    #:scheduler-add-work #:scheduler-run-all
    #:scheduler-schedule-collection #:scheduler-steal-work
    #:scheduler-plan #:scheduler-buckets
    #:scheduler-worker-count #:scheduler-queue-capacity
   ;; Plan classes (for typep in tests)
   #:nogc-plan #:semispace-plan #:marksweep-plan #:immix-plan
   #:gencopy-plan #:genms-plan #:genimmix-plan #:stickyimmix-plan #:stickyms-plan
   ;; Conditions
   #:heap-exhausted #:no-active-plan
    ;; Sanity (test support)
    #:compute-live-set #:make-random-object-graph #:random-mutator-step
    ;; Allocator
    #:free))
;; Maclina symbols live in the clamsara-vm package, defined in src/vm/package.lisp
;; and loaded by the clamsara/vm secondary system.

(in-package #:clamsara)
