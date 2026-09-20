# Stateful collector quality regressions

This note records the executable evidence in `test/quality/stateful.lisp`.
It does not claim target, concurrent, workload, performance, or generational
collector coverage.

## Reproduction

Run from the repository root with normal SBCL startup so the project ASDF
source registry is active:

```sh
sbcl --noinform --non-interactive \
  --eval '(require :asdf)' \
  --eval '(asdf:load-system :clamsara)' \
  --eval '(load "test/quality/support.lisp")' \
  --eval '(load "test/quality/stateful.lisp")' \
  --eval '(clamsara.quality.stateful:run-stateful-quality-tests)'
```

Deterministic profile:

- seed: `#x14C1A05E`
- stateful mutation iterations per profile: 18
- profiles: SemiSpace/MarkSweep crossed with packed/scalar object-start maps
- oracle-checked stateful collections: 100 total (25 per profile)
- stateful extent: 2048 bytes per algorithm space
- stateful roots: 8
- stateful trace and conditional capacity: 128 each

Final native result on 2026-09-20:

```text
QUALITY-STATEFUL-PASS seed=#x14C1A05E iterations=18 profiles=4
```

Exit status was 0. No unexpected failure occurred in that run.

The files also passed the repository's native diagnostic compiler wrapper:

```lisp
(clamsara.debug:compile-source "test/quality/support.lisp"
                               :output-file "/tmp/clamsara-quality-support.fasl")
(clamsara.debug:compile-source "test/quality/stateful.lisp"
                               :output-file "/tmp/clamsara-quality-stateful.fasl")
```

Both reports had `:status :ok`, native `:warnings-p nil`, and
`:failure-p nil`. The support report recorded only the expected macro
redefinition condition because the source had already been loaded before it
was compiled.

## What is checked

`test/quality/support.lisp` builds real configurations with
`construct-plan`, binds real mutator contexts, and uses the configured root,
barrier, allocation, object-model, metadata, and collection APIs. It installs
no protocol fallback methods.

Each test node is an actual managed 32-byte object. Slot zero holds a managed
immediate logical ID. Slots one and two hold the tested managed edges. A
host-side table computes reachability, but it never replaces the managed
payload, roots, or edges. Snapshot traversal reads the real roots and fields.
It checks duplicate logical IDs with `reference-equal`, so a copied duplicate
cannot masquerade as preserved sharing.

The four main profiles perform the same deterministic operations and compare
the whole logical trace:

- shared nodes and two initial cycles;
- an unreachable cycle and isolated object on the first collection;
- repeated edge mutation through `barrier-store`;
- root replacement, including removal and later replacement;
- one new allocation per iteration;
- repeated collections without intervening mutation every third iteration;
- reclamation of objects that become unreachable only after prior mutations;
- allocation after reclamation;
- normalization of every old encoding after each collection.

For SemiSpace, every pre-cycle object encoding must become stale after a
successful move. For MarkSweep, reachable encodings must still normalize and
unreachable encodings must become stale. `valid-reference-p` is not used as a
liveness oracle.

The additional bounded regressions check:

| Case | Required observed result |
| --- | --- |
| Invalid allocation admission | size zero returns `nil, :failed, :invalid-size`; later real allocations succeed |
| Collection admission | unsupported scope, cause, algorithm, and foreign record signal their exact stable reasons; each caller record remains `:uninitialized` |
| Result reuse | one caller record completes two non-overlapping collections |
| Full raw-space reservation | eight live objects fill a 256-byte space; the next allocation returns `nil, :failed, :heap-exhausted` without losing the graph |
| Reuse after reclaim | removing the sole root and collecting makes all eight current encodings stale; a later allocation succeeds and normalizes |
| Safe retained continuation | injected partial Await failure returns `:retained/:coverage-failed`; cancellation wakes the joined participant once; allocation and a later complete collection work after the injected fault is removed |
| Stop reservation exhaustion | the second entry against a one-token coordinator signals `:preflight-failed`; its result remains uninitialized; later root-barrier mutation works and the object-free fixture shuts down |
| Finalizer action ownership | three callbacks run once, including callbacks after one deliberate callback error; a second drain returns zero; later collection does not repeat callbacks |

The injected invalid operations, Await failure, capacity failures, and one
callback error are expected test inputs. They are not unexpected suite
failures.

## Separate generation-correctness matrix: blocked, not run

The stale-reference checks above exercise hosted representation generations
and stale address encodings. They are **not** generational garbage-collection
evidence.

The current canonical runtime provides SemiSpace and MarkSweep plans, and the
sequential plan currently admits only scope `:all`. It does not expose a
nursery/mature plan, minor/major scopes, promotion result, or a remembered-set
inspection contract that this quality test can drive. Therefore the following
matrix is reserved but was not executed and is not reported as skipped-pass or
covered:

| Future generational case | Required assertion |
| --- | --- |
| Remembered old-to-young edge | an old object's sole strong edge retains the young target through a minor collection |
| Unreachable old during minor | a minor collection does not reclaim an unreachable old object |
| Promotion identity and root correction | a promoted object preserves logical identity and every root/edge is corrected to its admitted new representation |
| Overwrite insertion/deletion | installing old-to-young records the edge; overwriting it removes or safely conservatively retains only the permitted remembered state |
| Major reclamation | a major collection reclaims unreachable old objects and their old encodings fail normalization |
| Generational weak/ephemeron closure | old/young key, value, and weak-target combinations follow the common conditional fixed point without a missing incoming edge or strong fallback |

These cases must become executable when a real generational construction and
runtime API exists. A host-only payload model or a simulated remembered set is
not an acceptable substitute.

## Evidence limits

This suite is sequential hosted evidence. It does not exercise Mezzano IRQ
execution, concurrent barriers, compiler stack maps, checkpoint/image
protocols, or `:clamsara/workload`. The diagnostic tools allocate and are not
no-allocation or performance evidence.
