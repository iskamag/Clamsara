# Correctness-first checkpoint: client boundaries and paused LIST work

Code revision: `1099d6235d7cc2730ce5066fb404daaca0bd75d9`.
This checkpoint adds evidence only. It does not repair the reported defects.

## Direction

The user clarified that Gabriel is an integration enforcer, not a mandate to
reimplement Common Lisp. Framework correctness and client/storage boundaries
come first. No LIST implementation was made. General REST, compiler patching
and language expansion remain paused; the shared Maclina checkout is unchanged.
The broad paper/target/benchmark goal is still incomplete.

## Client boundary review

See [the independent source audit](client-boundary-audit.md) and
`evidence/client-boundary-1099d62/`. The report distinguishes:

- No direct Maclina dependency found outside the optional workload adapter.
- Concrete hosted accounting, representation and root-access helpers are called
  from construction/runtime paths. These limit client substitution; they are
  not new native corruption results in the existing hosted configuration.
- Finalizers accept FUNCTIONP callbacks without managed callback admission,
  do not expose CALLBACKS as corrected roots, and publish registration fields
  without the required composed root-store path. This is missing correctness
  enforcement in an accepted runtime path, not just a portability limitation.

The client model decides guest/reference ABI and scanning. The plan/components
choose collector geometry and declared work-storage representations. Valid
private vector storage is not itself a violation. Raw guest-word restrictions
also do not automatically authorize descriptor identity/name restrictions.
Held model/indexed WIP remains separate and uncommitted.

Both source-review versions and the exact reviewed pins are retained. Actual
paper sources were read separately from the live unchanged paper directory;
they were absent from the frozen code archive. No native opaque-client or new
lost-capture witness is claimed by this source audit.

Next: establish a strict core-only finalizer callback-admission baseline, then
repair or explicitly reject unsupported admission before publication. Do not
teach the collector Maclina closure layouts, invent new required public hooks,
ignore retained storage, or misuse snapshot-only root accessors.

## Preserved LIST baseline — not acceptance

`evidence/list-baseline-1099d62/` preserves PID21361, exit1 in
13.01035007298924 seconds. The unchanged V2 source ran all21 attempts:

- Behavior: 1 pass (empty LIST), 6 failures.
- Proposed N+2 capacity histories: 1 pass (empty LIST with zero arena), 12 failures.
- Host payload: 1 rejection diagnostic, not a positive admission test.

Only two successful owners discharged and closed. Eighteen failed owners plus
the diagnostic owner remained published with active tokens through summary.
All12 failed N17 capacity cases retained their case input graph. All1147 pinned
files were unchanged, including all20 original fixtures and clean shared
Maclina d92e9254. No failing owner was cleared/collected/closed by failure cleanup.
This is process-summary retention, not a surviving live-process/core claim.

The runner's outer PRE-UNWIND label actually records the rethrow after the test's
internal unwind; that limit is explicit, not retroactively fixed. The source-only
review also found omissions in physical-state comparison and in live outer
extent survival coverage. Old source, results, reports and incomplete V3 notes
are retained. No revised V3 test or LIST production implementation was written.
Capacity values are private design proposals, not Common Lisp arity requirements.
Settled MAPC evidence is unchanged; GCBench acceptance remains revision-specific.

## Later scoped update: shared copying action

The sections above record the1099 audit checkpoint, not a current full-conformance
claim. The held88-file model/indexed/ledger work was subsequently preserved on
`wip/held-model-indexed-ledger` at `95e5886c843889235ecfa50b9e5772c13734d22d`;
it is committed there, not accepted or merged into master.

The core-only finalizer admission baseline did run: PID22799, strict exit1.
A native FUNCTIONP callback that was not a bound-model reference was accepted,
returned a token and mutated registry state. No production finalizer repair is
included here. This is admission evidence, not a lost-capture consequence test.

[Shared copying action](shared-copy-action.md) records the later narrow runtime
refactor and its permanent tests. Construction and collection phases genuinely
use declared protocols; the independent composition review's initial claim that
private helpers/copy duplication alone violated the paper was withdrawn. The
report, addendum and corrections are preserved together.

SemiSpace/MarkSweep and their existing generational combination remain the only
implemented collectors in this commit. Immix/Sticky Immix, Claimore MGC/OVC,
Evha and Iso/request-private remain missing. A passing finite MGC research model
is not a runtime collector. The broad goal is still active and language expansion
remains paused.
