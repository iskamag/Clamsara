# Independent review: bounded allocation-geometry snapshot repair

## Verdict

**The scoped geometry behavior passes the independent probes, but the patch
exposes a prepublication cleanup blocker.** A size/alignment rule that performs
an escaping `throw` now runs after resource acquisition. Its escape leaves the
construction's resources and installed layout unreleased. Normal `error`
rejection tests do not cover this path.

No additional scoped token, staging, shared-binding, or registered-storage
regression was found in the bounded tests below. This is not full object-model
admission. Indexed identity callbacks and compound mutable names remain open.
CAS is unchanged and was not reviewed here.

## Frozen inputs and native method

Current snapshot: `/tmp/clamsara-geometry-review-1qmpthsw`, base `9dd8629` plus
five hashed overlays. All 41 source hashes and all five overlay hashes matched
before and after investigation. The original review is preserved in
`docs/object-kind-snapshot-review.md`.

Only new files in `independent-review/geometry-independent/` were created.
No live source, fixture, dependency, or paper was changed. Three native SBCL
processes ran serially after the parent released its startup slot. Every
bootstrap prepends its frozen source directory to ASDF's central registry and
asserts `system-source-directory :clamsara` matches it. FASLs and logs are local
to this review directory.

- `native-01.log`: 35 independently composed cases passed; exit 0.
- `native-escape.log`: eight current-snapshot escape observations; exit 0.
  These are failure observations, not eight conformance passes.
- `native-escape-baseline.log`: eight old-snapshot timing controls; exit 0.
- Source: `cases.lisp`, `escape-cases.lisp`, and three bootstrap files.
- `execution.json`, `integrity.json`, `artifact-sha256.json`: run and hash data.

The old control uses the previously frozen `9dd8629` snapshot at
`/tmp/clamsara-description-review-7p14doks`, not changing live files.

## Blocking finding: escaping binding rule skips transaction cleanup

The probe installs a legitimate callable hosted size or alignment rule that
executes `(throw 'rule-exit :escaped-size)` or `:escaped-alignment`. The matching
`catch` surrounds construction. Read-only `:after` resource-acquisition and
`:before` binding observers save the real construction/layout objects. They do
not replace core operations, translate the escape into an error, or alter its
returned marker.

In all eight current cases—size/alignment × semispace/marksweep × packed/scalar:

| Observation | Actual |
|---|---|
| Caller receives | exact `:escaped-size` / `:escaped-alignment` |
| Rule calls | 1 |
| Construction context | `:building` |
| Configuration | `:private` |
| Bound-model publication flag | NIL |
| Resources acquired | 11 semispace; 9 marksweep |
| Resource states released | 0 |
| Host release capabilities released | 0 |
| Installed layout active | T |
| Address client still owns that layout | T |

The eight aborted constructions were retained for inspection. No cleanup was
forced and no roots were erased to manufacture teardown. No objects had yet
been allocated into these unpublished worlds.

### Attribution and obligation

`src/host/object-model.lisp:538-576` now evaluates fixed function rules while
building the private catalogue. The calls are at lines 554 and 560.
`construct-plan` installs the layout and acquires resources before binding.
`src/construction/build.lisp:598-712` guards the effectful region with
`handler-case` for `error` only. `throw` bypasses that handler. Its cleanup helper
at lines 576-596 is therefore never called.

The builder file is unchanged by this patch. The cleanup weakness is broader
and pre-existing; the patch newly exposes it to these function rules by moving
their execution into binding after acquisition.

The old-snapshot native control makes this timing distinction concrete. The
same constructors do **not** call either function during binding (`calls = 0`),
return a world normally, and ordinary empty-world shutdown reaches
`:released/:complete`, releases all 11 or 9 resources/capabilities, and leaves
the layout inactive/unowned. This does not claim old runtime invocation of an
escaping rule was safe. It only isolates the new construction timing.

Normative unchanged paper: `chapters/construction.tex:163-172` requires a
transaction log for acquisitions and layout release capabilities;
`177-185` places model binding after map initialization and requires ordinary
failed-build unwind; `206-217` requires cleanup for **any prepublication
failure**, including before the first initializer and later failures.

### Minimal owner-correct repair

Put transaction cleanup under a publication-guarded `unwind-protect` in the
builder's effectful region. Split cleanup from re-signaling: the current
`%prepublication-unwind` always ends with `error`, so calling it unchanged from
an unwind cleanup would replace an otherwise valid `throw`.

On every unsuccessful prepublication exit, deactivate recorded begun components
and release logged acquisitions/layout in reverse order. On successful cleanup,
allow the original nonlocal transfer to continue unchanged. Preserve the normal
error reasons and explicit cleanup-contract-fault handling without double
cleanup. Add native assertions for exact throw values and actual released
resource/layout state. Moving interpretation back into the allocator or
inventing a new public snapshot protocol is unnecessary.

## Independent geometry checks that passed

### 1. Shared functions, shared offered model, separate binding lifetimes — 4 cases

