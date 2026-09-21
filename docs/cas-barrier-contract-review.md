# CAS repair: independent source/spec review

## Scope and method

This is a source/spec-only review of the frozen snapshot at
`/tmp/clamsara-staged-ledger-review-tirxn_0p` (manifest base commit `a3a0bae`).
All 41 production-file SHA-256 values and all 14 paper TeX SHA-256 values match
`review-snapshot.json`. I read the project `AGENTS.md`. I treated
`docs/cas-barrier-repair-design.md` as a proposal, not as authority.

I did not start Lisp, run native tests, change production files, change fixtures,
change dependencies, or delegate. This report makes no native-verification claim.
All citations below refer to the frozen snapshot unless otherwise stated.

## Verdict

**Repair the demonstrable ordering, ownership-protection, and closed-fatal
failures. Do not silently implement the proposal's two-reservation dual-subscriber
contract. Report the specification gap and reject affected compositions before
publication until it is resolved.**

The paper itself requires this distinction. `paper-v14/chapters/reading.tex:48-51`
says silence grants no permission and that an implementation choosing between
readings must reject the affected construction and report the requirement.
Private records and algorithms are free only within the specified behavior
(`reading.tex:56-62`). Calling an externally observable callback-count change a
private refinement does not make it private.

## 1. Disjoint READ/CAS subscribers: ordering is not ambiguous

Normative anchors:

- `construction.tex:143-153`: one acyclic contribution order, checked claims and
  execution methods, and one immutable composed barrier.
- `execution.tex:166-172`: reserve applicable rules in frozen order, reserve the
  simultaneous CAS write/read union, and cancel completed reservations in reverse.
- `execution.tex:182-190`: finish fallible transforms, run applicable read/write
  **before-exposure** methods in global contribution order, perform one release
  store, and then consume reservations without failure.

Let W subscribe only to `:CAS`, R only to `:READ`, with the frozen graph W -> R.
The required matched-CAS before sequence is W.cas, R.read, not R.read, W.cas.
The frozen source instead scans all READ callbacks and then all CAS callbacks
(`src/runtime/barrier.lisp:333-349`). This violates the order even with no dual
subscriber and no choice about reservation cardinality.

Use one contribution-first exposure traversal for these disjoint rules. Pass
raw old to both; pass processed observed as READ's final and transformed new as
CAS's final. Do not interleave exposure with fallible transforms to achieve the
order. The existing separated read and write transforms are consistent with
`execution.tex:175-184`.

The source repeats the READ-major/CAS-major split for after callbacks
(`barrier.lisp:344-349`). Using the same immutable contribution traversal after
is consistent with construction's one order. Precision: `execution.tex:185`
explicitly states before-callback order; line 186 says after callbacks consume
without failure and does not separately state an after-callback ordering rule.
Do not misquote it as doing so.

Reservation already traverses contribution indices in frozen order
(`barrier.lisp:99-113`). Preserve this for disjoint subscribers.

## 2. Mismatch cancellation must be reverse order

`execution.tex:170-178` requires reverse cancellation of completed reservations,
then cancellation of write-only reservations on mismatch, with only the read
path exposed. The current mismatch loop goes upward through indices
(`barrier.lisp:306-313`). With reserved W1 -> R -> W2, it cancels W1 then W2;
it must cancel W2 then W1 while retaining R.

This is an implementation defect independently of dual-subscriber semantics.
The general cancellation helper already walks downward (`barrier.lisp:80-88`).

Keep mismatch's other required distinctions: do not transform/write the new
candidate, do not commit a write delta, and return the read-transformed observed
value, false, `:COMPLETE` (`execution.tex:174-180`). A mismatch is not a retry.

## 3. READ-only rules receive inconsistent operation arguments

