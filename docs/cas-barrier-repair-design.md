# CAS barrier repair: bounded source-only design

**Historical proposal, not implementation authority.** The later actual-paper
review rejects the two-reserve dual-subscriber policy and blanket recoverable
pre-effect exception handling below. See `cas-barrier-contract-addendum.md` and
`cas-barrier-final-review.md`. The scoped repair rejects ambiguous READ+CAS
composition and keeps unknown/fatal exits closed. The original proposal follows
unchanged for provenance.

Source: fixed `/tmp/clamsara-description-review-7p14doks`, manifest commit
9dd8629. All 41 manifest source hashes matched. Paper: the original fixed
paper-v14. No native work, source/dependency edits, or delegation. This is a
proposal, not an implemented or independently executed repair.

## Normative anchors and present defects

paper-v14 `construction.tex:143-153` specifies one frozen contribution order,
duplicate-free event subscriptions, simultaneous resource claims, and only
retry-before-exposure/fatal-after failure. Runtime events are **`:READ` and
`:CAS`**, not a literal `:WRITE`; here "write leg" means the CAS event.

`execution.tex:166-190` requires the CAS union to be reserved in frozen order,
reverse cancellation, all admission before one raw load, comparison of the raw
encoding with expected, read transformation even on mismatch, write-only
cancellation on mismatch, and global contribution order for exposure. The fatal
boundary starts at the first before-exposure effect, not just at the raw store.

Current `src/runtime/barrier.lisp` still has the two previously executed defects:

- `:335-349` traverses the entire read path and then the entire CAS path. A graph
  edge WRITE-only -> READ-only is therefore reversed in exposure callbacks.
- Mismatch exposure at `:314-319` has no fatal wrapper. A callback error can escape
  without setting the barrier's sticky failed flag.

Additional source-evident traps to address in the same lifecycle:

- Mismatch cancellation (`:306-313`) is forward, not reverse order.
- Reserve/admit use `(first events)`, hence pass `:CAS` even to a read-only
  contribution (`:99-123`). Construction probes only declared event methods
  (`:31-46`); an admitted read-only EQL-`:READ` method need not accept this call.
- One reservation is reused for a dual-subscribing contribution, but two
  after-exposure invocations receive it on a match and only one on a mismatch.
  There is no explicit per-leg consume/cancel ownership in the current driver.
- Scratch is cleared before the busy check, and most pre-exposure errors bypass
  cancellation. Same-context recursive entry can overwrite outer ownership.
  These are source concerns here; I have not run new probes against this snapshot.

## Minimal explicit ownership model

### Use independently owned event legs

Treat a successful reserve invocation as owning one lifecycle. CAS has a read
leg for each `:READ` subscription and a write leg for each `:CAS` subscription.
A dual contribution owns **two lifecycles**, with separate reserve calls/tokens;
they need not have different EQ identities if the contribution correctly manages
shared backing. Reserve/admit/transform/exposure receive the leg's event symbol.
A leg is either canceled once or consumed once; no token is handed to two
terminal paths merely because the same contribution subscribes twice.

This uses the existing public protocol. Preallocate up to **2N private slots**
for N contributions, with owned/consumed state and an invocation-active flag.
Use checked construction arithmetic and account for those arrays/fields. Do not
allocate event lists, frames or reservation wrappers in the operation. Existing
contribution claims must genuinely cover the simultaneous read/write union;
do not automatically double an opaque author's already-unioned resource claim
or silently assume two reservations fit an old one-entry pool. Audit authored
dual subscribers and their claims against the chosen semantics.

**Specification precision:** the paper explicitly orders different contributions
but does not give a tie-break between two legs of one contribution, or fully
spell out shared-versus-separate token cardinality for dual subscribers. Separate
legs are a simple concrete refinement of the existing event methods. Document
this interpretation. If the intended contract is instead one token per whole
public CAS operation, the paper needs an explicit dual-leg consumption/cancel
contract; current code does not supply one. A single shared token plus two
ordinary "consume reservation" callbacks is not a repair. Rejecting all dual
subscribers is not support for the stated composition.

