# CAS integration and partition review

## Verdict and scope

**Source integration accepted for the scoped CAS repair.** No lost scenario,
assertion, callback binding, public-resource proof or managed-transform proof
was found in the installed **94 + 62 + 20 + 8 = 184** cases. The code partition
is exactly the declared twelve overlays over Git `a3a0bae`.

This is a **source-only** review of `/tmp/clamsara-cas-only-1hf1b7ih` using
`cas-candidate-manifest.json`. I did not start Lisp, compile/load a system, run a
native test, acquire the parent's native slot, modify a dependency, or delegate.
Only new review artifacts under `independent-review/integration/` were written.
This verdict is not a new native PASS, full-paper conformance or target admission.

Two scope qualifications matter:

1. The **whole directory** is not literally HEAD plus twelve files: it also
   contains the candidate manifest and **25 additional `paper-v14/` files**.
   Fourteen paper `.tex` files are manifest-pinned; eleven other paper source,
   build and generated files are not. None are blocked runtime/test code.
2. The candidate **does not contain** `docs/evidence/cas-boundaries-a3a0bae/`,
   cited by test comments. The original external evidence remains available.
   The parent says the final scoped commit will add evidence separately. Do not
   describe the present candidate as already containing that archive.

## 1. Integrity and exact partition

All **104 declared SHA-256 pins** match before and after review:
**41 production + 49 tests/ASDF + 14 paper**. A full Git archive of `a3a0bae`
contains 199 regular files. Comparing bytes for every candidate file outside the
new review directory finds only these code changes:

- `src/runtime/allocation.lisp`
- `src/runtime/barrier.lisp`
- `src/runtime/cycle.lisp`
- `src/runtime/finalizers.lisp`
- `src/runtime/records.lisp`
- `src/runtime/spaces.lisp`
- `test/quality/support.lisp`
- `test/quality/barrier-history.lisp` (new)
- `test/quality/barrier-edges.lisp` (new)
- `test/quality/barrier-claims.lisp` (new)
- `test/quality/barrier-boundaries.lisp` (new)
- `clamsara.asd`

All six runtime files are byte-identical to the final frozen CAS snapshot on
which I previously obtained 176/176. That does **not** transfer that old native
result to this different candidate: the candidate host object model is HEAD,
not the earlier WIP host model.

`src/host/object-model.lisp`, `test/quality/kind-history.lisp`, and
`test/quality/model-resources.lisp` are byte-identical to HEAD. New blocked
`indexed-snapshots.lisp`, `indexed-history.lisp`, `indexed-edges.lisp`, and
`staged-history.lisp` files are absent. The ASDF delta adds only the barrier
suite and its main-test dependency; it does not import blocked suites.

The complete tree-difference inventory, all manifest hashes, extra paper paths,
and complete non-review candidate hashes are in
`partition-and-assertions.json`. The full-tree equality-to-twelve-overlays flag
is deliberately **false** because of the disclosed paper additions.

## 2. Assertion and scenario preservation

The canonical comparison inputs are:

| Matrix | Canonical original | Installed file |
| --- | --- | --- |
| 94 | `/tmp/clamsara-staged-ledger-review-tirxn_0p/independent-review/cas-contract/acceptance-03.lisp` | `barrier-history.lisp` |
| 62 | `/tmp/clamsara-cas-fixed-review-byz5pwd5/independent-review/cas-fixed/additional-05.lisp` | `barrier-edges.lisp` |
| 20 | `/tmp/clamsara-cas-final-review-pvyqoprb/independent-review/cas-final/claims-transforms-03.lisp` | `barrier-claims.lisp` |
| 8 | `/tmp/clamsara-cas-boundary-red-5tso_czk/cases-02.lisp` | `barrier-boundaries.lisp` |

The four `*-integration.diff` files preserve complete source differences.
A Python source-token comparison (not a Lisp reader or execution) gives:

| Matrix | Original CHECK forms | Installed CHECK forms | Explanation |
| --- | ---: | ---: | --- |
| 94 | 79 | 79 | Two duplicate constructor guards moved to shared support; plan-type and exact-count checks added. |
| 62 | 84 | 85 | Same two guards moved; real collector, real allocator class, and exact-count checks added. |
| 20 | 63 | 65 | No original CHECK removed; unexpected-fatal and exact-count checks added. |
| 8 | 16 | 16 | Two duplicate constructor guards moved; plan-type and exact-count checks added. |

Both moved guards remain verbatim in `support.lisp:179-182` and execute through
the shared fixture. These are static CHECK-form counts, not runtime assertion
counts. A matching assertion string alone would not establish preservation:
I also compared surrounding scenario forms and helper bodies.

