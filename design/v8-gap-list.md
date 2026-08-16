# Paper-v8 fidelity gap list (working)

Source of truth: `paper-v8/chapters/*.tex` and `newgc.txt`. This file is a
status ledger, updated in place; the git log is the changelog.

## Open gaps

- **G9 — Compilation boundary (compilation.tex §3).** Inner VM/space protocol
  calls still dispatch through CLOS; no structural completeness test exists.
- **G10 — Concurrency (vm-capabilities.tex §6, plans.tex).** Single-threaded
  phase simulation only; no mutator contexts, scheduler/work packets, or
  adversarial interleaving. ZGC/Claimore concurrent phases run STW.

## Closed

- **G1** — Claimore hierarchy: superblock RC + metablock/block matrices +
  escape bits + staged reclaim (RC release -> search -> sweep -> compaction),
  block-granular hierarchical allocator, `:hierarchical` policy.
- **G2** — Precise scanning: per-type slot maps (type tag + header spare
  layout id), all scan/heal/remset sites route through them.
- **G3** — LOS space in every plan layout; oversize allocations bypass
  nurseries; reclaims clear the shared mark stratum by range.
- **G4** — Published-roots set (edge-granular, append-only, double-drained),
  real trap-B stand-ins, lazy strategy records guarded edges.
- **G5** — Weak references (slot-0 exclusion, weak phase between mark and
  reclaim) + finalization (known/pending, dead move in phase-weak).
- **G6** — Persistent allocator, dirty-set capture (MMU or card projection),
  CoW marking, checksummed delta segments, recovery truncation semantics.
- **G7** — Space/plan validation: requires-tier, partner, allocator
  coherence, moving/mixed-age, declared barrier names, scope->publication.
- **G8** — Sanity: RC in-degree verification + forwarding-drain check.

## Soundness fixes (2026-08-16)

- W1: weak-pointer bit preserved across copies; weak referent excluded from
  tracing after relocation.
- W2: LOS edges healed by Immix defrag, ZGC relocation, and superblock
  compaction (`heal-every-space`).
- W3: generational card barrier/scan/rebuild cover LOS->nursery edges.
- W4: finalizer deadness snapshotted in the weak phase, moved to pending in
  the epilogue (weak.tex §2).

## Phase machine

The ordered phase machine is the real `gc-phase` long-form method combination
(plans.tex §3). The boot assembler resolves the same most-specific phase
methods through `compute-applicable-methods` + `method-function`, so compiled
and interpreted collectors cannot diverge. Structural tests cover combination
order and compiled/interpreted agreement.

## Reviewer rounds (this pass)

- R1: 13 complaints (trap-A dangling, persistence no-ops, finalizer partial
  cycles, hierarchy dead code, medium-object hole, DLG-r sanity) — fixed in
  d5ba588.
- R2: 12 complaints (span corruption, image-based checksums, compaction dest
  heal, trap-B idempotency, cyclic dedup, sweep bound, :checkpoint ecase) —
  fixed in b48d8a4 and 3e01f5b.
- R3: 9 complaints — fixed in 3e01f5b and verified in-session (the round-4
  subagent hit its turn limit with no report; the assistant ran the repros
  directly: span exclusivity, trap-B same-copy, self-cycle single-copy,
  :checkpoint admission, sweep frees dead blocks in reached MBs, exhaustion
  control flow).
