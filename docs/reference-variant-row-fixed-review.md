# Independent review: immutable canonical-code rows

## Scoped verdict

**No blocker found in the reviewed serialized hosted row-closure contract.**
The implementation closes the observed moving reconstruction-capacity gap
without retargeting historical references, recycling records, or increasing H.
This is not full framework conformance or target/concurrent admission.

Snapshot: `/tmp/clamsara-variant-row-review-bnum_11t`.
Manifest base: `4e7c28f`, plus 19 recorded overlays. All 41 source hashes and all
19 overlay hashes matched before and after this review. No live source,
dependency, snapshot implementation, or old review artifact was changed.

The independent native result is **120 cases passed, exit 0**:

- 108 original acceptance cases, replayed outside the integration namespace;
- 12 new bounded edge cases, described separately below.

Final runner/log: `bootstrap-02.lisp`, `native-02.log` in this directory.
The native slot was explicitly released and is now back with the parent.

## Source argument

References below are to `src/host/object-model.lisp` in this snapshot.

1. **Admission and exact offers.** The constructor (line 165) admits H as a
   nonnegative fixnum. Binding (589 onward) retains the complete installed cell
   count C, including reserve/mature ranges at their actual granularities. H=0
   allocates no variant records. Positive H<C rejects before binding publication.
   The vector has exactly H preallocated records; no offer is rounded upward.

2. **Canonical codes.** Decode/pack (934–954) operates on bounded private hosted
   descriptor ranges. Tagged-base aliases mask to the same 16-bit tag. Kind
   occupies the low two bits, tag the next 16, and displacement starts at bit 18.
   Admitted decoded ranges do not overlap those fields. A base value uses no
   row. Malformed or object-incompatible forms reject before materialization.

3. **Whole-domain closure.** Publication (966–1017) reserves C entries only when
   the entire row fits. It visits all precreated descriptor indices, regardless
   of current liveness, ownership role, or current object size. It skips only
   `displacement >= route-limit - cell-address`, while still charging the slot.
   Initialization (1190 onward) requires `address + size <= route-limit`, and
   reconstruction (1019 onward) requires `displacement < size`. Therefore no
   valid initialized destination can request a skipped record. Unexposed bases
   remain accepted for reconstruction; authoritative publication is still needed
   for normalization.

4. **Stable lookup and commit.** A directory entry selects `row-start + index`.
   Existing codes never consume another row. There are at least twice as many
   directory slots as `floor(H/C)` admitted codes, with linear probing and no
   deletion, so a new-code capacity refusal cannot first encounter a full valid
   directory. Filling has no client callbacks or ordinary failure branch after
   preflight. It writes only existing records. Row offset and count publish
   before the key, which is written last. A guard rejects reentry and is cleared
   by `unwind-protect`. This is a serialized publication argument, not rollback
   of arbitrary asynchronous interruptions or private-accessor fault injection.
   No path decrements the historical variant count.

5. **Finite row arithmetic.** Positive-H binding requires fixnum route bounds
   and room for all 46-bit canonical codes. The largest pure-interior packed
   code is below `2^46`; tagged-base and tagged-interior codes are smaller.
   Eligible address additions are strictly below the fixed route limit. Row
   indices/counts are bounded by H. Power-of-two directory indexing is bounded
   by the admitted native vector size. This supports the row's arithmetic
   argument on this SBCL profile; it is not a blanket proof of all generic-call
   or supervisor allocation freedom.

6. **Static geometry.** `src/host/address-space.lisp:178–190` rejects an ownership
   replacement with different map granularity before pending/capability/counter
   changes. Existing coverage/alignment checks retain the same cell grid when
   granularities agree. Owner/map/generation changes then leave the fixed
   descriptor indexing valid. The parent added positive/negative ownership
   controls; my replay covers mixed 8/16-byte maps without changing their grids.

