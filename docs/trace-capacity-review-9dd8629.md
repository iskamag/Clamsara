# Trace-capacity probe: results (frozen 9dd8629, 4096-scale diagnostic)

Run under the native slot released by the geometry reviewer. Three complete runs,
each one fresh SBCL process, same probe file, frozen snapshot only. The slot is
released again after this report; no other SBCL/ASDF process was started by this
work outside these three runs (plus three failed pre-run attempts described
below, all of which exited before completing a world).

## Provenance (per run)

| Run | SBCL exit | Duration | Frozen tree | Pins before/after | Probe sha256 |
|---|---|---|---|---|---|
| 1 (`trace-capacity-probe-run1.log`) | 0 | 0.738 s | 167/167 files, added/removed/changed = none | match/match | `9d531948ad3642fe92fd47367c66751f21f1a1100f1b698b3f0ae830a6913701` |
| 2 (`trace-capacity-probe-run2.log`) | 0 | 0.737 s | 167/167 files, added/removed/changed = none | match/match | same |
| 3 (`trace-capacity-probe-run3.log`) | 0 | 0.739 s | 167/167 files, added/removed/changed = none | match/match | same |

- Command, environment and ASDF selection are recorded in each log header and in
  the `:ASDF-SELECTION` line: `:SOURCE-DIRECTORY "/tmp/clamsara-description-review-7p14doks"`,
  `:SYSTEM-FILE ".../clamsara.asd"`, ASDF 3.3.1, SBCL 2.6.8.3, `:CENTRAL-REGISTRY NIL`,
  `CL_SOURCE_REGISTRY=/tmp/clamsara-description-review-7p14doks///`,
  `CLAMSARA_PROBE_ROOT` set, `:PROBE-FILE` under this artifact directory.
- 42 pinned files (41 `review-snapshot.json` sources + `test/quality/support.lisp`)
  matched before and after every run, verified both by the runner (Python
  `hashlib`) and inside the probe (`sha256sum`, `:HASH-METHOD :SHA256SUM`).
- Runner sha256 `db3795e649ff850d8d54d8fe3ca696150c39ab685403edc39df3e4b3f670103d`;
  unchanged since the first successful run. Probe file was not edited after the
  three runs (`9d531948...` as logged).
- Three earlier attempts failed before completing the comparison and were not
  counted: (a) `--dynamic-space-size` placed after a Lisp option (runtime option
  ordering), (b) `*load-truename*` read at call time instead of load time,
  (c) `reference-address` called on a retired source encoding. Each failed run
  left the frozen tree unchanged. Their fixes are in the probe/runner; the three
  logged runs use the fixed files.
- One further run set (kept as `trace-capacity-probe-run{1,2,3}-exact-median.log`)
  printed exact rational medians (for example `:MEDIAN-MICROSECONDS 609/2`) when
  two middle samples averaged to a half microsecond. `%median` now rounds to
  whole microseconds; the pooled tables below come from the rounded runs.

## Structural results (all observed, all green in all 12 worlds)

| Quantity | trace 128 | trace 8324 | Meaning |
|---|---|---|---|
| plan handle length | 2384 | 84344 | `10*trace + 8*128 + 5*16`; `:PLAN-FORMULA-MATCHES-HANDLE T` |
| plan physical bytes | 19088 | 674768 | handle primitive size + padding, from the immutable capacity account |
| plan auxiliary bytes | 19568 | 19568 | identical: the 15 displaced views share the one acquired handle |
| descriptor cells | 16 | 16 | `2 spaces * 128/16`; model capacity 16 = exact admission floor |
| base-reference primitive size | 64 | 64 | one `host-reference` struct per descriptor cell, 64 B |
| stop history | 26 used / 64 | 26 used / 64 | warm-up + 24 measured + 1 discharge, observed `:STOP-NEXT` |
| trace counters per cycle | reserved/committed/take = 8/8/8 | 8/8/8 | 8 source objects claimed, committed and drained |
| cycle counters per cycle | discovered 8, moved 8, bytes 128 | same | real moving graph, all survivors |
| live representations after cycle | 8 | 8 | sources retired, destinations retained |
| discharge | `:COMPLETE`, 0 moved, live 0 | same | owner-driven: roots cleared by the probe first |
| close | unbind `:UNBOUND`, shutdown `:COMPLETE`/nil | same | clean close in every world |

`GEOMETRY-MATCH T` held across all four worlds of all runs: every geometry field
was equal, including arena/words/descriptor plane lengths, model capacities,
map granularity and root/registry/stop capacities. The trace capacity is the only
declared difference, plus its plan storage.

Per-cycle graph assertions (8 objects, 26 cycles per world, 4 worlds per run,
3 runs): payload ids preserved, chain addresses equal to the successor root,
every object moved to a different address each cycle, retired source encodings no
longer normalize, and live count exactly 8 after each cycle. No assertion failed
in any world (`:HARD-CLOSE` count 0 in all logs).

## Timing results (microseconds per collection, `sb-ext:get-time-of-day`, granularity 1 µs)

Per world (24 measured collections each; warm-up excluded):

| Run | World | trace | min | median | max |
|---|---|---|---|---|---|
| 1 | R0 | 128 | 260 | 272 | 4115 |
| 1 | R0 | 8324 | 285 | 304 | 24936 |
| 1 | R1 | 128 | 261 | 269 | 286 |
| 1 | R1 | 8324 | 271 | 278 | 297 |
| 2 | R0 | 128 | 264 | 270 | 3830 |
| 2 | R0 | 8324 | 285 | 306 | 25855 |
| 2 | R1 | 128 | 262 | 270 | 280 |
| 2 | R1 | 8324 | 271 | 275 | 306 |
| 3 | R0 | 128 | 262 | 269 | 3814 |
| 3 | R0 | 8324 | 284 | 306 | 389 |
| 3 | R1 | 128 | 263 | 268 | 283 |
| 3 | R1 | 8324 | 268 | 271 | 304 |

