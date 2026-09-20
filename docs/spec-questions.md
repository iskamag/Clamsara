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
An optional implementation now passes its initial native lifecycle/capacity
matrix. Run `(asdf:test-system :clamsara/generational/test)` when selecting it.
Independent expanded profile review remains open; this is not currently a
specification complaint.

## Not paper defects

Duplicate method definitions, ignored initializers, permissive identity
adapters, Maclina reader integration, and quadratic registration scans are
implementation issues. They belong in regression tests and fixes, not in a
paper revision that excuses them.
