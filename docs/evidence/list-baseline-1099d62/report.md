# Unchanged v2 LIST baseline on 1099d62

**Strict result: FAIL, exit 1. Native slot released.**
PID `21361` ran for 13.010 seconds. All 21 cases were attempted
in the requested order. No expected-red success exit was used.

- Seven behavior cases: **1 pass, 6 failures**. Only N=0 LIST completed.
- Thirteen private N+2 capacity cases: **1 pass, 12 failures**. Only N=0,
  zero-cell arena completed. These counts are proposals, not CL minima.
- One separate host-payload diagnostic: rejection observed and owner retained.
  This is not positive capacity or payload-admission acceptance.

## Source and harness

- Clamsara and workload resolved exactly to `/tmp/clamsara-list-baseline-1099d62-xzks71ws/` (HEAD
  `1099d6235d7cc2730ce5066fb404daaca0bd75d9` snapshot).
- Maclina resolved to `/home/iskam/quicklisp/local-projects/Maclina/`, clean
  `d92e9254b45da4e508503b984f02403c6fb6677a` before and after.
- Unchanged `regression-draft-v2-construction.lisp` loaded successfully through SBCL's native
  Lisp reader/compiler. No harness/source correction was needed or made.
- All 1147 pinned files matched before/after: snapshot files, the unchanged
  test, new runner/bootstrap, selected dependency source trees, and all 20
  original fixtures in both snapshot and working tree. No production,
  dependency or fixture was edited. `pins.sha256` lists the exact coverage.
- ASDF used a private path-preserving FASL cache. Distinct source paths with the
  same FASL basename were explicitly checked not to collide.

The load emitted one Common-macros undefined-variable warning and ten style
warnings. The v2 file itself loaded and all cases ran. This is not an upstream
warning cleanup or dependency acceptance claim.

## Observed failures and reachability

| Group | Observed result |
| --- | --- |
| Behavior ONE/MANY/ORDER/IDENTITY/MOVING/MAPC-NESTED | TYPE-ERROR: host REST lists are not guest CONS values |
| N17 arena exact/one-short, direct/nested (19/18, 22/21 cells) | TYPE-ERROR on host list of managed references |
| N17 FUNCTIONS exact, direct/nested (2/4 slots) | WORKLOAD-CALL: VM-FRAME-CAPACITY-EXHAUSTED |
| N17 FUNCTIONS one-short, direct (1 slot) | Expected capacity condition recorded, but final WORKLOAD-CALL capacity failure; no completed recovery |
| N17 FUNCTIONS one-short, nested (3 slots) | Expected capacity condition recorded, but final TYPE-ERROR on one-element host list; no completed recovery |
| N17 SAVED exact/one-short, direct/nested (2/1, 4/3 slots) | INVALID-ARRAY-INDEX-ERROR at index equal to vector length |
| Host-payload diagnostic | TYPE-ERROR; retained, not an admission pass |

All 21 runtimes reached construction. No constructor failure was counted as
success. The twelve failed N17 capacity owners retained their case graph root
at summary. The unchanged baseline still installs guest LIST/BUILD, so these
private N+2 bounds do not validate an as-yet-unimplemented native LIST extent.
The SAVED-vector faults and FUNCTIONS refusal/recovery failures remain red;
they are not turned into successful capacity rejection tests.

The native runner's `LIST-BASELINE-PRE-UNWIND` label needs a precise limit:
its outer handler sees the error rethrown by v2 WITH-OWNER, **after v2's internal
unwind**. Therefore those records show real retained scalar state, but not the
original failure instruction or pre-internal-unwind phase. The original v2
boundary observer runs only for capacity conditions; this runner did not dump
all its saved snapshots. No claim of original instruction-level capture is made.
A future improved observer must be a new runner/source version; this evidence
and the unchanged v2 are preserved.

## Ownership

At final summary, both successful owners were COMPLETE with configuration and
token cleared after the normal discharge/close path. All 18 failed owners were
FAILED-RETAINED, configuration PUBLISHED, token active. The separate diagnostic
owner was PAYLOAD-REJECTED-RETAINED, configuration PUBLISHED, token active.
Their VM/native frame counts were zero after normal stack unwinding. The runner
never cleared their roots, collected them, or closed them after failure.
They remained in `*OWNERS*` through summary and process exit; this does not claim
they survive as live Lisp objects after the process terminates.

No nonempty LIST graph/movement gate or successful refusal→nonempty-recovery→
discharge history passed. No general REST matrix, benchmark fixture execution,
LIST implementation/performance result, or broader callable proof is claimed.

## Artifacts

- `execution-start-01.json`, `execution-01.json`: exact command/PID/timing/exit.
- `bootstrap-01.lisp`, `runner-01.lisp`, `native-01.log`: preserved native run.
- `results.sexp`, `owners.sexp`: native reader-printable final records.
- `results.json`, `owners.json`, `reachability.json`: bounded decoded summaries.
- `source-pre-sha256.json`, `source-post-sha256.json`, `pins.sha256`: exact pins.
