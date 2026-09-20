# Independent-review repair status

The fixed-snapshot report in [review-ac22bdd.md](review-ac22bdd.md) remains
historical evidence. This file tracks later repairs; passing bounded tests is
not complete paper-v14, language, benchmark or target admission.

## Finalizer registration and token identity

Commit `5f735dd` addresses slot reuse and registration admission. Opaque tokens
now come from a construction-provisioned historical pool. Each has an owner
identity, a historical generation, and its actual record index, assigned before
publication. Resolution requires the current record to hold that exact token.
A private owner key, rather than the registry/configuration itself, prevents a
retained stale token from holding the whole disposed configuration alive.
Tokens contain no referents or callbacks.

`make-sequential-finalizer-registry` has two bounds:

- `:capacity` (F): simultaneous records and at most 2F root locations;
- `:registration-capacity` (H): successful registrations over the registry's
  lifetime, default `max(F,64)` and at least F.

Cancellation or completed draining frees a record but **does not recycle a
historical token**. A full F-record set rejects with `:weak-storage-exhausted`.
An exhausted H-token history rejects with `:generation-exhausted`. No token
object, larger token vector, or registry namespace is allocated at registration.
There is no global mutable registry-ID allocator or ownerless integer token.

The token vector and records, owner key and indexed views are explicitly owned
and charged before publication. Referent admission now requires normalization
and a live authoritative object-start entry in a space owned by this
configuration. NIL, ordinary host values, foreign-model and stale references
reject before record/history consumption.

### Native regression evidence

`(asdf:test-system :clamsara/quality/finalizers/test)` is also selected by the
main test operation. It covers SemiSpace/MarkSweep × packed/scalar starts:

- 12 cancel/re-register histories and 12 drain/re-register histories per profile;
- reuse of a middle hole with other registrations still active;
- correction of live registered referents before later finalization;
- stale tokens not affecting successors and physical-slot publication order;
- cross-registry tokens with a valid destination-registry execution context;
- forged token copies and malformed token values;
- stale/foreign/copied correction tokens returning `:stale` under completed
  real safepoint coverage, with records unchanged and a valid correction control;
- invalid references, callbacks and contexts, followed by valid registration;
- distinct F/H exhaustion with unchanged history on rejected requests;
- fixed token/vector identities and exact retained auxiliary charges;
- ordinary collection and fixture shutdown after history exhaustion.

The original cancel/reuse regression failed natively with
`Reused slot's current token cannot cancel its registration`.
A separate probe of the unchanged review snapshot also failed with
`Registry A's token canceled registry B's unrelated registration`.
The latter used B's valid context, so the failure was token aliasing, not a
context-validation mistake. The repaired registration histories pass.

### Not repaired by this change

- Callback queue ownership and retained-stop cleanup were a separate repair;
  see the next section for its bounded evidence.
- Managed callback admission, callback-support roots, and composed/synchronized
  registry writes are not established by these host-callback tests.
- The paper does not name a foreign-token cancellation error. This implementation
  returns `:already-finalized` without effects for unknown/foreign tokens.
  The exact repeated-cancellation return convention remains a clarification
  question; no such ambiguity permits a stale token to affect a successor.

A source-only independent verification of the fixed registration repair found
no new concrete issue in that slice. It checked identity/state invalidation,
F/H exhaustion, local-reference admission and ownership enumeration, not native
byte totals or callback execution. The native integrated main/tools/workload,
optional-generational and optional-loaded structure gates also pass; the new
accounting test checks actual frozen byte totals.

The registry is therefore **not yet a fully conforming finalizer service**.

## Callback queue ownership and unwind cleanup

The queue repair uses the same fixed F-entry storage as a FIFO ring. A drain
removes an entry and claims its record as running **before** invoking code.
Recursive drains can claim other records, never the running one. Collector
publication appends behind remaining pending work; finishing a callback does
not reset the queue or discard a later collection's batch.

Each drain invocation attempts at most its entry queue length. Newly published
work cannot extend that bound indefinitely. A nested drain can consume work
that would otherwise have belonged to the outer invocation; each return count
counts only callbacks actually invoked by that call.

One unwind cleanup path handles normal return, contained ERROR and escaping
nonlocal exits. An unsuccessful invocation increments the bounded failure count
once. Normal terminal cleanup shares a record-release helper with cancellation.
Execution contexts are pinned while callback frames remain active, including
nested frames: unbind returns `:retry`, and shutdown cannot discard participation.

A nested collection's **result status alone** does not decide whether cleanup
can mutate roots. If the plan resumes open, cleanup can finish. If forwarding
has made the failure fatal and the plan retains the stop, the running record
stays claimed and rooted, outside the queue. It is not recycled, later callbacks
are not invoked, and a normal callback return is followed by
`:collection-busy`. An escaping THROW still escapes after the same root-preserving
cleanup. This is not a recovery path for the closed configuration.

