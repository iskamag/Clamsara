# DeepSeek 4.1 Flash review: performance/storage claim honesty (frozen 9dd8629)

- Reviewer: DeepSeek 4.1 Flash subagent (read-only review, source/log analysis only).
- Subject: frozen snapshot `/tmp/clamsara-description-review-7p14doks`, commit `9dd8629`
  ("Admit source and destination representation capacity before binding").
- Normative paper: `/tmp/clamsara-independent-review-3ygbx_br/paper-v14`.
- Evidence logs: `/tmp/clamsara-capacity-array-stress.log`,
  `/tmp/clamsara-representation-capacity-final.log`, plus the earlier 500k logs.
- No SBCL/ASDF/benchmark was launched. No source, fixture, paper or existing artifact was
  modified. This review wrote only this file.
- Depth: bounded review of dense model representation, array scan/copy, representation
  capacity, accounting, counters and tests. Not whole-project acceptance; no benchmark,
  no Gabriel, no target admission, no current-tree GCBench claim.

## 0. Verdict (short)

The numeric storage claims in the frozen snapshot are reproducible and were not
inflated. I re-derived every headline number of the 500,000-element run from frozen
source and Git history, to within ~150 bytes:

- the object/extent/capacity/bytes-moved arithmetic is exact;
- `FIXED-MODEL-PLANE-BYTES 80011312` is an exact shallow sum of the 15 top-level plane
  vectors (I reproduced 80011312 - 752 = 80010560 as the array-data sum, and the same
  752-byte header slack reproduces the 4096-element run exactly);
- `ACCOUNT-PHYSICAL-BYTES 48133504` is explained within 142 bytes by
  `%runtime-object-entry-count` (10x trace) + two forwarding vectors + two packed maps +
  registry; 83% of it is the plan trace-object vector, which holds no guest object;
- `ACCOUNT-AUXILIARY-BYTES 160290512` is explained by the plane spines + one
  `host-reference` struct per descriptor cell + stage buffers + forwarding/maps;
- the log-to-log deltas (physical +512, auxiliary +7808) are deterministic and
  attributable to the finalizer registration-history change (64 entries x 8 = 512), not
  drift.

Three presentational weaknesses are real and worth fixing in the docs (not fatal):

1. `:fixed-model-plane-bytes` counts only top-level plane vectors. It excludes the
   1,000,132 per-cell `host-reference` structs (56-64 B each, ~56-64 MB) and the stage's
   nested `bytes`/`words` arrays (~8 MB), which are charged only in the auxiliary
   manifest. The reported figure understates the model's retained storage by ~1.8x, and it
   is printed next to a smaller "account-physical" number, which invites misreading.
2. The marginal "capacity" pair in the 500k log (`MODEL-REPRESENTATION-CAPACITY` =
   `MODEL-DESCRIPTOR-CELLS` = 1000132) is a fixture formula, not an exercised bound: the
   run peaks at 4 simultaneous representations. The real boundary evidence is the
   4096-scale representation-capacity suite (24 rejections, 16 full-survivor histories
   reaching live-count = capacity = 16).
3. `:reference-callbacks 500000` / `:numeric-strong-callbacks 0` in the printed evidence
   plist are a parameter and a literal, not measured counters; and the workload actually
   performs ~3 element scans (~1.5M mapper/strong callbacks), so 500000 under-reports the
   callback total by about 3x.

No hidden quadratic work exists in the exercised 500k path. The scan/copy paths are
linear in elements/bytes with heavy byte-level constants. Two unexercised superlinear
candidates are identified below as source hypotheses (MarkSweep first-fit free list,
borrow-pool scan), plus test messages that claim complexity properties they cannot
establish.

## 1. Snapshot and log provenance (important caveat)

`review-snapshot.json` pins 41 sources; all 41 sha256 values match the files in
`/tmp/clamsara-description-review-7p14doks` (checked: 41/41). `git show
9dd8629:src/host/object-model.lisp | sha256sum` equals the snapshot's
`src/host/object-model.lisp` hash, so the snapshot is the committed revision. HEAD is
`9dd8629` (committed 2026-09-20T20:11:24+05:00).

