# Independent correctness review: fixed Clamsara snapshot

Snapshot: `/tmp/clamsara-independent-review-3ygbx_br`, base commit
`ac22bddc255fc85529e3ff85ea8fe49061fc6b25`, with the three overlays recorded in
`review-snapshot.json`. Normative paper source is the fixed `paper-v14/` copy
recorded by the parent. No project/dependency sources or benchmark fixtures were
changed. All new probes and logs are in `independent-review/`.

This is a bounded review, not a conformance verdict. Severity: **High** means
ordinary admitted operation can break lifecycle/ownership or strand the runtime;
**Medium** means an admission/protocol defect with a narrower trigger.

## Confirmed defects

### 1. High: reused finalizer slots create undecodable live tokens

- `src/runtime/finalizers.lisp:159-162` decodes a token as
  `(mod (1- token) capacity)`.
- `src/runtime/finalizers.lisp:174-185` independently chooses the first free
  slot and increments one global counter. Those choices agree only in special
  allocation histories. A cancellation creates a hole immediately.
- Public reproducer: register token 1, cancel it, register token 2. The latter
  occupies slot 0, while its decoder checks slot 1. `cancel-finalizer` returns
  `:ALREADY-FINALIZED` for the still-active registration. Collection later reaches
  `freeze-finalizer-candidate` (`:227-239`) with a token it cannot resolve.
- Native result in `finalizer-probes.log`:
  `tokens=1/2 second-cancel=:ALREADY-FINALIZED`, then
  `cycle=:RETAINED/:RECLAIM/CORRECT/:POST-PUBLICATION-FAILURE plan=:RETAINED`.
  This is a normal registry-use history, not an injected collector fault.
- Fix direction: bind each token to its actual slot and nonwrapping generation;
  validate that identity during precommit too. Add cancel/re-register,
  partial-hole reuse, and repeated drain/re-register histories.

### 2. High: finalizer drain does not own work across callback control flow

`src/runtime/finalizers.lisp:263-281` snapshots the queue length, invokes callbacks
without checking/claiming the queued state, and clears the whole pending count
at the end. Setting `:FINALIZED` does not protect an entry that subsequent drains
never check.

Independent native public-API histories in `finalizer-probes.lisp` show:

1. A callback `THROW`s to its caller. Two drains invoke it twice (`calls=1`, then
   `calls=2`). `HANDLER-CASE` catches `ERROR`, not a nonlocal exit, and cleanup is
   not protected.
2. A callback calls `drain-pending-finalizers` recursively. It invokes itself
   twice during one outer drain (`drained=1 calls=2`).
3. A callback drops another registered object's last root and collects. The
   nested cycle completes and appends its finalizer. The outer drain overwrites
   the new pending count with zero. The next drain reports zero while the second
   slot stays `:PENDING` and rooted. The callback is lost and storage leaks.

The third case requires no malformed callback or concurrency: callbacks are
mutator code, so allocation and collection during a callback are expected.
Use an explicit pending/running/done claim and a queue head/tail protocol that
preserves appends. Perform terminal cleanup on every exit and define reentrant
admission. Test nested collection, recursive drain and nonlocal escape, not only
signaled callback errors. The paper requires at-most-once invocation and done
transition after normal or nonlocal return (`chapters/clients.tex`, finalizer
registry section).


### 3. High: copying representation capacity is not admitted before forwarding

- `src/host/object-model.lisp:1045-1049` has a separate maximum live
  representation count. Sources and initialized destinations both consume it.
- `src/runtime/records.lisp:477-494` validates a geometry-derived trace capacity,
  but not this model bound. `src/runtime/spaces.lisp:259-299` initializes and
  publishes each copy before discovering whether the remaining representations
  fit. Equal byte extents do not prove this separate capacity.
- `capacity-probes.lisp` creates a normal `make-quality-world` with
  `:object-capacity 3`. Construction succeeds and two 32-byte rooted nodes
  allocate in a 2048-byte SemiSpace. Collection copies one node, then rejects
  the second destination: `:RETAINED/:ROOTS/:POST-PUBLICATION-FAILURE`,
  `objects-moved=1`, plan `:RETAINED`. This is preventable capacity exhaustion,
  not an injected fault. Both byte spaces have ample room.
- Expected: reject the insufficient composition, constrain admitted allocation
  to a proved copying bound, or preflight all representation reserves before
  any forwarding. Do not strand a previously usable heap after the first copy.
  Add a low-model-capacity test with at least two live objects; testing only
  trace-vector and byte-space capacity misses it.
- Normative basis: `paper-v14/chapters/collectors.tex:44-48,97-98` and
  `paper-v14/chapters/construction.tex:163-164`.

### 4. High/Medium: composed CAS has the wrong exposure/failure boundary

