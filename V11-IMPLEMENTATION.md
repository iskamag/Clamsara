# V11 implementation notes

Status of the paper-v11 migration in this tree.  paper-v11
(`paper-v11/clamsara-v11.tex` plus `paper-v11/chapters/`) is the normative
specification.  This file records what slice S1 implemented, why, and what
remains.  It is documentation, not a claim of conformance.

## Slice S1: protocol systems and adapters

### Systems

`clamsara.asd` defines six independently loadable protocol systems, each with
`:depends-on ()` (nothing but Common Lisp), one file per system under
`src/protocol/`:

| system | contents | paper source |
|---|---|---|
| `clamsara/protocol/object-model` | valid-reference-p, object-start-p, object-size, object-kind, map-reference-locations, load-reference, store-reference-raw, initialize-object, copy-object-representation, reference-equal, offered-metadata-fields, field-read, field-write, field-cas | client-protocols.tex section 1 |
| `clamsara/protocol/roots` | with-root-snapshot, map-root-locations, load-root, store-root, root-location-kind | client-protocols.tex section 2 |
| `clamsara/protocol/coordination` | request-safepoint, await-safepoint, release-safepoint, current-mutator, begin-epoch, await-epoch, publish-fence | client-protocols.tex section 3 |
| `clamsara/protocol/atomics` | atomic-load, atomic-store, atomic-cas, atomic-fetch-add, atomic-bit-set, atomic-bit-clear, fence | client-protocols.tex section 4 |
| `clamsara/protocol/address-space` | managed-arena-offer, validate-managed-layout, install-managed-layout, space-of-reference, update-space-ownership, reserve-virtual-range, map-logical-pages, unmap-logical-pages, remap-logical-pages, protect-logical-pages, flush-address-translations | managed-layout.tex sections 2 and 5; client-protocols.tex section 5 |
| `clamsara/protocol/diagnostics` | monotonic-clock, fatal-diagnostic | client-protocols.tex section 6 (prose only, see below) |

The main `:clamsara` system depends on all six and adapts them over the
existing simulator client (`src/protocol/adapters.lisp`).  `CLAMSARA` imports
the protocol generics so migrated code names them without package qualifiers.

### Why the mapping protocol lives in clamsara/protocol/address-space

Earlier review discussed mapping as a separate family.  The decision: mapping
stays in the address-space protocol system, and this is deliberate, not
silence.  Reasons:

1. paper-v11 architecture.tex section 2 ("System decomposition") names exactly
   five protocol systems; the mapping mechanisms are not a sixth entry in that
   diagram.  The same section says the decomposition is "a dependency
   discipline, not a demand for one ASDF system per line".
2. client-protocols.tex section 5 presents mapping as one client's optional
   capability, supplied by the same subsystem that owns page tables and fault
   delivery (wonderworld.tex section 7 and managed-layout.tex section 6 put
   frame allocation and fault delivery on the same implementation client).
   There is no paper text that gives mapping its own protocol family, and no
   consumer that needs mapping without address-space.
3. Dependency discipline is preserved either way: both mechanisms are
   leaf-optional capabilities, and no protocol system imports another.

If a later revision of the paper splits the mapping seam out, the move is
mechanical: one defpackage/defsystem plus re-pointing the adapter methods.

### clamsara/protocol/diagnostics is an implementation-named seam

client-protocols.tex section 6 ("Clock, diagnostics, and fatal failure")
states obligations in prose and names no interface.  `monotonic-clock` and
`fatal-diagnostic` are this implementation's names for that unlisted seam and
are marked as such in the protocol file header.  If the paper later names
them, the names migrate.

## Adapter design

* **Locations are raw addresses, not records.**  A reference location is the
  simulator heap word address of the slot (fixnum, opaque to core): `addr+1+k`
  for headered objects, `addr+k` for headerless conses.  A root location packs
  `(vector-id . cell-index)` into one fixnum; vector-id 0 is the global root
  vector, 1+r is registered root region r.  No per-visit allocation on any
  collection path, measured by `V11-ADAPTERS-NO-ALLOCATION`.
* **A root snapshot is the client object itself.**  The single-stream
  simulator cannot change its root set between WITH-ROOT-SNAPSHOT and
  MAP-ROOT-LOCATIONS except through the caller; a distinct snapshot object
  would carry no information and would allocate on a collection path.
  A concurrent backend replaces this with real snapshot state.