The evidence logs are **not** snapshot-pure executions:

- `/tmp/clamsara-capacity-array-stress.log` was written 20:01:08, and `/tmp/clamsara-
  representation-capacity-final.log` 20:05:36 - both ~6-10 minutes **before** the commit
  (20:11:24). Both compile the live tree (`; compiling file
  "/home/iskam/src/vibe/Clamsara/..."`), and the stress log compiles
  `src/host/object-model.lisp` "written 20 SEP 2026 08:01:02 PM".
- The commit was created from that working tree, so content equality is likely, but it is
  not cryptographically established by the artifacts.
- The live tree today differs from the frozen snapshot in exactly two files,
  `src/host/object-model.lisp` and `test/quality/allocation.lisp` (`git status`: plus
  untracked `docs/object-kind-snapshot-review.md`, `test/quality/kind-snapshots.lisp`,
  modified `clamsara.asd`). The live `object-model.lisp` adds kind/description snapshot
  hash tables and rewrites `%host-kind-description`; the live 21:24 log already reports a
  different 4096 auxiliary total (1603088 vs 1601232).
- Every number below is re-derived from the **frozen** source, so the arithmetic is
  snapshot-consistent; the "executed" status belongs to the pre-commit working tree.

## 2. Verified arithmetic (500,000-element run)

Fixture: `test/quality/model-resources.lisp:1358-1554` (`test-variable-arrays`) with
`:element-count 500000` (`:1556-1558`).

| Quantity | Derivation | Value | Log |
|---|---|---|---|
| object bytes | `16 + N*8` with N=500000 | 4000016 | `OBJECT-BYTES 4000016` |
| space extent | `align-up(2*bytes + 1024, 16)` | 8001056 | `SPACE-EXTENT 8001056` |
| descriptor cells | `2 * extent/Q` (Q=16), one cell per Q of each space | 1000132 | `MODEL-DESCRIPTOR-CELLS 1000132` |
| offered capacity | fixture `:model-capacity (/ (* 2 extent) 16)` (`:1551`) | 1000132 | `MODEL-REPRESENTATION-CAPACITY 1000132` |
| bytes moved | `2 * bytes` (2 arrays copied) | 8000032 | `BYTES-MOVED 8000032` |
| total arena bytes | `2 * extent` | 16002112 | implied by planes |

`bind-object-model` computes `total-cells` as sum over routes of
`ceiling((limit-base)/granularity)` (`src/host/object-model.lisp:540-556`) and rejects
`capacity < total-cells` before allocating planes (`:560-567`). With map granularity =
Q = 16 in this fixture, offered and required are equal by construction.

### Fixed model planes (exact)

`FIXED-MODEL-PLANE-BYTES` is `test/quality/model-resources.lisp:1162-1179` summing
`%host-object-storage` (`src/host/resources.lisp:31-46`) over 15 top-level plane objects
created at `src/host/object-model.lisp:568-633`:

- arena: `total-bytes` = 16002112
- words: `ceiling(total-bytes,8)` elements = 2000264 * 8 = 16002112
- 5 fixnum planes (sizes, alignments, descriptor-kinds, generations, counts):
  `5 * 8 * 1000132` = 40005280
- base-references spine: `8 * 1000132` = 8001056
- data sum = **80010560**; plus 19 array headers/rounding = **80011312** (752 B).

The same formula on the 4096-element run gives 665920 + 752 = **666672**, exactly the
logged `FIXED-MODEL-PLANE-BYTES 666672`. The identical 752-byte slack in both runs
confirms the figure is a shallow sum of the 15 vectors.

What the figure excludes (all allocated at binding, all still retained):

- `base-references` elements: one `host-reference` struct per descriptor cell,
  `src/host/object-model.lisp:655-662` (`%make-host-reference`), 1000132 structs. A
  6-slot `defstruct` (`:61-67`) is ~56-64 B in SBCL -> **56.0-64.0 MB** not counted.