`barrier-probes.lisp` authors two real contribution classes and builds an actual
SemiSpace configuration with the normal builder and hosted object model. It does
not replace raw loads, stores, tracing, or the collector. The write rule declares
`:before (:read)` and the read rule applies only to `:read`.

**Medium, order:** a matched CAS returns `(NIL T :COMPLETE)` but logs
`READ-before, WRITE-before, READ-after, WRITE-after`, contrary to the declared
write-before-read order. `src/runtime/barrier.lisp:335-349` loops over the entire
read path first, then the write path, rather than one ordered union. The paper
requires global contribution order (`chapters/execution.tex:184-186`). Rules
whose exposure effects depend on construction order cannot trust this driver.
Run exposure by frozen contribution order, selecting each applicable event
within that traversal. Define/test the case where one rule handles both events.

**High, closed failure:** on a mismatched CAS, a deliberate read-rule
before-exposure error escapes as the ordinary injected error. The barrier is
still open (`barrier-failed=NIL`) and the next managed read succeeds.
`src/runtime/barrier.lisp:314-322` lacks the fatal protection used for a matched
CAS at `:333-351`. An exposure rule may already have changed authoritative state;
this branch must use the same closed-fatal handling. Normative basis:
`chapters/execution.tex:188-189`. The fault is intentionally injected into an
authored contribution; the observed *driver response* is the defect, not the
fact that a non-failing contribution was made to signal.

Existing CAS fixtures put read before write in both cases
(`test/barrier/barrier.lisp:355-382`), so they cannot detect the reversed-order
case. They also do not inject exposure faults on mismatch.

### 5. Medium: positive but kind-invalid allocation sizes bypass validation

`src/runtime/allocation.lisp:67-78` checks positivity but not the admitted kind's
size rule. Validation happens only at `initialize-object`, after raw allocation
(`:89-97`), or never happens if raw capacity fails and collection runs first.

For the ordinary 32-byte node kind in `capacity-probes.lisp`:

| Request | Expected | Actual |
|---|---|---|
| 16 bytes | `NIL :FAILED :INVALID-SIZE`, no state change | signals generic `"Invalid hosted object initialization"` |
| 512 bytes in a 256-byte space | same invalid-size result, no collection | `NIL :FAILED :HEAP-EXHAUSTED`, after moving a rooted node and invalidating its old encoding |

Validate the model's size/alignment rules and checked extent before reserving
or collecting. This is required by `chapters/execution.tex:97-105`, not just
an error-message preference. Test positive invalid sizes, not only zero or
negative inputs.

## Additional confirmed contract gap

- **Confirmed smaller registration gap:** `register-finalizer` accepts `NIL`
  as a referent, gives it a token, and keeps it registered after a complete
  collection (`finalizer-probes.log`, final probe). Its entry
  (`src/runtime/finalizers.lisp:167-186`) never validates an allocated local
  referent, contrary to `chapters/clients.tex:376-378`. Reject invalid/foreign/
  stale referents before publishing the registration.
## Reasoned concerns, not independently reproduced

These do not extend the findings into a blanket verdict.

- **Callback-root concern:** registry
  roots expose referent/support slots, while registration stores an arbitrary
  host function in a different callback vector and sets support to `NIL`
  (`src/runtime/finalizers.lisp:11-16,181-184`). I found no managed callback
  support handoff in this path. The paper requires callbacks/support to be
  retained. Host function reachability does not establish that captured managed
  references can be traced and corrected. This is a specific registry coverage
  concern, not a claim that the whole language adapter was tested here.
- **Reasoned retained-callback concern, source-only:** drain checks the plan
  only at entry (`finalizers.lisp:261-262`). If a callback performs a collection
  that returns with the plan/stop retained, drain still clears that record and
  invokes later callbacks (`:263-281`) without rechecking admission. This needs
  a regression proving no later callback or mutator cleanup runs while the plan
  remains stopped. The confirmed nested-collection probe above exercised only
  a *successful* nested collection.
- **Shutdown follow-up, source-only:** this snapshot does not decrement pending
  count before invocation; the running referent remains in its provider root
  until callback return. Normal shutdown is also blocked by a bound context
  and by allocated objects (`src/runtime/cycle.lisp:610-614,619-628`). Those checks do
  not replace an explicit active-drain/running-callback obligation in a repair
  that dequeues first. Keep running callback/referent roots separate from queue
  membership and make shutdown refuse to deactivate their owner. I did not
  review the parent's later repair or establish a separate shutdown reproducer.