7. **Accounting.** The model manifest (2045 onward) registers all H records,
   their vector, and both directory vectors, including unused tail/hole records.
   Codes/addresses retained by row filling are bounded fixnums. The additional
   native tests independently reconstruct resource charges from closed manifests
   and verify row/directory membership and unchanged charges after first
   materialization, rejection, and movement.

## Original 108-case replay

The replay copies the original independent fixture/cases and corrected
promotion oracle into new artifacts. Its only aggregate-runner repair is the
already disclosed `(plusp *failed*)` truth test. It does not use the parent's
code-to-row directory to decide these original requirements.

All 108 pass: exact H boundaries 0/1/C−1/C/2C−1/2C/2C+3; real rejected-builder
unwind; canonical aliases; pre-effect byte/field preservation; all descriptor
cells and immutable address reuse; inactive/reserve/future larger destinations;
both collectors and both maps at fine and mixed granularities; rooted graph
movement; staging/unexposed destinations; and four nursery-to-mature histories.
Successful fixtures discharge normally. No failed collection was force-closed.

The integrated fixture matches the independent fixture apart from namespace,
provenance header, and the optional-runner export. The parent split 104 ordinary
cases from four optional promotion cases and fixed the aggregate truth test.
Its separate four 20-code collision histories were source-reviewed here, not
counted among my 120 native cases.

## Additional 12 cases

**Eight endpoint-hole cases:** both algorithms/maps at 8/16-byte map granularity.
Invalid forms before first materialization leave bytes, descriptor planes,
records, directory, and guard unchanged. After displacement 31 reserves one
whole C row, a valid but unexposed 16-byte object near each route end cannot
rebuild that form. These holes do not buy a second code. Three real collections
preserve the rooted 64-byte object, displacement, payload, directory, and rows.

**Four maximum-field cases:** both algorithms/maps. Each space is 2 MiB, with
an explicit **1 MiB packing/map quantum and two descriptor cells per space**.
Thus C=4/H=12 for SemiSpace and C=2/H=6 for MarkSweep. One real 1 MiB leaf is
rooted in three admitted forms:

- maximum tagged-base tag 65535, including alias `#x2fffffff`;
- pure-interior displacement 1,048,575;
- maximum tagged-interior descriptor `#x3fffffff`: tag 255 and displacement
  1,048,575, the actual decoder field maxima.

Invalid descriptors and a fourth valid code reject without state changes.
Three real cycles preserve all three forms, first/last payload bytes, expected
moving/nonmoving bases, and unchanged directory/record storage. Exact accounting
is checked before materialization and after collection.

This does **not** natively test the maximum 28-bit pure-interior displacement;
that larger packed-code bound is a source argument. The deliberately coarse
geometry is an explicit edge fixture, not a reduced benchmark or a dense
large-array capacity claim.

## Fixture changes and limits

Source review found explicit H=0 offers on base-only workload/quality/runtime
fixtures, with no removed roots, assertions, or changed guest heap extents to
make row admission pass. Nonbase fixtures offer full rows: normally 3C, exactly
C for second-code exhaustion, and explicit row multiples in the new suites.
The workload sources do not manufacture hosted nonbase forms. The large-array
fixture's H=0 change removes an unused reserve; it is not performance evidence.

The parent's full-ASDF, ownership RED/control, and 500k results are separate
parent-run evidence. I did not rerun those gates. Target code placement/CLOS
admission, concurrent/asynchronous publication, arbitrary injected mid-fill
faults, and broader descriptor/callback issues remain outside this verdict.
The design document still contains draft “not yet compiled”/“Pending” wording;
update that status when archiving final evidence rather than treating it as a
current test report.

## Preserved harness correction

`native-01.log` already passes the original 108 cases. My added accounting helper
then used `mapcar` on the vector capacity account, so all 12 extra cases stopped
before their semantic checks. `additional-checks.lisp` and that log are preserved.
`additional-checks-02.lisp` changes only that traversal to `map 'list`; the final
run passes all 120. This was a test bug, not an implementation failure.

Run records, source-integrity checks, source notes, and artifact hashes accompany
this report. No source/implementation failure was suppressed.
