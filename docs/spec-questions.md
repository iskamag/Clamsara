# Specification questions for a possible v15

`paper-v14` remains normative and unchanged. This is a question log, not an
errata list or permission to relax acceptance. No contradiction has yet been
established for the questions below.

For concrete implementation-guide feedback and proposed worked traces, see
[Implementation feedback on paper-v14](paper-v14-implementation-feedback.md).
That note separates unclear integration guidance from confirmed implementation
bugs; it does not change the normative paper.

## Hosted residency boundary — open question

Make the acceptance evidence distinguish:

- fixed, charged host storage implementing a simulated managed arena;
- actual guest payload placed and reclaimed in that arena;
- interpreter control objects with exact writable roots;
- host containers or boxed values used as unaccounted guest payload.

The final category was an implementation defect, not evidence that v14 is
wrong. A regression demonstrated host conses and boxed double-floats retained
by a numeric word plane. The advertised word representations now reject them
before writes; broader language-adapter residency is still incomplete. Review whether the paper should state a sharper hosted
residency test and supported scalar representation contract.

## Dynamic root registration accounting — open question

Construction requires a complete capacity account and exact physical and
auxiliary capacity (`chapters/construction.tex`, resource contract). Roots can
be registered through the root-client protocol. A regression demonstrated retained service records allocated after publication
without updating the frozen account. That was an implementation bug.

The implemented repair uses explicit charged reserves and pre-effect exhaustion.
Review whether v15 should make the active-provider, total-location, and
historical-token bounds explicit, including external provider ownership versus
root-service ownership. A clearer contract may help future clients avoid the
same mistake; it is not a reason to accept uncharged growth now.

## Generational coverage — clear v14 rule, newly selected work

`chapters/validation.tex` labels generational composition an optional profile.
The user has now requested generation-correctness tests, selecting additional
work. Current SemiSpace/MarkSweep successes do not establish that profile.
An optional implementation now passes its native lifecycle/capacity tests and
a separately selected independent matrix, including 288 seeded strong-graph
collections and 96 conditional combinations. Run
`(asdf:test-system :clamsara/quality/generational/test)` for that matrix.
See `docs/generational.md` for the repaired major policy and bounded evidence.
Common-core review findings and broader profile admission remain open; this
is not currently a specification complaint.

## Finalizer cancellation outcomes — narrow clarification

`chapters/clients.tex`, “Finalizer registry,” requires an opaque token to identify
one record generation, idempotent cancellation before freeze, and
`:already-finalized` afterward. Cross-registry aliasing and a stale token naming
a successor are implementation defects, not ambiguous permissions.

The following return conventions need a precise statement:

- After a successful cancellation, does repeating that cancellation return
  `:canceled` or `:already-finalized`, including after its physical slot is reused?
- Does cancellation with another registry's token signal an invalid-token
  condition, or may it return `:already-finalized` without effects?

The hosted implementation currently returns `:already-finalized` without effects
for inactive or foreign tokens. Its token repair preserves that convention;
it does not claim the paper explicitly chooses it. The invariant is tested
independently: neither request can alter a successor or another registry's record.
For referent correction, the specification already explicitly requires `:stale`
on a token/state/encoding mismatch.

## CAS dual subscriptions and OPERATION — current v14 complaint

`chapters/execution.tex:129-141,166-190` does not settle the reservation and
terminal-callback contract for one opaque contribution subscribed to both READ
and CAS. Please specify:

- One reserve call for the union, or separate read/write calls?
- Which OPERATION values reach reserve/admit/transform/exposure: the outer
  operation or each selected path?
- How many before/after calls occur on match, in what within-contribution order,
  and which call consumes each reservation?
- How does mismatch settle an unused write part while retaining the read path,
  given that cancel takes no event argument?

The baseline one-token/two-after implementation had no established generic
ownership argument. The repaired driver rejects this dual composition before
publication. The earlier proposed two-token alternative was also an
unsupported contract choice, not merely private storage. Do not double an
opaque author's claims to force that choice. Under `chapters/reading.tex:48-51`,
affected construction must reject before publication until the contract is
resolved. No new profile label is proposed.

For disjoint subscribers, contribution-first BEFORE order and reverse mismatch
cancellation are clear requirements. The baseline also contradicted its
own event-specialized admission by passing CAS to READ-only reserve/admit
methods. The repair uses the selected event consistently; the OPERATION wording
should still make the intended mapping explicit.
The text explicitly orders BEFORE, while a matching AFTER order is consistent
with the single frozen order rather than separately specified at line186.

Finally, reserve :RETRY is explicitly failure-atomic. That does not prove an
arbitrary ERROR/THROW before returning a token acquired nothing, nor authorize
reopening as ordinary retry after an unknown callback fault. The driver must
preserve known ownership and fail closed when state cannot be established.
See [the CAS addendum](cas-barrier-contract-addendum.md).

## Opaque barrier method admission — signature repair and remaining limits

At `06b2615`, construction substituted NIL for unknown reservation, context,
location and value arguments. The independent34-case baseline demonstrated18
false rejections of valid author-owned-token methods and3 false acceptances of
auxiliary-only ADMIT methods. The original evidence is preserved in
`opaque-barrier-admission-baseline.md`.

The scoped repair uses a private construction-only necessary signature check:
match known actual contribution/event specializers and require a compatible
primary under the existing STANDARD method combination. Leave unknown arguments
unknown. Preserve per-event rejection and conditional TRANSFORM. It adds no
sample-token API, compulsory superclass or obligation to accept NIL. Unsupported
host introspection/combination is a capability complaint, not evidence that the
author's method is missing. See `opaque-barrier-admission.md` for revision-specific
native and independent results.

Successful NIL-token controls prove ownership is separate from token value.
They do not require all authors to accept NIL. Likewise, a primary candidate
does not establish the RESERVE result domain, inter-phase overlap, effective
method success, non-failure, storage bounds or target entry admission. An author
still cannot depend on another component's private representation. These duties
remain open; they are not waived by a structural check or by the hosted tests.
The OPERATION wording gap and full opaque-author/Mezzano admission remain
unresolved. No paper amendment or new author declaration is proposed here.

## Not paper defects

Duplicate method definitions, ignored initializers, permissive identity
adapters, Maclina reader integration, and quadratic registration scans are
implementation issues. They belong in regression tests and fixes, not in a
paper revision that excuses them.
