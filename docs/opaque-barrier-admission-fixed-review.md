# Opaque-admission draft: independent source and native review

## Verdict

**Scoped ACCEPT; no blocker found.** The one-file change removes the invalid
NIL-prototype requirement and checks for a known-argument-compatible primary
under the current STANDARD generic functions. It does not pretend that this
necessary condition proves effective execution or target admission.

Independent native gate: **54/54 PASS** (the unchanged 34 cases plus 20 new
bounded edges), **PID 15448**, exit **0**, **2.3573243940481916 s**. All **349
input pins** stayed unchanged. Fourteen real rejected construction owners remain
retained; there are zero failed or expected-fatal worlds. The exclusive native
slot was explicitly released to the parent after the process finished.

This report covers `/tmp/clamsara-opaque-draft-8qjnkk81`, not the parent's later live integration or
staged commit. The earlier **PID 14790 baseline remains RED: 13/34 pass, 21 fail**;
its files and reports were not changed. This result clears those observed
structural admission defects in this snapshot, not the broader holds below.

## Source partition and control-flow check

I compared the candidate against its full `head-06b2615.tar` Git archive.
The **only code/test/ASDF difference** is `src/runtime/barrier.lisp`.
The snapshot also contains the explicit head tar and 25 `paper-v14/` inputs;
the one-file claim is about code/test/ASDF, not the entire directory.
The 14 normative paper `.tex` inputs match the paper used in the prior review.

`barrier-draft.diff` records the full source change. It adds
`%barrier-primary-candidate-p` and replaces only the constructor's method check.
Every runtime function from `%barrier-event-p` onward is **byte-identical** to
the old source. The composed-barrier slots, final constructor arguments, all
other runtime records, construction/publication code, resource accounting,
ASDF and fixtures are unchanged. No registry or retained method cache is added.

Specific checks in `src/runtime/barrier.lisp`:

- **14-41:** the helper is private construction code. Its only production call
  site is the composer. It inspects metadata, not barrier execution bodies.
- **24-26:** a nonstandard method combination produces
  `:UNSUPPORTED-BARRIER-METHOD-COMBINATION`, not a false missing-method result.
- **27-32:** EQL specializers compare by EQL; class specializers use TYPEP, which
  permits inheritance and built-in objects. A specializer the adapter cannot
  interpret produces an accurate unsupported-specializer reason.
- **33-40:** only empty-qualifier primary candidates count. The actual
  contribution and specified event position constrain candidates. No unknown
  reservation/context/location/value position is inspected or populated by NIL.
- **41:** the non-SBCL branch reports `:UNSUPPORTED-BARRIER-METHOD-ADMISSION`.
  This is an explicit host capability limit, not new author protocol syntax.
- **65-76:** event positions are correct: RESERVE index 2; ADMIT, TRANSFORM and
  exposure index 3; CANCEL no event. Indices are zero-based. Each declared event
  is checked, and TRANSFORM is required only for `:TRANSFORM` policy.
- **59-60, 77-79:** the dual READ+CAS ambiguity rejection and final immutable
  barrier construction are unchanged.

The semantic basis remains `construction.tex:143-153`,
`execution.tex:129-141/166-189`, `overview.tex:36-40/54-57`, and
`reading.tex:56-62`. An author-owned reservation type is not another component's
private representation. Construction CLOS is permitted. No author must add a
NIL fallback, return a sample token, use a new superclass, or register methods.
Standard-method-combination primary requirements follow CLHS 7.6.6.2, not a new
blanket policy copied from the metadata protocol.

## Native process and reproducibility

The native run was separately authorized after the source-only handoff.
No production, frozen fixture or dependency file was changed, and no work was
delegated. The complete command, run from `/tmp/clamsara-opaque-draft-8qjnkk81`, was:

