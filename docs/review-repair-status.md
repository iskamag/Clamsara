# Independent-review repair status

The fixed-snapshot report in [review-ac22bdd.md](review-ac22bdd.md) remains
historical evidence. This file tracks later repairs; passing bounded tests is
not complete paper-v14, language, benchmark or target admission.

## Finalizer registration and token identity

The first repair addresses slot reuse and registration admission. Opaque tokens
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

- Callback THROW/reentry can still repeat invocation in the old drain path.
- Callback-triggered collection can still lose newly pending work there.
- Safe retained-stop behavior during callback cleanup remains unproved.
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

## Other confirmed review findings

Still open: under-admitted model representation capacity; composed CAS event
ordering and mismatch exposure-fault closure; invalid positive allocation-size
admission before collection or other effects. These have not been waived by
passing existing component suites.

## Generational recovery

Commit `31e73a4` fixes the separate mature-capacity/major-recovery defect and adds
96 conditional combinations plus 288 independently written graph-oracle cycles.
See [generational.md](generational.md) for policy, geometry and limits. This does
not repair shared-core failures listed above.
