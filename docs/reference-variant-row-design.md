# Immutable nonbase code rows

Base: `4e7c28f`. The repair passes the parent native gates below.
Independent native replay passes 108 original cases plus 12 additional edge
cases. The [fixed-snapshot review](reference-variant-row-fixed-review.md) found
no blocker within the serialized hosted row-closure contract. Its separate
[integration note](reference-variant-row-integration-addendum.md) preserves the
boundary between reviewer-run and parent-run evidence. Read the separate
[paper-path correction](reference-variant-row-provenance-addendum.md): the row
review verified the supplied policy, not a fresh normative-paper audit.
The independent defect is preserved in `reference-variant-capacity-review.md`.
No benchmark or target acceptance is implied.

For C descriptor cells and exactly H preallocated variant records, a canonical
nonbase code owns a complete C-slot row. Its first materialization checks a whole
row remains before changing records. A preallocated canonical-code-to-row
hash directory publishes the row only after every eligible record is ready.
Rebuilding an already admitted code at another installed descriptor index is
`row-start + descriptor-index`; it cannot consume a new record. Original record
addresses, kinds, tags and displacements never change after publication.

H=0 is base-only. Positive H<C rejects binding, rather than clamping the offer.
There are floor(H/C) historical codes, with an unusable H mod C tail. Aliased
raw reconstruction descriptors share the canonical decoded code. All H records
and both directory vectors remain explicitly charged, including unused cells.

The domain includes reserves and mature ranges at their actual map granularities,
not just live or currently owned cells. Only a cell too near its fixed route
limit for the displacement is skipped, while still consuming its reserved slot.
Inactive cells and cells currently containing a smaller object must be ready for
future valid objects. Initialized unexposed destinations remain supported.

Publication uses only preallocated records and bounded arithmetic, with no
client callbacks. The hosted profile is serialized; a row-publication guard
rejects reentrant nonbase materialization. An unwinding unpublished fill clears
that guard. Directory/count publication follows the non-failing fill. Concurrent
or asynchronous publication is not admitted by this design.

To avoid creating boxed address arithmetic during row filling, nonzero H also
requires nonnegative fixnum route bounds and 46-bit fixnums for all canonical
packed codes. The concrete simulator's existing at-most-60-bit address range
already satisfies the address check on this 64-bit SBCL. These defensive checks
are not a proof of all supervisor allocation freedom. Base-only models do not
gain a high-address or target claim from this change. Actual valid displacement+address is less than
the route limit. Row/index sums are bounded by the preallocated vector length.

Ownership preparation rejects map-granularity changes before consuming a
capability. Owner/map/generation changes with the same granularity remain allowed;
the physical descriptor domain stays fixed. A new native test compares real
coverage-valid different/equal-granularity ownership requests.

The workload adapter and fixtures that only emit base references explicitly use
H=0. Nonbase tests provision complete rows at their unchanged heap geometry.
The previous independent second-form exhaustion test still checks pre-effect
failure, using exactly one row rather than one incomplete record. No benchmark
fixture, heap extent, root, or expectation was removed to make admission pass.

## Native evidence

The independent acceptance report is preserved in
[reference-variant-row-acceptance-review.md](reference-variant-row-acceptance-review.md),
with its [harness correction](reference-variant-row-harness-addendum.md).
Frozen `9dd8629` executes 108 cases: 44 pass and 64 fail their intended row-policy
assertions. This is separate from the earlier 16-case post-forwarding defect
matrix. The 64 failures are 56 boundary offers and 8 future-larger/charged-hole
budget cases. The controls include actual movement, exact encoding round trips,
staging, all installed cells, reverse builder cleanup and nursery promotion.

The first parent replay reports 108 passes and zero case failures, then wrongly
exits 1: the original aggregate uses `(when *failed* ...)`, but CL zero is true.
The original artifact is unchanged. Only the integrated copy uses `PLUSP`.
The earlier independent generational count-oracle correction is also disclosed
in the original report; the corrected real graph and movement assertions remain.

The main-selected `:clamsara/quality/reference-variants/test` compiles 104
independent non-generational cases and four parent directory histories. The
optional `:clamsara/quality/generational/test` adds the remaining four independent
promotion cases. The parent cases admit 20 distinct canonical forms, including
tagged interiors, exercise actual hash collisions, reject a 21st code with an
unusable tail, and compare directory and immutable record fields through three
real collections. They do not measure lookup complexity or concurrent behavior.

The separate ownership test rejects a coverage-valid 16-to-8 map-granularity
change without consuming a capability or changing the route. Its equal-granularity
control really transfers ownership and advances the generation. The same test
fails on frozen `9dd8629`; this is a new fixed-domain restriction, not proof that
the old ownership operation always corrupted an object.

Parent logs:

- `/tmp/clamsara-variant-row-green.log`: 108/0, erroneous aggregate exit 1.
- `/tmp/clamsara-variant-row-integrated3.log`: focused gates exit 0.
- `/tmp/clamsara-variant-row-full.log`: main, tools, workload, optional generation
  and structure gates exit 0, including the existing 288 generation histories.
- `/tmp/clamsara-variant-row-500k.log`: 500,000-element stress exits 0 with the
  original heap, object and descriptor geometry; 2 objects/8,000,032 bytes move.
- `/tmp/clamsara-ownership-granularity-red.log`: semantic baseline failure.

The first two integrated attempts failed in the parent test setup: a misspelled
layout accessor, then an overlooked base-only conditional fixture offer H<C.
The accessor and explicit H=0 offer were fixed; no collector expectation or
benchmark fixture changed. Source/test/ASDF hashes stayed unchanged through the
full/stress gates. Paper and all 20 benchmark fixture hashes also match.

See [quality-model-resources.md](quality-model-resources.md) for freshly measured
storage. The array fixture now explicitly offers H=0; removal of its former
small unused variant reserve and the smaller directory changes overhead, not
heap size. Process times include startup and test bookkeeping and are not an
isolated performance result.

## Limits

Fixed review snapshot: `/tmp/clamsara-variant-row-review-bnum_11t`, with 41
production source hashes and 19 overlays recorded in `review-snapshot.json`.
Independent replay passes all 108 original cases and 12 new adversarial cases.
The new checks verify invalid codes before materialization, charged endpoint
holes, exact row/directory account membership and unchanged charges through
three collections. Maximum tagged-base tag 65535 (including an alias) and
maximum tagged-interior tag 255/displacement 1048575 use a real 1 MiB object.
That separate fixture uses Q=1 MiB and two cells per space, not the benchmark
geometry or a claim to test the full 28-bit untagged interior range.

The additional native runner initially used MAPCAR on the capacity-account
vector; the corrected MAP LIST source and both logs are preserved. Its 12 cases
are integrated in `reference-variant-edges.lisp`, with only a namespace change
and removal of an unused MAP loop variable/nested IGNORE declaration that
caused a style warning. The final full gate, `/tmp/clamsara-variant-row-final2.log`,
passes 104+12 independent main cases, four parent directory cases and four
independent optional promotion cases, with no new style warning. The selected
ASDF source directory is explicitly asserted. All 41 production hashes still
match the independent snapshot; final test/ASDF pins are recorded separately.

Reentrant guard/unwind behavior has a source-level argument, not an injected
mid-fill native-exit demonstration.
No arbitrary metadata mutation, asynchronous interruption, target no-allocation,
closed-dispatch, or full model-description admission is claimed.

Indexed identity callbacks, compound kind names, CAS, managed callable roots,
language integration, all current benchmark runs and target admission remain
separate open work. The historical GCBench acceptance at `113aa6a` is not a run
of this implementation.