### Stable schedules, not event-major scans

For reserve, admit, and each exposure phase, loop over contributions in their
frozen global order, then that contribution's applicable legs. Use a documented
within-contribution tie-break, for example READ then CAS. The same tie-break
across phases makes logs and reverse cleanup unambiguous.

If the order is `W, D, R`, with W write-only, D dual, R read-only, matched-CAS
before order is `W.cas, D.read, D.cas, R.read`; after order is the same.
Mismatch first cancels write legs in reverse reservation order (`D.cas, W.cas`),
then exposes `D.read, R.read`. The read leg of D remains owned during cancellation
of D's write leg. This is not cancellation of the entire dual contribution.

All transforms remain fallible and complete before exposure. Read transforms
run in contribution order on the read candidate; matched write transforms run
in contribution order on the new candidate. This phase separation is stated by
the paper; do not try to interleave transformations and exposure to repair the
cross-event order. Observers receive the already-final value for their own leg.

## State machine

Use explicit operation phase plus per-leg ownership, with one unwind boundary
starting **before the first reserve**. The phase need not be a new public record.

1. **ENTRY / SCRATCH-OWNED:** validate context, open configuration and sticky fatal
   state. Claim the context's invocation scratch before clearing it. Same-context
   reentry returns retry before touching the outer frame; a flag is sufficient
   for this serialized profile. This is scratch ownership, not the location
   guard, so reserve-before-core-guard is preserved.
2. **RESERVING:** reserve every applicable leg in contribution order. Record each
   successful ownership immediately. A protocol `:RETRY` owns nothing for that
   failing call; cancel all prior owned legs in reverse order. Return
   `NIL,NIL,:RETRY`, with no load or write.
3. **GUARDED:** acquire the existing serialized location guard only after all
   reservations. If unavailable, cancel in reverse and retry. Admit all legs
   before the sole raw load. Admit retry likewise cancels/retries without a load.
4. **LOADED / TRANSFORMING:** load raw once. Compare **raw encoding** with expected,
   not normalized/logically equal or read-transformed values. Transform the read
   candidate starting at raw; its `old` argument stays raw throughout. On match,
   transform the write candidate starting at caller-new; its `old` also stays raw.
   Any retry cancels every owned leg in reverse, discards raw/candidates, and
   returns `NIL,NIL,:RETRY`. No location/raw reference escapes to a slow path.
5. **MISMATCH PREPARATION:** skip all write transforms. Cancel only write legs in
   reverse order. Read legs remain owned. The raw slot is unchanged.
6. **EXPOSING:** set phase to irreversible **before invoking the first applicable
   before-exposure method**, including the mismatch read-only path. Run all
   applicable before callbacks in contribution-first order. On match perform
   one release store; on mismatch perform no store. If no before callback exists,
   enter this phase before the core store/other first irreversible effect anyway.
7. **CONSUMING:** run applicable after callbacks in the same global order. After
   each successful return mark precisely that leg consumed. On success every
   owned leg has been canceled or consumed, never both. Return transformed
   observed, match boolean, `:COMPLETE`; do not return raw or the write candidate.
8. **DONE:** clear only this invocation's scratch and release guard/invocation
   ownership. Do not let generic cleanup reset a sticky fatal state.

For read/store/root-store, the same ownership/phase machinery should use their
single event path. Do not fix CAS cleanup while leaving a different lifecycle
interpretation in the sibling operations.

### Preeffect errors versus postboundary faults

Before EXposing, ordinary errors/nonlocal exits must unwind guard and successfully
owned reservations, not leak them. Preserve the original error after safe
cleanup; do not silently relabel an arbitrary signal as a protocol retry. This
requires the failing reserve to be failure-atomic and admission/transforms to
have no exposed heap effects, with private state undoable by cancel. If a rule
violates those guarantees, or cancellation itself signals, do not guess that
retry is safe: use a sticky invariant-fatal path. The driver cannot cancel a
claim for which a signaling reserve never returned a token.

