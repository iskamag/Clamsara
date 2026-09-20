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
