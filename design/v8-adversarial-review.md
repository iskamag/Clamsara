# Paper v8 adversarial review

This is a review of executable behaviour, not a claim that every class or axis
named in the paper is implemented.

## Verdict

| Question | Current answer |
|---|---|
| Does the simulator exercise real reachability and movement? | Yes for headered objects and the optional Maclina cons subset. Copying roots/slots, promotion, remembered sets, Immix evacuation, and ZGC-style relocation are now asserted by tests. |
| Does collection allocate in the host Lisp heap? | The first live post-boot collections measure zero SBCL allocation for every collecting plan, including fragmented Immix evacuation, after forcibly closing SBCL's thread allocation region. Boot is outside that boundary. This is still an empirical backend result, not a structural guarantee: inner VM/space operations use CLOS and a cache invalidation or new specialization could allocate an effective method. |
| Is this the paper's no-CLOS compiled collector? | No. SBCL boot compilation resolves the seven outer phase methods to direct method-function calls, but their inner component and VM protocol calls remain generic. |
| Is there a Lisp workload rather than only hand-built headers? | Yes, optionally. `clamsara/maclina` evaluates a CL subset and redirects `cons`, `car`, `cdr`, `consp`, `rplaca`, `rplacd`, and `list` to the simulated heap. Maclina stack, values, and closure environments participate in root rewriting. Maclina itself still allocates host compiler/interpreter objects. |
| Does the simulator validate concurrent collectors? | No. Mutator stop/resume, safepoints, faults, and concurrent phases are single-threaded simulations. The software MMU is preallocated but collectors do not run an adversarial scheduler or real races. |

## Defects fixed in this pass

- Generational plans now use a copying nursery, survivor ages, promotion, and
  healed remembered-set edges. Previously a "minor" was effectively an
  in-place mark/sweep. Remembered sets are rebuilt after evacuation so healed
  old-to-young edges survive subsequent minors.
- Sticky plans now log and rescan mutated marked objects; previously a child
  added after the parent's first minor could be reclaimed.
- Cycle kind now reaches spaces. Previously `:major` was silently changed to
  `:full`, so Immix defragmentation could not execute.
- Immix major evacuation now copies out of place and preserves the destination;
  dead and moved object-start metadata is cleared.
- ZGC-style relocation now consumes the live mark set instead of clearing it
  before compaction. SATB remark now drains objects introduced by the buffer
  without generic-function rest-list allocation.
- Pointer colours and forwarding tags no longer manufacture host bignums on
  SBCL.
- Tracer, roots, forwarding, RC, barriers, publication, free lists, Immix
  blocks, strata, and software-MMU tables are fixed-capacity/preallocated.
- Collection scans no longer allocate capturing closures or temporary range
  conses. Root callbacks receive collector state explicitly.
- `plan-collect` is an ordinary compiled entry point; boot resolves the outer
  phase methods directly on SBCL and resolves the observed post-reset
  `vm-object-reference` cache miss before mutators run.
- The optional v7-era Maclina workload seam has been restored and tested across
  semispace flips.

## Remaining paper-v8 blockers

1. Finish compilation below the phase boundary. VM access, object-model,
   space trace/reclaim, barriers, and allocator operations must be spliced or
   otherwise directly called so correctness cannot depend on CLOS cache state.
2. Make object and root scanning precise. The core simulator currently treats
   every payload slot as a possible reference instead of delegating to
   per-type layouts/pointer maps as the VM protocol requires. Maclina references
   and signed immediates are disjoint, but its stack scan still lacks PC-indexed
   stack maps.
3. Wire a real large-object space into every applicable plan. `los-space` is
   currently absent from plan layouts, and its default allocator is still a
   free list rather than the page-based `los-allocator`.
4. Implement a real concurrent simulator: multiple mutators, scheduler-controlled
   safepoints, interleaved barriers, fault delivery, and relocation races.
5. Replace Claimore's flat nursery/mature scaffold with the paper's hierarchy,
   coalesced RC ownership rules, cycle backup, checkpoint persistence, and
   crash/recovery invariants.
6. Implement weak references/finalization and persistence event semantics.
7. Expand the Maclina value model beyond `NIL`, signed 59-bit immediates, and
   cons references. Symbols, strings, vectors, functions, and general objects
   currently remain host values or are rejected at simulated-heap stores.
8. Bring the sanity checker up to the paper: verify actual RC in-degree,
   forwarding-table release rules, per-plan mark invariants, DLG over all live
   objects, and persistent/checkpoint state.
9. Add model checking/differential tests. Passing graph tests demonstrate the
   covered paths, not collector correctness over all heap shapes.

## Reproduction

```lisp
(asdf:load-system :clamsara/test)
(clamsara:run-test-suite)

(asdf:test-system :clamsara/maclina/test)
```

The standard suite includes a raw SBCL allocation-region probe around the first
live post-boot `plan-collect`, remembered-set scanning, sticky dirty rescans,
SATB remark, and fragmented Immix evacuation. It avoids `get-bytes-consed`,
which can allocate a bignum itself.
