# V3 native strengthening: both requested gates passed

**PASS: synthetic observer self-check and 5/5 runtime groups. All 17 owners closed.**
This run used the unchanged frozen MAPC production overlays in
`/tmp/clamsara-mapc-draft-wd3ba0th`. No test input or production correction was required.

## Execution and provenance

- PID **19747**, exit **0**, process time **12.588902973 seconds**.
- Working directory / exact Clamsara ASDF source root: `/tmp/clamsara-mapc-draft-wd3ba0th`.
- Input: `/tmp/clamsara-gcbench-52e08f1-tfa6uf75/independent-review/gabriel-next/capacity-strengthening-v3/capacity-ownership-v3.lisp` (unchanged).
- New private cache: `/tmp/clamsara-gcbench-52e08f1-tfa6uf75/independent-review/gabriel-next/capacity-native-v3-y4t009zr/fasl`.
- Shared unpatched Maclina source directory and collision-free cache translation
  are asserted in the bootstrap.

```sh
sbcl --noinform --non-interactive --load /tmp/clamsara-gcbench-52e08f1-tfa6uf75/independent-review/gabriel-next/capacity-native-v3-y4t009zr/bootstrap.lisp > /tmp/clamsara-gcbench-52e08f1-tfa6uf75/independent-review/gabriel-next/capacity-native-v3-y4t009zr/native.log 2>&1
```

`source-pre-sha256.json` equals `source-post-sha256.json`. Pinned frozen production
sources, all 20 fixtures, shared Maclina sources, and V1/V2/V3 inputs are unchanged.
The original sources, source-only review, and PID 19086 evidence are preserved.
This is a new native result, not a retroactive upgrade of those old observations.

## Results and exact reachability

| Group | Owners | Result |
|---|---:|---|
| synthetic observer self-check | 0 | PASS |
| physical boundaries | 13: calibration + 12 cases | PASS, all cases reached |
| protected snapshot witness | 1 | PASS |
| nested inner rejection / outer movement | 1 | PASS |
| smaller nonempty recovery | 1 | PASS |
| nonempty recovery after outer release | 1 | PASS |

The log labels six top-level groups. Precisely, these are **one synthetic check
and five runtime groups**, not six runtime histories or six individual assertions.
No construction, admission, callback, wiring or syntax failure occurred.

The old twelve-case matrix reran with the stronger observer. Boundaries remain:
tokens **208/207**, frames **2/1**, native cells **5/4**, snapshot queue **23/22**,
census queue **23/22**, and stack **68/67**. All six short cases rejected real
nonempty MAPC before effects. Five exact non-stack cases executed callbacks.
**The exact 68-slot stack case still tests only private entry admission**, not
full nonempty callback execution. All twelve empty retries passed.

## Descriptor identity oracle

CAP-STATE now includes descriptor SOURCE in its EQ identity list and compares
SOURCE-INDEX with EQL separately. All existing state-invariance checks ran with
that representation. The synthetic self-check confirmed:

- unchanged source/index passes;
- a structurally EQUAL but distinct source cons fails;
- a structurally EQUAL but distinct index/property-key cons fails;
- equal numeric indices pass under EQL.

The synthetic check did not mutate an actual descriptor or create a runtime.
The actual runtime checks retained their normal real-provider/snapshot paths.

## Nonempty recovery evidence

**Four-cell arena (owner 16):** the initial real two-list call rejected its five-cell
demand with `:NATIVE-CELL-CAPACITY-EXHAUSTED` before callback/effects. A subsequent
nonempty one-list call fit its three-cell scope in the same unchanged arena. It
executed **2 callbacks**, checksum **34**, across **2 moving cycles**. The returned
list was `(11 13)`. Native-cell/frame counts returned to zero. The owner then
proved zero-discovery discharge and closed. This is actual nonempty recovery,
not the empty fast path.

**Five-cell arena (owner 17):** the outer history completed after **2 inner
rejections**, with its returned graph checked and its native extent released.
A new nonempty two-list call then fit the same five cells. Cumulative checks were
**3 callbacks**, checksum **112 = 47 + 65**, and **3 moving cycles**. The recovery
result was `(11)`. The original inner-rejection count stayed two. Native-cell/frame
counts returned to zero, then discharge and close completed.

These are separate new owners, not additions to the prior run's owner records.
The original snapshot/nested witnesses also passed again with checksums 65/47.
Across this V3 run, there were **32 observed protected snapshots** and **15 moving
cycles**. Counts exclude unobserved close collections. Every owner ended with
phase `:COMPLETE`, configuration NIL, token NIL and condition NIL.

## Scoped review addendum

The two strengthening gates requested after the fixed-source review have now
passed for these exact frozen overlays. No additional blocking defect was found
within the tested managed MAPC operation/admission/ownership scope. This closes
the identified observer and nonempty-recovery evidence gaps for this source.

The source-only review's broader limits remain: entry reservation does not bound
arbitrary later callback work; exact stack admission is not full callback capacity;
native callback locals/captures are not proved safe; common-walk count equality
is not a stand-alone completeness proof; this is not Mezzano/supervisor admission,
full Gabriel/GCBench acceptance, or verification of a later integrated revision.
LIST was not investigated or changed. Integration must retain the reviewed bodies
and its own source/integration gates.

Historical accounting stays separate:

- PID 19086 / V2: 3 runtime groups, 12 boundaries, 15 completed owners.
- PID 19747 / V3: 1 synthetic check + 5 runtime groups, the same 12 boundary
  shapes rerun, 17 completed owners including the two new recovery histories.

Artifacts: `native.log`, `execution.json`, `owners.json`, `reachability.json`,
bootstrap/runner and matching pre/post source manifests. Original V3 input and
V2/V1 evidence remain untouched. **Native slot explicitly released; no process
is running.**
