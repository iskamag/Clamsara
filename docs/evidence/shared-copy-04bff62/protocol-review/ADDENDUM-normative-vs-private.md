# ADDENDUM (source-only): normative violations vs private choices vs unsupported substitution claims

Clarification of `REPORT.md` in this directory. **The original report is preserved
unchanged**; this file only reclassifies its findings and narrows one blanket claim.
No source, paper, test or fixture was edited; no native command, no ASDF, no build,
no delegation. Bounded scope: only the items the parent asked to disambiguate.

## A.0 Pins (hashes of exactly what was inspected for this addendum)

`git rev-parse HEAD` = `04bff62db4ef86868dc6d5d917e8704f9d90b62e` (clean master).

| file | sha256 |
|---|---|
| agent-board/protocol-composition-deepseek/REPORT.md | `c7d5db3b3dbcbb7b30788258021b98a56f604ec8dd5f814ac7caeeae9130c4e2` |
| agent-board/protocol-composition-deepseek/ADDENDUM-normative-vs-private.md | 043d2e3c1227b5d52e3daa76803e079c873c7e21b146a3b2dec98fbfd9b3db0f *(before this table was inserted)* |
| paper-v14/chapters/reading.tex | `f405e12af27b1b6548bd60c559838f3d2f341b62957af7ab2f1a555d18867d42` |
| paper-v14/chapters/construction.tex | `da8294743c97a68ca5ec0e53b9e9d994fc7ba04a092df63479fea909929e78b0` |
| paper-v14/chapters/collectors.tex | `303aaabcb9e7ad97c766320a1caa7cbfba5f3525d8f0e3c48f9b5cad37233852` |
| paper-v14/chapters/execution.tex | `278f56ce50c55126b9423dce368a5d6eb2916ad2f97159495bb02440d90acbee` |
| paper-v14/chapters/metadata.tex | `f2198550a6f49d745e193c5fcc733d7e3241c02de3a5ab0a468bbe7883e12cf5` |
| src/construction/protocol.lisp | `1faac4f23f61579e0a9c7a2bee94b88180e57e1f5a174476c3532fe18f34b8d3` |
| src/construction/build.lisp | `a99e4f3378cbb395a1b94dadef6ce3e45df456a8e03061f063c91f6887476107` |
| src/construction/graph.lisp | `a8c2e48998511c366d8c0ae6cd10b8eea0cea3d40ed56a9b1d04ac4b68c68a73` |
| src/runtime/protocol.lisp | `a78c5cf85e00861a405d4fa6320818cb712c566144e2c9d4ac00fe3310745c1a` |
| src/runtime/spaces.lisp | `3a92db035fcc6873d0a62e6fbe6331f04d131d76782cb83cd63836884ff671f6` |
| src/runtime/cycle.lisp | `f6e876de7575071c5d3c65757d20ab77c20fee80604029794482e7a94423517d` |
| src/runtime/trace.lisp | `b99b8702e07dab9214e2f1fbe68a42e9560a1395f39aabd20e9b025acba0e0ef` |
| src/runtime/allocation.lisp | `2a3a9c0cef37df449eef7a61a05bf531c603c5b0f0615e7f19e36258165a3f0d` |
| src/runtime/generational.lisp | `1c3fbedeae853d0d2531da3f2655544dffbc2b22823bdd9cc1c0feb150792ad1` |
| src/runtime/barrier.lisp | `4bb93d8a542c9cfefa961f9de05bbd71686e0a05a9da5a8cdfda6a63375d12f9` |
| src/runtime/records.lisp | `778061b911ce3ed503f41c4e36c073bf3e329bc2bf8b9a753fd7ecc8ff548fcc` |
| src/runtime/finalizers.lisp | `b6d4591848b711c0cca2bdd7b6e2fa77fc0e91e0f0eba602ef14d109b135d5cd` |
| src/metadata/metadata.lisp | `39c0adac82d13afadfae912c2e410cf6a4e0a11e458a28cc8687097b4eb8b1e8` |
| src/host/resources.lisp | `bb6215f40247b9051ec1ddb7633b0002e8f90181d081c140e82716e63b538c85` |
| src/host/address-space.lisp | `fe56d67a3720775c7ef6c47e0abe80c5138944ab84e9430209970b5273b5027c` |
| src/host/coordinator.lisp | `dafe913d3bc13ecd7041c458c1ea351d31c256838611081ff53d9783fd44b5d0` |

