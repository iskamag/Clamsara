# Independent review of the frozen CAS repair

Snapshot: `/tmp/clamsara-cas-fixed-review-byz5pwd5`.
The actual `paper-v14/chapters/` text is the authority. The CAS design/addendum is
not a substitute for it. The paper is byte-identical to the earlier review.
Only the six declared runtime files differ from the earlier 41-file baseline.
All 41 production, 49 test/ASDF and 14 paper pins match before and after this work.
No production, live fixture or dependency files were changed. No delegation.

## Verdict

**Hold this exact snapshot for one reproduced shutdown contract defect.**
The core disjoint-CAS lifecycle repair passed the bounded histories reviewed here.
This does not establish general paper conformance, arbitrary author admission,
resource-union capacity, concurrent operation or Mezzano safety.

Independent native result: **155/156 histories pass; PID 11176, exit 1**.
The unchanged original 94 histories pass. Of 62 new histories, 61 pass and the
precise post-fatal shutdown rejection history fails. Forty-five expected-fatal
worlds and the one failed world are retained, not force-closed.

## 1. Confirmed defect: irrecoverable fatal shutdown returns recoverable RETAINED

`paper-v14/chapters/construction.tex:391-394` gives shutdown's `:RETAINED` result
for a **recoverable retained movement/image obligation** and says a later call
continues that shutdown. An irrecoverable barrier fault is not such an obligation.
`clients.tex:480-484` permits catching a hosted diagnostic escape for reporting;
it does not authorize a new recovery outcome or resumed heap execution.

The frozen repair's `src/runtime/cycle.lisp:604-610` accepts a fatal plan into
shutdown preflight. `cycle.lisp:622-625` returns `:RETAINED,:FATAL-INVARIANT`.
Consequently `src/construction/build.lisp:735-758` changes both published
configuration/construction states to `:CLOSING` and returns that result.

The new exact assertion reproduces:

```
outcome=:RETAINED
unbind=:RETRY
configuration=:PUBLISHED -> :CLOSING
construction=:PUBLISHED -> :CLOSING
resource release index=0 -> 0
```

No resources are released and no GC cycle or stop is fabricated. Those are good
properties, but they do not authorize the returned contract. Earlier tests only
checked no release; they could not detect this distinction.

Recommended narrow repair, agreed in the parent exchange but **not applied or
verified in this snapshot**: reject a fatal plan through the existing
`runtime-rejection` / `:FATAL-INVARIANT` path in shutdown preflight, before changing
either published state. A defensive fatal branch in drain should also reject,
not return `:RETAINED`. Preserve pins, roots, the acquisition log and fatal state.
This is rejection of an unadmitted post-fatal entry, not a newly promised recovery
result. It follows the default no-new-effect rejection rule
(`reading.tex:25-31`) and the closed diagnostic rule (`clients.tex:480-484`).
The existing fatal heap remains closed; rejection must not manufacture a usable
heap or a retry/recovery protocol. The paper still does not define a reclamation
procedure for an irrecoverably failed configuration, and this repair must not
pretend to provide one.

## 2. Source review: ownership and event routing

### Scratch before callbacks

`src/runtime/barrier.lisp:241-259` validates the entry and requires context state
`:IDLE` before touching scratch. It then changes private state to `:PRE-EFFECT`,
adds a plan pin, installs unwind protection, and clears the two arrays. Same-context
reentry returns retry before clear/reserve. The separate location guard is not
acquired until all reservations finish (`:260-265`). This preserves reserve-before-
core-guard (`execution.tex:166-174`) without pretending the invocation pin is a
new public API or a target lock.

Normal settlement alone sets `:IDLE` and decrements the pin (`barrier.lisp:213-238`).
Fatal settlement keeps context state `:FAILED`, the pin and unresolved scratch
(`:81-97`). `allocation.lisp:45-66` refuses unbind of that owned context. No fatal
case is installed as a retained GC cycle. This is a private implementation state
choice allowed by `reading.tex:56-62`.

### One contribution slot, not invented event lifecycles

`barrier.lisp:27-31` rejects overlapping READ+CAS subscriptions before publication.
The exact native rejection test checks outer `:BARRIER-COMPOSITION-SIGNALED`, cause
`runtime-rejection/:AMBIGUOUS-CAS-RESERVATION-CONTRACT`, nonempty contributor paths,
and completed unpublished construction unwind. Thus a generic unrelated error
cannot satisfy this control.