- stage buffers: `stage-capacity` (1 here) stages each holding a
  `max-object-bytes` (4000016) byte array plus a `ceiling(bytes,8)` word array
  (`:624-633`) -> ~8.0 MB not counted.
- locations/handles/variants element structs (small here).

These elements are counted only in the auxiliary manifest, because
`%register-bound-object-model-auxiliary` registers each element
(`%register-vector (host-model-base-references model) t`,
`src/host/object-model.lisp:1941`, plus the stage arrays at `:1949-1952`).

### Whole-account physical / auxiliary (500,000)

`ACCOUNT-PHYSICAL-BYTES` sums `%capacity-account-entry-physical-bytes` over all resources
(`test/quality/model-resources.lisp:1511-1521`); per resource that is
`%resource-state-physical-bytes` = primitive storage of the acquired handle + padding
(`src/host/resources.lisp:77-90`, recorded at `src/construction/build.lisp:568-573`).

- plan object vector: `%runtime-object-entry-count(trace,16,4)` =
  `10*trace + 8*16 + 5*4` = **5000808** words
  (`src/runtime/records.lisp:183-186`), trace = `extent/Q` = 500066
  (fixture `:143`, `:1551`). Storage = 8 + 8*5000808 = **40006472** (40.0 MB).
- 2 side-forwarding vectors: `2 * (8 + 8*500066)` = 8001072
- 2 packed object-start maps: `2 * (8 + 62509)` = 125034
- finalizer registry resources (`src/runtime/finalizers.lisp:78-95`): 752
- 2 spaces: 16 each; plan configuration-auxiliary, plan index: small

Sum **48133362** vs logged **48133504** (residual 142 B, well within header/rounding
detail). 40.0 MB of the 48.1 MB (83%) is the plan trace-object vector, which holds no
guest object for this workload.

`ACCOUNT-AUXILIARY-BYTES 160290512` is dominated by the same plane set, now including the
per-cell structs and stage arrays:

`80011312 (spines) + 56007392..64008448 (structs) + 8000064 (stage arrays) + 2
forwarding vectors 8001088 + maps 125056 + small` = 152.1..160.2 MB -> observed 160.3 MB.
So the auxiliary total, not the physical total, is the number that contains the model's
real retained state.

Ratios (computed, from the log + source): account total
`48133504 + 160290512 = 208424016` B for a 16002112 B arena = **13.0 bytes per arena
byte**; auxiliary alone = 10.0 B/B. For the ~8 MB of live guest payload the account is
~26x.

### Cross-run deltas are deterministic, not drift

| Log (time) | physical | auxiliary |
|---|---|---|
| `clamsara-model-resources-500k.log` (11:22) | 48132992 | 160137744 |
| `clamsara-model-resources-500k-final.log` (11:29) | 48132992 | 160282704 |
| `clamsara-capacity-array-stress.log` (20:01) | 48133504 | 160290512 |
| 4096-run, logs 11:29-17:07 (16 runs) | 402240 | 1593424 |
| 4096-run, logs 17:50-20:05 (8 runs) | 402752 | 1601216/1601232 |

- The 4096 physical step +512 = exactly 64 entries x 8 B = the finalizer registration
  history growth (`history = max(capacity,64)`), matching
  `src/runtime/finalizers.lisp:88-92` (`:minimum-physical-bytes (+ 16 (* 8 (+ (* 2
  capacity) history)))`). The same +512 appears in the 500k pair.
- The +7792/+7808 auxiliary step is consistent in magnitude with 64 token structs
  (~3.6-4.1 KB) plus the index resource's auxiliary reserve growth `64*64 = 4096` B
  (`:92`), i.e. within ~130 B.
- The 11:22 -> 11:29 auxiliary step (+144960) is the root fixed-reserve change that
  `docs/quality-model-resources.md` names; it is revision-attributable, not noise.