Each profile binds the **same** offered model twice. Two kinds share the same
size function and the same alignment function. First binding captures 32/8;
before any allocation the caller changes lexical values to 48/16 and constructs
the second binding. Afterward the caller changes both values to zero.

Results:

- Description creation invokes neither rule.
- Each binding invokes each function once per kind: counters 2/2 after binding
  one, 4/4 after binding two. No later allocation, collection, or shutdown adds
  calls.
- Binding one still allocates 32-byte objects; binding two allocates 48-byte
  objects. The opposite size rejects `:invalid-size`.
- Both configurations retain the original allocation tokens, but have distinct
  private snapshot vectors.
- Each real root graph has four reachable objects and preserves child IDs
  101/102 through collection.
- After normal shutdown of binding one, binding two still collects all four
  objects with size 48/alignment 16 and intact children.

This tests pre-first-allocation capture and shared-offer lifetime directly,
not only mutation after a first allocation.

### 2. Descriptor aliases — 1 case with 7 rejected and 2 accepted forms

Against `:alias`, both allocation and direct initialization reject: the name
symbol, another kind's name, NIL, a copied opaque record, a foreign same-name
record, a weak-description record, and another local kind's token. Allocation
returns `:failed/:invalid-kind`; direct initialization signals. Sizes,
descriptor generations, and live-count remain unchanged across each rejection.
The actual rooted control object survives collection.

Direct initialization accepts the original token and its explicit private
snapshot alias; each test destination is unexposed and then retired normally.
`object-kind` for a published object returns the original token. The private
alias check is implementation characterization, not a new public API promise.
This exercises the snapshot's strict descriptor EQ guard.

### 3. Staging, conditional fields, and handle publication — 2 cases

Packed and scalar semispace worlds bind a fixed callable-rule kind and an
indexed variable-size kind. Before the first object allocation, the caller
changes fixed size 32→48, alignment 8→32, and the caller-created hosted variable
rule's element size 8→16. The bound objects still use 32/8 and four array slots.

For each kind, the real model stages its representation and installs it into an
unpublished reserve-space destination initialized with the original token.
Checks cover:

- used byte count, original opaque token identity, and strong mapper identities;
- preserved real child references and weak/ephemeron cleared fields;
- fixed strong, weak, ephemeron-key, and ephemeron-value staged handles:
  stale before publication, present after install/map publication, stale after
  temporary destination retirement;
- subsequent real collection of the unchanged rooted sources and both children
  (IDs 301/302), with no function reevaluation.

Only the successful temporary model-test destinations are manually published
and retired. Real roots are not rewritten to hide a failed world. This exercises
the existing model staging facility, not a complete OVC movement participant.
Indexed staged handles were not tested.

This fixture's changed alignment is not the original review's failing
prefix-placement geometry. It verifies frozen geometry through staging and
collection; it does not reproduce that former alignment failure layout.

### 4. Prebinding mutation of caller-owned hosted rule inputs — 28 cases

After creating a valid indexed description but before binding, the caller
changes its original variable-rule input to one of seven invalid states:
header -1, header 24, element size 0, element size 16, minimum -1, maximum 0,
or numeric elements with the reference indexed layout.

All four profiles reject with `:bind-object-model-signaled`. This confirms
binding revalidates copied variable geometry rather than preserving invalid
prebinding changes silently. These cases assert rejection, not detailed unwind;
the distinct escaping-rule cases inspect actual unwind state.

### 5. Explicit storage and capacity checks within the above cases

An independent membership walk—not the patch's visitor—checks original and
snapshot kind vectors, rules/functions, normalized layouts/slots, conditional
records/tables, and every description-lookup key/value against closed resource
manifests. Required unique objects: 40 in each shared-model world and 45 in each
staging world. The description hash contains 6 and 10 aliases respectively and
does not grow during tested runtime operations.

No duplicate registered object was found. Primitive physical/auxiliary charges,
including the hash-table backing through the host's size operation, match the
resource states and immutable capacity-account entries. These checks do not
prove ownership of arbitrary closure environments or untested external leaves.

## Scope and limits

The snapshot mechanism and exact-token lookup stay model-owned. The allocator
is not taught private hosted rule layouts. Fixed functions are resolved to
scalar geometry; variable geometry is copied. The tests confirm those scoped
properties and do not assert arbitrary callable stability.

Caller lexical mutation and mutation of the caller-created private hosted
variable-rule input are distinguished from opaque-output mutation. No test
writes a private returned kind/conditional record or bound query table to claim
a public defect. The variable-rule constructor/setters remain a hosted-private
extension, not a portable format mandated by the paper.

Indexed identity callback environments, compound mutable names, full descriptor
admission, arbitrary custom models, target/no-allocation execution, concurrent
profiles, and CAS remain outside this repair verdict. No parent integrated or
500k stress run is presented as independent evidence; those are parent results.

**Recommendation:** retain the geometry design, but fix and retest escaping
prepublication cleanup before claiming this bounded repair safe to integrate.
