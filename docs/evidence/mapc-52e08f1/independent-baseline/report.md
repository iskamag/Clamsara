# Strict MAPC nine-group baseline

## Result

**9 groups: 2 pass, 7 fail. Exit 1.** This is a red baseline against unchanged
Clamsara code `52e08f1`, not an implementation or Gabriel acceptance result.
The parent reports current repository HEAD `3a5a867` is a docs-only successor;
this process used the frozen `/tmp/clamsara-gcbench-52e08f1-tfa6uf75` source directory.

- Completed command PID: **17620** (shell handle; SBCL thread log identifies 17623).
- Process time: **1.482693847 seconds**. This uses the private
  cache populated by the preserved first attempt; it is not benchmark timing.
- Working directory: `/tmp/clamsara-gcbench-52e08f1-tfa6uf75`.
- Command:

```sh
sbcl --noinform --non-interactive --load /tmp/clamsara-gcbench-52e08f1-tfa6uf75/independent-review/gabriel-next/native-strict9-c2zybsxw/bootstrap-02.lisp > /tmp/clamsara-gcbench-52e08f1-tfa6uf75/independent-review/gabriel-next/native-strict9-c2zybsxw/native-02.log 2>&1
```

The bootstrap asserts the exact Clamsara/workload source directory, shared
Maclina directory, and collision-free private output translation. Cache:
`/tmp/clamsara-gcbench-52e08f1-tfa6uf75/independent-review/gabriel-next/native-strict9-c2zybsxw/fasl`.

## Group results and reachable paths

| Group | Result | What actually ran |
|---|---|---|
| direct-empty | FAIL | Actual installed MAPC + ML callback + NIL + NIL: 3/2 arity error; no callback. |
| semantics | FAIL | First one-list matrix case passed; second two-list case failed. |
| moving | FAIL | Native graph/checksum 33 oracle passed; guest callback/GC blocked by arity. |
| nested | FAIL | Native checksum 99 oracle passed; guest outer MAPC arity failed before any inner MAPC. |
| closure | PASS | One-list MAPC callback solely owns a managed capture; checksum 27, actual automatic movement, corrected six-cons result, zero-discovery discharge and close. |
| designator | PASS | One-list symbol callback resolves in its own guest environment; poison native definition not called; sum 3, actual automatic movement, zero-discovery discharge and close. |
| error | FAIL | Native sentinel condition EQ oracle passed; managed call failed arity before intended ERROR; retry not reached. |
| throw | FAIL | Native two-value oracle (17 23) passed; managed call failed arity before THROW; retry not reached. |
| dderiv-load | FAIL | Original file load stopped at top-level MAPC, lines 46-48; four property identities were not reached. |

All seven group failures are exactly:

```text
MACLINA.ARGPARSE:WRONG-NUMBER-OF-ARGUMENTS
Got 3 arguments, but expected exactly 2
```

Counts are **groups**, not assertions. Inside the semantics group, its nine
matrix cases reached 1 pass and 1 fail; 7 were not entered. The separate
single-return-value check was also not reached. There is no aggregate assertion
count. The passing closure case asserts six distinct managed conses with leaf
values `(1 2 3)`, exactly six discovered and moved in its explicit live-result
cycle, then zero discoveries after owner consumption. Both passing groups assert
positive automatic movement; their exact automatic counters were not printed.

No managed expected-ERROR, managed THROW/retry, nested scratch-slot separation,
or three-list behavior passes by treating wrong arity as success. No executable
capacity gate exists or ran. The DDERIV test is only load/setup, not TESTDDERIV.
The passes concern existing one-list ML callback paths, not a new native-call
scope or arbitrary native callable/capture ownership.

## Owner retention

Each runtime was held in the caller's `*RUNNER-RUNTIMES*` before test entry and
then adopted in the probe's `*OWNERS*`. The log records all seven failed owners
as `:FAILED-RETAINED`, configuration `:PUBLISHED`, and root token active at the
end of the process. No failed history evaluated NIL, collected for discharge,
erased roots/definitions/properties, or closed. Both successful histories have
configuration NIL and inactive/unset token after successful close.

Retention is observed through the final native summary, before process exit.
No live Lisp process or resumable core image remains. This is not a claim that
normal unwinding extends guest dynamic roots beyond their lifetime. The log
preserves conditions, last phase, and pre-unwind scalar VM registers.

## Preserved harness corrections

- V1 `mapc-strict-regression-draft.lisp` remains byte-for-byte unchanged.
  Its PHASE helper inherited CL:PHASE. The new canonical
  `mapc-strict-regression-v2.lisp` renames only that helper and its exact calls
  for the package collision. Native pre-load name audit found no inherited
  symbol for any listed new definition and confirmed old PHASE belongs to CL.
- V2 also strengthens the requested ERROR oracle to EQ identity of one sentinel
  condition. A private test-only native emitter captures no managed payload and
  signals that exact object. Wrong-arity PROGRAM-ERROR is not caught as success.
  See `../mapc-strict-v1-v2.diff` for the complete source difference.
- Attempt **17570**, exit 1 after **11.224852783s**, reached **zero
  groups**: my newly authored bootstrap name-audit LET lacked a closing paren.
  `bootstrap.lisp`, `native.log`, `execution-01.json`, and its post hashes are
  preserved. Only a new `bootstrap-02.lisp` corrects it. That retry passed source
  loading/name checks and executed all nine groups. No error is hidden as a pass.

## Integrity and release

`source-pre-02-sha256.json` equals `source-post-02-sha256.json`: all pinned frozen
production sources, all 20 fixtures, shared Maclina Lisp/ASD sources, V1, V2 and
runner/bootstrap files are unchanged by execution. Shared Maclina Git HEAD is
`d92e9254b45da4e508503b984f02403c6fb6677a`, with empty porcelain status. No preserved
patch was applied. No production, dependency, or fixture file was edited.

Artifacts: `native-02.log`, `execution-02.json`, `reachability.json`,
`maclina-git-state.json`, source pre/post hash manifests; the first attempt is
recorded separately. **Native slot explicitly released. No process remains.**
