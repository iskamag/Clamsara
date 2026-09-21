# Independent bounded CAS acceptance baseline

This is a native follow-up to `report.md`, authorized by the parent's later
native-slot handoff. The original source/spec report remains a record of the
source-only review. This follow-up is not target or full-conformance evidence.

## Canonical artifacts

- `acceptance-03.lisp`: 94 independently authored acceptance histories.
- `bootstrap-03.lisp`: explicit private ASDF source registry and output translation;
  asserts the frozen snapshot is the actual `clamsara` source directory.
- `native-03.log`: complete final baseline output.
- `source-native-03-sha256.json`, `source-native-03-post-sha256.json`: 104 source,
  paper, ASDF and test pins before/after the native run.
- `native-results.json`: commands, retained PIDs, exit status, artifact hashes,
  result labels and provenance.
- `acceptance-02.lisp`, `bootstrap-02.lisp`, `native-02.log`: preserved first native
  run, 93 histories. Version 03 adds the post-fatal public-unbind/shutdown history
  and checks that a dual rejection reports a non-NIL symbolic reason.
- `acceptance-01.lisp`: preserved unexecuted draft. Its misspelled condition type
  `construction-error` was corrected to the real `construction-rejected` in 02
  before any native startup. It is not evidence of an implementation failure.

Only the parent's `make-cas-world` construction function was reused, with naming
changes. It is clearly delimited in the case file. The opaque test contributions,
observer, settlement accounting, all assertions and runner are independently
authored. The shared real `clamsara/quality/support` fixture is loaded unchanged.

## Result

Final baseline: **94 histories, 58 pass, 36 fail; PID 10102, exit 1.**
There were no compiler warnings. The strict runner errors whenever any history
fails. The earlier run was PID 10020, exit 1, with 58/93 passing.

All 104 before/after pins are identical. All 41 production hashes and all 14
paper TeX hashes still match the review manifest. No production, live fixture or
dependency changes occurred. ASDF outputs are only under this review directory.

| Histories | Pass | Fail | Observed baseline behavior |
|---|---:|---:|---|
| Legitimate reserve/admit/transform RETRY | 57 | 0 | Exact-once reverse cancellation; no exposure/store; bounded raw-load counts; later successful reuse |
| Second-context busy contention | 1 | 0 | Independent scratch, reverse cancellation of contender, outer consumption once |
| Before/after ERROR/THROW across match, mismatch, read, store, root-store | 0 | 20 | All allowed later allocation, bind and collection after escape |
| Same-context reserve/admit/transform reentry | 0 | 3 | Reserve reentry executes an inner load; later reentry erases outer ownership |
| Active unbind/collection at reserve/admit/transform | 0 | 6 | Unbind destroys live scratch; collection runs while the raw location interval is active |
| Disjoint mismatch/match/read-first controls | 0 | 3 | Forward write-only cancellation, event-major exposure, READ rule reserve/admit gets CAS |
| Unreturned-reservation ERROR/THROW | 0 | 2 | No raw load/store, but state with an unknown acquired token remains open |
| Fatal public-unbind/shutdown | 0 | 1 | Public unbind succeeds; shutdown blocks, but the plan remains open |
| Ambiguous dual READ+CAS rejection | 0 | 1 | Construction publishes the ambiguous dual contribution |

### Passing RETRY cases

The single-path matrix is all 5 operations x all 3 retry phases x first/middle/last
rule: 45 histories. The mixed W1 -> R1 -> W2 -> R2 matched-CAS matrix tests all
4 rules at all 3 retry phases: 12 histories. All 57 also rederive the location and
complete a later invocation. The token counters check acquisitions equal exactly
one cancel or consume, with no active token left. The mixed tests witness ownership
across both subscribed sets; they do not prove resource claim/capacity admission.

### Fatal matrix evidence

Faults are injected in the first applicable before or after callback. The log
checks that later callbacks did not run, that before faults precede the raw store,
that after faults follow the required store, and that no ordinary cancellation
occurs after exposure. The frozen implementation sends matched/read/store/root-store
ERROR through its fatal diagnostic but still leaves other heap entry routes open.
Mismatch ERROR escapes as an ordinary error. Every injected THROW escapes through
the rule's nonlocal-exit tag instead of the fatal tag.

All 20 cases then independently attempt allocation, binding, collection and
shutdown. The first three are allowed in every baseline world. Shutdown is blocked
by active contexts; its release index remains 0. **That shutdown result is not
proof of sticky fatal closure.** The additional public-unbind case also preserves
registered roots and sees no resource release, but still detects the open plan.
The repaired implementation must not release a poisoned world's resources merely
because its context can later be unbound.

### Active collection and reentry evidence

Reserve-phase same-context reentry causes two raw loads and consumes an inner
frame before the outer invocation resumes. Admit/transform reentry leaves outer
tokens active without a matching terminal call. The separate-context contention
control passes, so the same-context failure is not a generic failure of every
nested attempt.

Active collection at reserve/admit invalidates the outer reference-location lease;
subsequent access reports a stale location. At transform it contributes additional
raw loads and returns while the protected interval is live. The history requires
pre-entry collection rejection with the caller-owned cycle record unchanged,
not a new stop/recovery policy.

## Ownership, roots, and failure retention

Each world is built through real `construct-plan` and public allocation. Source,
old and new are placed in registered roots; the tested root-store has its own
registered root. Successful ordinary histories clear roots, collect, unbind and
shut down through the existing real fixture. Failed worlds are retained in
`*failed-worlds*` until process exit and are not force-closed. Expected fatal
passes would remain rooted and closed in `*expected-fatal-worlds*`; the baseline
has zero such passes. No cleanup mutates plan state or bypasses root/retirement
protocols to make a case appear to pass.

The rule observer uses a preallocated 1024-cell vector containing only symbols,
fixnums and NIL. Each rule has two preallocated opaque token records. Rule callbacks
do not append/cons event transcripts. Pretty output and conversion to lists happen
after the entry completes or escapes. These token markers witness ownership;
**they do not assert public resource-capacity coverage, simultaneous-entry claims,
whole-entry allocation freedom, or target no-allocation admission.** Raw-method
`:around` observers call the original methods and only increment fixed counters.

The unknown-reservation histories deliberately signal/throw after acquiring a
test token but before returning it. They do not demand that arbitrary pre-effect
ERROR is recoverable or that a driver can cancel a token it never received. They
demand that unknown ownership cannot leave heap execution open. This is distinct
from the 57 legitimate, failure-atomic `:RETRY` histories.

## Dual gate and remaining limits

The dual history requires rejection before publication and a reported symbolic
reason. It makes no one-token/two-token assumption. On a repaired run, inspect
`DUAL-REJECTION-REASON` and the reported construction paths/cause to confirm the
reason names this specification gap rather than an unrelated rejection. The
paper does not assign an exact keyword for that complaint. The separate disjoint
histories require normal construction and successful matched CAS, so rejecting
all barrier contributions cannot satisfy this suite.

The suite does not prove arbitrary callback purity, public resource-claim capacity,
concurrent synchronization, Mezzano residency, or complete paper conformance.
It is a bounded hosted regression matrix against a pinned baseline.

## Slot release

Both retained native handles have finished. **The exclusive native slot is released.**
No further native run will start without a new handoff.