Construction checks execution-method applicability for every declared event
(`barrier.lisp:31-46`). Therefore a READ-only rule whose reserve/admit methods
specialize on `(EQL :READ)` passes this check. But CAS calls
`%reserve-barrier-path` and `%admit-barrier-path` with `(:CAS :READ)`
(`barrier.lisp:273,284`), and those helpers unconditionally pass `(first events)`
(`barrier.lisp:108,122`). They invoke that admitted READ-only rule with `:CAS`.
Transforms and exposure later receive `:READ` (`barrier.lisp:293,314-319,335-337`).

That is a concrete mismatch between construction's admitted dispatch domain and
runtime dispatch. For disjoint subscribers, selecting the actually subscribed
path gives one unambiguous event within this existing event-dispatch convention:
READ-only gets `:READ` for reserve, admit, transform and exposure; CAS-only gets
`:CAS`. A literal `:WRITE` is not a declared event (`construction.tex:143-145`).

**Normative wording caveat:** `execution.tex:129-139` names the argument
`operation`, but does not expressly define whether it denotes the outer public
operation or the selected subscription/path. The paper requires the read path
and method admission, but does not contain an explicit sentence mapping this
argument to the keywords for CAS's read leg. Thus the source inconsistency is
certain; an assertion that the paper explicitly defines that keyword mapping
would be too strong. Record this textual gap. Do not use it to invent a dual
subscriber's operation-dispatch contract. If author compatibility depends on
choosing between outer-operation and event-path semantics, report/reject that
ambiguity under `reading.tex:48-51`, rather than promising both.

## 4. Dual READ+CAS subscribers: the paper does not settle the contract

The proposal says a dual subscriber owns two lifecycles, receives two reserve
calls, and needs independently owned event slots
(`docs/cas-barrier-repair-design.md:43-69`). It admits that cardinality and
within-contribution order are not spelled out, then proposes a refinement.
That is not enough under the paper's silence rule.

What the paper does say:

- A contribution is one opaque value; its event list is duplicate-free
  (`construction.tex:143-153`; `execution.tex:166`).
- CAS reserves the union of applicable read/write rules and the construction
  claims cover that simultaneous union (`execution.tex:167-172`).
- On mismatch, cancel *write-only reservations*; run only read-rule exposure
  callbacks (`execution.tex:177-180`).
- After callbacks consume reservations without failure
  (`execution.tex:184-187`).

What it does not say:

1. Whether a rule in both path sets is reserved once as an opaque contribution,
   or twice as two event invocations.
2. Whether reserve/admit receive outer `:CAS` or a selected `:READ`/`:CAS` path
   for that shared contribution.
3. Whether before/after are invoked once or twice for that contribution on a
   match, and in which within-contribution order.
4. Which invocation consumes a shared reservation, or how multiple invocations
   share ownership without repeated consumption.
5. For mismatch, whether one shared reservation is consumed by the READ callback
   while dropping its uncommitted write part, or a separate write reservation is
   canceled while a read reservation remains live.

The cancellation signature has no event argument
(`execution.tex:140-141`). A single opaque reservation can in principle own an
internal aggregate, but the driver cannot assume how it separates or finishes
parts. Conversely, two calls can acquire two entries from an author's one-entry
pool even though the author understood the declared union as one compound claim.
The capacity declaration is a maximum *simultaneous entry* claim, not a license
to choose callback cardinality or to double author claims
(`construction.tex:145-153`; `execution.tex:171-172`).

The frozen code reserves once per contribution (`barrier.lisp:99-113`), reuses
that token for READ and CAS exposure on match (`:335-349`), and runs only READ
exposure on mismatch without canceling the dual token (`:306-319`). Its after
helper does not track which callback has consumed ownership (`:142-154`);
arrays are merely cleared after the entire phase (`:352-353`). This does not
establish a correct generic dual lifecycle. It also does not prove every opaque
shared-token implementation is inherently impossible: an author could implement
an aggregate token, but the needed contract is absent from the paper.