Every selected original top-level scenario form appears token-for-token in the
installed source: **13, 11, 6 and 8 forms**, respectively, including parameterized
loops and their bodies. There are no unmatched scenario forms. **66 common
helper function bodies** are unchanged after removal of comments/whitespace.
The changed helpers are confined to shared constructor use, explicit observer
bindings, extra fixture assertions, and catching the actual diagnostic escape.
The JSON records those comparisons rather than treating all refactoring as
byte identity.

The boundary `attempt` helper now catches `clamsara::simulator-fatal` as well as
its authored `cas-probe-exit`. It no longer relies on an unmatched THROW becoming
a control error. The claim `one` helper explicitly turns an unexpected fatal
escape into a retained test failure. Neither change removes an assertion.

## 3. ASDF and strict runners

`clamsara.asd:143` wires the new system into `clamsara/test`.
`clamsara.asd:153-172` loads history, edges, claims and boundaries in order, then
calls all four exported runners. Each runner enforces its exact expected count
and zero failures; a false return or signaled check fails ASDF. The `AND` chain
may stop after an earlier failure; it cannot report a successful four-suite
run by skipping a later failed suite. Suites do not rely on load-time test runs.

Exact-count gates are at history:588, edges:496, claims:455, boundaries:226.
The 94 and 62 suites share their rule implementation/package but have separate
per-invocation counters. Claims and boundaries use their own packages.

## 4. Real construction, roots, collectors and resource claims

`support.lisp:183-294` still creates the real root provider, coordinator,
address space, host object model, atomics, diagnostics, finalizer registry,
metadata, spaces, collector plan, configuration and mutator. The new
`:configure-plan` hook runs **before `construct-plan`**, hence before graph
discovery, initialization, immutable accounting and publication. No constructor
or collector primary is replaced with a stub. Test plan subclasses expose their
real contributions and map their own auxiliary storage.

History:172-179 and boundaries:95-99 use that shared builder. Edges:162-203
binds the requested algorithm and configurator; it transforms a real
`marksweep-plan` into its test subclass, not a SemiSpace-labelled substitute.
Each edge case checks the world algorithm and actual context allocator class:
`bump-runtime-allocator` for SemiSpace and `free-list-runtime-allocator` for
MarkSweep. Negative pin probes still compare real allocator/registry state,
then exercise the same real components after the pin clears (edges:290-325).

The 15 claim histories retain the acquired `:independent-cas-pool` public
resource (claims:66-138), public one-entry-per-rule claims, and a per-rule
outstanding-entry limit even while other pool cells are free. Capacity 3 rejects
before publication and proves real acquisition unwind; capacity 4 admits and
witnesses four simultaneous owners, mismatch settlement, retry cancellation,
and reuse (claims:369-447). The original zero-claim token tests remain ownership
histories, not an invented public capacity proof.

The five non-identity managed-transform histories remain unchanged in their
substantive helper bodies (claims:292-368). Their targets are stored in real
registered roots before use; root reads precede the measured entry. They prove
raw-old comparison versus transformed observed return and transformed stored
value. After dropping independent target roots they run **two real collections**
and read the graph through actual roots and object slots. The expected first
collection has six dead objects out of nine. Match retains `701 -> 707 -> 708`;
mismatch/read retains `701 -> 702 -> 709`. No host-side substitute graph or fake
collection is introduced. Shared root and collection helpers are at
support:363-387; the graph oracle starts at support:397.

## 5. Observer coexistence and repaired harness regressions

The shared raw observer contract is still exactly **`:LOAD` or `:STORE`**
(`support.lisp:83-106`). It receives no managed value or borrowed location.
Comparison instrumentation has a separate zero-argument callback
(`support.lisp:111-118`), so the archived claim observer's two-way `ECASE`
remains valid.

Post-operation fault injection uses shared `:AFTER` hooks for raw load,
comparison and raw store (`support.lisp:119-133`). It does not replace primaries
or emulate their results. `extra-one` binds both the boundary hook and separate
comparison observer (`edges:163-183`). `one` explicitly binds the ordinary
observer (`history:314-320`). Bindings end with their test scope. The boundary
hook may receive a borrowed location only during that call; it does not retain
it in test state.

The permanent suites therefore do not install competing raw-operation `:AROUND`
replacements. Archived helper methods remain historical, and their coexistence
must still be checked in a combined native image; source inspection alone is
not that runtime check. The parent's latest reported combined run is listed
below, explicitly as parent evidence.

## 6. Failure ownership and repeated runners

Failure and expected-fatal owner lists use `DEFVAR`, not load-time resets.
Runner LETs reset only current-run counters/results and record previous list
lengths. They do not bind or clear `*failed-worlds*` or `*expected-fatal-worlds*`.

