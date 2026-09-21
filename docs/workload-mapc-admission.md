# Managed multi-list MAPC: scoped repair and evidence

The MAPC repair passes the behavioral, physical-capacity, integration and exact
staged-tree gates below. This is not full Gabriel,
arbitrary callback, whole-storage or Mezzano acceptance.

## Repair

The unchanged DDERIV fixture uses MAPC with two lists at lines 46–48. The
adapter previously installed a guest lambda accepting only FUNCTION and one
LIST. The repair keeps the source/runtime split and installs a native managed
MAPC that accepts one or more lists. It stops at the shortest list, preserves
left-to-right argument order, ignores callback values and returns the original
first list as one value. No fixture or Maclina dependency was changed.

Three production files change: `src/workload/{roots,control,maclina}.lisp`.
The provider provisions native cons-cell sources at setup. A call owns a disjoint
2N+1-cell extent: original return list, N cursors and N callback arguments. Its
actual environment-resolved callable occupies FUNCTIONS; its original writable
cells occupy SAVED-VALUES. It never borrows primitive temporary slots 0–15.
It reloads moved cursor/argument/return values and releases only its own extent
on normal return, ERROR or THROW. It does not erase outgoing VM values.

A shared source walker drives both protected descriptor installation and a
separate non-retargeting census. The census uses its own bounded queue/hash and
clears that scratch. Admission checks actual frame, cell, stack, token and both
control-queue lengths. For a known ML callback it includes N argument slots,
LOCALS-FRAME-SIZE, and existing control objects in those future local slots.
The active extents themselves reserve the cells; a nested census includes them.
No empty records, fake frame counts, growing registry or fixed two-list branch
substitutes for these physical owners.

## Native chronology

| Evidence | Observed result |
|---|---|
| Parent baseline 17256, unchanged 52e08f1 | 3 groups: 1 pass, 2 arity failures; 2 failed published owners retained through summary |
| Independent baseline 17620 | 9 groups: 2 one-list passes, 7 exact 3-versus-2 arity failures; 7 failed owners retained |
| Draft 18283 | All 9 behavioral groups pass; 9 owners discharge and close |
| Draft full gate 18497 | Main, tools, workload, optional generational/288 histories and structure pass |
| Independent capacity V2, 19086 | 3 groups, calibration + 12 boundaries + 2 witnesses = 15 closed owners |
| Independent strengthened V3, 19747 | Synthetic observer check + 5 runtime groups; 17 closed owners |
| Integration 19852 | Parent wrapper EOF error before MAPC tests; preserved, not a semantic pass |
| Corrected integration 19986 | Full gates, permanent tests, unchanged archived tests and permanent repeat pass; 78 MAPC owners close |
| Exact staged tree 20364 | The same full/permanent/archive/repeat gates pass; archive inputs come from the staged tree; 78 MAPC owners close |

All executed source pins match before/after. The frozen code contains exactly
the three production overlays on HEAD 3a5a867; integration adds two test files
and only the workload ASDF block. Held indexed/name/ledger/model work is excluded.

The behavioral groups exercise one/two/three lists and all empty positions,
first-list identity, a single returned value, real callback movement, nested
calls, callback-only captures, guest symbol lookup against a poison native
function, exact ERROR identity, two managed THROW values, recovery and four
DDERIV setup property identities. They do not run TESTDDERIV.

The observed exact/one-short boundaries are roots 208/207, frames 2/1, cells 5/4,
snapshot queue 23/22, census queue 23/22 and VM stack 68/67 for the measured
callback shape. All six short cases reject a real nonempty call before callbacks,
managed allocation, stores or descriptor/source changes. Five exact non-stack
cases invoke the callback. Exact stack is **entry-only helper evidence**, not
proof that the whole callback fits. These numbers are not universal minima.