- **Reasoned generational progress limit:** minor preparation reserves space for
  every allocated nursery object, even dead objects
  (`src/runtime/generational.lisp:361-382`). A failed minor is `:RETAINED`, so
  allocation returns before attempting full collection
  (`src/runtime/allocation.lisp:147-151`). The repaired explicit major provides
  recovery, but does not itself prove automatic allocation recovery when mature
  is full. The paper explicitly says retained stops escalation; this needs a
  deliberate plan policy, not blind escalation through a retained cycle. I did
  not make this a new confirmed generational defect.

## Independent assessment of the generational repair

The inspected major path skips promotion reservations (`generational.lisp:385-400`),
uses ordinary nursery copying (`:423-428`), prepares/finishes mature MarkSweep
(`:597-605,637-646`), and preserves the conservative mature dirty card
(`:615-619`). These changes address the reported inability to reclaim a full
mature space while a nursery survivor exists. I found no new defect in that
specific repaired path during this bounded review.

Independent evidence, separate from the parent's conclusions:

- The snapshot's recovery test and original optional lifecycle/capacity tests
  pass natively.
- `generational-probes.lisp` compares the actual managed root/edge graph with a
  host ID/edge oracle after mutations and every collection. Packed and scalar
  starts, seeds 731 and 15799, each run 72 explicit cycles: 54 minors and 18
  majors. Total: **288 oracle-checked cycles, 216 minors and 72 majors**, plus
  four successful cleanup cycles. Node identities are managed immediate payloads;
  all edges and roots use the real barriers/provider protocol. Histories include
  old-source replacement, deletion, sharing/cycles, major-to-minor transitions,
  and repeated address reuse. Geometry: Q=16, nursery=256 bytes per semispace,
  mature=4096 bytes, 32-byte nodes, 8 roots. This is bounded strong-graph evidence,
  not exhaustive weak/finalizer or failure coverage.
- The repair still shares the finalizer and other core defects above. Passing
  this history is not admission of the whole optional profile.

## Evidence, claim honesty, and unreviewed scope

All five requested native gates passed on the fixed snapshot:
`:clamsara`, `:clamsara/tools/test`, `:clamsara/workload/test`,
`:clamsara/generational/test`, `:clamsara/quality/generational/test`.
All top-level runs assert the ASDF source directory. See `baseline.log` and
`batch2.log`. The tools' malformed-IF compiler error is expected and its test
reports 14 passing checks. No dependency was patched for this review.

`make -C paper-v14 check` passed: 13 chapters, 29 listings, 231 forms read and
227 declarations accepted (`paper-check.log`). That check reads/evaluates
interface/helper definitions, not their lifecycle histories. In particular,
`paper-v14/chapters/persistence.tex:45-46` says the repository's checkpoint fixture
executes the protocol; this fixed source tree contains neither those checkpoint
entry definitions nor a checkpoint test. That factual fixture claim is stale
or needs a named external artifact. It does not establish an optional profile.

The repository's broad status prose is mostly careful: `docs/migration.md` and
`docs/generational.md` disclaim full conformance and target acceptance. I did not
find grounds to call their literal statements that the listed tests pass false.
The gap is inference: the finalizer tests cover one fresh batch plus an `ERROR`
callback (`test/quality/stateful.lisp:374-423`), not token reuse, `THROW`, recursive
drain, or callbacks that collect. The implementation comment claiming nonlocal
failure cannot repeat a callback (`src/runtime/finalizers.lisp:269-270`) is
specifically disproved by the probe.

I read the normative chapter sources. Deep review focused on finalizer ownership,
copy-capacity admission, allocation validation, composed barriers, and the
repaired generational lifecycle. I spot-checked roots, tracing, metadata and
reclamation code; I did **not** exhaustively validate construction rollback,
all metadata provider/domain combinations, all borrowed-location lifetimes,
movement participants, all generational conditional combinations, or arbitrary
failure positions. No concurrent profile, Evha, Claimore, image restart,
Mezzano/supervisor allocation/residency, full language ownership, full19 Gabriel,
or current-tree full-depth GCBench acceptance is claimed. The historical
113aa6a GCBench result is not current-tree evidence. Later parent edits are
outside this fixed-snapshot review.

## Reproduction

From the snapshot directory, with native startup coordinated in the shared
environment:

```text
sbcl --noinform --non-interactive --load independent-review/baseline.lisp
sbcl --noinform --non-interactive --load independent-review/finalizer-probes.lisp
sbcl --noinform --non-interactive --load independent-review/batch2.lisp
make -C paper-v14 check
```

`batch2.lisp` loads the independent capacity, barrier and generational probes,
then the workload gate. Probes print expected-versus-actual evidence described
above; their process exit code is not a correctness verdict. In the fault cases,
retained configurations are deliberately left closed until process exit.
The barrier fixture is an authored contribution extension, not a protocol stub.

All probe processes completed. The native startup slot was released to the
parent. Overlay hashes still match `review-snapshot.json`.