Disjoint contributions select the applicable READ or CAS event (`:99-107`), reserve
in frozen contribution order (`:134-153`), and use that same selected event for
admit. Existing N-sized arrays remain N-sized (`allocation.lisp:25-40`;
`barrier.lisp:109-115`). There is no second reserve call or invented two-leg
terminal protocol. Two new native controls establish that a successful opaque
NIL token still has independent ownership and is consumed/canceled once.

This is the proper response to the dual cardinality gap under
`reading.tex:48-51`. It is rejection, not support for dual composition.
`execution.tex:166-178` still does not settle one versus two reserve calls,
shared consumption, per-contribution tie order or mismatch settlement.

### Reverse/once settlement and the fatal boundary

`barrier.lisp:117-132` traverses owned slots downward and clears one only after
cancel returns and the sticky-open check passes. The same helper filters write-
only mismatch reservations. Exposure uses one contribution-first traversal
(`:189-211`), with each READ observer receiving the processed observed value and
CAS receiving final new. After callbacks clear ownership only after the sticky
check. This fixes the order and settlement defects identified against
`construction.tex:143-153` and `execution.tex:166-190`.

The source distinguishes the only documented result statuses from invalid
statuses. Unexpected ERROR/THROW/invalid statuses become invariant-fatal rather
than being relabeled retry. Legitimate `:RETRY` still reverse-cancels known claims.
An arbitrary reserve fault that did not return a token is not treated as
failure-atomic. Fatal keeps unknown state closed; it does not invent a token or
undo a published effect. These are defenses against protocol violations, not a
new supported recoverable-error contract for authored methods.

### Caught nested fatal cannot restore the outer entry

There are sticky checks after reserve/admit/transform, after every before callback,
after raw load (`barrier.lisp:271`), after exact comparison (`:275`), after raw store
(`:295`), and before terminal ownership clears (`:129-132,207-209`). The outer
unwind checks state again. A callback that catches another context's fatal escape
cannot turn the enclosing invocation into success/retry or forget current tokens.

The nine added histories inject and catch a second-context fatal at reserve,
admit, transform, before, after, cancel, raw load, comparison and raw store.
All pass. They check two retained context pins, retained known tokens, no fabricated
ownership for the unreturned nested token, no transforms after a closed raw
load/comparison, no after callbacks after a closed store, and no later callback
or terminal clear after the caught fatal. Four cancel-fault histories separately
check successful reverse-prefix settlement without a second cancel after ERROR
or THROW in the current cancel.

## 3. Ordinary entry protection has real negative and later-positive controls

`records.lisp:583-592` rejects fatal state and live barrier pins for ordinary
entries. Binding/allocation and collection call it. The raw allocator boundary
(`spaces.lisp:101-145`) runs before either bump cursor or free-list descriptor
changes. Refill (`:164-172`) checks bound context and ordinary admission. The
finalizer register/cancel/drain entries use the same check
(`finalizers.lisp:227-238,271-277,364-371`).

Added native controls cover reserve/admit/transform/before/after:

- 20 raw/refill histories cover both real SemiSpace bump and MarkSweep free-list
  allocators. A blocked direct call must return the precise rejection reason
  `:BARRIER-BUSY`, preserve allocator cursor/free descriptors and reservation
  history, and preserve context cursor/limit. After the barrier, direct raw
  reservation succeeds and is canceled through the real private raw-cancel
  operation; a normal managed node is then allocated and rooted. Refill later
  returns the concrete simulator's normal NIL result without state mutation.
- 15 finalizer histories cover register, cancel and drain. Rejection must preserve
  registration history, record states and pending queue. Registration/cancellation
  then succeed after the barrier. Drain tests create a genuinely pending finalizer
  through real registration and collection, verify its callback cannot run under
  the pin, then run it exactly once afterward. No fake pending queue is installed.
- The 22 new expected-fatal histories also test direct raw/refill and finalizer
  entries against precise `:FATAL-INVARIANT`, with no allocator/registry change.

Thus the evidence is not merely that an admission flag exists. These are actual
normal APIs with negative effects checked and later working controls. No stronger
contract for arbitrary nested ordinary calls is claimed.

## 4. Fixed storage and accounting: measured facts versus logical bounds

Source-derived logical inventory:

- One `barrier-pin-count` slot in each plan (`records.lisp:343-345`).
- One context `barrier-state` slot (`records.lisp:571-575`).
- N opaque token slots and N independent ownership slots per bound context, not
  2N independent reservation lifecycles (`allocation.lisp:25-40`).
- No per-invocation frame/token array allocation. Normal calls reuse the same arrays.
- One pin per non-idle context. Binding's checked generation limit bounds the
  number of ever-created contexts; normal calls release their pin and fatal calls
  retain theirs. The count does not consume per-call history.