```sh
sbcl --noinform --disable-debugger --no-userinit --no-sysinit --load /tmp/clamsara-opaque-draft-8qjnkk81/independent-review/opaque-admission/bootstrap-01.lisp --quit > /tmp/clamsara-opaque-draft-8qjnkk81/independent-review/opaque-admission/native-01.log 2>&1
```

- Implementation: **SBCL 2.6.8.3-db35d4561**.
- Original cases: `/tmp/clamsara-cas-staged-yik9o9qk/independent-review/opaque-admission/acceptance-source-02.lisp`, byte-identical to
  the PID 14790 red-baseline input.
- New canonical cases: `additional-source-02.lisp`.
- Bootstrap/log: `bootstrap-01.lisp`, `native-01.log`.
- Machine result: `native-results.json`.
- Pin evidence: `native-pre-sha256.json`, `native-post-sha256.json`.

The private source registry ignored inherited configuration. The bootstrap
asserted `:clamsara` and `:clamsara/quality/support` resolve to this exact frozen
root. The private path-preserving cache used
`(t ("/tmp/clamsara-opaque-draft-8qjnkk81/independent-review/opaque-admission/fasl-01/" :implementation))` and asserted separate output
paths for `/one/package.fasl` and `/two/package.fasl`. No cache was removed.
The 349 pins cover every non-review snapshot input, the original 34-case source,
new case drafts and bootstrap. All 345 frozen snapshot-file pins also remain
unchanged independently in `source-pre/post-sha256.json`.

Both strict runners enforce exact case counts and zero failures. The bootstrap
also refuses success if any failed-owner record exists. No syntax, reader,
compiler-error or wiring failure occurred. No compiler warning was found;
four optimization notes in unchanged host-model source are present. The
unexecuted draft `additional-source-01.lisp` is preserved separately.

## The original 34: real builder and execution evidence

All **34/34** original cases pass without an assertion/source change:

- Broad controls and each independently typed reservation phase.
- All phases typed, token subclass, EQL READ event restrictions, and an observing
  rule that legitimately has no TRANSFORM method.
- Valid typed primary/before/after/around method combination.
- Exact completion or transform retry, cancellation, settled token reuse,
  one raw read/no store, idle context and cleared plan pin.
- Real registered roots, managed slots and post-entry collections/graph checks.
- Six missing-phase, five wrong-EQL-event and three auxiliary-only negative
  constructions, each with the exact nested missing-method reason, contributor
  paths, no publication, no execution callback and real acquisition unwind.

Those 14 rejected construction owners remain in the original persistent
`*rejected-builds*` list while the new edges run. Neither suite clears them.
This run now exercises the typed callbacks and GC paths that the old constructor
rejected before entry. It does not discard the old failed baseline evidence.

## Four new real-builder/runtime histories

The edge suite uses the original real fixture/check helpers, not collector or
host-method stubs:

1. An actual contributor subclass inherits all token-specialized methods:
   ordinary completion.
2. The same inherited contribution shape: transform retry/cancel/reuse.
3. A **fresh vector-valued opaque actual**, not a STANDARD-OBJECT, selected by
   EQL-specialized contribution methods: ordinary completion.
4. Another fresh vector actual: transform retry/cancel/reuse.

The vector holds only its author's private state. It does not carry a managed
reference or borrowed location. Its state/token/counters are mapped by the
inherited owner-storage method; the extra actual vector itself is mapped too.
Construction retains that exact vector in the composed barrier. These cases
assert normal published states, the existing **N=1** workspace shape and stable
workspace identities across entry, followed by real collection and the rooted
`811 -> 812` graph. The inherited-class cases use the original `801 -> 802`
managed graph checks.

### EQL method setup and ownership

For each vector case, ordinary test-author setup creates a **new actual** and
adds methods specialized on exactly that value before constructing its world.
It never redefines a production generic function, changes its method
combination, removes a method, or replaces a method applicable to an older
actual. No relevant method is removed even if an older world fails and remains
retained. The second vector's identity is distinct from the first's.

