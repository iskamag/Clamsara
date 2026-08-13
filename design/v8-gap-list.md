# Paper-v8 fidelity gap list (working)

Source of truth: `paper-v8/chapters/*.tex` and `newgc.txt`. This file is a
status ledger, updated in place; the git log is the changelog.

## Open gaps

- **G1 — Claimore hierarchy (heap.tex §6, strata.tex §5.1, newgc.txt §3/§7).**
  Only per-superblock RC exists. Missing: per-SB metablock points-to matrices
  (256x256), per-MB block points-to matrices, block escape bits
  (from-foreign-sb / to-foreign-sb / pointed-to-by-older), the staged reclaim
  (RC release -> search closure over reached MBs/blocks -> precise trace ->
  rare block compaction via off-heap forwarding), and block-level reuse in the
  hierarchical allocator. Mature space currently declares `:policy :refcount`;
  the spec's superblock-space policy is `:hierarchical`. Region sizes must be
  VM-declared so the simulator can exercise the hierarchy at small scale.

- **G2 — Precise scanning (memory.tex §3, vm-capabilities.tex §6.2).** Core
  scanning treats every payload slot as a potential reference. The VM protocol
  requires per-type layouts/pointer maps (`vm-scan-object-references` decides
  which slots are references). Slot maps per type tag; all scan/heal/barrier
  paths must delegate to them.

- **G3 — LOS space absent from plan layouts (axes.tex §2.1, heap.tex §2).**
  `los-space`/`los-allocator` exist but no plan constructs a LOS region;
  plan-level `plan-allocate` overrides route every size to the nursery.

- **G4 — Read-guarded DLG (locality.tex §1-2, vm-capabilities.tex §6.5).**
  No published-roots set, no double drain, no reclaim re-check. Trap Variant B
  is a stub that just sets the public bit. `private-immix-space` exists but is
  unused (Iso and Claimore nurseries are plain immix spaces).

- **G5 — Weak references + finalization (weak.tex).** Entirely missing.

- **G6 — Persistence (persistence.tex).** Checkpoint is a stats bump. Missing:
  persistent allocator, dirty-set capture, segment log + checksums, CoW via the
  software MMU, recovery, gc-event wiring.

- **G7 — Metaclass validation (heap.tex §7, barriers.tex §6, plans.tex §1).**
  Missing: `requires-tier`, copying-space partner check, allocator/policy
  coherence, scope->publication, moving->mixed-age, active-set/concurrency
  rejection, RC rule admitting `:hierarchical` policies, trap-rule validation.

- **G8 — Sanity checker (testing.tex §1).** Missing: RC in-degree verification,
  forwarding-drain check, DLG-r verification for read-guarded strategies.

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

## Open

- **G9 — Compilation boundary (compilation.tex §3).** Inner VM/space protocol
  calls still dispatch through CLOS; no structural completeness test exists.
- **G10 — Concurrency (vm-capabilities.tex §6, plans.tex).** Single-threaded
  phase simulation only; no mutator contexts, scheduler/work packets, or
  adversarial interleaving. ZGC/Claimore concurrent phases run STW.

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
