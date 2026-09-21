# Barrier history integration — scoped CAS repair

Current result: the source-only integration review accepts the184-case wiring
and the12-file code/test/ASDF partition. The exact staged source also passes the
full component gate,184 permanent histories,176 unchanged archived histories,
and repeat184 (PID13509, exit0,16.337472531s). All native input pins are unchanged.
That runner loads the archived cases from its staged evidence directory.

The milestones below are chronological. Earlier “pending” and “uncommitted”
notes describe their own revisions, not a later failure or a full-conformance
claim. The final integration review is `cas-barrier-integration-review.md`.
Known model-domain/handle, opaque admission, compiler, benchmark and target holds
remain separate. No goal-completion claim is made.

The original assertions and failed transcripts remain immutable under
`evidence/cas-boundaries-a3a0bae/`. The permanent test system is
`:clamsara/quality/barrier-history/test`, also in the main test operation.

- `test/quality/barrier-history.lisp`:94 independent baseline histories.
- `test/quality/barrier-edges.lisp`:62 additional independent histories, including
  the precise fatal-shutdown regression which failed the first frozen repair.
- `test/quality/barrier-boundaries.lisp`:8 parent regressions, including the
  EQL READ-only method which has no broad fallback.

The shared quality fixture now has a test-only CONFIGURE-PLAN seam before graph
construction/publication. It preserves the real builders and guest geometry.
A shared passive BEFORE observer counts real raw operations. A separate AFTER
hook injects source-boundary failures without replacing production primaries or
another suite's AROUND methods. Its borrowed location is used only in that call,
never saved. This is test instrumentation, not target allocation evidence.

The suites have explicit repeatable strict entrypoints. Resetting run counters
does not erase previously failed or expected-fatal worlds. Summaries distinguish
per-run retention from retained totals. Expected-fatal worlds keep their genuine
roots and resources. The parent harness now catches the pre-established
`clamsara::simulator-fatal` escape rather than relying on the historical unmatched
THROW control error; its earlier logs are preserved unchanged.

PID11332 passed the full component gate, the first102 integrated histories twice
(including after archived AROUND instrumentation loaded), and all156 unchanged
independent histories. The exact shutdown result was :REJECTED/:FATAL-INVARIANT;
configuration/construction remained :PUBLISHED and release index remained0.
These overlapping runs cover164 distinct histories, not258 different tests.

The62-case permanent integration was added after that run. It still needs native
verification. The raw hooks, shared MarkSweep plan selection and repeatability
changes must pass with unchanged assertion bodies. Native authority currently
belongs to the independent reviewer on the later frozen snapshot; do not race it.

No test here authorizes the old :RETAINED fatal-shutdown result, arbitrary opaque
NIL-probe admission, dual READ+CAS token semantics, target synchronization or a
full resource account for dynamic context populations. The marker-based histories
declare no resource claims. Separate acquired-pool/claim and rooted non-identity
transform proofs are being reviewed, not presumed from these passes.

## Later verification and integration corrections

The final independent review passes176/176: original156 +15 real public-claim
pool histories +5 rooted, non-identity transform histories with two real graph
collections each. PID12020 exit0/2.628832073s,106 pins unchanged. Its unchanged
addendum is `cas-barrier-final-review.md`. The original155/156 HOLD remains in
`cas-barrier-fixed-review.md`; it is not rewritten as a pass.

All184 distinct CAS histories are now permanent:94+62+20+8. The twenty new
histories are in `test/quality/barrier-claims.lisp`. Its strict runner preserves
previous failed owners and catches the configured fatal diagnostic explicitly.
It does not use the historical unmatched-THROW error as a success criterion.

Two integration mistakes are preserved, not attributed to production:

1. PID12239 exit1/3.459475299s: a generated text replacement did not install the
   EXTRA-ONE hook and collector-selection bindings. Three raw fault injections
   never fired. MarkSweep-labelled controls actually used SemiSpace. The fix
   installs those bindings with an exact edit and checks the requested collector
   and actual allocator class in every added history. The original failed source,
   log and pins are retained in `integration-01/`.
