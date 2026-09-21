# Native capacity/ownership result on frozen MAPC draft

**PASS: 3/3 top-level groups. All 12 boundary constructions reached and completed.**
This validates these bounded hosted cases on the frozen draft. It is not approval
of full language, benchmark, arbitrary callback, or supervisor conformance.

## Execution

- PID **19086**, exit **0**, process time **12.130560814 seconds**.
- Source and working directory: `/tmp/clamsara-mapc-draft-wd3ba0th`.
- Private cache: `/tmp/clamsara-gcbench-52e08f1-tfa6uf75/independent-review/gabriel-next/capacity-native-7l6mqmdt/fasl`.
- Loaded test source: `capacity-ownership-v2.lisp`. Original
  `../capacity-source-v1/capacity-ownership.lisp` is preserved unchanged.
- Exact Clamsara/workload and shared Maclina ASDF source directories and
  noncolliding output translations are asserted by the bootstrap.

```sh
sbcl --noinform --non-interactive --load /tmp/clamsara-gcbench-52e08f1-tfa6uf75/independent-review/gabriel-next/capacity-native-7l6mqmdt/bootstrap.lisp > /tmp/clamsara-gcbench-52e08f1-tfa6uf75/independent-review/gabriel-next/capacity-native-7l6mqmdt/native-01.log 2>&1
```

No test source correction was needed after this run. V2 adds stage reporting
only; `v1-v2.diff` preserves the complete difference. No production, dependency,
fixture or shared Maclina file was edited. Native dependency warnings are retained
in the log; there was no harness loading/compilation error.

## Construction / admission / callback reachability

The boundary group made one roomy calibration owner and twelve fresh physical
constructions. None failed during construction. Every private admission check
and every intended actual MAPC check reached its specified assertion.

| Physical dimension | Exact | One short | Actual nonempty behavior |
|---|---:|---:|---|
| root token vector | 208 | 207 | Exact invoked callback; short rejected before effects. |
| FUNCTIONS and SAVED-VALUES | 2 | 1 | Exact invoked callback; short rejected before effects. |
| native cons-cell arena | 5 | 4 | Exact invoked callback; short rejected before effects. |
| snapshot control queue | 23 | 22 | Exact invoked callback; short rejected before effects. |
| census control queue | 23 | 22 | Exact invoked callback; short rejected before effects. |
| VM stack | 68 | 67 | Exact **private entry admission only**; short actual MAPC rejected before effects. |

The five exact non-stack callbacks each ran once and produced checksum **65**.
The exact stack case deliberately did not invoke a nonempty callback. Its bound
is two argument slots plus 66 callback local slots, not arbitrary operand growth.

All six short configurations rejected both private admission and the actual
nonempty MAPC entry with the asserted dimension-specific capability reason:
root-provider, VM-frame, native-cell, control-root (both queues), or VM-stack
capacity exhaustion. No wrong-arity or callback error substitutes for these
expected failures. No unexpected admission/callback failure occurred.

Each rejection checked zero additional callbacks, managed allocation attempts,
and barrier-store attempts. It compared physical vector/token/cell identities,
root descriptors, arena contents/links, VM registers/stack/values, and snapshot
queue/count/seen before and after. Census scratch was empty afterward. These
were additive observer methods; no primary or published capacity was replaced.

All **12 empty retries** succeeded without an extra callback. Each short case
then released only its own callback definition after the expected rejection had
been proved. A real collection moved exactly the two still-owned input conses,
whose CARs remained **11 and 13**. This callback release is necessary for the
intentionally undersized control queue to scan the remaining owners; it is not
unexpected-failure cleanup.

Counts above are boundary histories and call paths, not individual assertions.
`reachability.json` records all twelve owners and the explicit stack exception.

## Independent protected-snapshot and movement witnesses

**Snapshot group:** adding another operator alias for the same actual ML callback
did not duplicate its census control graph. Real COLLECT invoked the normal
protected snapshot path. The test compared census root/control counts with the
installed active descriptors and snapshot control count. Census itself did not
change those descriptors or the physical sources.

A second real collection ran at ML callback entry. Its actual protected-snapshot
root count was no greater than the admission reservation computed immediately
before the production primitive was entered. The callback completed with checksum
**65**, preserving the managed returned list. The owner reports **3 observed
snapshots**, including final discharge, and **2 moving cycles**. Exact root counts
at those callback snapshots were asserted but not separately printed.

**Nested group:** the five-cell outer scope remained active while each inner
nonempty MAPC tried to claim another five cells. Both inner attempts rejected with
`:NATIVE-CELL-CAPACITY-EXHAUSTED`, with no callback or state change. A real collection
then moved outer payload before the ML callback read its argument leaves and
capture. Both outer callbacks completed, with checksum **47**, and the returned
list retained leaf values **1 and 2**. The owner reports **2 inner rejections**,
**2 callbacks**, **3 observed snapshots**, and **2 moving cycles**. No temporary
slots 0..15 were used as fixture scope storage or filled with artificial sentinels.

Across calibration, boundaries and both witnesses, the test recorded **25 protected
snapshot observations** and **10 moving cycles**. These counts exclude any close
collection not guarded by the test's snapshot observation extent.

## Owner lifecycle and integrity

All **15 owners** completed: calibration + 12 boundaries + snapshot + nested.
Each ended with configuration NIL, root token NIL, and condition NIL. All successful
histories proved zero-discovery discharge and close. No failed owner required
cleanup. The runner still had separate group error catches and retained runtime
handles; unexpected-failure cleanup was never installed.

`source-pre-01-sha256.json` equals `source-post-01-sha256.json`, covering the frozen
production sources, all 20 fixtures, shared Maclina Lisp/ASD sources, preserved
source v1, source v2, bootstrap and runner. Source pins remained unchanged.

## Limits

- The numbers are measured boundaries for this callback/environment shape, not
  universal minimum capacities. Calibration drift would fail the test.
- Exact stack entry remains helper-only. Future callback frames/operands and
  arbitrary native callback locals/captures are not covered.
- Common-walk census equality alone does not establish complete root coverage;
  the independent moved-payload and nested witnesses provide separate evidence.
- This is the frozen MAPC draft, not an integrated commit or a full Gabriel run.
  The separate known LIST/REST failure was not investigated or changed here.
- Hosted tests do not establish Mezzano/supervisor allocation freedom.

Artifacts: `native-01.log`, `execution-01.json`, `owners.json`, `reachability.json`,
pre/post source hash manifests, V2 source, bootstrap/runner and V1/V2 diff.
**Native slot explicitly released. No process remains running.**
