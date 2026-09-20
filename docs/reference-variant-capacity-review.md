# Bounded nonbase-reference variant-capacity probe

## Finding

**A natively admitted hosted tagged/interior reference with variant capacity 1
strands semispace collection after the first copy and forwarding publication.**
Both object-start map forms reproduce it. Sufficient-capacity moving controls
and all tested nonmoving controls complete and preserve the reference encoding
and real graph.

This is not the existing pre-effect mutator variant-exhaustion case. The
collector correctly retains the stop once publication has occurred; the newly
observed issue is that the reconstruction-capacity shortage is reached only
after that boundary. No silent successful corruption was observed.

## Scope and setup

Frozen source: `/tmp/clamsara-description-review-7p14doks`, commit `9dd8629`.
All 41 recorded source hashes match before and after. Only new files under
`independent-review/variant-capacity/` were created. No source, dependency, or
fixture was changed.

The 16-case matrix is:

- semispace / marksweep;
- packed / scalar object-start maps;
- tagged-base / interior references;
- variant capacity 1 / 4.

A small real fixture uses the existing hosted model, public construction and
collectors, and quality root/slot helpers. It offers 128 representation cells
for layouts needing 64 cells (semispace) or 32 (marksweep), including reserve
space. Thus the representation-cell capacity repair is satisfied.

The reference descriptors are the **private hosted ABI inputs** already used by
the repository tests: `#x20000001` for tag 1 and `#x10000008` for displacement 8.
This is not a claim that portable clients may manufacture arbitrary opaque
reference descriptors. Each descriptor is passed to the actual
`rebuild-reference`; only its returned value enters the actual registered root.
Before collection, the probe verifies `valid-reference-p`, normalization to the
allocated base, exact descriptor return, and same-base encoding roundtrip.

The rooted 32-byte parent has a real strong edge to a 32-byte child. Their slot
IDs are 501/502; raw payload bytes at offset 24 are `#xA7`/`#xB3`. The returned
nonbase reference is root 0. Host locals are not substituted for roots.

## Actual results

| Configuration | Cases | Result |
|---|---:|---|
| Semispace, capacity 1 | 4 | retained after publication |
| Semispace, capacity 4 | 4 | three successful collections, normal discharge |
| Marksweep, capacity 1 or 4 | 8 | three successful collections, normal discharge |

All four tiny moving cases return:

```
status :retained, reason :post-publication-failure, phase :roots
objects-discovered 1, objects-moved 1, bytes-moved 32, objects-dead 0
forwarding T, plan :retained, stop :covered
variant-count 1, active representations 3 (before collection: 2)
```

The actual movement record is base 4096 → 4608, and source forwarding metadata
matches the recorded destination. This is after real destination creation and
forwarding, not a pre-effect refusal. Subsequent allocation rejects
`:collection-busy`; unbinding returns `:retry`. The real roots remain untouched.
The four retained worlds are kept for inspection and are not force-closed.

Every successful control rechecks descriptor identity, exact encoding
roundtrip, both graph IDs, the real child edge, and both raw payload bytes after
each collection. Moving bases alternate 4608 → 4096 → 4608; the original tag or
interior displacement remains unchanged. Semispace discovers/moves two objects
and 64 bytes each round. Its variant count rises from 1 to 2 and then stays 2.
Marksweep remains at base 4096 with variant count 1 and moves no objects.
All 12 positive-control worlds complete ordinary fixture teardown.

Historical variant count remains 2 (moving) or 1 (nonmoving) after discharge.
This supports retained historical encodings for these addresses. It is not a
stress proof over an unbounded sequence of distinct addresses/forms, and capacity
4 is only sufficient for this bounded control.

## Source mechanism and contract relevance

`src/host/object-model.lisp:860-885` keys nonbase variants by descriptor cell and
encoding. A previously unseen destination needs the next preallocated variant
record; a full pool signals `Reference encoding capacity exhausted`.
`rebuild-reference` at lines 887-919 reaches that helper for nonbase forms.

`src/runtime/spaces.lisp:225-299` performs copy and forwarding publication.
Only after `trace-object` returns does
`src/runtime/trace.lisp:216-237` rebuild the original reference form at the new
base. The unexpected reconstruction fault is converted to the observed retained
post-publication failure by the cycle boundary. MarkSweep reconstructs at the
same base and finds the existing encoding instead.

The unchanged paper's `chapters/clients.tex:128-136` requires normalization and
rebuilding of admitted tagged/interior references, preserved displacement at a
moved base, and descriptors that fit entry allocation restrictions. This probe
shows an accepted hosted form/configuration whose moving reconstruction capacity
is not rejected or secured before forwarding. It does not invalidate the
retained-stop safety behavior after failure, and it does not establish a complete
replacement capacity policy. No speculative repair is proposed here.

## Native artifacts and probe correction

Each bootstrap prepends the frozen ASDF registry and asserts the exact selected
system source directory. New FASLs are local to this probe directory.

- `bootstrap-02.lisp`, `cases-02.lisp`, `native-02.log`: complete matrix,
  exit 0, final marker `cases=16, preserved-worlds=4`. Failure/control outcomes
  are explicitly asserted.
- `bootstrap.lisp`, `cases.lisp`, `native-01.log`: preserved first attempt.
  It already observed the same retained collection, then exited 1 because my
  extra diagnostic tried the mutator `barrier-read` while the plan was retained.
  That access correctly rejected `:collection-busy`. Version 2 removes those
  diagnostic payload reads; it does not bypass the barrier or disable errors.
- `execution.json`, `source-integrity.json`, `artifact-sha256.json`: run and
  source/artifact records.

Both native processes ran serially in the granted slot. The slot was explicitly
released after the complete matrix. This evidence is limited to the frozen
hosted sequential implementation and private hosted reference forms. It says
nothing about target supervisor admission, concurrent collectors, CAS, or the
later geometry/unwind patch's integrated gate.