The plan is explicitly enumerated by construction's owner storage inventory;
`host/resources.lisp:25-40` measures both a standard object's header and slot vector.
The new plan slot therefore participates in the measured manifest charge without
needing a guessed extra-byte constant. `host/resources.lisp:104-148` computes
actual retained auxiliary storage, and `construction/build.lisp:546-573` copies
that final measured capacity into the immutable account. The declared 65536-byte
auxiliary reserve (`runtime/records.lisp:407-411`) is not that final measured total.

A native N=3 fixture measured:

| Object | Hosted measured bytes |
|---|---:|
| Test `review-plan` (includes its test-only rules slot) | 272 |
| Composed barrier | 96 |
| Bound execution context | 160 |
| N=3 token vector | 48 |
| N=3 ownership vector | 48 |
| Whole fixture construction auxiliary resource state | 332128 |

These are **SBCL measurements of this fixture**, not target sizes, ABI formulas,
or the incremental cost of one slot. The test verifies plan and barrier occur
in the construction manifest, both arrays have exactly N entries, and array
identities survive invocation. The dynamically bound context is intentionally
not in the already-closed construction manifest. It and its arrays are allocated
before context publication (`allocation.lisp:25-42`; `execution.tex:90-95`).
Their measured sizes are reported separately, not falsely folded into the
immutable construction capacity total.

This does not establish an aggregate resource account for arbitrary dynamic
context populations. It also does not establish whole-entry allocation freedom.
The fixed event observer is not an allocation measurement. The host source's
checked claim sum remains `construction/build.lisp:151-176`; no claim multiplication
was added. All contribution markers in these tests declare NIL resource claims.
Therefore **no native resource-capacity/simultaneous-union claim is made**. A claim
of that gate would need actual public resource contributions/claims and capacity
accept/reject histories; these ownership markers are not a substitute.

## 5. Remaining specification/admission limits

1. `execution.tex:129-139` still names OPERATION without explicitly defining outer
   public operation versus selected subscription event. The repair consistently
   routes disjoint subscribers in the already-admitted event convention; it must
   continue to report that textual gap, not assert an explicit portable keyword
   promise that the paper does not make.
2. The paper explicitly orders before callbacks (`execution.tex:185`); using that
   order for after callbacks is consistent with one frozen contribution order but
   is not a separately quoted after-order sentence.
3. Construction admission still probes with NIL reservation/context/location
   arguments (`barrier.lisp:32-51`). That can reject methods legitimately specialized
   to an author's actual opaque token/context/location class. Nonempty
   `compute-applicable-methods` is also not a proof of successful effective-method
   execution, resource bounds or non-failure. The new NIL-token test proves one
   ownership case; it does not validate arbitrary opaque author admission.
4. A private busy boolean/pin is not a target atomic/park synchronization proof.
   `execution.tex:192-198` remains the requirement for target guarding or an
   independently admitted lock-free realization. No raw-CAS loop was introduced.
5. Indexed/name/staged-handle WIP remains outside this review and held. No native
   result here settles those contract questions or Mezzano admission.

## 6. Reproduction and honest harness history

Canonical replay files: `bootstrap-02.lisp` and `additional-05.lisp`.
The bootstrap has private ASDF source/output roots and an actual source-directory
assertion. It loads the original unchanged `acceptance-03.lisp` from the earlier
review before loading new cases. `native-02.log` has the full final transcript.
`native-results.json` records commands, PIDs, exit codes, hashes and summaries.

Run 1 (PID 11112, exit 1) passed 94 old plus 59 new histories but had two **harness**
undefined-function failures from an unqualified private construction-context
accessor. Those are not implementation failures. The original file/log are
preserved. Draft 01/02 parentheses and draft 04's unpublished-state expectation
were corrected before their native execution; all drafts remain available.

Final run (PID 11176, exit 1) has 94 old + 62 new histories, 155 passes and the one
real shutdown defect above. Deliberate warnings report replacement of the prior
test counter `:AROUND` methods and the test world helper; the new wrappers preserve
those counters and call the real production methods. This is not a clean-warning
claim. No production method body is replaced, and no production/live fixture file
is edited. These review-local helpers should be integrated through shared test
seams rather than copied as method redefinitions into a combined permanent suite.

Normal worlds retire through real root clearing, collection, unbind and shutdown.
Fatal/failed worlds keep registered roots and are retained until process exit.
There is no manual plan-state reset, forced close, fabricated pending record,
fabricated retained cycle or fake stop release.

**The exclusive native slot was explicitly released after both handles finished.**
No further native process will start without another handoff.
