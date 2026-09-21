# Opaque barrier method admission — scoped repair in validation

This is a construction-time signature correction, not a complete admission
proof. Independent 54/54 and the parent full integration/replay gate pass.
The repair follows the separate CAS repair `06b2615`. The exact staged code,
permanent tests and evidence replay also pass (PID 15902). The chronological
validation notes below identify each input revision.

## Established defects and authority

The unchanged native baseline has 34 histories: 13 PASS, 21 FAIL (PID14790,
exit1,2.3107352420920506s). Eighteen valid author-owned-token cases wrongly
reject. Three auxiliary-only ADMIT cases wrongly publish. The two broad
controls and eleven missing-phase/wrong-event negatives pass. See
`opaque-barrier-admission-review.md` and `opaque-barrier-admission-baseline.md`.
The original source report is intentionally still a pre-native report.

The paper leaves private reservation representation to its author. It does not
require NIL compatibility, sample tokens, a compulsory superclass or a new
registration API. See reading56–62, construction95–100/143–153 and
execution129–141/166–189. Under the six existing STANDARD generic declarations,
CLOS requires an applicable primary; auxiliaries alone are not an implementation.
Parent host-only probe14391 and the independently fetched CLHS7.6.6.2 confirm
that even a guarded around-only method fails before its body runs. The earlier
hypothetical permission for around-only implementation was wrong.

## Implementation boundary

Only `src/runtime/barrier.lisp` changes production code. The private
`%barrier-primary-candidate-p` runs during construction, never from the mutation
driver. It enumerates existing SBCL method metadata without executing authored
methods, fabricating arguments, allocating runtime scratch, retaining a new
registry or changing the contribution API.

It matches the actual contribution, including inheritance and EQL specializers.
It matches each described event at position 2 for RESERVE or 3 for the other
event-bearing phases. CANCEL has no event argument. Other argument positions
remain unknown and are not inspected. A compatible unqualified primary must
exist. TRANSFORM remains conditional on the declared transform policy. The dual
READ+CAS ambiguity rejection, callback driver and lifecycle stay unchanged.

The hosted adapter verifies STANDARD method combination before interpreting
qualifiers. Other combinations reject as
`:unsupported-barrier-method-combination`, not a fabricated missing method.
Unavailable introspection rejects as `:unsupported-barrier-method-admission`;
an unsupported known-position specializer has its own capability complaint.
The non-SBCL branch is an explicit rejection, not Mezzano implementation.
No permission to change shared protocol generic definitions is established here.

A surviving primary is only a necessary signature candidate. This cannot infer
RESERVE's return domain, inter-phase overlap, applicable auxiliary behavior,
CALL-NEXT-METHOD correctness, nonfailure or allocation freedom. It is not an
executable-method compiler or a target admission certificate. Existing
component/host validation duties remain; unresolved duties stay unresolved.

## Validation so far

- Parent 15069: unchanged independent 34 PASS, exit0,2.430415509035811s.
  Fourteen expected rejected construction owners retained; zero failed owners.
- Parent 15212: full main/tools/workload/optional288/structure,184 installed CAS,
  176 archived CAS and repeat184; opaque 34 before and after. Exit0,
  16.383415152085945s; all input pins unchanged. The opaque runner retains 28
  expected rejected constructions, zero failed. CAS retains its 144 cumulative
  expected-fatal worlds. These are different categories, not leaks manufactured
  by cleanup. Existing dependency/workload/archive warnings remain in the log.
- Independent 15448: 54/54 PASS, exit 0, 2.3573243940481916s; all 349 pins
  unchanged. This is the unchanged 34 plus four new real builder/runtime
  histories and sixteen private metadata/capability checks. Fourteen expected
  rejected builds remain; zero failed/fatal worlds. See
  `opaque-barrier-admission-fixed-review.md`.
- Parent 15549: the permanent 54, full components/CAS gates, unchanged archived
  54, then permanent 54 again PASS; exit 0, 17.141640603076667s, all pins
  unchanged. The admission suites retain 42 expected rejected construction
  owners, zero failed/fatal. CAS retains its separate 144 expected-fatal worlds.
  The 54 comprise 38 real builder histories (24 valid and 14 rejecting) and
  16 private metadata/capability checks, not 54 target-admission proofs.
- Permanent files are `test/quality/barrier-admission.lisp` and
  `test/quality/barrier-admission-edges.lisp`. Only package names and headers
  differ from the independent bodies. The main test operation invokes their
  serial `:clamsara/quality/barrier-admission/test` system.
- Source-only integration review accepts the exact four overlays and confirms
  complete body equality of both suites after header/package normalization.
  All 346 manifest hashes match and 347 non-review files remain unchanged. See
  `opaque-barrier-admission-integration-review.md`. This is distinct from native
  acceptance; the review preserves its one input-locator mistake.
- Parent 15902: exact staged-tree full components/CAS plus permanent 54,
  archived 54 and repeat 54 PASS, exit 0, 17.168019577045925s. Archived opaque
  and CAS cases load from that staged tree's own evidence archive. All native
  input pins remain unchanged. The final code/test/ASDF bytes match this run;
  later evidence/report additions are documentation only. Retention remains
  42 expected rejected builds and a separate 144 CAS expected-fatal worlds,
  with zero failed owners.
- The earlier prepared 34-only integration snapshot was not executed. Run
  15549 used the later 54-case candidate
  `/tmp/clamsara-opaque-integrated54-2nmikfx1`, with four code/test/ASDF overlays,
  an input manifest and separately copied actual paper. Run 15902 uses
  `/tmp/clamsara-opaque-staged-ms6tash4`; the exact inputs and command are recorded in
  `staged-final/execution.json`.

The draft native input is `/tmp/clamsara-opaque-draft-8qjnkk81`: HEAD06b2615
plus one production overlay, an archived HEAD tar and separately copied actual
paper. It excludes held indexed/name/ledger code and ASDF hunks. Later permanent
integration is a distinct input and needs its own gate.

Evidence is under `docs/evidence/opaque-admission-06b2615/`. Baseline failures,
source reports, host-only probe and revision-specific logs/pins are preserved.
Original335 baseline input hashes were also rechecked by the parent. Timings
are process durations, not isolated performance claims.

No current full benchmark, model-domain/handle, compiler ownership, aggregate
opaque storage, concurrency or Mezzano hold is cleared by these results.

## What the additional tests do not establish

The inherited-contribution and fresh EQL-vector cases use real construction,
managed roots, token settlement, fixed N=1 scratch and post-entry graph checks.
Fresh EQL methods retain small nonmanaged author-side fixture state; they never
replace/remove methods applicable to older retained worlds. This is not a code
retirement, whole-residency or concurrent target-installation proof.

Private capability probes do not execute their method bodies. Reading the
non-SBCL branch and compiling it as a new anonymous function on SBCL establishes
only its explicit unsupported reason. It is not Mezzano or non-SBCL compilation.
The production helper and six generic method combinations remain unchanged.
The arbitrary custom-specializer unsupported branch has source review only.