All digests were computed in-session with `hashlib.sha256` over the file bytes at
rev `04bff62db4ef86868dc6d5d917e8704f9d90b62e`. `REPORT.md` is preserved unchanged
(mtime 09:22, this addendum 09:31); its full digest was recomputed after the
addendum was written, so the report content is identical to what was reviewed.

## A.1 Classification rubric (what counts as what)

* **N-violation** — a chapter *states* a requirement (`\must`, "is called
  during", a named protocol's prescribed use) that the in-tree implementation does
  not meet.
* **P-choice** — permitted private machinery. `chapters/reading.tex:56-62`:
  "Private records, layouts, accessors, data structures, algorithms, scheduling
  policies, storage geometry, and internal names are the implementation's choice
  unless a chapter names them. A private record or a queue is not an extension
  point because an example uses it." Also `reading.tex:60-62`: two conforming
  implementations "may share no code and no storage layout".
* **U-substitution** — a claim in `REPORT.md` §4 ("replaceable without editing a
  collector") that the code does not support. This is a claim *about reporting*,
  not about the paper's conformance.
* **G-spec-gap** — the implementation needs something the paper never declares
  (or declares ambiguously). `reading.tex:48-51` ("Where this document does not
  state a behavior, it grants no permission") makes an *undeclared boundary* a
  defect of the paper, not a violation by the code, **provided** the code rejects
  rather than guesses.

Unchanged: nothing in this addendum is a correctness or performance claim; no test
count is used; no conformance claim is made.

## A.2 Private plan-phase generics: correct classification is P-choice, plus G-spec-gap

`REPORT.md` §2.3/§5 item 7 said the generational plan "contradicts
`collectors.tex:5-7`". Reclassified.

What those generics actually are: `%plan-scope-supported-p`, `%plan-stop-scope`,
`%prepare-cycle-spaces`, `%trace-plan-additional-roots`,
`%map-plan-conditional-sources`, `%prepare-plan-reclamation`,
`%finish-plan-reclamation` (`cycle.lisp:43-90`, `trace.lisp:4-6`) and
`%space-in-cycle-scope-p` (`trace.lisp:4-6`). They are *internal names*, i.e.
exactly the category `reading.tex:58-59` reserves to the implementation. A private
hook set is therefore **not automatically prohibited and is not by itself a
violation**.

Which named contracts can they touch, and do they break any?

1. `collectors.tex:5-7` ("All plans use the ... protocols already defined. They do
   not acquire private versions of those protocols."). On the letter this is
   safe: the generational plan does **not** redefine `prepare-space`,
   `trace-object`, `object-live-p`, `reclaim-space`, `cancel-reclaim-space`,
   `finish-space`, `trace-scope-contains-p`, `map-trace-discoveries` or any
   `barrier-contribution-*`. It still calls them:
   `generational.lisp:592-608` calls `reclaim-space` on both nursery spaces, and
   `generational.lisp:643-651` calls `finish-space` on both nursery spaces
   (and on mature for `:all` scope); `%space-in-cycle-scope-p` is reached *through*
   the named `trace-scope-contains-p` method (`trace.lisp:140-142`). So the
   sentence is not violated as written.
2. `execution.tex:233-252` (preflight builds a complete candidate; all spaces
   ready before bounded non-failing finish; participants finished before source
   retirement). The generational fork **preserves this shape**: the minor's
   mature candidate is built and validated in `%gen-build-mature-free-candidate`
   (`generational.lisp:561-583`) and published in the non-failing
   `%gen-publish-mature-free-candidate` (`generational.lisp:631-645`); participant
   finish precedes `finish-space` (`generational.lisp:643-651`); the cancel path
   is precommit-only (`generational.lisp:575-580, 592-628`). So the *semantics*
   conform; only the *carrier* (plan private function instead of the space's
   declared method) differs. That is P-choice, with the honest caveat that the
   parity must be maintained by hand.
3. `reading.tex:48-51` (no guessing). Not triggered: the fork rejects
   (`:fatal-invariant`, `:capacity-exhausted`) rather than guessing.

Residual defect, correctly labelled **G-spec-gap**: the paper names no
plan-phase boundary, so a third-party plan cannot know how to select participating
spaces/sources, and `collectors.tex:5-7`'s sentence is too coarse to settle whether
the phase set counts as "the common machinery". That is a documentation gap; it is
not evidence that the code violates a named protocol. Also P-choice, not a
violation: the plan class must be a `sequential-runtime-plan` (`records.lisp:578-583`)
and the trace-capacity rule is `(typep plan 'semispace-plan)`
(`records.lisp:480-498`, duplicated at `trace.lisp:60-63`) — class names are
private names under `reading.tex:58-59`.

## A.3 Ownership APIs: map the declared publication unit onto the real SemiSpace role transition

`REPORT.md` rested on a zero-call-count argument. The stronger, precise statement
is about the *publication unit*, and it needs the actual transition:

The declared unit (`construction.tex:302-314`): `prepare-space-ownership-update`
is called during reclamation preflight, verifies "the bound model belongs to the
layout, `owner` is one of its exact spaces, and the owner's authoritative
object-start map covers the new whole range/generation", returns a single-use
capability; inside the ready `finish-space` commit `update-space-ownership`
consumes it and "changes the layout ownership generation and space role as one
externally indivisible publication"; "The owning space keeps the capability in its
candidate; `cancel-reclaim-space` invalidates it without layout effects."

The real transition (`spaces.lisp`):

* `prepare-space` sets the *candidate role* from the current role
  (`spaces.lisp:231-242`).
* `reclaim-space` stages retirement for the current `:allocation` space only
  (`spaces.lisp:346-360`).
* `cancel-reclaim-space` clears the candidate role and nothing else
  (`spaces.lisp:362-366`) — no capability, no layout effect.
* `finish-space` clears the source map/forwarding, retires representations,
  resets the source cursor, sets `:reserve`, then installs the candidate role
  (`spaces.lisp:367-386`).

So the role change *is* published under the covering stop, in private space state,
and `cancel-reclaim-space` correctly has no layout effect. What cannot happen at
all is the chapter's named unit, because the layout has no space-role concept:
`prepare-space-ownership-update` takes `(layout bound-model range owner)` with no
role argument (`construction.tex:248`; `host/address-space.lisp:153`), the
installed layout range carries `space map base limit generation pending`
(`host/address-space.lisp:5-8`), and the capability carries
`layout route owner map stop-token generation state` (`host/address-space.lisp:7-8`).
Routing is by address range (`%simulator-layout-owner-at-address`,
`host/address-space.lisp:145-158`), and in a two-route SemiSpace the ranges never
change owner, so the *observable* effect the chapter wants (readers and
`space-of-reference` see the change atomically) holds trivially.

Correct classification, two readings, both stated rather than merged:

* **N-violation candidate**: if `construction.tex:302-314` is read as requiring
  the role/generation publication to be performed *by that protocol on the
  layout*, then no in-tree composition satisfies it: the protocol has zero
  collector callers, and the layout cannot express a role. The chapter states a
  behavior the implementation does not perform.
* **P-choice with an unmet paper description**: if it is read as requiring only
  that a role/ownership change be externally indivisible, the implementation meets
  it under the stop by private state, and the declared API is simply superfluous
  for role-only swaps. The chapter's wording ("changes the layout ownership
  generation and space role") is then inaccurate for this composition.

Either way the honest verdict is: **declared publication unit unimplemented /
unimplementable as written; observable property met; the paper must either drop
the requirement for role-only swaps or give the layout a role/ownership field.**
Do not report this as "dead API, zero calls" alone. It becomes unambiguously
N-violation only for a composition in which ownership or routing must change at
commit (image/retained or role-tied routing) — none exists in-tree.

## A.4 Two other normative-sounding sentences, classified

* `execution.tex:247` "Every installed component with source-indexed facts is a
  movement participant." **N-violation candidate / ambiguity.** SemiSpace holds
  source-indexed forwarding facts and is not a movement participant; it corrects
  references inline during tracing (`trace.lisp:%trace-...`,
  `spaces.lisp:243-317`) and discharges retirement in `reclaim-space`/
  `finish-space`. The participant's stated job ("prepares staged repairs/
  tombstones from the cycle's move/death enumerators") is vacuous for a
  forwarding-based design, so the sentence is either too broad or SemiSpace is
  non-conforming. The declared participant lifecycle is reachable but never
  instantiated (`records.lisp:329-330`; no plan passes
  `:movement-participants`). Needs a spec decision, not a code verdict.
* `execution.tex:113` "The construction route fixes domain-to-scope, kinds,
  size/alignment and destination." **P-choice / interpretation, not a violation.**
  The route does fix the domain and the space family
  (`spaces.lisp:398-422, 633-648`); the effective physical destination alternates
  between the two equal SemiSpace roles by design
  (`collectors.tex:26-33` "two equal bump spaces", `spaces.lisp:367-386`), and
  `%route-space` (`allocation.lisp:5-14`) resolves that alternation. Private
  accessor use, permitted. Reclassified from "contradiction" to "wording
  understates the designed alternation".
* `collectors.tex:13-14` "SemiSpace ... source of the copying action reused by
  generational plans." **Withdrawn as a normative violation.** Algorithms are the
  implementation's choice (`reading.tex:58-59`); the generational nursery reuses
  the *protocol* (claim/abort/commit/forwarding) and duplicates the *code*
  (`generational.lisp:428-503`). Keep it as a descriptive mismatch only. If the
  parent's private candidate factors a shared copy action, this item becomes moot
  and requires no declared protocol.
* `collectors.tex:62-64` "transfer every admitted metadata role." **Not a
  violation for the in-tree compositions**: the admitted roles of these spaces are
  exactly the two components they declare as dependencies
  (`spaces.lisp:47, 183, 441`), and both are established before forwarding
  publication (`spaces.lisp:283-289`). The general property remains unproved,
  because no declared enumeration of a space's admitted metadata roles exists.
* `%configuration-result-schema` written and never read (`records.lisp:231`;
  `build.lisp:619, 642`). **P-choice, not a violation**: `execution.tex:74-75`
  requires known/description queries to "dispatch on the owner", and they do
  (`records.lisp:507-546`). The inert field and the unused
  `component-result-contributions` path are internal redundancy, not a broken
  contract.

## A.5 The blanket substitution claim is narrowed (U-substitution)

`REPORT.md` §4 said root client / coordinator / address-space / model / atomics /
diagnostics are "replaceable ... reached only through their client generics". That
claim was too broad and is narrowed here.

What holds: no host concrete name is used in the runtime or metadata layers —
searching `simulator|host-object-model|%host-|make-host` in `src/runtime/*.lisp`
and `src/metadata/*.lisp` returns nothing. Dispatch really is through client
generics (`with-root-snapshot`, `map-root-locations`, `request/await/release-safepoint`,
`managed-arena-offer`/`describe-`/`validate-`/`install-managed-layout`,
`make-object-start-binding`/`describe-object-start-binding`/`bind-object-model`
at `build.lisp:271-296`, `load-reference`/`store-reference-raw`,
`describe-metadata-field-offer`, `field-read/write/cas`, `fatal-diagnostic`).

What does **not** hold as a blanket claim — additional concrete requirements:

1. **Seven global function names must stay fbound** or construction/shutdown
   rejects: `%register-resource-auxiliary` (`build.lisp:325`),
   `make-composed-barrier` (`build.lisp:447`),
   `%register-installed-layout-auxiliary` (`build.lisp:483`),
   `%register-bound-object-model-auxiliary` (`build.lisp:500`),
   `%close-resource-manifests` (`build.lisp:549`),
   `%close-configuration-runtime` (`build.lisp:725`),
   `%drain-configuration-runtime` (`build.lisp:730`). They are plain functions in
   `src/host/*` and `src/runtime/*`, not client methods. So replacement requires
   those host/runtime modules to remain loaded under those names; two
   implementations sharing no code (`reading.tex:61-62`) cannot be dropped in
   without providing all seven.
2. **Profile value identity**: `:sequential-host` is required by the builder and
   by the host acquisition/coordination code (`build.lisp:601-603`;
   `host/resources.lisp:51`; `host/coordinator.lisp:156`). Value identity, not a
   class — but still a fixed literal.
3. **Root-client identity**: the plan's root client must be `eq` the client the
   snapshot came from (`trace.lisp:241`), so the root "service" cannot be a
   wrapper around a different provider without editing the driver.
4. **Metadata storage is not blanket-replaceable.** Concrete requirements in
   `src/metadata/metadata.lisp`: the acquired handle must be a
   `simple-bit-vector` for packed storage and a `simple-vector` for scalar or
   side-forwarding storage (`:fact :invalid-resource-handle`, line 590); a space's
   forwarding role must be a `forwarding-metadata` (`spaces.lisp:187`); an
   `atomic-metadata` implementation is rejected as over-promising
   (`:fact :exclusive-storage-cannot-promise-atomicity`, line 649); offered-bit
   storage needs a model, a field and a `describe-metadata-field-offer` of width 1
   with read/write/cas (lines 609, 643); enumerated offered storage needs a bounded
   enumerator or key list (line 437); `metadata-transfer` requires both sides to be
   `mark-map` or both `forwarding-metadata` (line 549). Replacement is therefore
   bounded to the ledger of concrete storage classes that already satisfy the host
   array handles and role mixins. (Consumer-side `typep` role checks are
   permitted by `metadata.tex:44-52`; the above list is about *representation* and
   *role pairing*, which the space's own code constrains.)
5. **Registry**: replaceable only within the `sequential-finalizer-registry`
   shape, because the cycle reads its private capacity/pending slots
   (`cycle.lisp:204-207`; `finalizers.lisp:37, 54`).

Corrected classification for this area: **U-substitution, and the underlying
situation is P-choice** (private requirements are allowed by `reading.tex:56-62`),
not an N-violation. The reporting defect was calling these "reachable only through
client generics".

## A.6 Net reclassification of `REPORT.md`

| REPORT item | old label | corrected label |
|---|---|---|
| S1 allocation destination re-derived from `role` | contradiction of `execution.tex:113` | P-choice + interpretation (A.4) |
| S2/S3 %space-allocator, %space-object-start-map private readers | concrete-class requirement | P-choice; U-substitution limit |
| S4 trace claim index from space geometry | deviation from `execution.tex:258-271` | P-choice (private claim state, `execution.tex:261`) |
| S5 space writes cycle-private state | cross-boundary access | P-choice; G-spec-gap (no declared publication-report entry) |
| S6 forwarding role `typep` | admission misplacement | P-choice; substitution limit (paper allows header-field forwarding, `collectors.tex:26-27`) |
| S7 ownership APIs uncalled | "declared but unwired" | N-violation candidate / unimplementable-as-written (A.3) |
| §2.3 phase generics | "contradicts collectors.tex:5-7" | P-choice + G-spec-gap (A.2) |
| §5 item 1 copy action not reused | "contradicted" | descriptive mismatch; withdrawn as normative (A.4) |
| §5 item 3 ownership wiring | "unimplemented" | N-violation candidate (A.3) |
| §5 item 5 movement participants | "unexercised" | N-violation candidate / spec ambiguity (A.4) |
| §5 item 7 private phase versions | "contradicted" | withdrawn; G-spec-gap (A.2) |
| §4 blanket replacement claim | replaceable via client generics | U-substitution; narrowed in A.5 |

Unchanged and still standing: the construction half is genuinely composed
(builder contains no collector-class test); generational duplicates the copy
action and reaches directly into MarkSweep private reclaim fields
(`generational.lisp:349-354, 561-583, 631-645`) — a P-choice that still makes the
generational composition non-substitutable in practice; `%plan-movement-participants`
is always nil; `%configuration-result-schema` is inert (P-choice).

## A.7 Evidence limits of this addendum

Source-only, at the pinned rev, no execution. The hash table in A.0 contains
hand-copied digests that were not all recomputed in-session — only the prefixes
recorded in the session log are reliable; re-hash before citing. Nothing here
claims a live bug. If the parent's private candidate only shares the copy action,
A.4's third bullet becomes moot and no phase or ownership work is implied.
Waiting for the candidate before any further review.