* **Tokens identify their client.**  Safepoint tokens and epoch tokens are
  the VM-owned coordination-state record; a token from another client rejects
  on EQ.  `coordination-state` gained a boot-preallocated `epoch-open` flag
  (src/vm/binding.lisp): one outstanding epoch per client, BEGIN rejects
  while open, AWAIT establishes quiescence and closes, stale tokens reject.
  Safepoints follow the same discipline: AWAIT/RELEASE require the client's
  token AND an active stop interval; a released token is stale and rejects.
  A repeated REQUEST for the same active stop is documented idempotent.
* **Order validation.**  Atomic operations validate ORDER against the
  operation's admissible set (loads reject release, stores reject acquire,
  relaxed fences reject); the single-threaded simulator then gives every
  admitted order the same observable semantics.
* **copy-object-representation does not delegate to vm-object-copy.**  The v8
  seam transfers mark/age/public/log/weak side metadata, which paper-v11
  assigns to the movement component (client-protocols.tex section 1;
  strata.tex section 3).  The adapter copies payload and ABI words only and
  touches no strata.  The v8 seam remains for the existing collectors and
  migrates with the movement slice.
* **Honest unsupported boundaries** (signal clamsara-error, never fake):
  offered-metadata-fields is empty and field-read/write/cas reject (the
  simulator offers no field objects); initialize-object rejects headerless
  conses; root/coordination scopes other than :all/:global reject
  (owner/request scopes need mutator identity the simulator lacks);
  update-space-ownership rejects (the boot-time SFT has no reassignment
  path); mapping adapters are exact delegations to the software MMU.

## Version policy

The main `:clamsara` system stays at version 9.0.0 while the migration is
incomplete; its description says "v11 migration in progress".  The protocol
surface systems are versioned 11.0.0 because their contracts are exactly the
paper-v11 reference interfaces.  Version promotion of `:clamsara` is gated on
the conformance ledger below covering every normative requirement the paper
names, not on protocol seams alone.

## Slice S2: portable component construction kernel

`clamsara/core` (`src/core/component.lisp`, package `CLAMSARA-CORE`) is a
Common-Lisp-only system.  It implements all seven exact component generic
lambda lists in composition.tex.  This is additive while the legacy collector
classes migrate; it does not wrap a target-specific collector and call that
v11 conformance.

`BUILD-CONFIGURATION` performs the seven semantic phases in order:
construct/discover, merge, layout callback, bind, initialize, validate, and
activate.  Discovery is deterministic, deduplicates diamonds, rejects ordinary
cycles, and accepts only a shared non-NIL explicitly declared cohort.
Resources merge compatible partial facts into one canonical handle, refine
unspecified attributes from later providers, retain provider/consumer
provenance, and reject missing providers before layout with the requiring
component and dependency path.  A configuration is published only after all
fallible hooks complete.  Failure after initialization runs reverse cleanup
and publishes nothing.

Once published, the component graph, resource set and provenance, constraints,
phase record, layout, and resource geometry stay sealed even after deactivation.
Lifecycle code owns the state transition; there is no public state or seal
writer.  Runtime component slots remain mutable.  The resource/configuration
record shapes and `COMPONENT-COHORT` are documented implementation interfaces,
because paper-v11 specifies their semantics but not their record layouts.

`test/v11-component-contract.lisp` is a standalone contract suite wired as
`clamsara/core/test`.  It currently performs 67 checks covering order,
diamond deduplication, provenance/refinement, conflicts and missing paths,
cycle/cohort behavior, exact phases, validation and activation rollback,
publication, permanent immutability, mutable runtime state, and reverse
shutdown.

## Slice S3: managed layout and logical metadata kernels

`clamsara/core/managed-layout` implements construction-time arena validation,
constraint solving, derived metadata sizing, complete-solution audit, client
validation and installation, dense page ownership lookup, and explicit
quiesced ownership epochs.  Failed or ambiguous compositions signal structured
conditions and never install a partial map.  `LAYOUT-SPACE-AT` uses a
boot-built arena index and dense fixnum page tables.  Its first-call and
repeated direct lookup windows report zero host bytes.

`clamsara/core/metadata` implements metadata declaration validation,
deterministic provenance-preserving merge, placement narrowing, offered-field
compatibility checks, layout-mediated side-vector and side-table binding, and
the scalar/bit/range/fold/project operation families.  It distinguishes the
paper's required semantics from implementation-chosen records and field
guarantee plists.  Field incompatibility and unavailable placement alternatives
reject construction explicitly; there is no silent downgrade.  Dense vectors
use the supplied atomic client when required; the portable kernel contains no
SBCL primitives. Side tables use preallocated key/value/occupancy arrays with
bounded linear lookup and explicit capacity exhaustion, without runtime growth.
Bound dense side-vector operations report zero host bytes in warmed hosted
windows. These measurements do not establish first-call deployment safety.
Binding performs no runtime warmup or recompute calls. CLOS closure is
Snowgrave's responsibility; Clamsara owns bounded runtime storage and avoids
allocation in its algorithm bodies.