Verdict on accounting: the counters are actual
(`check-resource-charges` recomputes handle+padding and the whole manifest,
`test/quality/model-resources.lisp:598-646`), deterministic, and revision-explained. The
category *names* follow the paper (`construction.tex:77` returns
"physical-bytes, entry-capacity, auxiliary-bytes"; `:119-125` calls them nonnegative
minima), but "physical" is not a memory-footprint number.

## 3. Concrete findings

### 3.1 Printed counters are not the measured counters (executed evidence + source)

`test/quality/model-resources.lisp:1547-1548` builds the evidence plist with

    :reference-callbacks element-count
    :numeric-strong-callbacks 0

`element-count` is the call parameter and `0` is a literal. The test body does assert the
real quantities separately (`:1412-1414` `(= seen element-count)` and identity order;
`:1423` `(zerop strong-count)`), so the *behaviour* is verified, but the log line cannot
be read as a measurement. Additionally the same array is scanned fully three times: store
loop `:1384-1395` (500000 mapper callbacks), read loop `:1400-1411` (500000), and the
collector's strong trace of the array during `collect` (`src/runtime/trace.lisp:256-280` ->
`map-reference-locations`), i.e. ~1.5M callbacks; the printed 500000 under-reports ~3x.
There is no plan counter for scanned references or callbacks
(`src/runtime/records.lisp:28-34` has 6 counters: discovered, moved, bytes-moved, dead,
weak-corrections, finalizers-enqueued).

### 3.2 "Fixed model planes" understates retained model storage (derived)

