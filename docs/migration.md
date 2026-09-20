# Canonical rewrite status

The paper-v14 rewrite is the normal `src/` implementation and the `:clamsara`
ASDF system. The temporary `src/v14/` tree and versioned system/package names
are removed. Previous v8/v11 source, tests and benchmark drivers are deleted;
Git history preserves them. No legacy copy or archive is kept in the tree.
No legacy collector is a dependency of the new systems.

## Native commands

- `sbcl --noinform --non-interactive --eval '(require :asdf)' --eval '(asdf:load-system :clamsara)'`
- `sbcl --noinform --non-interactive --eval '(require :asdf)' --eval '(asdf:test-system :clamsara)'`
- Optional workload adapter: `(asdf:load-system :clamsara/workload)`.

## Evidence and limits at cutover

The complete staged core, host object-model and atomics compiled and loaded
through native SBCL ASDF before the move. This was not just source `LOAD`.
Compiler style warnings still identified incomplete model helper integration;
loading is not proof that a collection cycle succeeds.

Individual native checks passed for 77 client generic signatures, 46 builder
checks, metadata safety (8 groups), host safety (8 groups), barrier rules and
ordinary root-provider stores. Resource/layout checks passed the first seven
groups. The ownership-update group was still blocked on the object model.
These were pre-cutover results; canonical commands must be rerun after moving.

The model is being changed to dense charged storage with direct indexing and
one authoritative allocation map. Complete collection lifecycle, full manifests,
weak/ephemeron/finalizer behavior and full benchmark runs remain under test.
No full paper-v14 conformance or Mezzano supervisor admission is claimed.

## Benchmark fixtures

All 19 `bench/gabriel/reference/*.cl` files remain unchanged. The checked-in
`test/fixtures/boehm-gc.lisp` remains unchanged. Its SHA-256 is
`0a2af82bc5a1c0e2246d3d0709111c43a67577a51445b7ab2860abb346603153`.
The Boehm runner defaults to depth 18 and reports this file as the checked-in
Lisp translation, not an independently obtained upstream C/Java original.
Full workload acceptance is still outstanding.

## Post-cutover progress

Canonical protocol, construction, host and barrier ASDF tests passed in one
native process (`/tmp/clamsara-stable-contracts.log`); construction reported
72 checks. Canonical metadata safety separately passed. The first full
canonical load failed in the in-progress model rewrite, so full-system load
and execution must be rerun after its repair. Model implementation ownership
moved to the worker who authored the dense design; independent atomics/model
tests remain with the former implementation owner.

## Hosted checkpoint (2026-09-20)

The native main ASDF test operation now passes, including repeated SemiSpace
and MarkSweep collection, conditional/finalizer lifecycle, retained failures,
105 construction checks, and independent quality regressions. Those quality
checks include 100 stateful oracle-checked collections, structural defect
fixtures, frozen resource ownership, post-publication root reserves, and guest
word admission. Fourteen development-tool regressions also pass.

The 500,000-element array stress passed a real moving collection of two
4,000,016-byte objects. Final capacity-account physical/auxiliary bytes were
48,132,992/160,282,704. This is array evidence, not a full benchmark run.

The small managed workload smoke passes through clean shutdown. Its adapter
remains unfinished: full Gabriel/GCBench runs have not passed; REST, literal,
closure and foreign-call boundaries need complete residency/rooting evidence.
Numeric model slots now reject unsupported boxed numbers and host containers
before writes. That does not establish all guest representations or target
residency. Native reader quasiquote is installed per interpreter environment,
without replacing global engine functions.

The optional generational implementation has passed its standalone native
lifecycle/capacity probes. It remains separately selected and needs independent
profile review; stale address-token generations are not that evidence.
Mezzano supervisor admission, allocation freedom, concurrency and IRQ safety
remain unproved. `docs/spec-questions.md` separates questions from known bugs.

Development diagnostics: `tools/README.md`. Quality commands and limitations:
`docs/quality-structure.md`, `docs/quality-stateful.md`, and
`docs/quality-model-resources.md`.
