# Addendum: scope, process accounting, collection accounting, and timing wording

Source/log-only clarification requested by the parent. **No native process was
started for this addendum.** The original report
(`performance-storage-honesty-review.md`), `PROBE-NOTES.md`, the probe, the runner
and every probe log are byte-identical to their state at hand-off; hashes are
listed at the end of this file and nothing outside this new file was written.
This addendum does not replace the results file
(`trace-capacity-probe-results.md`); it corrects its framing in four places.

## 1. Why the 4096-element array comparison was replaced

The probe that ran is an 8-object / 128-byte-semispaces chain diagnostic, **not**
the variable-array world. The replacement was forced by two frozen-source facts:

1. **The array fixture has no trace-capacity keyword.**
   `test/quality/model-resources.lisp` builds the 4096-element array world in
   `make-model-world`, which hardcodes the trace bound at line 143:
   `:trace-capacity (ceiling actual-extent q)`. Changing the declared trace
   capacity there would require editing that fixture, mutating a constructed plan,
   or adding a new fixture inside the frozen tree. All three were excluded by the
   task constraints.
2. **The requested low value is inadmissible for that heap.**
   `validate-component` for a `sequential-runtime-plan` requires
   `trace-capacity >= max over semispace spaces of (extent / packing-quantum)`
   (`src/runtime/records.lisp:484-493`). For the 4096-element array geometry the
   extent is `align-up(2*32784 + 1024, 16) = 66592`
   (`test/quality/model-resources.lisp:1361-1364`), so the required trace capacity
   is `66592 / 16 = 4162`. A declared 128 would be rejected with
   `:invalid-trace-capacity`. "Identical 4096-element geometry, trace 128 vs 8324"
   is therefore **not constructible**, not merely inconvenient.

Two further details belong in the record:

- The review's own proposal mixed two numbers: `8324` is that geometry's *model
  admission capacity* (`2*extent/Q`, `test/quality/model-resources.lisp:1551`),
  not its trace capacity, which is `4162`. The review's `:143` citation was right;
  the "128 vs 8324" pairing was not.
- For the array shape, a legal same-geometry comparison would have been
  **4162 vs 8324** (6 x 4162 = 24,972 vs 6 x 8324 = 49,944 derived fill slots per
  collection), i.e. a factor-2 trace-bound difference rather than the requested
  factor-65 one. That variant was not run and is not claimed.

What was done instead, and why it is still a fixed-geometry bound comparison:

- `test/quality/support.lisp`'s `make-quality-world` **does** expose
  `:trace-capacity` (`:92`), `:object-capacity`, `:extent`, `:map-granularity` and
  `:configure-model`, and passes the trace capacity to the plan (`:195`, `:210`).
  No new fixture was needed and no repository source was touched.
- Admissibility then bounds the requested pair from the other side: with trace 128
  admissible, `extent/Q <= 128`, i.e. `extent <= 2048` at Q=16. The smallest legal
  geometry was chosen (extent 128 -> 8 cells per space, required trace 8, model
  capacity 16 = `2*extent/Q` = exact admission floor), so the 8 x 16-byte leaves
  fill one space exactly and copy work stays minimal.

Honest consequence: the executed diagnostic contains **no arrays, no indexed
layouts and no element callbacks**, and says nothing about the 4096-element shape.
The array scan/copy claims in the review rest only on the earlier 4096/500,000
element logs (pre-commit working tree), never on this probe. The probe addresses
only the fixed-cost side of the question: plan storage and declared trace capacity
at a fixed, minimal geometry.

## 2. Exact process count

Total SBCL processes started for this diagnostic work: **14**.

