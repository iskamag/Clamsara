# Object-kind description snapshot review

## Verdict and scope

**The accepted hosted rule forms do not provide the paper-v14 snapshot guarantee.**
This is now a native result, not only an aliasing concern. Changing a caller's
lexical size/alignment-rule environment after binding changes allocation
admission. A real semispace collection of previously published objects then
fails after its first forwarding publication. Unchanged controls pass.

A second, narrower hosted-extension case is worse: mutating a caller-created
`host-variable-size-rule` geometry makes collection report `:complete` while
losing a previously strong child. That case uses a private hosted construction
record and setter. It is not presented as a portable public-protocol test.

The report does **not** call private writes to opaque descriptions legal.
Mutating copied caller-owned layout/list inputs passed. Mutating model-owned
query results or opaque records demonstrates aliases, but is not independent
public-contract evidence.

Snapshot: `/tmp/clamsara-description-review-7p14doks`, commit `9dd8629`.
Normative paper: `/tmp/clamsara-independent-review-3ygbx_br/paper-v14`.
All 41 source hashes in `review-snapshot.json` matched before and after probes.
Only new files under `independent-review/description-probes/` were created.
No live project source was read or changed.

## Exact normative obligation

References are to the unchanged paper's `chapters/` directory:

- `clients.tex:60-62`: every admitted kind has a finite construction-time
  description.
- `clients.tex:81-88`: the opaque-description rules apply; binding “snapshots
  each description once”; execution does not observe later mutation;
  `object-kind` selects that snapshot; the allocation descriptor must name the
  same kind; **the model** interprets size, alignment, and layout rules.
- `construction.tex:96-108`: no record class/accessor layout is public; the
  builder describes once, copies returned proper lists (including finite
  constraint trees), captures other values, and later mutation has no effect.
  Description calls are construction-only and effect-free.
- `clients.tex:108-111,173-177`: tagged location keys are kind-local, unique,
  and stable for the admitted lifetime. Strong identities come from the
  snapshotted strong layout.
- `clients.tex:113-119`: binding is a pure handoff. The returned private bound
  model is immutable; the offered model stays unchanged.

These clauses do not require any model to accept arbitrary Lisp functions, nor
require a generic deep-copy operation for arbitrary closure environments.
They require the model's **accepted** rule interpretation to have finite,
stable bound meaning. The hosted model explicitly accepts function size rules
and invokes function alignment rules, with no documented caller obligation to
freeze their lexical environments. The probes change only the caller's scalar
lexical variables, between operations, and never write an opaque kind or bound
model in those cases. The rule functions themselves merely read those values.
This is an accepted-hosted-input counterexample through the exported
`make-object-kind-description` interface, not a claim that function syntax is
universal in the paper.

The paper's “captures other values” wording does not specify how to freeze a
function. It does not cancel the explicit no-later-mutation rule. A model can
resolve a finite rule at binding or reject a rule it cannot snapshot.

## Native method and evidence

Two serialized SBCL/ASDF processes ran the real
`:clamsara/quality/support` fixture. No core model/collector methods were
replaced, no errors were disabled, and no benchmark was needed.

Each bootstrap prepends the snapshot to `asdf:*central-registry*`, asserts
`asdf:system-source-directory :clamsara` resolves to that exact snapshot, and
places new FASLs under this report's directory. The logs begin with that source
path. Both processes exited 0 and reached their final event markers. An exit of
0 means the observation script completed, **not** that snapshot conformance
passed.

- `bootstrap.lisp`, `cases.lisp`, `native-01.log`: 32 worlds.
- `bootstrap-02.lisp`, `definitions-02.lisp`, `supplement-02.lisp`,
  `native-02.log`: 16 worlds.
- `execution.json`: process IDs, exit codes, durations, source verification.
- `source-verification.json`: per-source pre-run hash results.