From EXposing onward, **every abnormal exit** is fatal, including ERROR, THROW,
and RETURN-FROM. A handler-case for ERROR alone does not catch nonlocal transfer;
use unwind protection with the explicit phase. No postboundary path performs
ordinary cancellation of already-published effects. Poison before invoking the
fatal diagnostic, and guard against recursively treating the diagnostic's own
signal as another exposure failure. Never return retry/complete from this path.

The fatal state must remain closed if a hosted test catches the diagnostic.
At least block every subsequent composed barrier entry before it clears scratch.
Also audit the configuration boundary: current `%barrier-fatal` poisons only the
barrier while allocation/collection primarily check plan state. A consistent
configuration-wide irrevocable-close policy must block further managed work,
not just repeated CAS. Choose a state/policy compatible with unbind/shutdown;
do not accidentally label a poisoned barrier as a recoverable retained cycle,
resume it, or release a stop token it never acquired. This is a design obligation,
not a new native confirmation about the existing fatal path.

## Raw-CAS race failure: do not mix two algorithms

**Recommended minimal implementation:** retain the paper's protected sequential
guard and one release store. The raw comparison plus guard excludes legitimate
writers until the store. There is no ordinary raw-CAS race outcome in this
admitted algorithm. A guard-ignoring foreign writer is outside that admission;
a plain busy boolean is not a new multi-thread/Mezzano synchronization proof.

If raw CAS is used only as a defensive guard assertion after before-exposure,
a failed CAS is an invariant fault on the closed fatal path. It is not the
initial mismatch case, and must not return the first raw/processed observation
as though it were the value observed by the failed raw CAS.

A genuine lock-free attempt loop is a separate admitted realization
(`execution.tex:192-198`). Every failed attempt must undo exact deltas or leave a
**documented conservative over-approximation**; a failed decrement is forbidden.
The present generic cancel contract is pre-exposure-only and cannot simply be
reused as an arbitrary inverse after callbacks. A failed attempt's actual raw
observed value must get a valid read path too, with its own capacity, guard/root
and retry argument. Do not add such a loop to this bounded repair without that
complete contribution-specific proof. In particular, neither swallowing race
failure as ordinary mismatch nor returning retry after exact effects is valid.

## Native tests to write after implementation

Use real builder-composed contributions and actual model locations. Instrument
finite native callback logs, not protocol stubs. Include:

- Both global orders W->R and R->W; a W->dual->R graph; matched and mismatched CAS;
  literal EQL-event method specializers so misrouted reserve/admit cannot hide.
- Independent read/write transforms, and an observe-final rule: exact compare
  uses raw while returned observation uses the read chain and stored value uses
  the write chain. Assert one raw load and one store on match, zero on mismatch.
- Each reserve/admit/read-transform/write-transform retry and ordinary error at
  first/middle/last leg. Assert reverse exact cancellation, no double terminal
  calls, no slot change, cleared local ownership, and successful later reuse.
- Dual-leg reservations with independent capacity: mismatch cancels only its
  write leg, successful CAS consumes both once, late reserve failure cancels
  earlier legs exactly. Assert simultaneous-union resource admission/accounting.
- Mismatch and match before/after ERROR and nonlocal exits, including failure in
  the first before method. Assert sticky fatal closure, no ordinary cancellation
  after exposure, no usable return, and refusal of later managed work.
- Same-context recursive entry from reserve/admit/transform, plus another context
  meeting a busy guard: outer tokens and counts must remain intact.
- Keep the sequential core distinct from any raw-CAS implementation. If a
  defensive raw CAS is selected, force its failure after successful preliminary
  comparison and assert fatal—not normal mismatch/retry. A lock-free profile
  needs separate races proving its documented exact/conservative delta behavior.

This design repairs the confirmed order and mismatch-boundary defects while
making token ownership explicit. It does not claim arbitrary concurrent target
admission, purity of authored methods, or complete framework conformance.
