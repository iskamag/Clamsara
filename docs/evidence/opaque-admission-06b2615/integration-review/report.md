# Opaque-admission permanent integration: source-only review

## Verdict

**Scoped source integration ACCEPT; no blocker found.** Candidate:
`/tmp/clamsara-opaque-integrated54-2nmikfx1`.

The candidate is exactly the declared **four code/test/ASDF overlays** over
`06b2615e804ab6425a045b27f4565ceaeaa4cde6`:

1. `src/runtime/barrier.lisp`
2. `clamsara.asd`
3. `test/quality/barrier-admission.lisp`
4. `test/quality/barrier-admission-edges.lisp`

No native process was started for this integration review. The native slot
remains with the parent. Only new files in this review directory were written.
This report does not promote a previous native result to a differently packaged
input set or claim general method admission/conformance.

## Integrity and partition

All **346 candidate-manifest hashes** match. All **347 non-review files**,
including the manifest itself, are unchanged across this review. The complete
byte comparison uses the existing immutable
`/tmp/clamsara-opaque-draft-8qjnkk81/head-06b2615.tar`; its hash is recorded in
`integration-evidence.json`.

The whole candidate also contains the manifest and **25 copied `paper-v14/`
files** outside that HEAD tree. The four-overlay claim is deliberately limited
to code/test/ASDF. Existing HEAD docs/evidence are unchanged; this candidate
contains the older committed CAS archive, not an automatically copied new
opaque-admission evidence archive.

The held `src/host/object-model.lisp`, `test/quality/kind-history.lisp` and
`test/quality/model-resources.lisp` are exactly HEAD. New blocked indexed and
staged history/snapshot/edge files are absent. No held model/name/ledger work
or change to shared support/old suites is included.

A first lookup assumed this candidate carried its own head tar and raised a
Python IndexError when none was present. The comparison was then made against
the already pinned draft head tar above. That was an input-locator mistake,
not a native, source or implementation failure.

## Exact suite preservation

The production file is byte-identical to the file tested independently in
**PID 15448**. For each installed suite, I removed only the leading comment
header and applied the requested package renames to the original source:

- `clamsara.independent.opaque-admission` ->
  `clamsara.quality.barrier-admission`
- `clamsara.independent.opaque-edges` ->
  `clamsara.quality.barrier-admission-edges`

The entire remaining body is **byte-identical** in both cases. The 34-case file
contains 31 static CHECK forms before and after; the 20-case file contains 30
before and after. Those are source-form counts, not runtime assertion counts.
Whole-body equality also preserves helpers, signals-runtime-reason checks,
parameterized histories, raw counters, exact 34/20 gates and zero-failure gates.
No assertion, callback binding, negative reason or root/GC/unwind check was lost.

The edge package imports state and helpers from the renamed base package, and
its qualified call to the base `one` runner is renamed consistently. These are
not half-renamed packages with separate counters/owner lists.

Saved source evidence: `baseline34-integration.diff`,
`edges20-integration.diff`, and `integration-evidence.json`.

## ASDF wiring

`asdf-integration.diff` shows only:

- Addition of `clamsara/quality/barrier-admission/test` to the main test chain.
- A new system depending on existing `clamsara/quality/support`.
- Serial load order: base 34 before the 20-case edge file that imports it.
- Explicit calls to both exported runners in the correctly renamed packages.
- A failure if either runner is false or signals.

Neither file runs a test matrix at load time. The AND chain can short-circuit
when an earlier suite fails; it cannot call that a successful 54-case gate.
No optional model/indexed suite is silently added.

## Ownership, method setup and interpretation

The preserved runners reset only per-run counters, not the persistent failed
or rejected-owner lists. The edge suite shares those lists with the renamed
base suite. Repetition preserves earlier failed owners and EQL methods.

Each real vector case creates a fresh non-STANDARD-OBJECT actual and adds
methods specialized on only that value before constructing its world. It
neither redefines a production generic/method combination nor removes/replaces
a method applicable to an older actual. Earlier retained worlds are not made
uncallable by fixture cleanup.

The two fresh EQL method sets can keep their private, **nonmanaged** vector,
token and counter state reachable from MOP tables for the test-image lifetime.
That state carries no managed root/location, configuration or collector owner.
This is not proof of method retirement, runtime concurrency or whole residency.
The tests use ordinary cleanup only for successful worlds, and retain failed
owners without forced closure. No public author registry or additional author
contract was introduced.

The four new real-builder histories remain distinct from the sixteen private
metadata/capability checks. The latter do not construct sixteen configurations
or demonstrate effective execution. The custom-`+` test uses a private generic;
the suppressed-feature check compiles a fresh anonymous host function. Neither
changes production GF definitions. The latter is **not** Mezzano/non-SBCL
compilation or admission evidence.

## Prior native evidence, not a new integration run

The separate unchanged draft source/native report is:
`/tmp/clamsara-opaque-draft-8qjnkk81/independent-review/opaque-admission/report.md`.

Its independent **PID 15448** result was 54/54 PASS, exit 0,
2.3573243940481916 s, all 349 inputs unchanged. It retained **14 expected
rejected construction owners**, **0 failed worlds**, and **0 expected-fatal
worlds**. Those categories must not be conflated. They are the observations
from that one independent invocation, not a claim about this parent's repeated
integrated run or its cumulative counts.

The preceding **PID 14790** red baseline remains intact: 13/34 pass, 21 fail
(18 false rejections, three false publications). No source rewrite or renamed
package erases that history.

Parent PID 15549 was running this integrated candidate when this review was
requested. Its own log/manifests, not body equality alone, establish its native
result. This source reviewer did not execute or re-certify that process.

## Unchanged scope limits

The primary-candidate filter is a necessary STANDARD-combination structural
check. It does not prove overlap of unknown argument domains, successful method
bodies or CALL-NEXT-METHOD chains, safe auxiliaries, complete allocation freedom,
custom-method-combination support, target synchronization, residency or stable
installation lifetime. The OPERATION and dual READ+CAS specification gaps,
held model/index/ledger work, broader benchmarks and Mezzano gates remain.

The frozen integration candidate has no source-integration blocker within that
scope. No further native permission was assumed.
