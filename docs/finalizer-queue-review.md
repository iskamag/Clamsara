# Independent bounded finalizer queue verification

Target: `/tmp/clamsara-finalizer-queue-review-lk542af4`, git archive `5f735dd`
plus the overlays in `review-snapshot.json`. All eight overlay hashes were
verified. Normative paper: the original fixed paper-v14 snapshot. Only new
`independent-review/` files were created. No project/dependency sources changed.

## Result

**No new concrete queue/ownership defect found in this bounded review of the
serialized hosted repair.** This does not approve managed callback admission,
full registry conformance, concurrency, recovery, or target execution.

I independently wrote and ran `queue-probes.lisp`; I did not merely rerun the
parent's 56 cases. Native SBCL/ASDF loaded the asserted private source directory.
The process exited 0 in 2.18 seconds and printed `INDEPENDENT-QUEUE-PASS cases=16`.
Source and complete compiler/runtime output are in this directory.

## Independent native histories and actual outcomes

Each family ran on SemiSpace/MarkSweep × packed/scalar starts.

1. **Composed ring/slot reuse, two contexts, recursive GC and unwind:** ten
   rounds per profile, 40 rounds and 200 callback invocations total. A drains B
   through a second context; B collects and throws. A catches, reuses B's slot
   for E, collects, then throws outward. A's unwind cleanup drains C; C collects
   and recursively drains D/E through the first context; D deliberately errors.
   Every round has exact order `(:A :B :C :D :E :C-RETURN)`, cleanup drain count
   1, no stale-token effect on E, and three recorded failures (A/B escape and
   D error). Counts reach 50 invocations/30 failures per profile. Ring wrapping,
   pending appends, live running roots and nested context-depth pins all survive.
   Final queue/root slots are empty; both context depths are zero; cleanup closes.
2. **Cross-registry unwind:** A's callback drains a different configuration's
   registry. B's callback collects both configurations and throws through both
   drains. Each registry retains exactly its unclaimed tail and records one
   escaped callback. Later drains return 1 each, in order `(:A1 :B1 :B2 :A2)`.
   No duplicate invocation or leaked context depth occurs. Both worlds close.
3. **Two-deep collection failure, with return or outward THROW:** two different
   contexts own A/B callbacks when B provokes conditional-capacity exhaustion.
   - SemiSpace: the nested cycle returns `:RETAINED/:WEAK-STORAGE-EXHAUSTED` and
     keeps the plan closed. Return path: inner and outer drain both report
     `:COLLECTION-BUSY`. Escape path: `:ESCAPED` propagates. In both cases states
     remain `(:RUNNING :RUNNING :PENDING)`, all three referent roots remain, C
     does not run, and both context depths return to zero. Further drain rejects
     and unbind returns `:RETRY`. The intentionally closed worlds are left intact.
   - MarkSweep: the same cycle result is safely resumable with plan open. Return
     path: inner drain returns 2, outer returns 1. Escape path preserves C for
     a later one-item drain. Order is `(:A :B :C)` and normal cleanup succeeds.
   Failure counts are 0 for normal returns and 2 when B's THROW unwinds A/B.

`DEMAND` records assertion failures in a separate host list before signaling,
and the list is checked outside all callbacks. Thus the drain's ERROR handler
cannot turn a failed assertion into a passing expected-error case. Event order,
completion counts and outside assertions add further checks. Host callbacks are
only test controllers. Moved running references are reloaded from the actual
registry roots; no claim is made that arbitrary native Lisp locals are corrected.

## Source reasoning

- `src/runtime/finalizers.lisp:339-352` validates pending state, marks the record
  running, and removes its FIFO entry **before** user code. Nested drains cannot
  reclaim that same entry, and the record remains unavailable for registration.
- `:321-336` appends at the ring tail and does not overwrite the current queue
  length on return from a callback. With `0 <= head < F` and `0 <= count <= F`,
  the tail calculation avoids an overflowing `head+count`; head advancement
  also stays at most F before wrapping.
- `:354-364,383-394` performs terminal cleanup through unwind protection and
  restores context depth even on callback escape. A retained plan prevents root
  clearing/reuse. The post-callback check (`:395-397`) stops later claims while
  closed. Crucially, it tests actual plan state, not merely a `:RETAINED` cycle
  report, so safe nonmoving failures need not strand the drain.
- `src/runtime/allocation.lisp:54-57` refuses unbinding an active callback
  context. `src/runtime/records.lisp:569` provisions that depth state. The normal
  active-context shutdown guard remains in force. Nested calls through distinct
  contexts were tested, not just depth on one context.

These changes directly address the previous duplicate/lost-work mechanisms.
The source checks and histories are consistent with paper-v14
`chapters/clients.tex:397-406` (ordered pending publication, at-most-once claims,
terminal cleanup) and `chapters/execution.tex:428-438` (mutator callbacks and
retained closure). They are not a proof over every possible history.

## Limits and remaining concerns

- The parent's existing `RUN-CALLBACK-EXIT :ERROR` fixture in this frozen snapshot
  can mask an earlier swallowed payload assertion. The parent reported adding
  an outside `REACHED-EXIT` check after this snapshot was frozen. I did not read
  or execute that later edit. My probes use independent outside failure evidence.
- Full main/tools/workload/optional-generational/structure gate results are
  parent-reported, not independently rerun here. I freshly loaded the actual core
  and quality support and executed the new adversarial histories.
- Running-root retention already passed the old baseline; I do not credit it as
  a newly repaired property. This review adds composed lifetime/queue histories.
- Managed callback representation/support roots, composed registry writes, and
  arbitrary callback argument/capture rooting remain open, as requested. No
  claim is made that host FUNCTIONP callbacks satisfy the managed-callback ABI.
- No concurrent writers, asynchronous interruption during claim/publication,
  image restore, retained-cycle recovery, arbitrary diagnostic/host-fatal signals,
  or no-allocation/Mezzano admission were exercised. Retained worlds stay closed;
  their preserved records are not evidence of a resumable drain.

## Reproduce

From the fixed snapshot:

```text
sbcl --noinform --non-interactive --load independent-review/queue-probes.lisp
```

Entries: `CLAMSARA.QUEUE.INDEPENDENT::COMPOSED-WRAP-HISTORY`,
`TWO-REGISTRY-ESCAPE`, and `RECURSIVE-COLLECTION-FAILURE`. LOAD runs the 16-case
matrix. `bootstrap.lisp` prepends the snapshot registry and asserts its ASDF
source directory. All native work finished; the startup slot was released.
