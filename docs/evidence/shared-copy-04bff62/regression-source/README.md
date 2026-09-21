# Focused copy-action regression draft v1

**Source only. No Lisp reader, compiler, ASDF operation, or test was run.**

Source baseline: runtime commit `1099d6235d7cc2730ce5066fb404daaca0bd75d9`,
from `/tmp/clamsara-list-baseline-1099d62-xzks71ws`.
The live repository was clean at `04bff62db4ef86868dc6d5d917e8704f9d90b62e`.
The pinned implementation and fixture inputs match that baseline byte-for-byte.
No candidate shared-copy implementation was used to derive the assertions.

## Artifact and intended entry

`copy-action-tests-v1.lisp` defines package
`CLAMSARA.COPY-ACTION.INDEPENDENT.V1`. Loading it does not run tests.
The entry is `run-focused-copy-tests`.

After separate native authorization, load the normal `clamsara/generational`
and `clamsara/quality/support` definitions through the project environment.
Load the baseline `test/quality/generational.lisp` definitions too. Then load
this draft and call its entry. The optional existing
`clamsara/quality/generational/test` system supplies those definitions, but
its ASDF test operation is not this focused entry. Do not run either now.
No Maclina or Snowgrave dependency is needed for these hosted runtime cases.

Run this draft in a dedicated image. It installs four uniquely checked
auxiliary methods only while a fault case collects. It refuses to replace
an existing method with the same qualifiers and specializers. It removes
only its own methods, even if an assertion fails. The real primaries remain
unchanged. These observers allocate host diagnostic lists; this is not a
supervisor/IRQ or allocation-free-path test.

## Bounded matrix

Each case runs against packed and scalar authoritative object-start maps:

* SemiSpace: three live 32-byte nodes, duplicate roots, a two-node cycle,
  shared child, and child self-cycle. One real dead allocation. Two complete
  collections must preserve the explicit ID graph, actually move each node,
  and retain exactly three authoritative starts.
* Generational: promote that graph in a minor. Add a young two-node cycle
  that shares mature objects. A major must copy the two young nodes within
  the nursery, not promote them; mature addresses must stay fixed. A following
  minor must promote both, without an intervening payload or root store.
* First-copy failure: separately exercise SemiSpace, minor promotion and
  major nursery copying. A real two-node cyclic graph is rooted. After the
  real initializer and copy primary run, the auxiliary copy method signals
  before any forwarding publication. Check the returned
  outcome, source graph, all authoritative start sets, actual allocator
  ownership/frontiers, representation retirement, and released stop.
* Second-copy failure: exercise the same three routes. The first object is
  genuinely copied, forwarded and committed. The next copy signals before
  its own publication. Check the earlier forwarding identity, exact starts,
  real counters and retained source/destination representations. The stop
  must remain covered. Ordinary collection and allocation reject, and
  mutator unbind returns `:retry`.

This is 16 small cases: four successful graph histories and twelve injected
failed cycles. `coverage.json` contains the planned matrix, not run results.

## Failure seam and ownership oracle

The failure is in the **generic copy operation's `:after` method**, after
its unchanged real primary runs. It is not an artificial trace failure,
claim, forwarding bit, root snapshot, allocator counter, or result record.
A `:before` initializer observer records the real destination address.
Observers of `allocate-raw` and `%cancel-raw-allocation` record the actual
allocator identities. Nothing calls those actions to simulate ownership.

First-copy SemiSpace/major failure must cancel exactly its destination raw
reservation. Minor promotion must neither borrow nor cancel that allocator:
its destination came from the genuine preflight promotion reservation.
The mutator context's allocator owner must not change in either fault case.

`runtime-retire-object-representation` is an ordinary function, not an
extension point. This draft **does not interpose it**. It reads the hosted
model's live count and descriptor-active state. The first failed destination
must be inactive and publicly stale, with only the two real source
representations left. After the second fault, both source and both destination
representations remain active under the retained stop; only the first
new destination has an authoritative start. This is retained scratch, not a
successful rollback or a reusable allocation.

`*copy-owners*` retains actual worlds, root tokens, result records, and
observations. All twelve expected failed-cycle worlds remain published with
active root tokens. This includes first-copy failures whose plan reopened;
there is no test retry/collection/close that erases their failure state.
After a world has been returned by its constructor, unexpected assertion
failures also retain that world and re-signal the condition. Construction
failure before that return is outside this copy-action ownership claim.
Successful graph cases alone use the ordinary successful fixture close.
Do not close failed worlds externally to claim discharge. A terminal failed
world is retained until the test image ends, not beyond process termination.

## Existing coverage and narrow gaps

The baseline already has strong success/graph/history tests in
`test/runtime/semispace.lisp`, `test/runtime/generational.lisp`, and
`test/quality/generational{,-history}.lisp`. The positive cases here are a
small extraction for the shared-action boundary, not a claim that graph
tracing was previously untested. `test/runtime/retained-failure.lisp` already
checks stop retention after a post-forwarding weak-correction failure.
The new focused gap is ownership/authority on a copy-operation exception,
and an exception on a later actual copy after an earlier successful copy.

Source-feasible with existing seams:

* The complete moving graphs and stated copy-operation fault boundaries.
* Real start maps, reservations, forwarding, descriptor state, counters,
  returned outcomes, and ordinary-entry rejection checks.

Not covered; do not silently substitute another test:

* A fault partway through the primary's inline byte/word memmove requires a
  new legitimate hosted copy fault seam. The `:after` fault is after a complete
  primary copy, before that generic operation returns. It is not partial-copy
  or real hardware/OOM evidence.
* A fault immediately after this object's own forwarding publication needs
  a separately reviewed publication seam. The second-copy test instead
  proves a real **earlier** publication is already visible.
* Forcing raw to-space exhaustion by shortening live vectors/cursors or
  breaking equal-extent invariants is forbidden. Equal Q-charged SemiSpace
  extents reserve enough room; a native exhaustion claim needs a legitimate
  bounded destination policy/fault seam. Mature preflight capacity failure
  already has existing tests; it is not a destination-copy failure.
* Trace/work exhaustion, conditional references, finalizers, movement
  participant protocols, callback queues, commit atomicity, allocator backend
  variation, MGC, Gabriel, and Mezzano are not new claims of this draft.

No production, dependency, fixture, paper, LIST, or MGC artifact was edited.
`source-checks.json` records a Python balance scan and source symbol checks.
These are not Common Lisp reader/compiler validation. All sixteen cases
remain unexecuted. Preserve this v1 source and its pins if a later native
reader/compiler/assertion failure requires a new version.
