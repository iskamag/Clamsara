# Final CAS review addendum

Snapshot: `/tmp/clamsara-cas-final-review-pvyqoprb`.
This addendum does not replace or rewrite the prior HOLD report at
`/tmp/clamsara-cas-fixed-review-byz5pwd5/independent-review/cas-fixed/report.md`.
That earlier snapshot really failed 1 of 156 histories: irrecoverable fatal
shutdown returned `:RETAINED` and changed published shutdown state.

## Result and scope

**The narrow shutdown defect is repaired in this snapshot. The scoped independent
hosted gate passes: 176/176 histories, PID 12020, exit 0, 2.628832073 seconds.**

- The original 94 and additional 62 histories are loaded unchanged: 156 pass.
- Twenty new independently authored public-resource and transform histories pass.
- Forty-six expected-fatal worlds remain rooted/closed and retained until process
  exit. No failed world remains in this successful run. Nothing is force-closed.
- All 106 manifest pins remain unchanged: 41 production, 51 tests/ASDF, 14 paper.
- No production, live fixture or dependency changes were made. No subdelegation.

This is bounded hosted evidence for this CAS repair, not whole-paper conformance,
arbitrary author admission, optimal all-event resource admission, concurrent
synchronization or Mezzano safety. The boundary limitations below still apply.

## 1. Narrow shutdown fix independently verified

The only production change since the prior reviewed snapshot is in
`src/runtime/cycle.lisp`. Fatal preflight now signals `runtime-rejection` with
`:FATAL-INVARIANT` before the generic shutdown entry changes configuration state.
The defensive fatal drain branch likewise rejects instead of returning
`:RETAINED`.

The unchanged exact history now reports:

```
outcome=:REJECTED reason=:FATAL-INVARIANT unbind=:RETRY
configuration=:PUBLISHED -> :PUBLISHED
construction=:PUBLISHED -> :PUBLISHED
resource release index=0 -> 0
```

This removes the unsupported recoverable outcome. `construction.tex:391-394`
reserves shutdown's `:RETAINED` result for a recoverable movement/image obligation.
The new rejection preserves the pre-existing fatal state, roots, pins and resource
ownership, consistent with no-new-effect rejection (`reading.tex:25-31`) and the
closed diagnostic path (`clients.tex:480-484`). It does not promise recovery or
reclamation of an irrecoverably failed heap. The prior HOLD is cleared for this
specific defect, not retroactively erased from the earlier snapshot's evidence.

## 2. New proof: actual public resource contributions and claims

The new package `clamsara.cas-final-proofs` builds a real plan with the existing
`make-quality-world :configure-plan` seam. It adds a public resource contribution:

- identity `:INDEPENDENT-CAS-POOL`;
- representation `:RUNTIME-OBJECT-VECTOR`;
- logical capacity 3 in the undersized case, 4 in admitted cases;
- checked by the normal builder and acquired through the real resource provider.

Four opaque contributions have the explicit order W1 -> R1 -> W2 -> R2. W rules
subscribe only to CAS; R rules only to READ. Each declares a public reservation
claim for one simultaneous entry of that same named resource and representation.
Their claim sum is 4. The test independently reads the public descriptions and
`construction-resource` result and confirms the actual acquired handle, logical
capacity and vector length. Runtime reserve consumes **that same resource vector**,
not a second marker array or an assumed capacity. An opaque token is its slot
index and contains no borrowed location or managed reference.

Each rule refuses a second outstanding reservation for itself, even if another
pool cell is free. This enforces its claimed maximum 1 across competing calls
rather than relying on the single-caller test schedule. The finite pool also
bounds total ownership. This source rule is not a concurrent synchronization proof.

Fifteen new resource histories establish:

1. Capacity 3 rejects with `:BARRIER-CLAIM-CAPACITY-EXHAUSTED` and resource paths.
   The barrier was not published, the runtime pool was not initialized, and the
   real acquired resource/transaction are released by unpublished unwind.
2. Capacity 4 admits and uses exactly the acquired four-entry pool. All four
   claims are owned simultaneously before admit, and admit precedes the sole raw
   load. A matched CAS consumes each once, then a later CAS reuses the same pool.
3. Mismatch still reserves the simultaneous union. It reverse-cancels W2 then W1,
   exposes/consumes only R1 and R2, makes no store and later reuses all entries.
4. Reserve/admit/transform retry at each of the four rule positions: exact owned
   membership, reverse cancellation, zero store/exposure, the correct 0-or-1 raw
   load count, no candidate return, no leaked pool entry, and later successful reuse.

These are scoped native public-claim/capacity observations supporting
`construction.tex:145-153` and `execution.tex:166-178`. They are stronger than the
previous zero-claim marker histories. They do **not** prove that the builder's
all-contribution sum is optimal for every mutually exclusive event set or profile.
No overlapping READ+CAS contribution or invented two-reserve lifecycle is used.