V3 strengthens SOURCE identity with EQ and SOURCE-INDEX with EQL. A synthetic
observer self-check detects equal-but-distinct source/key conses. Two new real
histories establish nonempty recovery, not only an empty fast-path retry:
- A 4-cell arena rejects a two-list call, then completes a one-list call with
  two moving callbacks and checksum 34.
- A 5-cell outer extent survives two inner refusals, releases, then supports a
  new nonempty two-list call. Cumulative checksum 112 and three moving cycles.

V3 records 32 protected snapshot observations and 15 moving cycles across its
17 owners. Shared-walk census equality alone is not root-completeness proof;
the independent moved-payload, capture and nested witnesses are separate checks.
V2 retains its original 15-owner/25-snapshot/10-moving-cycle counts.

## Permanent tests and review

`clamsara/workload/test` includes `test/workload/mapc.lisp` and
`test/workload/mapc-capacity.lisp`. Independent behavior V2 and capacity V3 bodies
are unchanged after header/package normalization. Strict wrappers count 9 new
behavior owners and 17 new capacity owners across 5 runtime groups. They retain
prior handles on repeats and do not clean unexpected failures. Test methods are
unique, dynamically scoped additions and remove only their own method objects.

See [fixed-source review](workload-mapc-fixed-review.md) and
[integration review](workload-mapc-integration-review.md). The former predates
V3 execution; its later native addendum is retained in the evidence archive.
Source-only reviews do not take credit for parent native runs.

`docs/evidence/mapc-52e08f1/` preserves baselines, source revisions, private-cache
bootstraps, full logs, commands/results, pins and reviews. Historical mistakes
remain distinct: initial unsafe failure cleanup was not used as ownership proof;
PHASE collided with CL:PHASE before execution; baseline bootstrap 17570 reached
zero groups due to EOF; integration 19852 missed two parent wrapper closings.
The corrected candidate changes only those two closings, not independent cases.
Failed-owner retention is observed before process exit, not a live/core claim.

## Remaining limits and next blocker

Existing native-function compatibility remains. FUNCTIONP does not prove safety
of arbitrary native captures or unregistered native argument locals. The rooted
callback evidence concerns supported Maclina callable/control shapes. Current
entry admission also does not bound arbitrary later callback work.

The new arena, second control queue/hash and walk records are retained host
metadata. No whole post-bind accounting or host-allocation-free/supervisor proof
is claimed. Census clears provisioned queues/hashes, so this report makes no
active-only complexity or isolated performance claim.

DDERIV now loads but does not yet compute successfully. Probe 18744 computes the
first native kernel oracle, then managed evaluation fails in `%GUEST-CAR` on host
`(// 0 3)`. The stack identifies guest LIST's `(LAMBDA (&REST VALUES))` and LABELS
BUILD. Zero managed kernels pass; five later kernels are unreached. One real
published owner with active root token remains through the failure summary.
No failure cleanup, fixture edit or full TESTDDERIV run occurs. The earlier probe
18604 had coarse phase labels and a host-cons result-oracle gap; both are fixed
only in probe 02, with the original preserved.

A separately proposed arena-backed native LIST repair is not implemented here.
General REST, linker/foreign ownership, model handle/domain/backing holds,
finalizer callable roots, full all-19 Gabriel and paper/target admission remain
open. Shared Maclina is still unpatched at d92e9254. The accepted depth-18 GCBench
evidence is for code 52e08f1, not a rerun of this MAPC revision.

## Exact staged verification

PID 20364 exits 0 after 20.02792685991153 seconds. The full component gate and
permanent/archived/repeated MAPC tests pass with unchanged input pins. All six
code/test/ASDF files match the reviewed integration candidate byte for byte.
The archive replay loads its V2/V3 sources and runners from the staged tree
itself, closing the earlier external-archive gap. Seventy-eight MAPC owners
close with no unexpected failure. The main suite's 49 expected-fatal CAS worlds
remain a separate category. Later additions are reports and run evidence only.