Pooled (144 samples per capacity, 3 runs):

| Set | n | min | p10 | median | p90 | max | mean |
|---|---|---|---|---|---|---|---|
| trace 128, all samples | 144 | 260 | 264 | 269 | 286 | 4115 | 348.0 |
| trace 8324, all samples | 144 | 268 | 271 | 285 | 313 | 25855 | 641.2 |
| trace 128, steady second world only (post-hoc subset) | 72 | 261 | 265 | 269 | 278 | 286 | 270.0 |
| trace 8324, steady second world only (post-hoc subset) | 72 | 268 | 270 | 274.5 | 284 | 306 | 276.6 |

- Median delta +16 µs (all samples), min delta +8 µs; the pre-declared
  `RANGES-DISJOINT` criterion is **not met** (NIL), because of process-level
  outliers described below.
- On the post-hoc steady-state subset (second world of each run) the median delta
  is +5.5 µs and the min delta +7 µs, with overlapping ranges.
- Outliers are not distributed randomly: the 128-world outliers (3814-4115 µs)
  are always at measured cycle 1 of the first world; the 8324-world outliers
  (24936, 25855 µs) appear at measured cycle 19 of the first world in two of three
  runs and not at all in the third. They look like process-level events (for
  example a SBCL collection after construction) rather than collector behavior;
  the second world in each run has no outlier above 389 µs.

## Mechanism consistency (derived vs measured)

The derived extra work per collection is `6 * (8324 - 128) = 49176` fill-slot
writes (5 arrays in `%reset-trace-context` plus `retirement-starts` in
`%reset-cycle`; derived from frozen source, not observed). The measured deltas
imply:

| Estimate | Delta | Implied cost per extra slot |
|---|---|---|
| pooled median | +16 µs | 0.33 ns |
| pooled minimum | +8 µs | 0.16 ns |
| steady-state median | +5.5 µs | 0.11 ns |
| steady-state minimum | +7 µs | 0.14 ns |

0.1-0.3 ns per stored word is a plausible memory-bound `fill` rate, so the
direction and magnitude of the measured difference are consistent with the
derived fill mechanism. The measurement does **not** formally resolve the effect
(overlapping ranges); it corroborates it. Do not read these numbers as a
benchmark: one process per run, no isolation, no pinning, 128-byte semispaces.

## Corrections and confirmations for the earlier review

1. **Per-cell `host-reference` struct size is 64 B (observed).** The review's
   estimate was 56-64 B. For the 500,000-element snapshot this makes the per-cell
   structs 1,000,132 x 64 = 64,008,448 B (61.1 MiB), which the reported
   `FIXED-MODEL-PLANE-BYTES 80011312` does not include. Corrected fixed model
   retained estimate: 80,011,312 (plane spines) + 64,008,448 (structs) + 8,000,064
   (stage arrays) = 152,019,824 B (~145 MiB) versus the reported 80,011,312 B, so
   the reported plane figure understates model retained storage by ~1.9x (not
   ~1.8x). The auxiliary total 160,290,512 B is consistent with that plus the two
   forwarding vectors (8,001,088), the two packed maps (125,056) and small
   records.
2. **Plan accounting formula confirmed at two capacities.** Handle length is
   exactly `10*trace + 8*conditional + 5*finalizer` (2384 and 84344, both
   matching `%runtime-object-entry-count`), and the capacity-account physical
   value is handle primitive size plus padding (19,088 and 674,768). This is the
   same accounting path the review derived for the 500,000-element run, where it
   explained 83% of `ACCOUNT-PHYSICAL-BYTES` as the plan trace vector.
3. **Displaced views share one handle.** Plan auxiliary bytes are identical
   (19,568) at both trace capacities, confirming the design note that displaced
   arrays do not duplicate the acquired vector; the difference appears only in the
   handle length/physical bytes.

## Scope and non-claims

Diagnostic for one question on the frozen 9dd8629 tree: two freshly constructed
worlds per round, identical offers except `:TRACE-CAPACITY` (128 vs 8324), 8-object
chain graph, 128-byte semispaces, packed object starts, SemiSpace only, Q=16,
model capacity 16, four worlds per run in one process, 24 measured collections per
world. Not Gabriel, not GCBench, not target acceptance, not a benchmark, not
Mezzano/supervisor evidence. No claim about MarkSweep, generational plans, arrays,
weak/ephemeron/finalizer workloads, or the 500,000-element geometry. The only
files created during the runs are logs in this directory; the frozen tree is
byte-identical (167/167 files).

## Artifacts

| File | Content |
|---|---|
| `trace-capacity-probe.lisp` | Probe (sha256 `9d531948ad36...`, the file the logs record). |
| `run-trace-capacity-probe.py` | Runner with hash/tree verification (sha256 `db3795e649ff...`). |
| `PROBE-NOTES.md` | Design, offers, and how to read the log. |
| `trace-capacity-probe-run{1,2,3}.log` | Three complete runs (canonical `trace-capacity-probe.log` is run 3). |
| `trace-capacity-probe-run{1,2,3}-exact-median.log` | Earlier run set that printed rational medians; kept for provenance. |
| `trace-capacity-probe-pooled.json` | Machine-readable per-world samples and pooled statistics. |
| `performance-storage-honesty-review.md` | The review this probe follows from (preserved verbatim by the parent elsewhere). |
