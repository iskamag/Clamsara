# Variant-row evidence provenance

These are unchanged artifact copies, outside the ASDF source closure. Paths in
historical runners still name their original work directories. They are not
portable installed test entry points. Current integrated tests live under
`test/quality/reference-variant*.lisp` and are selected by canonical ASDF systems.

Independent source baseline: frozen `9dd8629` at
`/tmp/clamsara-description-review-7p14doks`. The independent corrected RED run
executes 108 cases, 44 pass and 64 fail actual row-policy assertions, exit 1.
Original files, hashes, first-run generational-oracle error, and the aggregate
CL-zero truth bug are described in the unchanged review and separate addendum:
`docs/reference-variant-row-acceptance-review.md` and
`docs/reference-variant-row-harness-addendum.md`.

The archived original aggregate always signals because `(when *failed* ...)`
treats zero as true. That does not turn its 64 baseline per-case failures into
passes. The first parent replay really logs 108 passes/0 case failures, but
its aggregate exit 1 is not called an accepted run. Only the integrated copy
corrects the guard with PLUSP. It splits 104 cases into the main-selected suite
and four into optional generation tests, without dropping their assertions.
Four parent directory histories separately cover 20 forms/collisions/immutable
fields through collections; two ownership controls test the fixed-granularity
restriction. The ownership baseline RED does not claim observed corruption.

Parent patch base: `4e7c28f`. Production matches the 41 hashes in
`/tmp/clamsara-variant-row-review-bnum_11t/review-snapshot.json`; that snapshot
also records 19 implementation/test/design overlays. Parent source/test/ASDF
pins are copied here; they remained unchanged during full and 500k gates.
The fixed-snapshot independent replay now passes 108 original cases plus 12
new edge/account cases; its bounded final report is preserved unchanged at
`docs/reference-variant-row-fixed-review.md`, with a separate integration note.

Parent focused PID2337 exits 0 (3.223 seconds). Parent full PID2390 exits 0
(4.877 seconds); tools intentionally compile a malformed IF, and dependency/
workload diagnostics include known warnings. Parent 500k PID2467 exits 0
(6.048 seconds). These durations include native startup, compilation/reporting
where applicable, and test bookkeeping; they are not performance isolation.
The first focused attempt had a misspelled test layout accessor; the second
missed a base-only fixture's explicit H=0 offer. Their logs remain in /tmp and
are disclosed in the design note; they are not successful evidence.

All 20 benchmark fixtures and the normative paper hashes match. The array run
keeps guest geometry unchanged; its newly explicit H=0 and smaller code directory
change auxiliary overhead. It measures two explicit reference scans, not all
collector callbacks. No full Gabriel/GCBench, target or no-allocation claim follows.

`sha256.json` identifies the copied artifacts. No historical source, report,
runner or log was edited to remove a failure.

## Fixed-snapshot and final integration follow-up

`fixed-independent-native-02.log` exits 0 with 108+12 passes. The preceding
`native-01` and additional-checks source preserve a test helper's MAPCAR-on-vector
failure; MAP LIST corrects the helper. The fixed original case runner only
changes the erroneous CL-zero guard. Fixture/generation sources are identical
to the original archived copies. No implementation override is installed.

The 12 new cases are copied into the main ASDF suite with a namespace change
and unused MAP loop binding/declaration removal. The final full parent process
PID2952 exits 0 (4.868 seconds): 104 independent base cases, 12 independent edge
cases, four parent directory cases, four independent optional promotion cases,
and all existing main/tools/workload/generation/structure tests. It explicitly
asserts the source directory. Final source/test/ASDF hashes remain unchanged
during that run; production still matches all 41 independently reviewed hashes.
An earlier successful integration run had only a nested IGNORE style warning,
removed before this final run. The 500k log predates only these test additions,
not any production change.

## Normative-paper path correction

The frozen snapshot manifest's `paper_root` names a nonexistent directory.
The reviewer confirmed that the row reviews used the supplied contract/proposal
and prior reference context, not a fresh direct normative-paper read elsewhere.
See `docs/reference-variant-row-provenance-addendum.md`. The original manifest,
reports, source hashes and native results remain unchanged. Parent checks of
the real normative paper are separate evidence, not independent paper review.
