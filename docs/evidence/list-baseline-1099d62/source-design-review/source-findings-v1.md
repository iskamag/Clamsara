# Independent LIST N+2 design review — source only

Reviewed frozen HEAD1099 source in `/tmp/clamsara-list-baseline-1099d62-xzks71ws`
and `report-v1.md`, `report-v2.md`, `regression-draft-v2-construction.lisp` in
`/tmp/clamsara-mapc-draft-wd3ba0th/independent-review/list-rest-next`.
No implementation, native/ASDF execution, fixture/dependency change or delegation.
N+2 below is a private proposed layout, not a normative public API arity policy.

## Verdict

The N+2 publication/counting sketch is coherent for admitted guest words in the
frozen runtime. I found no definite extra-cell undercount for that bounded case.
The draft is not yet a sufficient ownership/capacity acceptance gate. Three
specific gaps need correction or explicit disposition before implementation is
accepted. Other untested limits remain disclosed, not silently passed.

## 1. The physical-state oracle misses real source mutations

Draft lines 311–369 compare construction vectors, token objects, values, and
scalar state, but they omit:

- The identity of each native arena cons. `:NATIVE` stores only each CAR/CDR.
  Replacing an idle `(NIL . NIL)` arena cell with a distinct `(NIL . NIL)` cell
  in the same array leaves all current comparisons equal. This is a concrete
  source-level counterexample, not a mutation performed on an actual provider.
- VM-VALUES cell CAR contents. `:VALUES` keeps only the original spine pointer
  and uses EQ. An in-place CAR mutation can leave it equal to itself. Descriptor
  SOURCE identity does not snapshot that source's current CAR, and descriptor
  VALUE is not the read-through source for active `:VALUES` descriptors.
- The VM stack vector identity. `:STACK` copies values but not the vector itself.
  Replacing it with a same-content vector can evade this comparison.
- Snapshot/census walk, QUEUE and SEEN identities, actual bounds, and snapshot
  scratch state. `CENSUS-CLEAN-P` checks only eventual cleared census contents.
  It does not establish that either actual walk/queue remained the same object.

Saved cleanup value chains and dynamic binding/control cell payloads likewise
are not made immutable snapshots just by saving their head/control-object identity.
Do not promote this comparator to a whole-provider no-mutation oracle.

Action: add the missing physical identities and copied source contents, retain
SOURCE identity and EQL SOURCE-INDEX checks already present, and validate with
synthetic equal-content replacements/in-place value mutation. Keep copied managed
encodings only for the no-GC comparison; do not turn them into later GC owners.

## 2. Nested rejection is not outer-extent survival

Draft lines 447–449 build MAPC -> ML callback -> LIST. Lines 478–505 catch a LIST
capacity condition only outside `INVOKE-OWNED`. Thus the callback, MAPC extent and
outer ML frame all unwind before checking zero counts and doing direct recovery.

This tests a bounded nested call followed by full unwind and smaller reuse. It
does NOT test that an outer native extent remains usable after an inner LIST
rejection. An erroneous inner cleanup that clears outer cells can be masked by
the ensuing outer unwind; the separately rooted input in root15 still survives.

Action: add a distinct history that catches the inner rejection while the outer
MAPC callback/extent is live, forces a real collection, reads its moved arguments
and capture, continues the outer iteration and verifies its original return list.
Then test a new nonempty call after outer release. Do not relabel the current
full-unwind recovery as that missing history.

There is also no partial-build allocation-failure history: current negative
capacity cases reject before allocation, and movement cases finish normally.
Such a test would be needed to establish internal extent release and outer owner
preservation after allocation fails with an already-built tail. It is not proof
that root-capacity admission reserves enough heap for the whole LIST.

## 3. Root0's exceptional lifetime is not settled by N+2

`src/workload/protocol.lisp:231–271` makes WORKLOAD-WRITE-SLOT publish its payload
through temporary root0. Its cleanup is MULTIPLE-VALUE-PROG1, not UNWIND-PROTECT.
A `:RETRY` or error after publication can exit without clearing root0. N+2 input,
result and staging cells do not automatically discharge that helper-owned root.

Action: make the primitive's failure contract explicit. Observe root0 on a clean
retry and on fatal/retained failure; do not declare the whole provider unchanged
or ready merely because native/frame counters returned to their old values.
Do not blindly erase root0 on every unwind, restore a stale encoded value, or
attempt root-store cleanup through a fatal runtime. Preserve the real failed
owner/condition. Any helper change needs its own scope/ownership argument.

This is NOT a claim that the frozen runtime permits arbitrary moving barriers.
`runtime/barrier.lisp:266–326` holds a plan barrier pin from pre-effect through
completion/cancel; `runtime/records.lisp:584–591` and `runtime/spaces.lisp:104–111`
reject ordinary allocation/collection or raw allocation while pinned. The normal
frozen write path has no admitted managed collection inside that barrier extent.
The existing reports correctly exclude arbitrary moving-barrier support.

