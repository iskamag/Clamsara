# Shared copying action — candidate V1 (source-only)

## Status and exact scope

Candidate: `/tmp/clamsara-shared-copy-04bff62-xzksq1om`.
Base HEAD: `04bff62db4ef86868dc6d5d917e8704f9d90b62e` (runtime1099).
Only production changes: `src/runtime/spaces.lisp` and
`src/runtime/generational.lisp`. No live repository or historical snapshot edits.
No native execution, ASDF load, Lisp reader/compile check, or subdelegation.
The input archive and exact patch are retained here. Independent review and
native authorization are still required.

## Narrow repair

Both trace methods now call `%trace-copy-object`, a private ordinary function
in `spaces.lisp`. It owns the existing claim/seen/failed dispatch and the single
initialize/copy/object-start/forward/movement/work-commit/error sequence.

The methods pass references to top-level private functions, not newly created
closures or per-object policy records:

- SemiSpace: `%reserve-semispace-copy-destination`.
- Minor promotion: `%reserve-promotion-copy-destination`.
- Generational major: unchanged `:ALL` guard and `CALL-NEXT-METHOD`, which reaches
  the ordinary SemiSpace method and reservation policy.

No generic function, public protocol, lifecycle phase, retained field, resource
claim, result key, or ASDF component was added. The existing optional generational
system depends on core, so it sees the helper already defined in `spaces.lisp`.
This is shared implementation, not independent replacement of space, allocator,
object model, or trace collaborators.

## Ownership and publication

1. `trace-claim-object` still precedes all destination selection. `:SEEN` awaits
   the existing claim and reads source forwarding. `:FAILED` returns the source.
   Neither branch calls the reservation function, allocates another destination,
   nor receives/consumes owner capabilities.
2. Only `:FIRST` calls the reservation function. Its five ordinary return values
   are destination, address, bytes, owned allocator, and failure reason. NIL
   reason means success. These are stack-local control values, not retained
   ownership records.
3. The SemiSpace policy calls `allocate-raw` with Q-charged bytes and Q alignment.
   Only success returns its exact allocator as owned. This captured allocator,
   rather than a later destination lookup, receives the existing raw commit or
   cancellation. A refusal has no raw reservation to cancel.
4. The promotion policy reads the address reserved by plan preflight. It returns
   NIL for the allocator. It never allocates from, commits, cancels, or rewinds
   the mature free list. The plan's scratch reservation/reclaim ownership is not
   transferred to this copying call.
5. The common action initializes the same source-bound model representation,
   copies it, and publishes the destination object-start before source forwarding.
   It then sets the existing cycle-wide publication flag, commits an owned raw
   reservation if present, records movement, adds bytes moved, and commits the
   original trace claim/reservation with the **destination** work-space/start.
6. A successful first copy has one movement record, one objects-moved increment
   via `%record-cycle-movement`, one bytes-moved increment, and one discovery/work
   commit via `trace-commit-object`. Seen visits add none. A failed post-publication
   copy may have incomplete obligations; this extraction does not hide them or
   falsely count it as a successful discovery.

No per-object function, cons, vector, class instance, or retained field was added
merely for sharing. This does not claim the existing hosted object model or CLOS
runtime is allocation-free or suitable for supervisor execution.

## Bounds and alignment: retained differences

The policies retain their original checks rather than replacing them with one
supposedly equivalent validator.

- Both obtain source size/alignment and require positive integer bytes,
  power-of-two alignment, and alignment <= source packing quantum Q.
- SemiSpace charges `align-up(bytes,Q)` to its destination bump allocator.
  The allocator aligns the cursor and checks its resulting end against its
  limit. There is no newly invented second destination-bound policy.
- Minor promotion obtains `%gen-promotion-destination` before its validation,
  just as before. In addition to the common geometry predicates, it checks
  `base <= address` and `address + bytes <= limit` in that order. This is the
  existing raw-byte extent check, not a newly tightened charged-byte check.