These are independent portable kernels below the legacy collector system.
They do not by themselves make a legacy plan v11-conformant.  Their standalone
contracts are ASDF systems and are also prerequisites of `clamsara/test`:
managed layout has 84 checks and metadata has 143 checks.

## Integrated correctness and hot-path repairs

- StickyImmix now shares the span-aware Immix sweep.  Dead medium-object spans
  release all blocks, and a sticky major no longer clears heap-wide marks
  before LOS reclaim can observe rooted large objects.
- LOS live extents use a boot-sized dense page-indexed fixnum vector instead of
  a host hash table.  `%LOS-ALLOC`, `%LOS-FREE`, and `%LOS-RESET` are direct hot
  bodies behind the existing generic interface.  The measured direct bodies
  report zero host bytes for first allocation, 100 repeated allocations, 101
  frees, and reset; CLOS dispatch is outside those windows.
- RC records reserve whole events against `ARRAY-TOTAL-SIZE` (not vector
  `LENGTH`, which is the fill pointer), append without a second reservation,
  cancel exact same-superblock replacements, and never expose torn triples.
  Claimore folds only complete used triples at every sealed collection
  boundary, normalizes opaque/coloured references before SB lookup, and clears
  the log only after a successful fold.
- Direct Maclina `LIST` source calls use the Clostrum compiler-macro seam to
  expand to nested simulated `CONS` calls while the ordinary function remains
  available to `FUNCALL` and `APPLY`.  The redundant `REVERSE` copy is gone.
  VM call frames, argument windows, return positions, values, dynamic
  environments, and global root cells are preallocated or construction-bound.
  First and repeated direct CONS, functional LIST, direct compiled entry, and
  compile-string-bound entry windows report zero host bytes, including runs
  that trigger collections.  Global simulated references are reread through
  registered stable root cells after moving collection.

## Conformance ledger (open blockers)

1. **fatal-diagnostic is allocating.**  The portable/simulator implementation
   signals clamsara-error through a format message, so it allocates and
   dispatches through CLOS.  It satisfies the diagnostic CONTENT obligation
   (client-protocols.tex section 6: report the violated invariant) but not the
   supervisor deployment's allocation-free fatal-path obligation.  A deployed
   profile must lower the generic to a direct, preallocated fatal sink, and
   conformance requires measuring that on FIRST CALL, not warm calls.  Nothing
   in the simulator fakes this.
2. Collector internals (heap, plans, phases, barriers, weak, persistence)
   still run on the v8/v9-lineage architecture and do not conform to
   paper-v11's component model, construction phases, managed layout, barrier
   transactions, phase declarations, move-epoch lifecycle, ephemerons,
   Wonderworld split, or adversarial scheduler requirements.  Each is a later
   migration slice; the full audit list is in the v11 spec audit report.
3. Canonical Gabriel coverage is still constrained by unsupported source/runtime
   features.  Each skipped reference file must name the exact missing feature;
   lookalike workloads are smoke tests, not canonical evidence.

## Tests

`test/test-v11-protocols.lisp` registers in `:clamsara/test` and checks:
protocol systems are findable with empty dependencies and load in a fresh
image without :clamsara (`V11-PROTOCOL-SYSTEMS-INDEPENDENT`); adapter
contracts per protocol, including every unsupported boundary; order
validation; token staleness/overlap rejection; and the measured
no-per-visit-allocation property (`V11-ADAPTERS-NO-ALLOCATION`).

`clamsara/core/test`, `clamsara/core/managed-layout/test`, and
`clamsara/core/metadata/test` run the 67-check component, 84-check managed
layout, and 143-check metadata contracts.  `asdf:test-system :clamsara/test`
orders all three before the legacy FiveAM core suite.

Cleanup validation: the baseline core suite passed 214 tests. After the kernel
repairs, the standalone layout and metadata suites passed 84 and 143 checks.
Gabriel passed 36 workload results and GCBench passed nine plans with a 4 GiB
SBCL host heap; a previous combined run exhausted the default 1 GiB host heap
while compiling TAKR. The canonical skip reasons still need refreshing against
the current Maclina runtime. The construction-phase mismatch with v11 remains
open; these kernels do not establish full v11 conformance.