The main matrix uses `:semispace` and `:marksweep`, each with `:packed` and
`:scalar` object-start maps. Every mutation row has an unchanged control.
Normal worlds completed the fixture's normal shutdown. Failed or corrupt worlds
were kept without clearing their real roots to force shutdown. OS process exit
ended those bounded fixtures. Public/barrier root and slot operations established
all real managed edges; host locals were not substituted for roots.

## Cases and actual results

### 1. Caller-owned size-rule environment: admission and retained collection

Kind `:rule-object` uses `(lambda (kind) (declare (ignore kind)) size)`,
initially `size = 32`, and alignment 16. A published 32-byte object is reached
from root 0 through an ordinary rooted `:quality-node` parent.

Before mutation, 32-byte requests allocate and 48-byte requests return
`nil, :failed, :invalid-size`. After the caller sets `size` to 48:

- 32-byte allocation returns `nil, :failed, :invalid-size`.
- 48-byte allocation succeeds, with `object-size = 48`.
- The existing object's recorded `object-size` remains 32.
- The bound and offered description queries both expose a function now
  returning 48. Those queries are observations, not mutations or a required
  runtime query protocol.

For both semispace map forms, collection returns
`:retained/:post-publication-failure`, `:objects-moved = 1`, forwarding true,
plan `:retained`, stop `:covered`. The parent has moved before initialization of
its 32-byte child is rejected under the changed rule. Subsequent allocation
rejects `:collection-busy`; unbinding returns `:retry`.

For both marksweep forms, collection completes and the real child remains
reachable. It does not reinitialize a moving destination. Allocation admission
still changed. Unchanged controls complete in all four profiles.

A separate semispace/packed world completed one full collection before the
caller changed `size`. Its next collection fails in exactly the same
post-first-forwarding way. Therefore this is not restricted to objects that
have never moved.

### 2. Before-first-forwarding control

A semispace/packed world roots the rule object directly rather than through a
stable parent. After the same size change, collection returns
`:retained/:preflight-failed`, moved 0, forwarding false, **plan `:open`, stop
`:released`**. A subsequent ordinary fixed-kind allocation succeeds and
unbinding succeeds. This is a failed cycle without a held-stop world.

The generic observation helper prints `:UNEXPECTED-ALLOCATION` here because its
label assumes the post-forwarding case; it did not assert that assumption.
The actual state proves the publication boundary works differently before the
first forward. The original root was not cleared, and this failed world was not
forced through shutdown.

### 3. Caller-owned alignment-rule environment

Kind `:aligned` has size 32 and a function rule reading caller variable
`alignment`, initially 8. A rooted 16-byte prefix has a strong edge to it.
The caller changes `alignment` to 32 after publication.

Initially allocation requests with alignment 8 or 16 both succeed. After the
change both return `nil, :failed, :invalid-alignment`. The existing object's
stored alignment remains 8. In semispace the prefix moves first, placing the
next destination at a 16-byte but not 32-byte boundary; initialization under the
new rule fails. Both map forms report the same one-move retained
post-publication failure as case 1. Marksweep and unchanged controls complete.

This checks an admitted rule changing after binding; it is not an attempt to
allocate a newly admitted 32-aligned object into a 16-quantum plan.

### 4. Caller-created hosted variable rule: bound and geometry mutation

This is the private hosted rule extension already used by repository workload
setup and quality tests, not a portable representation mandated by the paper.
The caller constructs the record before passing it as `:size-rule` and retains
that input. The probe does not obtain a rule by reaching through bound-model
private fields. The record constructor/setters nevertheless are private,
which limits the public-interface claim.

Rule: header 16, element size 8, minimum 1, maximum 4, reference elements;
indexed strong layout begins at byte 16. A 48-byte object has four strong slots.

**Bound change:** setting the original input's maximum from 4 to 2 makes new
48-byte requests fail `:invalid-size`; 32-byte requests still succeed. The
existing object still maps four slots. When reached through a stable rooted
parent, both semispace forms fail after one forward. Marksweep and controls
complete and preserve the child in slot 3.