- History:314-359 retains failed and expected-fatal worlds, second contexts and
  transcripts. Only ordinary successful worlds call `close-quality-world`.
- Edges:409-497 reuses that ownership policy and retains direct rejection-case
  failures in the same accumulated list.
- Claims:248-277 retains its failed world/plan/condition/trace; 369-456 preserves
  earlier owners while reporting current-run counts.
- Boundaries:121-148 retains the three expected-fatal worlds and failed worlds;
  150-227 preserves all prior owners across another runner call.

No forced cleanup, manual plan reopening, fabricated retained cycle, root
retirement or resource release is used to make fatal cases pass. The exact
fatal shutdown history still checks rejection with `:FATAL-INVARIANT` before
configuration/construction state, release index or roots change
(`edges:437-464`). A rerun may pass while earlier failed worlds remain rooted;
that does not retroactively convert the earlier run into a PASS. The counters
and retained totals distinguish those cases.

## 7. Historical evidence remains separate

The earlier independent **94-case failure**, **155/156 shutdown HOLD**, and
final **176/176 scoped PASS** artifacts were not edited by this review. This
integration verdict does not erase them or upgrade their scopes.

Preserve these parent-reported integration/harness attempts as separate evidence:

- **PID 12239:** missing exact `extra-one` bindings caused three raw-injection
  failures; controls labelled MarkSweep actually used SemiSpace. These were
  integration defects, not a newly failing production CAS repair.
- **PID 12532:** fixed164/full passed, but archived20 had 18 errors after widening
  the shared two-event raw observer with `:COMPARISON`. Do not cite that run as
  a combined success.
- **PID 12601:** parent reports live full184 + archived176 + repeat184 PASS,
  exit 0, 8.990802017 s, 144 expected-fatal worlds and no failed worlds retained.
- **PID 12733:** candidate main184 passed, then workload dependency startup
  failed with missing ALEXANDRIA. Parent identified its flat private FASL cache
  as the cause; this review did not execute or independently diagnose that run.
- **PID 12854:** parent's next `:root` absolute cache mapping was invalid before
  tests. Preserve its log as a harness startup failure, not a CAS failure.
- **PID 12981:** parent reports the final cold, private path-preserving candidate
  run PASS, exit 0, 16.430080204 s. Reported coverage is main/tools/workload,
  optional288/structure, integrated184, archived176 and repeat184; 144
  expected-fatal worlds retained and no failed worlds. Reported pins stayed
  unchanged. Log: `/tmp/clamsara-cas-only-native3-zmv7go3l/native.log`.

Those native facts are **parent reports**, not processes run by this source
reviewer. Their logs/manifests remain the authority for the parent's native gate.
The parent reports that its final cache expression is
`(t (absolute-directory-string :implementation))`, with distinct output paths
asserted for `/one/package` and `/two/package`.

Review tooling history is also separate: the first Git archive request included
untracked-at-HEAD `AGENTS.md` and exited 128; the corrected source archive and
then full archive succeeded. Two Python comparison-cell syntax errors executed
no code; the corrected comparison produced the saved JSON. None was a Lisp
failure, and none changed candidate or original sources.

## 8. Limits that remain

- Dual READ+CAS reservation cardinality/lifecycle remains unspecified. Rejecting
  it with the explicit ambiguity complaint is not an invented two-leg contract.
- The paper does not explicitly settle outer-operation versus selected-event
  meaning for `OPERATION`. Passing EQL-specialized disjoint-event tests does not
  remove that specification gap.
- NIL applicability probes do not prove arbitrary opaque token/context/location
  method applicability or non-failure of the complete effective method.
- Dynamic-context workspace accounting is not immutable construction accounting.
  Fixture-specific SBCL measurements are not a target byte formula.
- AFTER ordering remains an implementation choice consistent with frozen order;
  it is not a newly written normative paper clause.
- No concurrent/lock-free execution, complete entry allocation-freedom,
  supervisor/CLOS admission, residency, Mezzano execution, or full conformance
  claim is established here. Prior Mezzano wired-EMFUN evidence remains separate.
- Blocked indexed/name/ledger/staged-handle work is not accepted by this report.

## Artifacts

- `report.md` (this report)
- `partition-and-assertions.json` (hashes, complete partition, assertion/function/
  scenario comparisons)
- `history-integration.diff`, `edges-integration.diff`,
  `claims-integration.diff`, `boundaries-integration.diff`
- `base-a3a0bae-source.tar`, `base-a3a0bae-full.tar` (read-only Git baselines)
- `base-a3a0bae.tar` (failed first archive artifact; not a valid baseline)