**Required disposition:** complain about these exact missing semantics. Reject
the affected dual READ+CAS construction with a stable reported reason before
publication. This is not support for dual composition and must not be advertised
as such. It is the specified response to an unresolved contract, not another
hosted profile. A declaration of two independent contribution identities with
disjoint subscriptions avoids this particular overlap ambiguity, subject to all
normal claim/order/domain checks; it is not permission to split an author's
opaque contribution automatically.

## 5. Fatal boundary: ERROR and THROW both matter

`construction.tex:150-151` admits only retry-before-exposure/fatal-after failure.
`execution.tex:184-189` makes exposure callbacks non-failing and requires the
closed fatal path from the first before-exposure effect. No raw store is needed
to cross this boundary: mismatch READ callbacks may already publish marking or
other effects.

Source defects:

- Mismatch READ before/after callbacks have no fatal boundary at all
  (`barrier.lisp:314-319`). An ERROR or nonlocal transfer escapes while the
  barrier is not marked failed.
- Matched CAS uses `handler-case` for `ERROR` only (`:333-351`). A `THROW`,
  nonlocal `RETURN-FROM`, or other abnormal transfer can leave without the
  sticky fatal flag. Store and read repeat this problem (`:198-208`, `:251-260`).
- The outer `unwind-protect` only clears `busy-p` (`:355`; sibling operations
  `:214,264`); it does not classify exposure failure.

An explicit private phase/completion marker plus unwind protection can detect
abnormal departure regardless of condition type. It must be armed before
calling the first before-exposure method because the driver cannot observe the
method's first internal effect. An abnormal departure from a supposedly
non-failing exposure method is not a permitted ordinary retry. If there are no
such methods, protect the first actual irreversible effect, such as the store.
Do not ordinary-cancel already published/consumed reservations on this path.
Do not reinterpret a failure from a diagnostic as a fresh callback failure and
invoke diagnostics recursively.

Closed means more than barrier-only poison. `clients.tex:480-484` requires the
fatal diagnostic not to return to heap execution; a hosted harness may catch
its pre-established escape only to format diagnostics after the failed entry.
The existing simulator diagnostic actually throws that escape
(`src/host/coordinator.lisp:176-178`). `%barrier-fatal` sets only the barrier flag
(`barrier.lisp:156-161`); bind/allocation/collection admit via plan `:OPEN` checks
(`src/runtime/allocation.lisp:21-22,128-131`;
`src/runtime/cycle.lisp:567-568`). Catching the fatal escape currently leaves
those heap routes open. A private sticky configuration/plan closure checked by
all managed-work routes is justified; a new public API is not needed.

Do not reuse `:RETAINED` as an invented barrier recovery state. A normative
retained cycle permits mutators to resume at a safe boundary
(`execution.tex:68-87`), and source shutdown assumes retained state has a real
retained cycle (`cycle.lisp:619-624`). Barrier fatal does not manufacture such a
cycle or acquire a stop token. Closure must not fabricate/release stop ownership,
resume execution, or free potentially published state as ordinary precommit
cleanup.

## 6. Pre-effect cleanup: preserve ownership; do not invent error semantics

The source acquires reservations before the operation's unwind protection
(`barrier.lisp:167-178,224-233,272-281`). Reserve ERROR/THROW can therefore strand
all earlier tokens. Inside the guard, admit/raw-load/transform failures clear
only `busy-p`; they do not cancel owned tokens. Next entry clears the arrays
(`:94-95`) and loses those ownership records. Explicit protocol-retry paths do
reverse cleanup, but abnormal exits do not.

The ownership boundary must start before the first reserve, record every
successful reservation immediately, and protect those records until cancellation
or successful consumption. For admitted pre-exposure retry, cancel completed
reservations in reverse and expose neither a usable raw value nor a location
(`execution.tex:151-159,169-178`). Known owned reservations are also the only
reservations a pre-effect abnormal-exit cleanup can safely cancel. Cancel itself
must be bounded/non-failing (`execution.tex:140-141`).