### Native evidence

Run `(asdf:test-system :clamsara/quality/finalizer-drain/test)`; the main test
operation also selects it. The first behavior-only baseline failed **22 of 36**
cases. It confirmed repeated THROW/reentrant invocation, lost appended work,
loss of the active execution context, and execution/root clearing after a
nested collection retained the stop. Ordinary running-reference/closure
retention already passed on that baseline; the repair does not claim to have
invented that behavior.

The expanded repair suite passes **56 cases** across SemiSpace/MarkSweep and
packed/scalar starts:

- Normal, ERROR and THROW completion without repetition or retained terminal roots.
- Recursive drains, plus an inner THROW caught by the still-pinned outer callback.
- Ten repeated interleavings per profile that wrap the FIFO with older pending
  work and newly published batches present at the same time.
- A callback that registers another callback and collects, with bounded work
  per drain and no lost successor.
- THROW after nested publication, then immediate physical-slot reuse while older
  callbacks remain queued; a later collection publishes the reused slot again.
- Running referent and child closure retention through a real collection.
  The test reloads the corrected physical registry root. It does **not** claim
  that arbitrary native Lisp locals are automatically writable guest roots.
- Capacity-one rings and rejection of registration into a still-running slot.
- Rejection of unbinding/shutdown while a callback owns its context.
- Nested conditional-capacity failure followed by normal return, THROW or ERROR.
  Copying retains the stop and roots; nonmoving failure resumes safely and drains
  remaining work. Fatal fixtures are deliberately not “cleaned up” by erasing roots.

A fresh independent verification found no new concrete queue/ownership defect
under serialized hosted execution. Its 16 additional composed cases include
40 wrap/reuse rounds with 200 callback invocations, two execution contexts,
cross-registry collection/escape, recursive drains during unwind cleanup, and
two-deep retained/recoverable failures. Its assertions record failures outside
the callback catcher. See [finalizer-queue-review.md](finalizer-queue-review.md).

Those independent histories are integrated as
`test/quality/finalizer-history.lisp` and selected by the drain test system.
The integrated 56+16 cases and the main/tools/workload/optional-generational/
optional-loaded structure gates pass. The parent's intentional-ERROR fixture
also now requires an outside completion marker after its payload assertion,
so an earlier swallowed assertion cannot masquerade as the intended error.

These are hosted callback-controller tests. Managed callable representation,
callback-support tracing and composed/synchronized registry writes are still
open. They prevent a claim of complete finalizer admission even with the new
queue histories passing. The source-only design note in
[finalizer-callback-design.md](finalizer-callback-design.md) explains the required
object-model/callable representation and actual activation roots. It is a
proposal, not implemented or accepted functionality.

## Allocation request validation

The hosted allocation path now checks kind-specific size and alignment before
raw reservation, refill or collection. A private model bridge interprets the
opaque rules; the allocator does not inspect their representation. Validation
includes exact fixed sizes, variable header/stride/count limits, maximum hosted
object size, and full fixed reference-word extents. Requested alignment must
cover the hosted kind's ABI alignment and fit the route quantum. The rounded
charge is checked against the construction target's arithmetic limit, not CL's
unbounded integer arithmetic.

`clamsara/quality/allocation/test`, also selected by the main tests, covers
168 rejected requests, 36 valid allocation controls and four valid-but-exhausted
requests across both collectors and both start-map representations. Rejections
must leave the rooted object, model planes, allocator state and context state
unchanged. Instrumentation around the real raw/refill/automatic-collection
methods requires no entry on rejection. It delegates normal operations without
stubs. Valid exhaustion still takes the normal refill/collection path and reports
`:heap-exhausted`, rather than being mislabeled as an invalid size.

The native baseline signaled `Invalid hosted object initialization` for a
positive wrong fixed size. The expanded repaired suite and integrated
main/tools/workload/optional-generational/structure gates pass. The bounded
[source-only review](allocation-admission-review.md) found no new concrete defect
for stable hosted descriptions. Its suggested exact arithmetic/model-size/
conditional-word boundaries and ordinary signaling-rule checks were then added
and passed natively. This is not a claim of complete object-model admission: binding-time descriptor snapshots,
function-rule stability and all other representation capacities still need an
audit. In particular, source inspection shows that binding currently copies the
kind vector while retaining its description objects; later mutation/stability
has not been independently exercised in this repair.

## Other confirmed review findings

Still open: under-admitted model representation capacity, and composed CAS event
ordering and mismatch exposure-fault closure. These have not been waived by
passing existing component suites.

## Generational recovery

Commit `31e73a4` fixes the separate mature-capacity/major-recovery defect and adds
96 conditional combinations plus 288 independently written graph-oracle cycles.
See [generational.md](generational.md) for policy, geometry and limits. This does
not repair shared-core failures listed above.