2. PID12532 exit1/6.858861351s: all164 integrated histories and the full component
   gate passed, then18 of the20 archived proofs failed. Adding :COMPARISON to the
   shared raw observer broke the original two-event observer's ECASE. This was
   an instrumentation error that triggered real fatal closure, not a runtime
   regression. The fix keeps :LOAD/:STORE unchanged and uses a separate
   before-comparison observer. Original sources/logs are in `integration-02/`.

PID12601 exit0/8.990802017s now passes full main/tools/workload/optional288/structure,
all184 integrated histories, all176 unchanged archived histories, then all184
integrated histories again with the archived instrumentation still loaded.
Source/test/paper/bootstrap pins are unchanged. There are zero failed worlds.
Each integrated run retains49 expected-fatal worlds; the archived suite retains46.
The total is144 retained fatal worlds, not discarded between runs. Existing
intentional dependency/tool/workload and archived helper warnings are not a
clean-warning claim. Full logs and input pins are in `integration-03/`.

This is still mixed-worktree evidence. A separate candidate starts from
HEAD a3a0bae and overlays only six CAS runtime files, shared test support, four
CAS suites and the CAS-only ASDF hunks. It excludes the held model and indexed
suite edits. Its first run, PID12733 exit1/7.586021937s, passed main184 but failed
loading a workload dependency: the private `(t directory)` output map flattened
distinct `package.fasl` paths. Nothing in production or the dependency was changed.
The original cache/log remain. A new private `:ROOT`/`:IMPLEMENTATION` mapping
preserves source paths and asserts noncollision. Candidate full verification and
source-only integration review are pending; mixed-worktree PASS is not a substitute.

The first output-map correction itself failed before tests: PID12854 exit1,
0.340048812s. :ROOT requires relative following components, not an absolute
pathname. After reading the installed ASDF resolver, the next runner uses
`(t ("/tmp/<private-cache>/fasl/" :implementation))`. The location list wildens
the target and preserves source-directory suffixes; explicit noncollision
assertions precede tests. No cache/index/dependency was erased or changed.
This is a harness correction, not a paper or production defect.

## CAS-only candidate passes

PID12981 exit0/16.430080204s passes the complete component gate, integrated184,
unchanged archived176, and repeat184 on `/tmp/clamsara-cas-only-1hf1b7ih`.
This is HEAD a3a0bae plus exactly12 code/test/ASDF overlays: six CAS runtime files,
shared support, four barrier suites and CAS-only ASDF changes. The host model,
kind-history and model-resources files are exactly HEAD; blocked indexed/staged
suite files are absent. The code-only candidate does not contain the new evidence
archive. That archive and reports are separate documentation proposed for the
scoped commit, not hidden candidate load dependencies.

The cold private output mapping demonstrably gives different paths for
`/one/package.fasl` and `/two/package.fasl`. It preserves absolute source suffixes
under the private implementation-specific cache. All source/test/paper/bootstrap
pins remain unchanged. The20 benchmark fixtures and complete earlier paper
manifest also match in both live and candidate trees. Shared Maclina remains
clean at `d92e9254b45da4e508503b984f02403c6fb6677a`.

This run retains144 expected-fatal worlds and zero failed worlds. Cold dependency
and delayed workload compilation warnings remain in the log, including the
existing Maclina native-attribute references. Archived helper redefinitions also
remain. The evidence is not a clean-warning, target, full-conformance or benchmark
claim. The canonical log/bootstrap/pins are in `candidate-03/`.

The12-overlay comparison is **code/test/ASDF only**, not a literal full-tree
identity claim. The code-only candidate also contains `cas-candidate-manifest.json`
and25 copied paper inputs/artifacts (14 TeX files plus build/bibliography files
and existing generated outputs); HEAD does not track that paper tree. None is a
production overlay. The integration reviewer inventories those extras explicitly.

Staging caught four trailing spaces on one blank line in `barrier-claims.lisp`.
Only that whitespace was removed. The earlier frozen candidate remains unchanged;
an exact staged-tree candidate is verified separately before the scoped commit.