Important limit to the proposal's stronger error policy
(`docs/cas-barrier-repair-design.md:132-148`): the explicit failure-atomic reserve
promise in `execution.tex:169-170` is **on `:RETRY`**. It does not establish that
an arbitrary signaling/throwing reserve acquired nothing before returning no
token. Nor does the paper specify preserving any arbitrary callback exception
and then reopening the runtime as an ordinary supported result. A driver can
clean up previously returned tokens; it cannot cancel an unknown token, infer
undoability of a violating callback, or relabel an unexpected condition/status
as protocol retry. If safe cleanup/state is not known, do not continue heap
execution. Report/reject unsupported callback behavior or use invariant-fatal
handling for a runtime contract violation; do not claim a new supported error
contract from the proposal.

## 7. Same-context reentry: a private invocation pin is justified

`%ensure-context-barrier-storage` clears context arrays before reserve
(`barrier.lisp:90-102`). The barrier busy check happens only after all reserves
(`:173,228,276`). Therefore:

- Reentry during outer reserve can enter before `busy-p` is set and overwrite
  earlier outer tokens.
- Reentry during outer admit/transform/exposure clears the same arrays and can
  reserve/cancel inner tokens before observing `busy-p`. Outer ownership is
  already lost by the time the inner call returns retry.

A per-context invocation/scratch-owner flag must be acquired before clearing
scratch and held through cancellation/consumption and cleanup. An inner call
that cannot own the scratch must leave it untouched and can return the existing
pre-exposure retry result; it must not clear an outer flag in its own cleanup.
This is a private implementation choice allowed by `reading.tex:56-62`, not a
new contribution method or public context protocol. It remains distinct from
the core location guard: reserve-before-core-guard still applies
(`execution.tex:166-174`). It does not prove concurrent/Mezzano synchronization
or admit arbitrary reentrant callbacks. Guarded entries still cannot allocate
ordinarily or run an unbounded callback (`execution.tex:192-194`).

Other paths that clear or retire context scratch must not do so while it is
owned. In particular, the current unbind path clears these arrays without a
barrier-invocation check (`allocation.lisp:45-65`). The normative unbind occurs
at a host safepoint (`execution.tex:90-95`), not from inside a live protected
barrier callback. Rejecting such unsupported entry is different from inventing
an unrestricted reentrant-unbind contract.

## 8. Keep the admitted sequential algorithm separate

The paper requires one guarded raw load, raw-encoding comparison, a processed
read result even on mismatch, and one release store on match
(`execution.tex:174-190`). The frozen source uses that basic shape; no raw-CAS
attempt loop is needed to repair the defects above. A lock-free realization is
separately conditional on failed-attempt delta cancellation or documented
conservative over-approximation (`execution.tex:192-198`). Existing pre-exposure
cancel is not a general inverse after publication. The private busy boolean and
an invocation pin are not target atomic/park/unpark evidence.

## Proposed repair boundary

Proceed, without deciding dual cardinality, on:

1. Disjoint contribution-first exposure and reverse write-only mismatch cancel.
2. Construction/runtime event-dispatch consistency for unambiguous disjoint
   subscribers, with the paper's missing OPERATION definition reported.
3. Unwind-aware fatal detection for mismatch, match, read and store, and durable
   closure of managed heap entry after the hosted diagnostic escape.
4. Private scratch ownership before first clear/reserve, complete known-token
   cleanup, and no retry/reopening based on unknown abnormal-exit state.
5. Construction rejection and an explicit specification complaint for overlapping
   READ+CAS contributions until callback/token cardinality, operation arguments,
   shared consumption, mismatch settlement and within-contribution order are
   defined.

Do not adopt the proposal's two-leg reservation model, per-leg public semantics,
blanket recoverable-error contract, or a new profile merely because those choices
are implementable. The paper expressly forbids that substitute for a contract.