- Promotion's aligned, Q-charged reservation still comes from
  `%gen-reserve-promotions` / `%gen-reserve-nursery-start` /
  `%gen-scratch-allocate`, which use the mature free-list snapshot. Construction
  still enforces the shared Q and aligned ranges. These preflight/construction
  mechanisms are unchanged, not reimplemented in the common action.

The common helper reads the stable source-model slot before private destination
slot selection, whereas the old methods selected some private destination slots
first. No public model operation or reservation was moved onto seen/failed paths.
This is not a promise about arbitrary advice on private accessors.

## Failure and condition boundaries

- Policy predicate failure becomes the same `trace-abandon-object` call with
  `:FATAL-INVARIANT`; raw allocation refusal keeps `:CAPACITY-EXHAUSTED`.
- Size/alignment queries, promotion address lookup, raw allocation, and the
  SemiSpace allocation-time `object-kind` query remain outside the copy handler.
  Their signaled conditions are not silently changed into a local copy rollback.
  A missing preflight promotion cell therefore still signals the existing runtime
  rejection. The unchanged cycle handler retains the stop on unexpected signals.
- The copy handler still begins with its `object-kind`/descriptor lookup and
  includes initialization, copy, publication, movement/counters and trace commit.
  SemiSpace keeps its earlier allocation-kind query; minor promotion does not
  gain that extra query. The original count/order of public ABI calls is preserved.
- If no forwarding has been published anywhere in the cycle, a caught copy error
  clears any completed destination start fact, retires the exact newly created
  representation, cancels only a raw reservation owned by this call, and abandons
  the same trace capabilities with `:PREFLIGHT-FAILED`. Promotion has no raw
  allocator cancellation in that path. Cleanup faults still escape to the
  unchanged cycle error handler rather than being disguised as a completed undo.
- If the cycle-wide flag is already true, the error path does **not** reset the
  object-start, retire the new representation, cancel the raw allocation, or
  abandon the claim. This includes faults on an as-yet-unpublished second object
  after an earlier object forwarded. It records post-publication failure and the
  unchanged cycle driver keeps the stop / retained fatal state.
- Existing first-failure precedence remains: for example movement capacity
  exhaustion records `:CAPACITY-EXHAUSTED` before the caller attempts to record
  `:POST-PUBLICATION-FAILURE`; `trace-fail` does not overwrite it. The forwarding
  flag, not reason relabeling, prevents resuming a partly copied heap.

## Specification examined; obligations not claimed

Actual paper-v14 `collectors.tex`: SemiSpace copying action (51-77), generational
composition (144-178). `execution.tex`: shared claim/reservation ownership
(255-340), movement/publication (354-374), and stop/failure boundaries.
Source checked: actual trace claim/commit/abandon and movement bookkeeping,
cycle failure handling, raw allocator commit/cancel, and promotion preflight.

This repairs duplicate copying implementation only. Existing allocation routing,
source-indexed movement participants, metadata-role transfer, ownership-layout
updates, result schema, generational private mature-state/reclamation coupling,
client ABI limits, finalizer admission, and held model work are unchanged. No
whole-paper architecture, arbitrary collaborator replacement, target, supervisor,
or broader collector acceptance follows.

## Evidence and next gate

- `shared-copy-v1.patch`: exact combined two-file diff.
- `spaces-v1.diff`, `generational-v1.diff`: individual diffs.
- `head04bff62.tar`: original committed input, path-preserving.
- `head-input-sha256.json`, `head-candidate-sha256.json`: every committed input
  file compared; exactly the two stated production files differ.
- `input-sha256.json`: live files actually read before implementation, including
  actual paper-v14; all rechecked unchanged.
- `provenance-v1.json`: input/candidate/patch/archive hashes.
- `source-checks-v1.json`: source-only checks, including zero parenthesis balance.
  This is not a Lisp-reader or native test result.

Independent review should challenge seen/failed no-reservation behavior,
SemiSpace/minor/major destination tags, unique successful movement/discovery,
pre-publication failure in both policies, absence of any mature raw commit/cancel,
and fatal retention after either current or prior forwarding. No such native
cases were run here. The candidate is frozen pending review/authorization.
