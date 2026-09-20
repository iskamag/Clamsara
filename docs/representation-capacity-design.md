# Source-only proposal: hosted representation-capacity admission

Reviewed the fixed `/tmp/clamsara-finalizer-queue-review-lk542af4` production
sources (parent reports these match de22e51). No native execution, edits to
sources/dependencies, or delegation. This is a proposal, not verified code.

## Recommendation: reject an undersized offer at object-model binding

For this dense hosted model, the minimal honest repair is a construction check:

```
C = sum over installed routes of (route-limit - route-base) / map-granularity
require offered host-model-capacity >= C
```

Use the already checked `total-cells` in `bind-object-model`, immediately after
its geometry/representability checks and before allocating the dense planes
(`src/host/object-model.lisp:537-565`). Reject with an explicit required/offered
capacity diagnostic. Keep the caller's offered capacity unchanged; do not use
`max(offered, required)`, enlarge either heap extent, or delete the runtime guard
as a substitute for admission. No new public protocol or runtime reservation
state is needed. The existing builder wraps binding errors and unwinds the
unpublished build (`src/construction/build.lisp:286-299`). Test that unwind.

**Proof for this particular limit:** each initialized representation occupies
one distinct nonzero `sizes` entry. `live-count` counts those entries until
retirement (`object-model.lisp:1046-1069,1796-1816`). There are exactly C entries,
and initialization requires its destination entry to be zero. Therefore before
any otherwise valid initialization, `live-count <= C-1 < offered capacity`.
This includes unexposed destinations, old sources awaiting retirement, mature
objects outside a minor's scope, and all finalizer-retained objects. It does not
rely on knowing reachability or discovery order. Keeping the runtime check
provides an invariant backstop, not ordinary capacity management.

Use actual installed map granularity, not blindly the plan's Q. Runtime space
validation permits map granularity smaller than Q (`spaces.lisp:91-95`). The
model prebuilds a descriptor and base encoding for every such map cell
(`object-model.lisp:635-651`). The result can be conservative relative to the
runtime allocator's Q-aligned starts; that is an explicit admission restriction,
not an exact maximum live-object calculation. A smaller proven bound is possible
with a more coupled allocator contract, but is not this minimal repair.

This policy already exists in the workload constructor for its equal-granularity
semispaces: `src/workload/setup.lisp:34-42` computes both extents/Q, derives a
capacity only when none was supplied, and rejects a smaller explicit offer.
Moving the guarantee to the common binding path closes the bypass.

### Compatibility and accounting consequences

This is a real contract tightening. It rejects some configurations whose actual
programs could fit fewer, larger objects. Many model-resource fixtures currently
request capacity 8/16 for 4096-byte extents; the variable-array stress requests 8
with a much larger extent (`test/quality/model-resources.lisp:1556-1558`). Those
are not all negative tests. Their positive fixtures must explicitly provision the
admitted layout bound, without changing heap sizes. Do not silently clamp an
explicit caller offer, or keep calling these capacities 8/16 in reports.

The dense descriptor/base-reference planes and arena already use geometry, not
the offered capacity. Raising an explicit offer to C does not itself enlarge
those planes or the heap. Resource reports must still describe actual storage
and actual policy; do not multiply a larger arbitrary offer into fictitious
physical storage. A capacity above C is a policy ceiling above the physical
layout bound, not evidence that more than C starts can coexist.

In particular, the fixed-pool exhaustion test around
`test/quality/model-resources.lisp:467-567` intentionally constructs capacity 2
and expects a third initialization to fail. That exact scenario becomes a
**construction rejection** test. Keep its independent variant/location/handle/
staging exhaustion checks with an adequately admitted representation capacity.
Do not erase those distinct resource tests to make the suite green.

## Normative basis, and what is not required

- paper-v14 `construction.tex:163-200`: complete capacity is provisioned and
  consumers validated before publication; validation can reject, not repair the
  graph. `:316-340`: physical/logical/auxiliary bounds and exhaustion actions are
  explicit, and stopped entries need storage for their admitted work.
- `collectors.tex:35-49,81-98`: every survivor subset, including finalizer
  retention, must fit; preflight precedes copying; post-forwarding capacity
  exhaustion is an invariant failure, not permission to reopen old sources.
- `clients.tex:44-45`: initialization creates an unexposed representation.
  Source and destination representations are distinct until retirement; merely
  having enough destination bytes does not provide their logical descriptors.
- `execution.tex:63-85`: pre-entry capacity rejection and post-admission failure
  are different contracts. Do not turn an admitted partial copy into a harmless
  allocation failure by changing its result label.

The paper does not require this exact constructor inequality or a new public
capacity-query API. It requires a sound capacity/progress argument. This is a
simple sufficient one for the actual dense representation. It does not solve
variant pools, handle generations, kind/size admission, or every other possible
initialization failure.

## Alternative: reserve copy credits when admitting allocation

Keeping small logical caps is possible, but is not a one-line preflight fix.
Let C denote the offered cap in this section. Count **allocated representations**,
including garbage not yet retired, not objects already proven live:

| Open-plan state | Sufficient admission invariant |
|---|---|
| SemiSpace, S source objects and empty reserve | `2*S <= C` |
| MarkSweep, M objects | `M <= C` |
| Current generational plan, M mature and Y young source objects | `M + 2*Y <= C` |

The mixed-generation peak is `M + Y + P`, where P is the number of initialized
nursery destinations/promotions and `P <= Y`. Mature sources remain represented;
they are not copied. Minor promotions increase mature occupancy only as they
consume the reserved young copy budget. Major nursery copies use nursery
reserve; old mature garbage is not free until closed commit. The current major
must remain independent of successful promotion reservation
(`generational.lisp:385-405`). `2*(M+Y)` incorrectly charges copies for mature
objects and can block a valid major with a full mature space.

Thus young allocation must preserve `M + 2*(Y+1) <= C`; any admitted direct mature
allocation must preserve `(M+1) + 2*Y <= C`. Check before reserving/mutating the raw
allocator or exposing a representation. Exhaustion uses the ordinary bounded
collection/retry path. If all admitted sources survive, collection still fits;
the next allocation may fail honestly. MarkSweep must not lose half its usable
logical capacity to a copying policy it does not use.

A correct implementation needs exact maintained role counts or equivalent
credits, checked arithmetic, rollback, retirement accounting, and construction
accounting of any added state. Existing mature/nursery snapshot counters are not
a general always-current allocation count. At a stop, freeze the source cohort;
never reclassify newly promoted destinations as additional original sources.
During copying, track actual initialized count plus **remaining** copy credits,
not actual count plus the original full source count again. Unpublished
candidates consume capacity too. Failed candidates return their credit; sources
are not retired early to manufacture room. Root/finalizer closure and any
additional moving spaces must fit the same argument. These complications are
why the constructor bound is the smaller honest repair here.

**Preflight alone is insufficient progress management.** Admitting S up to C,
then requiring `2*S <= C` at each collection can permanently prevent collection
even if every source is garbage. Dropping roots does not reduce S before tracing.
The mixed-generation analogue is the same. Exact reachability preflight could
avoid that false failure, but requires its own complete nonmutating traversal,
conditional/finalizer closure, capacity and accounting: not a minimal change.
Preflight remains useful as an invariant check when allocation has already
reserved the required credits.

## Focused test matrix for the recommended repair

1. **Construction boundary:** exact C accepted; C-1 rejected; original cap3/two-
   source setup rejected before publication. Above-C offer remains unchanged.
   Assert diagnostic required/offered values, unchanged offered model, released
   construction resources, and no published configuration. Exercise fragmented/
   multiple routes, packed/scalar maps, and map granularity smaller than Q.
2. **Native all-survive SemiSpace:** provision exactly C for two equal spaces;
   use Q-sized objects to fill the source. All survive and copy successfully,
   reaching the simultaneous source/destination bound. Repeat after role swaps,
   drop roots and repeat; assert identities, fields, moves and live-count after
   retirement. Include a source retained only through finalizer closure.
3. **Dense model boundary:** with small geometry and suitable nonoverlapping
   one-cell kinds, initialize all C descriptors across the installed routes;
   verify count C, retire/reinitialize, and verify exact count restoration.
   This exercises unpublished representation accounting separately from GC.
4. **Generational mixed states:** with nursery capacity N cells per side and
   mature D cells, bind exactly `C=2*N+D`. Fill mature and nursery, then run a
   major with every object live. Peak representation use can reach C even though
   mature is not copied. This must complete; `2*(M+Y)` would reject it. Repeat
   with mature garbage: do not assume that garbage frees representation slots
   before nursery copying. Verify it is reclaimed at commit and subsequent
   minor promotion/allocation can progress.
5. **Minor then major:** leave sufficient mature byte/free-list capacity for all
   young promotions; include preexisting mature sources and conditional/finalizer
   retention. Verify promoted destinations coexist with old young sources and
   old mature sources, and exact live-count after retirement. Then major-collect
   the result. Keep byte/free-list exhaustion tests separate from this cap.
6. **Fixture/report audit:** update positive fixture offers explicitly from their
   geometry, retain genuine negative constructor cases, retain other pool-
   exhaustion tests, and confirm arena/plane lengths and reported physical costs
   did not grow merely because the explicit logical offer changed. Run the large
   variable-array stress as well as core/optional-generational suites.

For the credit-based alternative, add threshold tests for nursery versus mature
allocation, full-garbage GC progress, all-survivor allocation failure with an open
valid plan, and all prepublication rollback paths. The constructor-only repair
does not claim to preserve low-capacity admission or implement those credits.

## Separate nonbase follow-up

The base-cell bound above does not cover historical tagged/interior encodings.
The later [canonical-code row repair](reference-variant-row-design.md) separately
provisions every legal relocation destination before returning the first
nonbase value of that code. It retains an exact finite record offer and rejects
changes to the fixed descriptor granularity. Read its own evidence and limits;
those do not follow from this base-representation proof alone.