**Geometry change:** setting original input `element-bytes` from 8 to 16 leaves
48-byte requests admissible. Before collection, the old rooted array still
maps `(0 1 2 3)` and slot 3 reaches a managed child with ID 90. Both semispace
forms then report:

```
status :complete, reason :complete, moved 1, dead 2,
forwarding T, plan :open, stop :released
```

The moved root maps only `(0 1)`. The original child is explicitly present in
`map-cycle-deaths`, and reading slot 3 signals `Managed node has no slot 3`.
The second dead object is an intentionally unrooted admission-probe allocation.
The child's old strong edge was never removed by the caller. The unchanged
control moves both array and child, reports only the unrooted allocation dead,
retains four slots, and reads ID 90 from slot 3.

Marksweep retains four slots and the child in both cases. The semispace failure
comes from recomputing destination element count under mutated geometry, then
scanning that destination's smaller layout. It is a native silent-loss result
for the hosted extension, not inferred merely from pointer aliasing.

### 5. Accepted indexed identity-function environment

A caller-owned `:indexed` layout plist contains an identity function reading a
lexical delta. With delta 0, a two-slot object maps `(0 1)`. Changing only delta
to 100 makes the same published object map `(100 101)` immediately and after
collection. All four profiles complete and preserve its child ID 99. Controls
retain `(0 1)`.

This demonstrates unstable strong identities for an accepted hosted layout
rule. It does not demonstrate lost reachability or a failed location handle.
No private bound-layout setter is used in this case. The variable-size
constructor used to establish the indexed representation is a private hosted
extension, as in case 4.

### 6. Original caller layout and conditional input containers: no defect found

In all four profiles, the caller mutates its original strong-layout vector and
nested slot plist, weak identity plist, weak/ephemeron input list cells, and
caller-created ephemeron location-input record after binding. These are inputs,
not returned opaque descriptions. Actual mappings remain:

- strong identity `:strong-edge`, with the original child preserved;
- weak `(:weak-edge :weak-clear :weak-clear)`;
- ephemeron `(:pair T :key-clear :value-clear :key-clear :value-clear)`.

Collections complete, the child ID remains 30, and normal shutdown succeeds.
The hosted constructor copied/normalized these particular input values early.
This prevents the overclaim that every retained-looking construction input is
vulnerable.

### 7. Opaque originals and bound query outputs: characterization only

Read-only comparisons show original kind, weak, and ephemeron description
objects are `eq` to bound descriptions. `object-kind` and
`object-kind-descriptor` select the original kind object; returned nested query
tables are not isolated snapshots. **Identity equality alone is not a defect:**
sharing an actually immutable opaque value can be correct.

One expressly labeled `:NOT-PUBLIC-CONTRACT T` marksweep world modifies:

- original opaque kind's private size-rule slot;
- original opaque weak/ephemeron private cleared-value slots;
- a private strong-slot offset reached via a bound query result.

Allocation and callbacks change; the redirected scanner loses a child while
collection reports complete. This is useful alias characterization, **not a
legal public mutation counterexample**. The paper publishes neither these
setters nor a promise that bound `describe-*` calls return caller-owned mutable
tables. Its description methods are construction-only. The legal-input verdict
in cases 1 and 3 does not depend on this experiment.

## Source mechanism (supporting, not replacement, evidence)

`src/host/object-model.lisp`:

- `209-213`: function rule evaluation calls the function on demand.
- `228-265,294-334`: strong layouts and input vectors are normalized/copied.
- `336-363`: variable-rule validity/geometry is checked at kind construction,
  but the rule object and function rules are stored by reference.
- `369-378`: `describe-object-kind` returns those actual rule/table fields.
- `550-614`: binding makes a new kind vector, then `replace`s original kind
  objects into it. No isolated executable kind snapshot is created here.