| # | Process | Purpose | Outcome |
|---|---|---|---|
| 1 | runner attempt 1 | full probe | failed: `--dynamic-space-size` placed after a Lisp option (runtime-option order) |
| 2 | runner attempt 2 | full probe | failed: `(truename *load-truename*)` with `*load-truename*` NIL at `--eval` time |
| 3 | direct interrogation | print `asdf:system-source-directory` / `system-source-file` | exit 0 (confirmed the private snapshot directory) |
| 4 | direct interrogation | load support + probe; print `*probe-root*`, truename, source dir | exit 0 |
| 5 | direct interrogation | call `%assert-frozen-source` only | exit 0 (`:ASDF-SELECTION` = frozen root) |
| 6 | direct interrogation | clock availability and `internal-time-units-per-second` | exit 0 (`sb-ext:get-time-of-day`, 1,000,000 units/s) |
| 7 | runner attempt 3 | full probe | failed: `reference-address` on a retired source encoding (warm-up movement check) |
| 8 | runner attempt 4 | full probe | failed: geometry comparison read `simulator-stop-base` (token identity base) as capacity |
| 9 | runner attempt 5 | full probe | **PASS** -> `trace-capacity-probe-run1-exact-median.log` |
| 10 | runner attempt 6 | full probe | **PASS** -> `trace-capacity-probe-run2-exact-median.log` |
| 11 | runner attempt 7 | full probe | **PASS** -> `trace-capacity-probe-run3-exact-median.log` |
| 12 | runner attempt 8 | full probe, after median rounding | **PASS** -> `trace-capacity-probe-run1.log` |
| 13 | runner attempt 9 | full probe | **PASS** -> `trace-capacity-probe-run2.log` |
| 14 | runner attempt 10 | full probe | **PASS** -> `trace-capacity-probe-run3.log` (= canonical `trace-capacity-probe.log`) |

Breakdown: **10 runner invocations** (4 failed, 6 complete) plus **4 direct
interrogation runs**. Of the 6 complete runs, 3 are the pre-fix exact-median set
and 3 are the rounded-median set that the results file pools.

Non-SBCL processes, for completeness: the runner's hash and tree checks use Python
`hashlib` with no subprocess; each probe process that reaches the hash step runs
`sha256sum` 8 times before and 8 times after the worlds (not SBCL, no collector
state); two `--check-only` runner invocations are Python-only and started no SBCL.
No ASDF process was started outside SBCL.

Evidence limit: the runner logs to a fixed path, so attempts 1-8 left no retained
log file; their outcomes are recorded in this table from the session, not from an
artifact. Attempts 9-14 are fully retained (6 logs). The frozen tree was verified
byte-identical after every run that reached the verification step (167/167 files,
42 pins matching before and after).

## 3. Collection accounting per world: 25 survivor + 1 discharge

Confirmed from the retained logs of the 6 complete runs (24 worlds total).

- **26 collections per world**, observed as `:STOP-NEXT 26` against the 64-entry
  stop history in every one of the 24 worlds; this equals 1 warm-up + 24 measured
  + 1 discharge.
- **25 survivor collections per world** (the 1 warm-up `:CYCLE :WARMUP` plus the 24
  measured samples). Every one of the 600 survivor collections across the 24
  worlds records `:STATUS :COMPLETE`, `:OBJECTS-DISCOVERED 8`, `:OBJECTS-MOVED 8`,
  `:BYTES-MOVED 128`, `:LIVE-AFTER 8`. Total survivor moves: 600 x 8 = 4,800
  objects; 4,800 x 16 = 76,800 bytes.
- **1 discharge per world** with the root set cleared by the probe first
  (owner-driven): every one of the 24 discharge records is `:STATUS :COMPLETE`,
  `:DISCHARGE-MOVED 0`, `:LIVE-AFTER-DISCHARGE 0`, followed by unbind `:UNBOUND`
  and shutdown `:COMPLETE` with nil reason.
- **Precision caveat:** the discharge record in the log does not carry
  `:OBJECTS-DISCOVERED` (the probe did not extract that counter for the discharge).
  "Zero discoveries at discharge" is inferred from the empty root set plus the
  observed 0 moves and 0 live representations; it is not an observed field. The
  discharge is also not an eight-object cycle in the survivor sense: it observes
  0 moves.
- The parent's phrasing is therefore correct and now evidenced: **25 survivor
  collections plus 1 zero-live discharge per world, not 26 eight-object cycles.**

## 4. Timing wording: compatible with, not isolating or causal

The results file said the deltas "corroborate" the derived 6-fill mechanism. That
is too strong. Corrected wording:

- The 6 fills per collection (5 arrays in `%reset-trace-context`,
  `src/runtime/trace.lisp:22-26`; 1 retirement array in `%reset-cycle`,
  `src/runtime/cycle.lisp:26-40`) and the 49,176 extra fill slots per collection
  (6 x (8324 - 128)) are **derived from source, not observed writes**. No plan or
  trace counter measures fill work, and the probe installs no instrumentation.
- The measured per-collection deltas (pooled +16 us median, +8 us minimum:
  0.16-0.33 ns per derived extra slot) are **compatible with** that derived work.
  They do not isolate it and do not establish causality, because:
  1. the two worlds differ in more than the fill count: plan handle length 2384 vs
     84,344 elements, capacity-account physical bytes 19,088 vs 674,768, and hence
     allocated footprint, locality and potential collection behaviour;
  2. the sample distributions overlap (`:RANGES-DISJOINT NIL`): the 128-world
     outliers are first-cycle process effects and the 8324-world ~25 ms events at
     measured cycle 19 of the first world are unexplained process-level events;
  3. no run varied the fill count independently of plan storage, so the fill arrays
     cannot be separated from the handle footprint in this data;
  4. 24 measured collections per world in one process per run, with no isolation or
     CPU pinning; the steady second-world subset was a post-hoc cut.

To isolate the mechanism one would need, for example, the same trace capacity with
different fill-array counts, or an observed fill/write counter, or repeated
process-level runs with the confounds controlled. Until then the timing numbers
support no more than "direction and magnitude are compatible with the derived fill
cost"; they must not be cited as evidence of the mechanism.

## Artifact hashes at hand-off (nothing below was edited for this addendum)

| File | sha256 |
|---|---|
| `performance-storage-honesty-review.md` | `b191d9fe3714c8cc6a49b39604fd549afc658e47d0c00cde38bd6c66b35bcfba` |
| `PROBE-NOTES.md` | `f42fd03b76cbf7ba2f544fa16d138cc92f33f326614ce2d5dc3dac6236816118` |
| `trace-capacity-probe-results.md` | `fae0816e6e1b11b5f8d5fcb3ad3a8503ad90ab81dd4381da713f3a407bc1a106` |
| `trace-capacity-probe.lisp` | `9d531948ad3642fe92fd47367c66751f21f1a1100f1b698b3f0ae830a6913701` |
| `run-trace-capacity-probe.py` | `db3795e649ff850d8d54d8fe3ca696150c39ab685403edc39df3e4b3f670103d` |
| `trace-capacity-probe.log` (= run 3) | `931097568ed7163f6d4555b90b2e2afc5945a71d8146ccb62f37a5aa044925ac` |
| `trace-capacity-probe-run1.log` | `37aeb42e22a51a0ad54371591b844669dc8f87e6c1e904be1613c0e5238315a7` |
| `trace-capacity-probe-run2.log` | `de8c1e05706f666a220fd79ddefb725b551257148bbf7a50cb559d0cf902cc52` |
| `trace-capacity-probe-run3.log` | `931097568ed7163f6d4555b90b2e2afc5945a71d8146ccb62f37a5aa044925ac` |
| `trace-capacity-probe-run1-exact-median.log` | `c14000f5e896baaebc9ae2a253d4c3107d2d67b9ba4940c11698b6bac99ae100` |
| `trace-capacity-probe-run2-exact-median.log` | `fc3c28dfe03548039da99379755491756c32c6c52cefad5b0acf59060c9a7f66` |
| `trace-capacity-probe-run3-exact-median.log` | `c1691d52973973db9c663687f6f9c97168cf8e37ac43e6e83c5d5bcb56c25fcd` |
| `trace-capacity-probe-pooled.json` | `ba36e7bd33d590bd133f52cac3df4713ae520ab9e5d4271f56248a838029b8ef` |
| `trace-capacity-probe-addendum.md` (this file) | computed after writing, not listed here |

Scope of this addendum: clarification only. It adds no new execution, no new
measurement, and no change to any claim about collector behaviour, Gabriel/GCBench
or target acceptance. The structural findings that do not depend on timing (plan
handle/physical/auxiliary lengths, 64-byte base-reference struct, stop-history and
discharge bookkeeping, 25 survivor + 1 discharge per world) remain as reported.