## 3. New proof: managed non-identity transforms and actual post-GC graph

Five new histories use the same real claimed pool and managed heap objects.
Both read and write paths have two non-identity transforms:

```
raw old 702 -> READ intermediate 704 -> returned observed 705
caller new 703 -> CAS intermediate 706 -> stored final 707
```

The numbers are immediate IDs in real managed objects, not substitute host graph
nodes. Every target is kept in a registered root. Target references are fetched
into the test's entry bindings **before** binding the raw-operation observer, so
incidental root reads cannot masquerade as the barrier's required raw slot load.
Reservations/logs contain no managed references or borrowed locations.

The histories establish:

- A match against raw old 702 succeeds even though the returned read value is 705.
- Expected 705 mismatches raw old 702 even though READ processing returns 705.
  Write transforms do not run and the slot remains 702.
- A plain composed read returns 705 without a store.
- READ-transform and late CAS-transform retry discard their computed managed
  candidates, reverse-settle the real pool, leave raw old unchanged, and succeed
  on a later invocation with newly derived location.
- Both before and after callbacks see raw old 702, not either intermediate.
  READ callbacks see final 705; CAS callbacks see final 707. Exposure uses frozen
  W1,R1,W2,R2 order on match and only R1,R2 on mismatch/read.
- The raw physical slot is checked independently: 707 on success, 702 otherwise.
  Each completed operation has one observed raw slot load and 1-or-0 stores.

After each transform history, the entry-only rooted transform bindings end.
The test drops all independent target roots while retaining only source 701.
It then performs **two genuine collections**, each followed by the real managed
root/object graph oracle. The collector itself is unchanged and scans actual
stored edges. The author test transforms are entry-scoped; they do not rewrite
scanner results or manufacture the oracle's physical graph.

The expected surviving graphs are:

```
match:         701 -> 707 -> 708
mismatch/read: 701 -> 702 -> 709
```

All other edges are NIL. The first collection must report six dead objects from
the original nine. Both collected graphs and the sole surviving root must agree.
This detects storing caller-new, a read target, an intermediate, or losing the
intended final target; a returned-value-only check could miss those defects.

## 4. Evidence provenance and integrity

Canonical new file: `claims-transforms-03.lisp` (20 histories).
It uses unchanged real fixture builders plus the shared test-only raw `:BEFORE`
observer hook. It does not redefine a production method or modify an old assertion.
New contribution/resource implementations are authored test components, not
stubs for runtime operations. The fixed 1024-cell observer contains only symbols,
fixnums and NIL. Bounded observation storage is not an allocation measurement.

Canonical run: `bootstrap-02.lisp`, `native-02.log`.
The bootstrap selects private ASDF source/output roots and asserts the actual
system source directory. It loads the original `acceptance-03.lisp` and
`additional-05.lisp` unchanged before the new proofs. `native-results.json` records
commands, PIDs, exact duration and hashes. `source-pre-sha256.json` and
`source-post-sha256.json` cover all 106 snapshot pins.

The initial run (PID 11947, exit 0, 2.610284934 seconds) also passed 176/176. Its
new test contributor was then strengthened to enforce the per-rule maximum across
competing invocations, and the canonical run passed again. This was a test-author
contract strengthening, not a production fix or a prior failure hidden from the
record. Drafts and both logs remain unchanged.

Warnings in both combined replays come from the preserved older 156-history
review helper's deliberate raw `:AROUND` counter and world-helper redefinitions.
The new proof package uses the shared `:BEFORE` hook and adds no such replacements.
There is no clean-warning or target no-allocation claim.

## 5. Boundaries still explicit

- **OPERATION wording:** `execution.tex:129-139` does not expressly choose outer
  operation versus selected event path. Disjoint event dispatch is internally
  consistent, but the paper wording gap is not resolved by passing tests.
- **Dual composition:** READ+CAS overlap remains rejected with an explicit
  specification complaint. These tests do not invent one-versus-two token semantics.
- **Opaque admission:** NIL applicability probes still do not establish all
  legitimate token/context/location-specialized author methods or effective-method
  non-failure. The earlier limitation remains unchanged.
- **Context accounting:** the new plan pin is measured in construction storage;
  dynamically bound context state and N/N arrays are provisioned before publication
  but are outside the immutable construction account. The earlier separate hosted
  measurements remain evidence, not an aggregate proof for arbitrary populations.
- **Targets/concurrency:** no Mezzano residency, supervisor dispatch, machine memory
  ordering, lock-free attempt rollback or general concurrent capacity proof is made.
- Indexed/name/staged-handle work remains outside this CAS acceptance scope.

The exclusive native slot is released. Both retained handles are complete, and no
new native process will start without another handoff.