- `936-941`: kind/descriptor queries select those retained records.
- `965-1024`: current rule state governs allocation size/alignment admission.
- `1057-1112`: initialization evaluates current rules again and writes a new
  per-object element count and alignment.
- `1343-1377`: the scanner uses that count and invokes the retained identity
  function for indexed identities.

`src/runtime/allocation.lisp:68-95` delegates size/alignment interpretation to
the model's private bridge. That ownership is correct; moving this knowledge
into the allocator would not fix snapshot semantics.

`src/runtime/spaces.lisp:225-299` initializes a semispace destination using its
kind before copy and forwarding. The work queue scans the destination
(`src/runtime/trace.lisp:256-280`). This explains both the retained rule-mismatch
failure and the smaller-destination-layout child loss.

No native instrumentation counted `describe-*` invocations. The absence of a
snapshot pass is source evidence; runtime changed semantics are the native
counterexamples. This review does not claim a separate measured call-count
failure.

## Minimal owner-correct design

Keep rule interpretation inside the hosted object model and its existing
`bind-object-model` handoff. No new public protocol is needed.

1. During binding, describe each admitted opaque kind/conditional description
   once and create configuration-private executable kind data. Snapshot every
   mutable hosted value the model understands: fixed slot data, conditional
   fields, variable-size parameters, indexed-layout parameters, and tables.
   Do not treat a new outer kind vector as the snapshot.
2. Resolve the currently accepted fixed size/alignment functions against the
   finite kind description during construction and store checked scalar
   results. Their present argument is the kind, not an individual allocation.
   For genuinely variable rules, store an immutable checked finite rule form.
   Reject forms whose meaning cannot be finitely bound; do not attempt arbitrary
   Lisp closure-environment copying or run them afresh in collection.
3. Bind indexed identity functions to finite validated identity data over the
   admitted element bound, or reject unsnapshotable forms. Enforce non-nil,
   unique, lifetime-stable tagged keys. Charge any added backing at construction.
4. Allocation precheck, initialization/copy, ordinary/staged mappers, and handles
   must all use the same bound executable snapshot. In particular, moving an
   object must not derive a different element count from mutable offered data.
5. Preserve opaque token ownership. Either existing bound descriptor queries
   return canonical tokens callers use for allocation, or explicitly accepted
   original tokens map by identity to the private snapshot. Do not reread mutable
   offered token fields to interpret a later allocation. No allocator-side
   knowledge of hosted struct layouts is needed.
6. Leave offered descriptions untouched. Construction-only query outputs may be
   copies or clearly model-owned read-only values; private setter misuse need
   not be supported. Re-run the legal caller-input cases separately from such
   misuse tests, including moving already-published objects and the first-
   forward publication boundary.

## Evidence limits

This is bounded hosted SBCL evidence. It does not prove Mezzano supervisor
admission, allocation-free callback execution, concurrent profiles, all staged
paths, all handle behavior, arbitrary custom models, or all possible rule forms.
It does not alter the existing allocation arithmetic/capacity repair verdicts
for stable descriptions. No managed-finalizer-callback claim is made.

The portability boundary matters: cases 1/3 use accepted function rules through
exported construction operations without opaque writes; case 4 uses a private
hosted input format; case 7 deliberately violates private representation
ownership. They must not be merged into an unqualified “all descriptors are
publicly mutable” claim.

## Reproduce

From any directory (the private registry assertion is in each bootstrap):

```
sbcl --noinform --disable-debugger --script /tmp/clamsara-description-review-7p14doks/independent-review/description-probes/bootstrap.lisp
sbcl --noinform --disable-debugger --script /tmp/clamsara-description-review-7p14doks/independent-review/description-probes/bootstrap-02.lisp
```

Run serially. The saved `native-01.log` and `native-02.log` are the original
outputs; do not overwrite them when reproducing.