## Allocation/write/return handoff: exact requirements

The raw allocation route can collect before obtaining a new object, but after
successful initialization/metadata commit it returns the new reference without
another managed allocation (`runtime/allocation.lisp:88–121,126–178`). Thus the
input row and old result must be published before that call, and the returned
reference must immediately reach the staging cell before any later managed
operation. A native callback closure holding the encoded result is not a root.

`%ALLOCATE-GUEST` with VALUES NIL does not borrow root0/root1 for its input list
and can be a narrow allocation helper. Its result still needs the immediate
staging publication. Do not use `%CONS*`, recursive `%LIST*`, or
`%HOST-LIST->GUEST` as if they provided this arena ownership contract.

For each slot write, reacquire target from staging and payload from its input or
result cell. Do not retain target/payload encodings across the other write, and
do not use WORKLOAD-WRITE-SLOT's returned payload as the new object result.
Publish staging as the result only after both CAR and CDR writes complete.

Before the final result-cell load, finish every fallible helper/cleanup operation.
After that load, scope release must be only nonallocating local extent bookkeeping
until the caller receives the result. No root-store helper, census or guest call
may be hidden in that transfer interval. The VM's host consing is not a claim of
host-allocation-free or supervisor-safe execution.

`%WORKLOAD-KIND-ALLOCATION` can call setup-provided size/alignment functions
(`protocol.lisp:85–99`); the frozen runtime's CONS offer is the constant 32-byte
kind (`setup.lisp:147`). Keep the leaf/no-reentrant-callback claim scoped to that
known offer, or publish ownership before any potentially effectful offered hook.

## Census inputs and physical bounds

For a nonempty leaf whose inputs pass the real model payload admission:

- Current source demand comes from the actual VM top/values/dynenv, existing
  active FUNCTIONS/SAVED-VALUES extents, global/property/code/control owners and
  the provider's fixed temporary-root count.
- The new SAVED-VALUES chain contributes exactly N+2 physical root locations,
  including NIL/aliased values. Deduplicate control objects, not these sources.
- A NIL FUNCTIONS entry adds no callable control graph. One frame is required in
  BOTH FUNCTIONS and SAVED-VALUES; N+2 cells are required beyond the active native
  cell count. LIST does not need a new ML callback-entry frame or local-stack pad.
- Validate logical provider capacity AND actual LOCATIONS length, and the actual
  separate census/snapshot queue bounds. The census must stay non-retargeting.
- Do not add a second charge for temporary root0: the provider already counts its
  fixed temporary locations. This does not resolve root0's lifetime issue above.

The existing census uses full-queue FILL/CLRHASH, as report-v2 discloses. It is not
an active-only/performance claim. `%PROVIDER-COUNT-LOCATION` still reports
`:OPERATION WORKLOAD-MAPC` on current-source overflow (`roots.lisp:434–440`). A
shared LIST census should use a truthful generic/operation label instead.

The regression constructor varies real cells and FUNCTIONS/SAVED-VALUES arrays,
which is sounder than spoofing counts or resizing active vectors. Its proposed
frame arithmetic is coherent: nonnested caller+LIST = 2; nested caller+MAPC+
ML-callback+LIST = 4. Nested arena = 3 MAPC cells plus N+2 LIST cells. Setup may
still fail before the boundary; only later native execution can settle minima.

No LIST-specific root-token or either queue exact/short matrix is present. This
is disclosed in the reports and remains untested; MAPC's old capacity results
must not be counted as native LIST admission results.

## Host/native closures and narrower oracles

The host model admits valid managed references, symbols, fixnums, characters and
single-floats (`host/object-model.lisp:404–411`). It does not admit arbitrary native
or ML function objects as heap words merely because they are FUNCTIONP. Validate
all input payloads before allocation/stores; the transient host &REST spine is
transport, not a guest list. Do not expand the root walk to arbitrary containers.

The draft's native wrappers retain an owner/runtime or original callable, not an
owned managed payload copy. OWNED-INPUT reloads root15, and movement PREPARE saves
only numeric addresses before allocating. Those facts do not prove arbitrary
native captures safe. A new initializer closure must similarly retain physical
arena cells, not rely on a captured encoded reference after a safepoint.

`RUN-HOST-PAYLOAD-REJECTION` catches any ERROR and accepts a retained configuration;
a late fatal store error can satisfy it. Lines 521–522 acknowledge this, so keep
it diagnostic unless strengthened with exact pre-entry phase/reason, no effects
and open-plan state. Configuration publication alone does not exclude plan fatal.
The graph oracle also omits admitted SINGLE-FLOAT leaves (lines 180–181), so it
cannot yet be reused as a complete admitted-immediate oracle.

## Provenance / limits

`source-pins.json` records all inspected project Lisp sources and the three input
artifacts. Those files remain unchanged. This report is source evidence only;
no native outcomes, capacity passes, new MAPC results, full REST, benchmark or
target claims were produced. Settled MAPC accounting and its implementation stay
separate from this proposed LIST work.
