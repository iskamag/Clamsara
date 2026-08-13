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

(none yet this pass)