There is no global token/state lookup registry or reused global state binding.
Method bodies reach the author's private state through their actual vector.
EQL metadata can keep the small author-side vector/state reachable for the test
image's lifetime. Those objects contain no managed heap references, roots,
configuration or collector ownership; normal successful worlds still close.
This bounded hosted metadata lifetime is not a claim about method retirement,
closed target code or immutable construction accounting of compiled code.

## Sixteen separate private metadata/capability checks

These are **not sixteen additional real configurations** and must not be
reported as runtime/collector executions. They use private generic functions in
`CLAMSARA.INDEPENDENT.OPAQUE-EDGES`. The production barrier generic functions are
not redefined for capability tests. A body counter stays **zero**.

The cases cover:

- Unknown token, context, location and payload specializers remain unknown;
  the same private method explicitly has no NIL-prototype applicability.
- Known contribution inheritance and true incompatible contribution classes.
- An EQL symbol contribution and a different, incompatible symbol.
- An incompatible EQL event, RESERVE's index-2 event and its mismatch.
- CANCEL's absence of an event position, without probing its EQL token value.
- Compatible and incompatible class-specialized known event values.
- Auxiliary-only and empty STANDARD generic functions returning no candidate.
- A private valid `+` method combination reporting
  `:UNSUPPORTED-BARRIER-METHOD-COMBINATION`, not missing-method.
- The alternate-host branch reporting `:UNSUPPORTED-BARRIER-METHOD-ADMISSION`.
- Unchanged identity of the production admission helper and unchanged STANDARD
  combination objects for all six production execution generic functions.

The alternate-host case reads the frozen helper with only the `:SBCL` feature
suppressed, then compiles the selected body as a **new anonymous test function**
and calls that function. It does not redefine the production helper. It proves
only this source branch's reason selection on the current SBCL host. It is
**not Mezzano/non-SBCL compilation, loading, runtime or supervisor admission**.
No native test for an arbitrary custom specializer implementation was added;
that unsupported branch was reviewed in source only.

The unknown-tail probe deliberately does not supply runtime objects satisfying
those private constraints. Its PASS means only that the necessary candidate
filter does not fabricate NIL constraints. It is not a proof that a real
configuration can generate all those argument domains or execute those methods.

## Retention, boundaries and limitations

Final native summaries:

```text
OPAQUE-ADMISSION-SUMMARY cases=34 failures=0 new-failed=0 new-rejected=14 retained-failed=0 retained-rejected=14
OPAQUE-EDGE-SUMMARY cases=20 failures=0 new-failed=0 retained-failed=0 rejected-delta=0 probe-bodies=0
OPAQUE-DRAFT-RETENTION failed=0 rejected=14 published-failed=0
```

There is no forced cleanup, fabricated fatal state or invented retained cycle.
The rejection records keep their real, fully unwound constructions. Normal
successful worlds use ordinary closure. The single run does not independently
prove arbitrary repeated-run behavior; persistent lists are not reset, and the
14 earlier rejections remain present after the edge suite.

A compatible primary remains **necessary, not sufficient**. The code does not
prove overlap between the actual RESERVE-result domain and each later method's
token domain, method-body success, CALL-NEXT-METHOD chains, safety of all
auxiliaries, absence of allocation, target synchronization or installation
lifetime. Independent primary candidates on disjoint unknown domains are not
a complete effective method. No custom-method-combination support is claimed.
Those limitations are not concealed by this scoped acceptance.

The OPERATION wording gap and dual READ+CAS reservation-contract gap remain.
Nothing here clears the blocked model/name/index/ledger/staged-handle work,
benchmark gates, concurrent/lock-free profiles, supervisor constraints,
residency, full-paper conformance, or Mezzano target gates. Prior wired-EMFUN IRQ
evidence remains acknowledged and separate. No extra public author obligation
was invented to make these cases pass.

The parent's later live permanent-34 integration and its subsequent full gates
are separate input sets. This report does not silently transfer the frozen
54-case result to those later files.
