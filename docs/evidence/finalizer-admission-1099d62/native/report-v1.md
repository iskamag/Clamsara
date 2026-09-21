# Native finalizer admission baseline — STRICT RED

**FAIL: frozen1099 accepted a native FUNCTIONP callback that is not a model
reference.** This is one invalid-callback admission failure, not an expected-red
PASS and not valid-managed-client corruption.

## Execution

- PID **22799**, exit **1**, **2.153761207 seconds**.
- Frozen source root: `/tmp/clamsara-list-baseline-1099d62-xzks71ws`.
- Unchanged input: `/tmp/clamsara-list-baseline-1099d62-xzks71ws/independent-review/finalizer-admission/admission-baseline-draft-v1.lisp`.
- One :SEMISPACE/:PACKED quality world: extent 2048, roots 2, registry F=2,
  lifetime token history 4. The caller held the real world before probe setup.
- New private path-preserving cache: `/tmp/clamsara-list-baseline-1099d62-xzks71ws/independent-review/finalizer-admission/finalizer-admission-native-ww84_306/fasl`.

```sh
sbcl --noinform --no-sysinit --no-userinit --non-interactive --load /tmp/clamsara-list-baseline-1099d62-xzks71ws/independent-review/finalizer-admission/finalizer-admission-native-ww84_306/bootstrap-v1.lisp > /tmp/clamsara-list-baseline-1099d62-xzks71ws/independent-review/finalizer-admission/finalizer-admission-native-ww84_306/native-v1.log 2>&1
```

Clamsara and quality/support source-root assertions passed. Loaded systems were
ASDF/UIOP and the Clamsara core, construction, metadata, host, runtime and
quality/support systems only. The loaded-system filter found no workload or
Maclina system; MACLINA.MACHINE and workload MAPC packages were absent. No old
finalizer positive suite was loaded or run. The `--no-sysinit --no-userinit`
process did not import shared Quicklisp/Maclina startup state.

The real Lisp reader loaded the unchanged V1 probe and runner. No construction,
reader, compilation or harness error prevented the case. No correction/retry was
needed, and no second case or captured-reference consequence witness ran.

## Observed case

The referent was published in application root0 and checked allocated/local with
payload **7101**. The callback was **FUNCTIONP=T**, **VALID-REFERENCE-P=NIL**.
REGISTER-FINALIZER returned normally with one token; it did not signal a runtime
rejection. The probe then raised its exact failure:
`:NATIVE-CALLBACK-WAS-ACCEPTED`.

| State | Before | After |
|---|---|---|
| NEXT-TOKEN | 0 | 1 |
| registry states | (:FREE :FREE) | (:ACTIVE :FREE) |
| returned values | none | one token, valid registry index 0 |
| token reserve indices | fresh unused history | (0 -1 -1 -1) |
| FNA-STATE-SAME-P | compared full captured states | NIL |

NEXT-TOKEN before/after is printed in the 25-value scalar rows. Before registry
states are established by the executed fresh-registry assertions; the V1 runner
did **not** separately print that before-state array. The unchanged probe held
its full before/at-signal/after snapshots in the owner until process exit. The
log records the full comparator result and the after-state array, not a serialized
full snapshot. No later reconstruction is claimed as a direct array dump.

All eight observed allocation/store/collection/stop attempt counters stayed zero,
and the callback was invoked zero times. This does not mean admission had no
effects: the registry uses direct array writes, and the token/state comparison
shows those effects. No positive composed-publication claim follows.

After the failure, root0 remained allocated/local with payload 7101. Configuration
was `:PUBLISHED`, plan was `:OPEN`, and both application and registry root tokens
were active. The returned token and the actual world were retained; none was
canceled, drained, collected, erased, restored or closed by the harness.

## Exact accounting and retention limit

- **1 reached admission case; strict RED/nonzero.**
- **1 actual retained world and 1 retained probe owner at final summary.**
- **0 closed owners.**
- **0 construction/harness failures, 0 additional cases.**

The process then exited with the failure. No resumable Lisp core was saved.
Retention here means the actual world/token/condition stayed owned through the
final process summary, not that an interactive live world still exists now.
The only unwind cleanup removed the probe's own temporary observer methods.

## Pins and scope

`source-pre-v1-sha256.json` and `source-post-v1-sha256.json` match exactly across
project Lisp/test/ASDF sources, the probe/bootstrap/runner, the read live-paper
sources, and the recorded shared Maclina source pins. Maclina was not loaded.
`fixture-manifest-verification-v1.json` also verifies the 20 reference fixtures
against their previously committed expected manifest. The fixtures were not
loaded. No production, fixture, dependency or test source was edited.

The baseline demonstrates invalid native-callback acceptance only. The stock
host model still supplies no FUNCTIONP model-reference callback, so genuine
managed callback root/publication/capture/moving-invocation positives remain
blocked. Existing native bookkeeping callback tests remain unchanged machinery
evidence with their original counts. No full finalizer, language, workload or
target acceptance is claimed.

Artifacts: `native-v1.log`, `execution-v1.json`, `owner-v1.json`, unchanged
bootstrap/runner, matching pins and fixture verification. The original source
and coverage plan are preserved. **Native slot explicitly released. No process
is running.**
