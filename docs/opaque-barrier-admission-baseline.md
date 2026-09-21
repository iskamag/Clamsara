# Opaque-admission strict baseline: native addendum

## Result

**RED: 34 histories, 13 PASS, 21 FAIL.** This independently confirms the scoped
admission defects on the unchanged staged source. It is not a repair or
conformance result.

- PID: **14790**
- Exit: **1**, as required by the zero-failure runner.
- Duration: **2.3107352420920506 s**
- Implementation: **SBCL 2.6.8.3-db35d4561**
- Input: `/tmp/clamsara-cas-staged-yik9o9qk`
- Cases: `acceptance-source-02.lisp`
- Metadata witness: `authored-token-probes.lisp`
- Bootstrap: `bootstrap-01.lisp`
- Log: `native-01.log`
- Structured result: `native-results.json`

This run followed a new, explicit exclusive-slot handoff. The original
`report.md` and `source-evidence.json` remain the unchanged **earlier source-only
stage**. This addendum supersedes only their not-yet-executed status. No native
run occurred during that earlier review.

Exact command, from `/tmp/clamsara-cas-staged-yik9o9qk`:

```sh
sbcl --noinform --disable-debugger --no-userinit --no-sysinit --load /tmp/clamsara-cas-staged-yik9o9qk/independent-review/opaque-admission/bootstrap-01.lisp --quit > /tmp/clamsara-cas-staged-yik9o9qk/independent-review/opaque-admission/native-01.log 2>&1
```

## Failure classification

| Histories | Result | Observation |
| --- | --- | --- |
| 2 broad untyped-reservation controls | PASS | Real construction, read completion, transform retry/cancel/reuse, exact raw/callback counts and post-entry GC graph checks complete. |
| 18 own-token positives | FAIL | Rejected before entry with `:BARRIER-COMPOSITION-SIGNALED`, nested `:MISSING-BARRIER-EXECUTION-METHOD`. |
| 6 missing required phases | PASS | Exact prepublication missing-method complaint, no callback execution, real acquisition unwind. |
| 5 wrong EQL events | PASS | Same required rejection/unwind, preserving event restrictions. |
| 3 auxiliary-only ADMIT implementations | FAIL | Construction wrongly succeeds and publishes despite no compatible standard primary. |

All 21 failures are the diagnosed **semantic baseline failures**. There was no
reader, syntax, bootstrap, source-registry, output-cache, missing-dependency or
fixture-wiring failure in this run. No compiler warning was found in this log.

The 18 typed positives include each isolated typed phase without a broad
fallback, all typed phases, an author-token subclass, EQL `:READ` methods, an
observing rule with no TRANSFORM method, and valid primary-plus-auxiliary
composition. They fail during construction, so this run does **not** demonstrate
their real typed callback execution, cancellation or post-entry GC. Those remain
required acceptance checks after a correction. The untyped controls exercise
the same real fixture and authored token-body helpers successfully.

The auxiliary-only cases detect wrong publication. They do not attempt an entry
in the known-invalid published configuration or fabricate later effects. Their
standard-method semantic defect is grounded in CLHS 7.6.6.2 and the separately
reported parent host-only probe, as documented in `report.md`.

## Direct applicability witness

For each of ADMIT, TRANSFORM, BEFORE, AFTER and CANCEL, the optional fixture-only
probe produced:

```lisp
(:NIL-PROBE NIL :OWN-TOKEN (NIL)
 :TOKEN-OWNED-BY-CONTRIBUTION T :EXECUTED NIL)
```

`NIL` means no applicable methods. `(NIL)` means one primary method, whose
qualifier list is empty. Only the reservation argument changed between the two
queries; the unknown context/location/value positions stayed untyped in these
authored methods. No execution callback was invoked by these metadata queries.
An unreserved token's applicability is not a claim that its execution
preconditions hold, nor an invitation for the production builder to sample
private tokens. The real successful controls reserve and settle their token.

## Isolation and integrity

The bootstrap used a private ASDF source registry with inherited configuration
ignored. It asserted both `:clamsara` and `:clamsara/quality/support` resolve to
the exact frozen root. Its private output mapping was:

```lisp
(t ("/tmp/clamsara-cas-staged-yik9o9qk/independent-review/opaque-admission/fasl-01/" :implementation))
```

It asserted distinct translated outputs for `/one/package.fasl` and
`/two/package.fasl`; the log contains their separate full private paths.
No cache was deleted or shared cache cleaned.

**All 335 pinned inputs are unchanged** before/after the process. This inventory
covers every non-review frozen file, including source, paper and archived
fixtures/docs, plus all four authored Lisp inputs/drafts in this directory.
The proof is in `native-pre-sha256.json` and `native-post-sha256.json`.
The 115 original production/test/ASDF/paper source pins also remain unchanged.
The draft `acceptance-source-01.lisp` is preserved but was not loaded. Only the
canonical `acceptance-source-02.lisp` ran. No production, frozen fixture,
dependency or ASDF file was changed.

## Real retained ownership

Before normal process exit, the harness retained:

- **21 failed owners:** 18 rejected construction owners and **three actual
  published worlds** from false acceptance.
- **11 expected rejected builds**, with observed real construction owners and
  completed acquisition unwind.
- **Zero expected-fatal worlds.** No fake fatal state was introduced.

The 18 false rejections have `world=NIL`, an actual retained plan/construction
observation, configuration `:FAILED`, and construction `:RELEASED`. They are
failed positive tests, not leaked published worlds. The log's root field is
not queried when no world was returned; it is not proof of root retirement.

The three false acceptances have `world=T`, `plan=T`, configuration and
construction both `:PUBLISHED`, and active real root-provider tokens. They were
not unbound, cleared or force-closed after the failed assertion. All failed and
expected-rejection lists retain their actual owners for diagnostic inspection.
Only the two ordinary successful worlds follow normal cleanup.

The strict runner then reports 21 failures and exits 1. It does not reinterpret
an expected-red baseline as a green acceptance run. No repeat-run result is
claimed by this single baseline.

## Proposed correction and unchanged limits

Use the source report's private construction-time necessary primary-candidate
check, constrained by the actual contribution and event. Do not substitute NIL
for unknown reservation/context/location/value arguments. Do not add a public
sample-token contract or compulsory broad fallback. Keep conditional TRANSFORM
and per-event negative checks. With the current STANDARD definitions,
auxiliary-only methods are insufficient; custom combinations are a separately
unsupported/unproved scope, not implicitly admitted by any qualifier's presence.

A compatible primary is necessary, not proof of unknown-domain overlap,
CALL-NEXT-METHOD correctness, non-signaling bodies, non-allocation or target
admission. The larger model/benchmark/concurrency/Mezzano holds remain intact.

The process is finished. **The exclusive native slot has been explicitly
released to the parent. No further native execution is authorized by this run.**