See section 2. The per-cell `host-reference` structs are the missing ~56-64 MB. The
quality doc's sentence "The model planes are hosted fixed backing. Their fixed, charged
overhead is distinct from guest allocation" is true, but a reader comparing
`FIXED-MODEL-PLANE-BYTES 80011312` with `ACCOUNT-PHYSICAL-BYTES 48133504` in
`docs/quality-model-resources.md:266-320` sees planes > account and cannot tell that the
two use different bases. Recommend: report the plane figure with its manifest-inclusive
sibling (or state "top-level plane objects only; per-cell structs are in the auxiliary
total").

### 3.3 Category inversion risk: "physical" is handle storage (derived)

83% of the 500k "physical" total is the plan's `10*trace` object vector
(`src/runtime/records.lisp:183-186`), and `trace` is the fixture's chosen bound
(one trace slot per 16 bytes of one space, `:143`). No counter in the log explains where
the 48.1 MB comes from. The docs should state the dominant term explicitly; otherwise
"whole-account physical 48133504" reads like the cost of holding two 4 MB arrays, while
the object payload actually lives in the model arena/words and is charged as auxiliary
(`src/host/object-model.lisp:1934-1935`).

### 3.4 The 500k "capacity" evidence is a tautology; the real boundary test is elsewhere (executed)

- Stress: offered capacity is set by the fixture to `2*extent/16`, required cells are
  `2*extent/16`; equality is arithmetic, not a test. Peak simultaneous representations is
  4 (2 sources + 2 destinations; `initialize-object` increments
  `host-model-live-count` at `src/host/object-model.lisp:1103`, retirement decrements at
  `:1850`, and the guard is `< live-count capacity` at `:1082-1083`). 4/1000132 = 0.0004%
  of the bound.
- Real boundary evidence (executed, `/tmp/clamsara-representation-capacity-final.log:68-76`
  `REPRESENTATION-CAPACITY-PASS` x8): `test/quality/representation-capacity.lisp` rejects
  offers 1, 3, `required-1` (24 cases) and runs 16 full-survivor histories with
  `required` and `required+7`; `run-full-survivors` asserts
  `(= required (length (host-model-sizes model)))` and, for SemiSpace, peak live-count
  `= 16 = capacity` after each of 4 cycles. That is a tight, executed bound.
  `REPRESENTATION-CAPACITY-TESTS-PASS rejections=24 survivor-histories=16` also appears in
  the 20:05 log, but belongs to the pre-commit working tree (section 1).

### 3.5 Hidden work in the exercised path (executed path + source)

1. **Per-collection trace-plane fills.** `%reset-trace-context` fills 5 arrays of
   `trace-capacity` (`src/runtime/trace.lisp:22-26`); `%reset-cycle` additionally fills
   `retirement-starts` (trace-capacity) and the conditional/finalizer arrays
   (`src/runtime/cycle.lisp:26-40`). For the 500k world: 6 * 500066 = **3000396 slot
   writes per collection** for a 2-object graph, ~24 MB of memory traffic, reported by no
   counter. The 6.414 s figure (if it is being used in discussion) is dominated by this
   plus plane construction, not by graph work.
2. **Byte-level copy and clear.** `copy-object-representation` copies byte-by-byte then
   word-by-word (`src/host/object-model.lisp:1146-1168`); `initialize-object` clears the
   arena and word planes over the object's full size (`:1024-1029`). For two 4 MB arrays:
   ~8.0M byte writes + ~1.0M word writes for copy, plus the same again for initialization
   fills. Linear, but a large constant; no counter reports it.
3. **Borrow-pool scan per element callback.** `%host-borrow-location` linearly scans the
   `locations` vector for a free slot per callback and errors when none is free
   (`src/host/object-model.lisp:1198-1205`). With `location-capacity` 2 (stress world
   `:1552`) and one-level callbacks this is cheap, but (a) cost is O(pool) per element and
   (b) scan/recursion nesting depth is silently bounded by `location-capacity`, a
   different budget from descriptor capacity. No log measures pool occupancy.
4. **Bounded backward scan on interior normalization.**
   `%host-canonical-start-from-route` walks cell by cell from the aligned address down to
   `aligned - ceil(max-interior-displacement/granularity)*granularity`
   (`src/host/object-model.lisp:734-752`). Default displacement 64 at Q=16 -> <=5 cells;
   fine, but it is a data-dependent scan whose worst case grows with the declared
   displacement, and no test bounds it.
5. **Binding is linear in cells with several heavy passes.** Plane allocation
   (`:568-633`), base-reference construction for 1000132 cells (`:655-662`), per-element
   manifest registration into an EQ hash table (`:1897-1952`), then manifest closure which
   reverses the list, computes `%host-object-storage` per entry and freezes it
   (`src/host/resources.lisp:96-150`). Construction transients (a ~1M-entry dedup hash
   table, ~1M conses) are released before publication and are **not** in the account; the
   account is a retained-state account only.

### 3.6 Unexercised superlinear candidates (source hypotheses - NOT measured)

1. **MarkSweep first-fit free list.** `free-list-runtime-allocator::allocate-raw` scans
   free descriptors from index 0 on every allocation
   (`src/runtime/spaces.lisp:115-130`). Reclaim coalesces contiguous runs
   (`:535-543`), so with F free runs each allocation is O(F) and a workload that
   fragments into many runs is O(N*F). `descriptor-capacity` is a construction input
   (`:427`, `:481-491`) and can be as large as model capacity. No log measures F,
   scan length, or MarkSweep allocation cost; the 500k log is SemiSpace-only.
2. **Kind lookup is linear.** `%host-kind-description` scans the kind vector with `equal`
   name comparison (`src/host/object-model.lisp:266-275`), reached once per allocation
   request (`:1006`) and once per `initialize-object` (`:1062`). Kind counts in all
   fixtures are 4-8, so this is unmeasured and probably irrelevant - but it is a per-
   operation O(kinds). The live (uncommitted) tree replaces it with a hash table; do not
   attribute that improvement to this snapshot.

### 3.7 Test messages that overstate what is proven (source)

- `"generic array rescan did not scale linearly"` (`:1414`) and
  `"O(1) generic-array endpoint lookup failed"` (`:1417`) are checked at a single
  element count. They prove one callback per element, correct identity order, and one
  successful endpoint read - not scaling and not O(1).
- `check-fixed-plane-snapshot` (`:1181-1189`) compares object identity and
  `array-total-size` only. Plane *contents* are expected to mutate; this is a
  replace/resize check, not a residency proof, and it does not see the unregistered
  transients in 3.5.5.
- The doc claim "Linear construction probes" (`docs/quality-model-resources.md:114-131`)
  is historically correct (I verified the old code from Git: `bd7cc3e`
  `src/host/object-model.lisp` had per-binding range scans = 2*N^2 accessor calls, matching
  the doc's 128/512 at N=8/16, and `5a4e14a` replaced
  `src/host/address-space.lisp:82-96` nested `dotimes (i) (dotimes (j i))` = N(N+1)/2 with
  a sort + single pass, matching 36/136). Caveats: the retained regression only runs
  `count = 16` and instruments exactly two functions
  (`test/quality/model-resources.lisp:1115-1156`), so the N=8 data point has no retained
  test; and the current validate path sorts routes (N log N) - comparisons are not
  instrumented, so "linear" is established only for the measured accessor calls.
  `%host-binding-matches-range-p` is still defined but never called
  (`src/host/object-model.lisp:489`); the test's `(zerop binding-calls)` check depends on
  it remaining defined.

### 3.8 Documentation consistency (source)

- `docs/quality-model-resources.md:244-320` distinguishes the historical 500k run
  (`/tmp/clamsara-model-resources-500k-final.log`, physical/auxiliary
  48132992/160282704) from the capacity-repair run
  (`/tmp/clamsara-capacity-array-stress.log`, 48133504/160290512), and states the plane
  figure matched exactly. That framing is honest. The one vagueness is "charges include
  intervening service changes": the +512/+7808 step is specifically the finalizer
  registration-history change (section 2), and could be named.
- `docs/migration.md:61-63` still quotes 48132992/160282704 as the stress result without
  dating it to a revision; at the frozen commit those numbers belong to an older service
  set. Minor, but it is the third distinct auxiliary total in `docs/`.
- The workload/GCBench docs are careful: `docs/workload-boundaries.md:283-308` limits the
  acceptance to revision `113aa6a`, states "operational evidence, not an isolated
  performance comparison" for the 1060.981 s elapsed time, and requires a fresh run for
  the current tree. No current-tree GCBench or Gabriel acceptance is claimed anywhere I
  read.
- `:ELAPSED-SECONDS 1060.981` in `docs/gcbench-113aa6a.log` is a 17.7-minute run for a
  64 MiB guest heap, consistent with the fixed-cost structure in 3.5: no timing claim is
  made from it.

### 3.9 The 6.414 s figure

The number is not present in the frozen docs (`grep -rn '6\.414' docs/` finds nothing) and
not in either named log; the array-stress log contains no timing line at all, and it
includes five `compile-file` blocks before the test. I therefore treat 6.414 s as process
elapsed time that includes startup and compilation, with no isolated measurement of
anything. Nothing in the snapshot presents it as a performance result, and this review
does not either.

### 3.10 Storage multiplier for the workload geometry (derived, not executed)

The same formulas applied to the `tools/run-gcbench.lisp:57-58` geometry
(extent 32 MiB/space, Q=16, `make-workload-runtime` sets
`trace-capacity = capacity = 2*extent/Q = 4194304`, `src/workload/setup.lisp:34-42`,
`:137-142`) give:

- plan trace-object vector: 10 * 4194304 words = 335.5 MB
- 6 dense descriptor planes: 6 * 8 * 4194304 = 201.3 MB
- arena + words: 2 * 64 MiB = 134.2 MB
- per-cell `host-reference` structs: 234.9-268.4 MB
- 8 stage buffers of 8 MiB max object: 134.2 MB
- 2 forwarding vectors: 33.6 MB; packed maps: 0.5 MB

=> ~1.07-1.11 GB of fixed hosted state for a 64 MiB guest heap (~16-17x). No doc states
this multiplier; the account numbers in the docs exist only for the small 500k/4096
fixtures and should not be read as the GCBench footprint. This is a *consequence of the
declared geometry*, not a measurement, and it is the single most useful missing storage
number I found.

## 4. Claims examined (status)

| Claim (source) | Status |
|---|---|
| 4000016-byte objects, 8001056-byte semispaces, Q=16, 1000132 cells/capacity | Verified exactly (source + log) |
| 8000032 bytes moved for 2 objects | Verified (cycle counters, `:1462-1473`) |
| Fixed planes 80011312 B unchanged by the capacity repair | Verified (identical in 11:22 and 20:01 logs; formula reproduces both) |
| Account physical/auxiliary actuals, not estimates | Verified by `check-resource-charges` at 4096 scale; not re-run at 500k in that log |
| Admission rejects insufficient offers with offered/required diagnostic | Verified in source (`object-model.lisp:565-567`) and executed (`representation-capacity` PASS lines, pre-commit tree) |
| Guard is conservative, not exact; never clamps raises heap | Verified in source; consistent with design note |
| "no per-object host container was installed" | True at allocation time; binding pre-allocates one struct per possible start (3.2) |
| "500000 reference callbacks, 0 numeric callbacks" | Behaviour asserted; printed fields are parameter/literal; total is ~3x (3.1) |
| "Linear construction probes" | Historically verified from Git; retained test is N=16, two functions, sort uninstrumented (3.7) |
| GCBench acceptance only at 113aa6a, not current tree | Consistent with docs; not re-run here |
| 6.414 s | Not found in snapshot docs/logs; unverifiable, not isolated (3.9) |

## 5. Uncertainty

- No process was run. All "verified" arithmetic is derivation from frozen source; only the
  logged values themselves are executed evidence, and those executions are from the
  pre-commit tree (section 1).
- The exact SBCL structure size of `host-reference` (56 vs 64 B) is not measured; the
  structural finding (per-cell structs excluded from the plane figure, included in the
  auxiliary manifest) is independent of that size. The +752 B plane slack and the ~142 B
  physical residual are header/rounding details I did not resolve byte-exactly.
- Auxiliary composition beyond the identified dominant terms is an estimate; the
  `check-resource-charges` equality check is the strongest available verification and it is
  executed only in the 4096-scale default quality run.
- I did not inspect the 19 Gabriel fixtures, FRPOLY/default-patch status, managed
  callbacks, CAS ordering or target admission; the parent's statements about those remain
  as given.

## 6. Next small controlled measurement worth running

Goal: turn 3.3 and 3.5.1 from source hypotheses into measured facts without a heavy run.
One SBCL process, low memory, frozen snapshot, no benchmark:

1. Build the existing 4096-element variable-array world twice at the same extent/payload/
   capacity, varying only `:trace-capacity` (e.g. 128 vs the fixture's 8,324 = 2*extent/Q
   at `test/quality/model-resources.lisp:143`).
2. Around `collect` only (exclude construction/compilation), record wall time, and record
   the fill counts performed by `%reset-trace-context` / `%reset-cycle` (wrap `fill` or
   count positions) plus `length` and `%host-object-storage` of the plan object resource.
3. Additionally print `(sb-ext:primitive-object-size (aref (host-model-base-references
   model) 0))` and `(length (host-model-base-references model))`.
4. Optional second process (marksweep scan hypothesis 3.6.1): extent 128, capacity 64,
   16 alternating live/dead leaves, then count iteration counts inside
   `free-list-runtime-allocator`'s `dotimes` across allocations.

Expected outcome: collection cost scales with `trace-capacity` and not with element count
(confirming the fixed O(extent/Q) fill), and the struct/plan measurements confirm the
~56-64 B per cell and 10 words per trace slot that 3.2/3.3 derive. This needs the parent's
serialized native slot; I did not start it.

## 7. What this review does not claim

No whole-project acceptance, no benchmark, no Gabriel/GCBench current-tree result, no
target/Mezzano admission, no repr of the parent's uncommitted live geometry or
kind-snapshot changes. The frozen snapshot's storage numbers are honest within the scope
above; the fixes I recommend are documentation/counter-labelling and one optional
instrumented measurement, not correctness claims about the collector.
