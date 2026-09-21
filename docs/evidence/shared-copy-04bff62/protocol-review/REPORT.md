# Are the real collectors constructed through the protocols? (paper-v14)

Reviewer: independent read-only review (DeepSeek Flash on ClosedRouter).
Question answered: **"Are the actual collectors constructed correctly through the
protocols, which is the whole point?"** — *not* backend portability, *not*
generic-method counts.

## 0. Pinned inputs

* Repo `/home/iskam/src/vibe/Clamsara`, branch master, clean, rev
  `04bff62db4ef86868dc6d5d917e8704f9d90b62e` ("Record client boundary audit and
  pause language expansion"). `wip/held-model-indexed-ledger95e5886` excluded; no
  checkout; no build/test/native command run.
* Paper: `paper-v14/chapters/{construction,collectors,execution,metadata}.tex`
  (read first-hand; parent verdicts not used as authority).
* Code read first-hand: `clamsara.asd`; `src/construction/{protocol,build,graph,
  records,validation,layout}.lisp`; `src/runtime/{protocol,records,barrier,trace,
  spaces,cycle,allocation,generational,finalizers}.lisp`; `src/metadata/metadata.lisp`;
  `src/host/{address-space,resources,coordinator,object-model,roots}.lisp`;
  `test/runtime/{semispace,marksweep}.lisp` (fixtures, read only, not evidence of
  correctness).
* Absent (verified by file list, not by test names): no Immix, Sticky Immix, Evha,
  Claimore, Iso/request-private, no NoGC space class; those are paper plans only.

## 1. Direct answer, one paragraph

**Construction: yes. Execution: no, for the moving and generational paths.**
The builder genuinely composes the real collectors: the plan, both SemiSpace
spaces, the MarkSweep space, every metadata storage, and the finalizer registry
are `component` objects discovered by a dependency walk, and their resources,
placements, constraints, initialization, validation, activation and barrier
contributions all pass through the generics declared in
`src/construction/protocol.lisp` and quoted in `chapters/construction.tex`. The
builder in `src/construction/` contains no test for `semispace-space`,
`marksweep-space`, `runtime-space` or any collector class — those classes are
*authors of declarations*, not special cases in the builder
(`src/construction/build.lisp:192-208, 210-236, 277-330, 446-479, 598-779`;
`src/construction/graph.lisp:294-330`). The same is true of the *stopped cycle
driver*: it drives spaces through `prepare-space` / `trace-object` /
`object-live-p` / `reclaim-space` / `cancel-reclaim-space` / `finish-space` and
the trace-context and movement-participant generics
(`src/runtime/cycle.lisp:355-400, 490-560`), and the barrier through
`barrier-contribution-*` over opaque contributions it does not know the class of
(`src/runtime/barrier.lisp:43-77, 226-330`). **But the things the driver can
drive are fixed concrete classes**: allocation reaches into a space's private
allocator slot, the trace context computes claim indices from a space's private
geometry, the trace-capacity rule and claim-cell sharing are decided by
`(typep plan 'semispace-plan)`, the allocation destination is re-derived from a
space's private `role` field, the trace context object is constructed by name
inside the plan, and the optional generational plan attaches through **private
plan-phase generics defined in `cycle.lisp`/`trace.lisp` and never declared in
the paper**. Generational is therefore not SemiSpace + MarkSweep composed through
protocols; it is a fork that duplicates the copying action and the MarkSweep
reclaim preflight and reaches into their private slots.

So: the whole point (collectors as protocol compositions) is *achieved for
configuration* and *only approximated for execution*. The gap is not
"generics exist"; it is that the execution half of the framework is one
sequential runtime whose extension points are private, and the paper declares
neither those extension points nor the concrete class requirements.

## 2. Per-collector verdicts

### 2.1 SemiSpace — construction through protocols: correct. Execution: protocol-driven surface, hardwired collaborators.

Verdict: **composed at construction, closed at execution.** Legitimate design,
not a violation of the construction chapter, but it does not satisfy "all plans
use the tracing protocol already defined" (`chapters/collectors.tex:5-7`) as
literally as the chapter reads.

Call path that does work (contract-relevant):

```
construct-plan (build.lisp:598)
  %discover-component-graph plan coordinator        ; plan + coordinator roots
  plan dependencies = spaces + registry + coordinator  (records.lisp:423-426)
  space dependencies = object-start-map [+ forwarding] (spaces.lisp:47, 183)
  builder: %validate-space-map-declarations (build.lisp:192)   ; map must be a
           direct dependency and in the graph, discovered via the declared
           SPACE-OBJECT-START-MAP generic (graph.lisp:312-318)
  placements solved -> initialize-component -> construction-placement
           (spaces.lisp:53-77)
  resources acquired -> construction-resource (spaces.lisp:63-84, 40-45)
  object-model binding after the maps are ready (build.lisp:210-236; marker
           component-requires-bound-object-model-p, protocol.lisp:184-188)
  validate-component -> metadata-bounds equality with the solved range
           (spaces.lisp:86-96)
  activate-component -> plan state :open (records.lisp:499-503)
```

Genuinely protocol-based, first-hand evidence:

* Spaces are recognized by *applicability* of the normative
  `space-object-start-map` generic, with no registry and no class test
  (`src/construction/graph.lisp:312-318`; `chapters/metadata.tex:81-90`).
* The builder enforces the paper's binding-order rule
  (`chapters/construction.tex:174-187`): a map hidden behind a
  space/model-consuming group rejects before any component initializes
  (`src/construction/build.lisp:210-236`).
* Placement, resource capacity, claim-sum and constraint preflight are all
  declarative and validated before publication (`build.lisp:23-160`).
* Lifecycle map is exact: initialize -> validate -> activate, with
  reverse-order deactivation and reverse-acquisition release on failure
  (`build.lisp:277-330`, `470-556`); deactivation runs before release exactly as
  `chapters/construction.tex:199-215` states.

Execution-side closures (the real findings):

| # | Finding | Evidence |
|---|---|---|
| S1 | Allocation destination is not fixed by construction; `%route-space` tests `semispace-space` and re-derives the live destination from the private `role` field. | `src/runtime/allocation.lisp:5-14` |
| S2 | The execution side reads the space's private allocator, not a declared accessor: `%space-allocator` is a slot reader of `runtime-space` and there is no `space-allocator`-style generic anywhere. | `spaces.lisp:35` (slot), `allocation.lisp:33,94`, `spaces.lisp:236,269,290,379,481,625`, `generational.lisp:349,634` |
| S3 | The execution side reads the *private* map reader `%space-object-start-map` (and `%space-range`) instead of the declared `space-object-start-map` used by the builder. The declared generic has exactly one consumer: the builder. | declared use `graph.lisp:312-318`; private use `trace.lisp:227`, `allocation.lisp:109,117`, `cycle.lisp:599`, `finalizers.lisp:225`, `generational.lisp:341,371,467,487,570` |
| S4 | The trace context computes claim indices from space geometry: `%trace-direct-index` reads `%space-packing-quantum`, `%space-extent`, `%space-base`, `%space-limit` of every `%plan-spaces` entry, and special-cases the plan class `semispace-plan`. No declared generic exposes a space's claim index/geometry. | `src/runtime/trace.lisp:44-64` |
| S5 | The space writes cycle-private state (the "forwarding published" flag, movement records, byte counters, the current retirement space). The cycle has no declared "publication happened" entry, so a third-party space cannot report publication without writing another component's slot. | `spaces.lisp:289-294, 349-353`; `generational.lisp:476-482`; slots at `records.lisp:103-160` |
| S6 | The space demands the concrete role class `forwarding-metadata` in `initialize-component`, not in `validate-component` where `chapters/metadata.tex:44` puts admission; and `forwarding-metadata` is a code-local role, not a chapter-declared one (`chapters/metadata.tex:13-18` declares only metadata/bit/range/transferable/atomic + `mark-map`). Paper also allows forwarding as "side metadata **or an admitted header field**" (`chapters/collectors.tex:26-27`); the typep forbids the second without editing the space. | `src/runtime/spaces.lisp:186-191` |
| S7 | The declared layout ownership transition is never called by any collector: `prepare-space-ownership-update` / `update-space-ownership` appear only in `protocol.lisp`, `package.lisp`, the host simulator, and acceptance tests. SemiSpace instead flips `%semispace-role`/`%semispace-candidate-role` in private state and `cancel-reclaim-space` merely clears the candidate role. | callers: `src/host/address-space.lisp:153-240`, `test/acceptance/resources-layout.lisp`; no collector caller; `spaces.lisp:362-366, 383-385` |
| S8 | The reported per-object "reversible pre-forwarding failure" branch is gated on the *cycle-global* flag, so after the first successful copy of a cycle a later pre-forwarding fault is classified `:post-publication-failure`. Conservative (matches "fails the trace context"), but the comment's per-object framing overstates locality. | `spaces.lisp:277-317` |

Small code notes (legitimate, recorded so they are not mistaken for defects):
the sequential allocator's `refill-mutator` correctly returns nil and documents
"no hidden TLAB refill source" (`spaces.lisp:162-170`); metadata transfer for the
two declared roles is a real protocol call
(`metadata.lisp:534-556`; `mark-map`/`forwarding-metadata` primaries at
`metadata.lisp:150-160, 178-180`); `metadata.tex:44` explicitly *permits* consumer
`typep` role checks, so the `typep` in `spaces.lisp:187`, `metadata.lisp:646-662`
is not by itself a fault.

### 2.2 MarkSweep — construction through protocols: correct. Execution: correct in shape, closed in type; one unused protocol.

Verdict: **the most honest of the three.** Its reclaim/commit split matches
`chapters/collectors.tex:112-127` closely: preflight builds a complete
non-authoritative candidate (survivor extents, coalesced dead/existing-free runs)
and commit rotates the candidate into the authoritative free list
(`spaces.lisp:585-604` vs `612-631`). Marks are space-private metadata reached
through `metadata-*` generics; the free-descriptor storage is an ordinary
declared resource contribution with displaced views
(`spaces.lisp:444-452, 454-483`).

Closures:
* The chunks of the reader are point S1-S4, S7 above: the free-list allocator
  class is created inside the space (`spaces.lisp:475`), the space must be
  `runtime-space` (geometry + allocator + model slots), and the ownership
  transition protocol is unused.
* `chapters/execution.tex:247` ("Every installed component with source-indexed
  facts is a movement participant") is not implemented by any in-tree space.
  MarkSweep discharges tombstones/retirement inside `finish-space` by filtering
  the cycle's death vectors (`spaces.lisp:612-631`), and the movement-participant
  list is always nil (`records.lisp:329-330`; no `make-*-plan` passes
  `:movement-participants`). `map-cycle-movements` / `map-cycle-deaths` have
  methods but no in-tree caller (`trace.lisp:303-311`; only re-exported). That is
  reachable-but-unexercised declared surface, not a wrong path.

### 2.3 Generational (optional system) — construction: partly protocol, partly undeclared private seam. Execution: a fork, not a composition.

Verdict: **not composed through the declared protocols.** This is the decisive
per-collector negative.

What is legitimately composed:
* `generational-plan` is a `sequential-runtime-plan` subclass and declares its
  three spaces through the ordinary `:spaces` path (`generational.lisp:7-34,
  188-224`), so discovery/resources/lifecycle are the common machinery.
* Its remembered-set rule is a real, protocol-conformant substitution: an opaque
  object with a 9-value `describe-barrier-contribution` and
  `barrier-contribution-*` methods, composed by the builder through
  `component-barrier-contributions` and `make-composed-barrier`
  (`generational.lisp:36-46, 99-100, 232-266`; `build.lisp:446-479`;
  `barrier.lisp:43-77`). This is the one place that *proves* the composition
  seam works for a plan-specific policy.
* Its capacity declarations are ordinary resource contributions
  (`generational.lisp:79-97, 114-171`).

What breaks composition:
* **Copying action duplicated, not reused.** `chapters/collectors.tex:13-14`
  states SemiSpace is "the source of the copying action reused by generational
  plans". In code, `trace-object` on `generational-nursery-space` reimplements
  claim/copy/forwarding/commit for the minor path and only delegates for major
  (`call-next-method`) cycles (`generational.lisp:428-503` vs
  `spaces.lisp:243-317`). The two bodies differ (bump allocation into to-space
  vs a pre-reserved mature free interval via `%gen-promotion-destination`), so
  the reuse claim is not implemented; there is no `copy-object`/`move` protocol
  generic to share.
* **MarkSweep internals reimplemented.** The mature reclaim preflight is
  rebuilt by writing MarkSweep's private reclaim fields
  (`%marksweep-reclaim-cycle`, `%marksweep-reclaim-cursor`,
  `%marksweep-reclaim-free-start`, `%marksweep-candidate-count`,
  `%marksweep-candidate-ready-p`) and calling the internal
  `%marksweep-add-free` (`generational.lisp:559-583`), instead of reusing
  `reclaim-space`. It also reads the mature allocator's private vectors
  `%free-starts`/`%free-limits`/`%free-count` to reserve promotion space
  (`generational.lisp:349-354`) and reads `%marksweep-descriptor-capacity`
  (`generational.lisp:82, 382, 392`) — i.e. it cannot be written without the
  MarkSweep implementation, and it must track it by hand.
* **Undeclared plan-phase protocol.** The plan phase set is a set of *private*
  generics defined in the runtime: `%plan-scope-supported-p`,
  `%plan-stop-scope`, `%prepare-cycle-spaces`, `%trace-plan-additional-roots`,
  `%map-plan-conditional-sources`, `%prepare-plan-reclamation`,
  `%finish-plan-reclamation` (`cycle.lisp:43-90`, `trace.lisp:4-6`), plus two
  `%space-in-cycle-scope-p` methods for the new space classes
  (`generational.lisp:417-426`). None appear in
  `src/runtime/protocol.lisp`, `src/construction/protocol.lisp`, or the paper.
  So a new collector must specialize private runtime generics, contradicting
  `chapters/collectors.tex:5-7` ("They do not acquire private versions of those
  protocols") if the phase protocol counts as part of the common machinery. As a
  spec matter this is a documentation gap: the paper never declares how a plan
  selects participating spaces/sources for a cycle.
* `generational-plan` must also subclass `sequential-runtime-plan` (see S9) and
  can only be loaded as a separate ASDF system that depends on `clamsara`
  (`clamsara.asd`, `:clamsara/generational`), i.e. on the runtime's private layer.

### 2.4 Plan/entry verdict (applies to all three)

Verdict: **the entry owner is a concrete class requirement in the execution
path.** `%configuration-runtime-plan` rejects any plan that is not a
`sequential-runtime-plan` (`records.lisp:578-583`), the trace-capacity rule is
chosen by `(typep plan 'semispace-plan)` (`records.lisp:480-498`) and the same
test decides claim-cell sharing (`trace.lisp:60-63`), so the trace-context
indexlayout of a new moving plan cannot be declared — it must be inferred from
the plan's class. The result/counter schema is *not* taken from the construction
schema: `%configuration-result-schema` is written by the builder and never read,
while every runtime query reads the plan's private `:counters`/`:causes`/
`:reasons` initargs (`records.lisp:323-353, 507-546`; `build.lisp:619, 642`;
`validation.lisp:175, 254-271`). No in-tree component defines a *non-default*
`component-result-contributions` (only the empty `component` default at
`protocol.lisp:47` and a construction contract test fixture at
`test/construction/contract.lisp:56`), so the declared result-contribution protocol
is inert for production code while the "real" schema rides private state. Likewise
`%plan-movement-participants` is permanently empty.

## 3. What is genuinely composed via stated protocols (correctly used paths)

1. Component graph discovery from the plan and the selected coordinator;
   dependency-once-by-`eq`; declaration snapshotting and freezing
   (`graph.lisp:200-330`; `build.lisp:598-660`).
2. Space identification and the space->map binding order
   (`graph.lisp:312-318`; `build.lisp:192-236`).
3. Placement (`make-placement-request`/`construction-placement`), resource
   capacity (`make-resource-contribution`/`construction-resource`), auxiliary
   registration and the capacity account (`build.lisp:23-160, 519-556`;
   `spaces.lisp:40-84`; `records.lisp:398-478`; `host/resources.lisp:90-120`).
4. Constraints, including SemiSpace's `:equal-extent`
   (`spaces.lisp:390-396`; `generational.lisp:70-77`; `build.lisp:150-166`).
5. Opaque barrier contributions and immutable composed barrier
   (`generational.lisp:36-46, 99-100`; `build.lisp:446-479`;
   `barrier.lisp`; `chapters/execution.tex:118-146`).
6. Metadata as one shared component per role with the role mixins owning the
   logical rules (`metadata.lisp:79-214, 559-661`).
7. Space/metadata validation as protocol checks with consumer-side role `typep`,
   which `chapters/metadata.tex:44-52` explicitly sanctions
   (`spaces.lisp:86-96`; `metadata.lisp:646-662`).
8. Transactional lifecycle and rollback ordering (`build.lisp:277-330, 470-556`).
9. Cycle driver order and phase semantics for spaces, participants, trace
   context, conditionals, finalizers and stop release
   (`cycle.lisp:355-400, 490-560`), matching
   `chapters/execution.tex:219-340`.

## 4. What can be replaced without editing a collector?

Replaceable today (constructor argument + declared method, no collector edit):

* Metadata storage class for any role the space already takes as an argument —
  e.g. swap `object-start-marks` for `scalar-object-start-marks`, or
  `side-forwarding` for another admitted side storage — provided it implements
  `metadata-bounds`, `metadata-ref/set/reset/reset-range/map-present` and, for a
  moving space, is a `forwarding-metadata` (S6).
* Barrier rule: any opaque contribution object with
  `describe-barrier-contribution` + `barrier-contribution-*` (proved by the
  generational remembered set).
* Root client, stop coordinator, address-space client, object model, atomics,
  diagnostics: reached only through their client generics
  (`with-root-snapshot`/`map-root-locations`, `request/await/release-safepoint`,
  `managed-arena-offer`/`validate`/`install`, `bind-object-model`,
  `load-reference`/`store-reference-raw`, diagnostics).
* Finalizer registry implementation **only if** it is a
  `sequential-finalizer-registry`-compatible component: the cycle reads its
  private `%registry-capacity`/`%registry-pending-count` (`cycle.lisp:204-207`;
  `finalizers.lisp:37,54`), and the client protocol declares no capacity query.

Not replaceable without editing collector code (concrete-class/private-state
requirements):

* Any space class: must descend from `runtime-space` and use its slots
  (`%space-base/limit/extent/packing-quantum/model/range/allocator`,
  `%space-object-start-map`). S1-S4, S7.
* Allocation destination/domain: `%route-space` + `%semispace-role`. S1.
* Allocator implementation: created by name inside each space
  (`spaces.lisp:194, 475`); no construction-time allocator contribution and no
  accessor generic. S2.
* Any plan class: must descend from `sequential-runtime-plan`; trace capacity and
  claim-cell layout follow from a `semispace-plan` type test; phase behaviour
  requires private runtime generics. S9, §2.3, §2.4.
* Trace context implementation: constructed by name in the plan
  (`records.lisp:227`) and specialized on by the spaces' `trace-object`
  (`spaces.lisp:243, 522`), so space and trace context are mutually concrete.
* Result/counter/cause/reason schema: plan-private initargs; the declared
  result-contribution path is inert (§2.4).
* Host integration: construction is gated on the profile value
  `:sequential-host` in the builder and again in the host resource acquirer
  (`build.lisp:601-603`; `host/resources.lisp:51`; `host/coordinator.lisp:156`).
  A different host must use that exact keyword or edit the builder. (Host-only,
  reported for completeness, not as the composition core.)

## 5. Unproved or contradicted paper claims (code-level)

1. `chapters/collectors.tex:13-14` — SemiSpace as "the source of the copying
   action reused by generational plans": contradicted; the action is duplicated
   (`spaces.lisp:243-317` vs `generational.lisp:428-503`).
2. `chapters/collectors.tex:62-64` — the copying action must "transfer every
   admitted metadata role": only the two roles the space holds in private slots
   are published (`spaces.lisp:283-289`), and there is no declared enumeration of
   a space's admitted metadata roles. True for the reference compositions, unproved
   as a framework property.
3. `chapters/construction.tex:302-315` — `prepare-space-ownership-update` called
   in reclamation preflight and consumed in `finish-space`: not implemented by any
   collector (S7).
4. `chapters/execution.tex:113` — "the construction route fixes
   domain-to-scope, kinds, size/alignment and **destination**": the scope and the
   named space are construction data, but the effective destination is re-derived
   each binding from the space's private role (S1).
5. `chapters/execution.tex:247` — every installed component with source-indexed
   facts is a movement participant: no in-tree space is a participant; the list is
   always empty (§2.2).
6. `chapters/execution.tex:232-243` and `:258-271` — one trace context, spaces
   "independently authored", `trace-scope-contains-p` with "no address-map
   guessing": the scope predicate delegates to an undeclared generic and the
   context's claim index is derived from space-private geometry arithmetic
   (`trace.lisp:4-6, 44-64`), so spaces are *not* independently authorable against
   the declared boundary alone.
7. `chapters/collectors.tex:5-7` — plans "do not acquire private versions of
   those protocols": generational acquires exactly that for the cycle phase set
   (§2.3).
8. No Conformance claim: nothing here is evidence of correctness of the
   algorithm, only of the composition structure. No test counts were used.

## 6. Verdict summary

* SemiSpace construction: **through the protocols, correct.** SemiSpace
  execution: **driven by protocol generics, closed to non-`runtime-space`
  implementations, one declared protocol unused (ownership update).**
* MarkSweep construction: **through the protocols, correct.** Execution: same
  closures; reclaim/commit split matches the chapter; movement-participant path
  unexercised.
* Generational: construction **partly** through protocols (spaces, resources,
  barrier contribution) and **partly** through an undeclared private plan-phase
  seam plus a fork of SemiSpace/MarkSweep internals. Not a composition.
* Cheapest honest fixes (no code written here): declare a space geometry/allocator
  accessor set, declare the plan phase protocol (or fold it into the execution
  chapter), wire one of `prepare/update-space-ownership` into the moving
  `finish-space`, drive the runtime schema from `%configuration-result-schema`,
  and either factor the copying action into a declared generic or correct
  `collectors.tex:13-14`.

## 7. Evidence limits

No native command, test, or dependency was run (per instruction and for
cleanliness); conclusions are structural, from source and paper text at the pinned
rev. No full-conformance claim. No claim that any of S1-S9 is a live bug: they are
substitution/composition limits and unproved claims. `%registry-*` and
`%marksweep-*` cross-boundary reads are mechanism-accurate today; the risk is
latent drift, not a current failure.
