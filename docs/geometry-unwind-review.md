# Independent review: geometry repair with prepublication unwind fix

## Verdict

**The previously reproduced escaping-rule cleanup blocker is fixed in the
bounded native tests.** The original 35 independent geometry cases still pass.
All eight former binding leaks now assert actual release, and nine new late-hook
cases pass. No additional defect was found in this scoped geometry/unwind repair.

This does not establish full object-model admission. Indexed identity callback
snapshots, compound mutable names, arbitrary callback stability, and CAS remain
outside this verdict.

## Frozen source and runs

Snapshot: `/tmp/clamsara-geometry-unwind-review-hu77pd9y`, with seven recorded
overlays and 41 source hashes. All hashes matched before and after this review.
The previous report is preserved in `docs/geometry-snapshot-review.md`.

Only new files under `independent-review/unwind-independent/` were created.
No live source, dependency, fixture, or paper was changed. Three SBCL processes
ran serially after explicit native-slot admission. Each bootstrap prepends the
frozen source directory to the ASDF registry, asserts its exact system source
path, and puts new FASLs in this review directory.

| Native log | Asserted result |
|---|---|
| `native-geometry.log` | 35 geometry cases pass |
| `native-escape-release.log` | 8 formerly leaking binding escapes fully release |
| `native-late-unwind.log` | 8 late failure cases plus successful-publication control pass |

All three exit 0 and reach their final markers. Unlike the earlier leak
observation script, the escape replay now explicitly asserts released state and
preserved escape behavior. Sources, bootstraps, `execution.json`,
`integrity.json`, and artifact hashes are saved beside this report. The native
startup slot was explicitly released after the runs.

## 1. Exact geometry replay: no regression found

`geometry-cases.lisp` is byte-identical to the previous independent 35-case
source. It again checks:

- the same offered model and shared functions bound into two configurations at
  different values, before first allocation;
- continued second-binding collection after the first configuration shuts down;
- stable original opaque tokens, strict descriptor-alias rejection, and internal
  snapshot aliases;
- fixed/variable staging, conditional fields, handle publication/retirement,
  preserved real children, and no fixed-rule reevaluation;
- 28 malformed prebinding changes to caller-created hosted variable-rule inputs;
- independent original/snapshot catalogue manifest membership and actual
  resource/capacity-account charges.

The same limits apply: caller-owned lexical/input mutation is not opaque-output
mutation; the variable rule is a private hosted input format. Indexed staged
handles and arbitrary closure ownership are not proved by these cases.

## 2. The eight previous binding leaks now clean up

The same size/alignment rules throw their original `:escaped-size` or
`:escaped-alignment` markers. Both collector algorithms and both object-start
map forms were tested. Read-only observer methods save real acquisition and
binding state; they do not replace effects or convert the throw to an error.

Every case now asserts:

- the exact escape marker reaches the caller; the rule ran once;
- no world was returned and the bound-model publication flag is NIL;
- construction context is `:released`; configuration is `:failed`;
- all 11 semispace or 9 marksweep resources **and** host release capabilities
  are released;
- the installed layout is inactive and the address client no longer owns it.

These are the exact resources/layout that remained unreleased in the previous
snapshot. The script retains the released records for inspection (`kept=8`),
not leaked or force-closed worlds. It does not erase roots or call shutdown on
an aborted construction.

## 3. Postbinding hooks, error observers, cleanup faults, and guard

A small real marksweep-plan subclass depends on a new component that declares
an acquired resource and requires a bound model. Its initialization and
activation methods verify that they see a real bound hosted model in a still
private configuration. No test writes a publication state or private model
representation. No existing implementation method is replaced.

The test matrix is initialization/activation × throw/error × clean cleanup/
deliberate deactivation error: eight cases. A ninth case constructs and shuts
down successfully. Activation failure here is an intentional contract-fault
injection to test cleanup, not permission for production activation hooks to
escape.

### Ordinary non-error exit

A late hook throws three values: `:late-exit`, `73`, and the exact component
object. Both phases preserve all three values. The partially initialized or
fully initialized component is deactivated exactly once. All ten acquired
resources/capabilities and the real layout are released.

### Ordinary error exit

The hook signals a precreated error condition. An outside, non-unwinding
`handler-bind` observer verifies that cleanup has already completed. It receives
the exact original condition object; the outer `handler-case` receives that same
object. The callback's condition is not recreated or replaced on the clean
cleanup path.

### Cleanup-contract fault

The component's deactivation method signals a separate precreated error. The
builder continues cleanup and releases all ten resources plus layout. Only then
it reports `:cleanup-contract-fault`.

The cause retains the exact original error object for an error exit, or the
explicit `:non-local-exit` category for a throw. Its cleanup-fault list contains
the exact deliberate cleanup error. A cleanup-contract fault intentionally
supersedes the original transfer; the three throw values are asserted only when
cleanup succeeds. The non-unwinding observer sees released state for the cleanup
fault too.

### Order and no double unwind

Read-only lifecycle observers record deactivations, resource releases, and
layout release. For every case, the complete observed sequence equals:

1. reverse recorded initialization order;
2. the existing reverse-acquisition transaction log.

All transaction entries are marked released. This exact sequence check catches
missing, repeated, or reordered cleanup, including a second unwind after error
re-signaling. The custom component's deactivation count is also exactly one.

### Successful publication guard

The normal-return control remains `:published` with active layout, unreleased
resources, and zero deactivations immediately after construction. Thus the new
`unwind-protect` does not undo a successful build. Ordinary shutdown later
releases everything in the same exact sequence, once.

## Source assessment

In `src/construction/build.lisp:576-596`, `%prepublication-unwind` now performs
cleanup and only signals if cleanup itself has error faults. It no longer
unconditionally re-signals the original error.

At lines 647-722, `construct-plan` owns the `unwind-protect`. Its guard reads the
actual configuration publication state. The body catches/stores ordinary
errors; cleanup runs before the saved condition is re-signaled at line 721.
Non-error transfers unwind naturally through cleanup without being translated.
The cleanup form is outside the body's `handler-case`, so its own reported
cleanup-contract fault does not re-enter that same unwind handler.

This keeps rollback in the builder that owns the acquisition log and matches
the unchanged paper's `chapters/construction.tex:163-185,206-217`. It adds no
public protocol and does not move rule interpretation back into the allocator.

## Limits

This is bounded sequential hosted SBCL evidence. It does not prove target or
no-allocation execution, asynchronous process termination safety, arbitrary
custom clients, or every possible cleanup failure. Native cleanup-fault tests
cover an `error` from deactivation, not a release-provider fault or a cleanup
hook that itself violates its non-failing contract with another non-error
transfer. No forced shutdown was used to hide an abandoned-world failure.

The parent's larger component/benchmark gates are separate evidence, not runs
performed by this reviewer. Within the reviewed geometry and ordinary
prepublication-unwind scope, the earlier blocking finding is resolved.
