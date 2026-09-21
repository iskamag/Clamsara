# Scoped fixed-source review: the MAPC overlays

## Scope and verdict

Reviewed the three frozen production overlays in
`/tmp/clamsara-mapc-draft-wd3ba0th` against the committed-code snapshot `52e08f1`.
The parent identifies `3a5a867` as a docs-only successor with the same baseline
code. Hash comparison finds exactly these three changed production Lisp files:

- `src/workload/roots.lisp`
- `src/workload/control.lisp`
- `src/workload/maclina.lisp`

**No definite supported-ML MAPC correctness defect remains identified in this
source review.** The scoped design addresses the one-list-only implementation,
physical root/cell ownership, bounded admission and nested scope release without
a Maclina patch. This is not full conformance approval. The two stronger test
oracles below are new unexecuted source and remain gates before final acceptance.
This review does not approve any later integrated commit without matching hashes.

## Production source findings

### `maclina.lisp`

The old one-list native helper now accepts the native transport argument list and
calls `%WORKLOAD-MAPC`. The later guest `(lambda (function list) ...)` replacement
is removed, not left as a competing implementation. Existing source-mode dispatch
still selects native syntax MAPC only during compiler source execution. Ordinary
guest MAPC uses the managed-list implementation. The adapter does not add guest
REST, edit the fixture, or replace global Common Lisp/Maclina definitions.

### `roots.lisp`

Provider setup provisions distinct snapshot/census walk records, bounded queues
and seen tables, and actual cons cells for native activation storage. Snapshot
and census share the source classifier. Physical source locations are counted
separately even when values alias; only known control objects are identity-deduped.
Known closures retain their actual template/environment and writable capture
cells; functions retain modules and literal slots. Arbitrary native containers
are not newly scanned as guest payload.

The census actuator counts/checks token bounds rather than installing descriptors.
It uses a different walk from the snapshot and clears that scratch even on error.
Protected refresh remains the path that clears/retargets descriptors. This is
visible in the source and was structurally exercised by the existing native tests;
V3 strengthens the identity check for descriptor SOURCE and SOURCE-INDEX.

### `control.lisp`

For N lists, admission accounts for 2N+1 native cells, required activation slots,
actual token/vector limits, both control queues, and the actual VM entry bound.
For an ML function/closure it includes N argument slots plus the template locals
frame. It scans existing future local control contents rather than fabricating
NIL initialization. Active native extents are the reservation counted by nested
admission; there is no new persistent callable registry or fake capacity counter.

The operation resolves symbol designators through the current Clostrum workload
environment. The actual resolved callable occupies FUNCTIONS. SAVED-VALUES owns
a distinct original-return cell, cursor cells and an argument-row suffix. The
suffix passed to APPLY is the registered physical chain, not an unrooted copy.
Managed cursors/return values are reloaded from those cells after callbacks.
Nested scopes use disjoint portions of the preallocated arena. Cleanup releases
only the current extent and restores its counts; it does not erase VM-VALUES on
nonlocal exit. The return transfer has no managed allocation between reloading
the return cell and its caller receiving the value.

The early empty-list path claims no unused native scope and invokes no callback.
For proper nonempty lists, the loop calls left-to-right and stops at the shortest
list, returning the original first list. Invalid/circular/mutating-list behavior
was not used to manufacture acceptance. Native callback compatibility remains,
but native FUNCTIONP alone is not claimed as managed-local/capture ownership.

## Existing evidence: retain the original accounting

Parent-reported evidence for this frozen draft: strict nine-group run PID 18283
passed 9/9, including formerly unreachable managed ERROR/THROW/retry and DDERIV
load-property gates. The parent also reports its full component/workload gate
passed. Those are parent runs, not new executions by this review.

First-hand capacity evidence is the preserved PID **19086**, exit **0**,
**12.130560814 seconds**, under `../capacity-native-7l6mqmdt/`:

- 3/3 top-level groups passed.
- Roomy calibration + all 12 physical boundary cases + two witnesses = 15 owners.
- All 15 owners discharged/closed. No unexpected construction/admission/callback
  failure occurred.
- Exact/one-short boundaries: tokens 208/207, frames 2/1, native cells 5/4,
  snapshot queue 23/22, census queue 23/22, stack 68/67.
- All six short cases rejected actual nonempty MAPC before callback/effects.
  Five exact non-stack cases invoked the ML callback. Exact stack remains private
  entry admission only, not a full nonempty callback capacity result.
- 12 empty retries, 25 observed protected snapshots, 10 moving cycles.
- Snapshot witness checksum 65; nested two-inner-rejection witness checksum 47.
- Source/fixture/shared Maclina pins were unchanged.

Two limits in that evidence must not be erased or retroactively upgraded:

1. V2 checks physical arrays/cells with EQ, but descriptor SOURCE and SOURCE-INDEX
   were only in structurally compared data. An EQUAL but distinct cons source/key
   could evade that specific no-retarget oracle. No such production mutation was
   observed or found by source inspection; the oracle itself still needed repair.
2. Its empty retries prove the valid empty path, not nonempty capacity recovery.

## New independent strengthening source — NOT executed

`capacity-ownership-v3.lisp` is a new full source revision. V1, V2, logs and old
counts are unchanged. `v2-v3.diff` records all new source changes.

- CAP-STATE adds every descriptor SOURCE to its EQ identity list. It records each
  SOURCE-INDEX separately and compares with EQL: numeric index value/type is
  preserved, while nonnumeric property-key identity cannot be replaced by a
  structurally equal cons.
- CAP-OBSERVER-SELF-CHECK creates only synthetic metadata. It requires unchanged
  sources to pass, EQUAL-but-distinct source and index conses to fail, and equal
  numeric indices to pass under EQL. It touches no actual provider descriptors.
- CAP-RUN-SMALLER-NONEMPTY-RECOVERY uses a four-cell arena. A real two-list call
  must reject its five-cell demand before effects. A subsequent one-list call
  then uses a three-cell extent, executes two callbacks across real collections,
  checks checksum 34 and the returned `(11 13)` list, and discharges/closes.
- CAP-RUN-POST-OUTER-NONEMPTY-RECOVERY is a separate history. After the five-cell
  outer scope completes despite two inner admission rejections, a new nonempty
  two-list call must reuse the released five cells. Intended cumulative checks
  are three callbacks, checksum 112 (47+65), three moving cycles, intact returned
  `(11)` list, zero active extents, discharge and close.

These are intended assertions, not observations or passes. The two runtime
histories are additional tests, not additions to PID 19086's 15 owners. The
synthetic observer self-check is not a runtime history. Static parenthesis balance
is zero; native read/compile and execution remain pending. No production, dependency
or fixture changes and no native execution occurred while authoring V3.

## Remaining boundaries

The census reserves the present native scope and known ML callback entry, not
arbitrary future callback work. Existing future local controls can conservatively
increase a bound; the measured capacities are not universal minima. Native
callback locals/captures require their separate foreign-lifetime contract.
Common-walk census equality cannot by itself detect roots missing from both walks;
actual moving graph checks remain necessary. These hosted tests do not establish
supervisor/Mezzano allocation freedom or target admission.

DDERIV load/property identity is not its complete computation/lifecycle. Full
Gabriel acceptance, owner-driven fixture discharge, quoted/linker/in-flight
ownership and other documented representation/compiler holds remain separate.
LIST was not investigated or changed in this task. No benchmark source or
parameter was reduced, no payload exemption was widened, and no upstream patch
was applied.

## Provenance

`provenance.json` pins baseline/overlaid source hashes, original V1/V2 sources and
native evidence, and this unexecuted V3. The three `*-production-overlay.diff`
files show the reviewed changes. The native command, all owner/case counters and
pre/post pins remain in the original capacity run directory. This review does
not relabel those old results with V3's stronger oracle or recovery coverage.
