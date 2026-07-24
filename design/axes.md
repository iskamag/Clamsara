# Collector design axes

Status: design draft (Clamsara rewrite). The framework is **general and
extensible**: a collector is a *point in a space of orthogonal axes*, not a
bespoke class. Primitives live on each axis; concrete collectors select and
branch them (via the MOP). This document fixes the axes by checking them against
the full target set:

- the nine textbook plans (SemiSpace, MarkSweep, Immix, GenCopy/MS/Immix,
  Sticky×2, NoGC),
- **Iso** — request-private, mark-region, opportunistic copying, publication
  write barrier (Qiu & Blackburn, PLDI 2025),
- **C4 / ZGC** — concurrent compacting, colored pointers, load barrier,
  off-heap forwarding, VM remapping,
- **Claimore** — thread-local nursery + non-moving concurrent RC mature,
  superblock-structured, persistence-first.

A collector that the axes cannot express is a gap in the framework.

## The axes

### Axis 1 — Heap structure (space kind)
What a region of memory looks like and how allocation packs it.

| kind          | allocator     | used by                          |
|---------------|---------------|----------------------------------|
| contiguous    | bump          | SemiSpace, copying nurseries     |
| mark-region   | Immix bump+   | Immix, GenImmix, Sticky, **Iso**, ZGC-ish |
| free-list     | segregated    | MarkSweep, GenMS                 |
| large-object  | page/treadmill| all                              |
| immortal      | monotone bump | GC bookkeeping (all)             |
| cons          | 2-word bump   | Mezzano headerless cons (address-ranged) |
| superblock    | hierarchical  | **Claimore** (block/metablock/superblock) |

Mark-region is **load-bearing**, not one-of-nine: it is the substrate for
opportunistic copying, which Iso and Claimore both need. NoGC = contiguous with
no collect method.

### Axis 2 — Metadata location (MOP-branched)
Where a piece of GC metadata physically lives. See `strata.md` §2.1.

| location        | examples                          | primitive surface          |
|-----------------|-----------------------------------|----------------------------|
| side (stratum)  | mark, card, line, log, age, public| `s-get/set/cas/fold/...`   |
| in-header       | type tag, STW forwarding          | VM object-model            |
| in-pointer      | C4/ZGC color bits                 | `ref-color/-set/-good-p/-strip` |
| off-heap table  | concurrent forwarding, RC counts  | `tbl-get/put` keyed by addr|

Each metadatum *declares* its location; the compiler emits the right access. A
plan can put forwarding in-header (STW) or off-heap (concurrent) **without
changing the marking code** — that is the extensibility test.

### Axis 3 — Reclamation policy (per space)
How a space decides what is dead.

- **trace** (mark): all textbook plans, Iso, C4.
- **reference-count**: Claimore-v2 mature (conventional refcount table,
  superblock 0 = root). Needs the field-log / RC-increment-decrement write
  barrier; pairs with a backup trace for cycles (LXR-style).
- **sticky / generational discrimination**: a *modifier* on trace (log bit
  splits young/old), not a separate policy.

This axis is where v7 was weakest — it assumed tracing everywhere. RC must be a
first-class policy a space can choose.

### Axis 4 — Moving model (per space, per cycle)
Whether and how objects relocate.

- **non-moving**: MarkSweep, Claimore mature, ZGC marking phase.
- **STW copy**: SemiSpace (Cheney), copying nursery.
- **opportunistic copy / defrag**: Immix, **Iso** — move when convenient,
  leave in place otherwise (the key to cheap thread-local moving).
- **concurrent relocate**: C4/ZGC — forwarding table (off-heap) + load barrier
  (self-healing) + VM remap. Mutators run during relocation.

The moving model selects which barriers (axis 5) and forwarding location
(axis 2) are required. They are not independent in *configuration*, but they are
independent *primitives* — which is what lets new combinations exist.

### Axis 5 — Barrier set (composable list)
Each barrier is `(metadatum, trigger, transfer)` (see `strata.md` §7). A plan
declares a *list*; the compiler fuses them into one inlined sequence.

Write barriers:
- **none** — SemiSpace, MarkSweep, Immix, NoGC.
- **card / points-to-younger** — generational plans, Claimore nursery remset.
- **SATB** (pre-write log) — concurrent marking.
- **field-log / RC** (Δ-buffer) — reference counting.
- **publication** (`src public ∧ dst private → publish closure`) — **Iso**,
  and Claimore's "promote-on-share."

Read/load barriers:
- **none** — most plans (Iso *deliberately* avoids read barriers).
- **LVB / self-healing** — C4/ZGC: on load, test pointer color; if stale, heal
  (consult forwarding table, update the slot, return good ref).

### Axis 6 — Heap ownership / scope
Who may collect a region and who may touch it.

- **global** — textbook plans, C4, Claimore mature.
- **thread-local / request-private** — **Iso**, Claimore nursery. Requires a
  *publication invariant* (DLG: public ⇏ private) maintained by the publication
  write barrier (axis 5), so a private region collects without a global pause.

This axis is entirely absent from v7 and is the core of both Iso and Claimore's
thread-local-pause goal. It must exist from the start, even if the first
implementations are global-only.

### Axis 7 — Concurrency / pause model
- **STW** — textbook plans, Iso local collections (between requests).
- **concurrent-mark** — SATB-based.
- **concurrent-relocate** — C4/ZGC (load barrier + remap).
- safepoint model is a VM concern; the framework declares where polls/barriers
  are needed (`vm.tex` compiler interface) and the plan declares which it uses.

## Target collectors as points in the space

| collector  | 1 structure | 3 policy | 4 moving        | 5 write bar | 5 read bar | 6 scope | 7 conc |
|------------|-------------|----------|-----------------|-------------|------------|---------|--------|
| SemiSpace  | contiguous  | trace    | STW copy        | none        | none       | global  | STW    |
| MarkSweep  | free-list   | trace    | non-moving      | none        | none       | global  | STW    |
| Immix      | mark-region | trace    | opportunistic   | none        | none       | global  | STW    |
| GenImmix   | mark-region | trace+gen| oppo (nursery+) | card        | none       | global  | STW    |
| **Iso**    | mark-region | trace    | opportunistic   | publication | none       | private | STW-local |
| **C4/ZGC** | mark-region | trace    | concurrent-reloc| SATB        | LVB        | global  | concurrent |
| **Claimore**| superblock | nursery:trace, mature:RC | nursery:oppo, mature:non-moving | publication + RC | none (page-fault remap optional) | private nursery + global mature | concurrent mature |

Reading across a row defines the collector; every cell is an independent
primitive choice. **The framework is "done" when each column is a real,
swappable primitive and the rows above are just configurations.** That is the
concrete, testable meaning of "general and extensible" for this project.

## Consequences for the spec

1. **Read/load barriers are first-class**, not a VM-only afterthought (v7
   demoted them). C4 is impossible otherwise.
2. **Reference counting is a first-class policy** (axis 3). v7 assumed tracing.
3. **In-pointer (colored) metadata and off-heap forwarding tables** are required
   metadata locations (axis 2). v7 had only side + in-header.
4. **Thread-local / request-private scope with a publication barrier** (axes 5,6)
   must exist from the start — it is shared by Iso and Claimore and is the whole
   point of the thread-local-pause goal.
5. The nine textbook plans are the **degenerate corner** (global, STW, no read
   barrier, trace) — perfect regression baselines, but they must not shape the
   abstractions, or Iso/C4/Claimore won't fit.

## Open
- C4 in-pointer/remap mechanics on a runtime without hardware colored-pointer
  support (Mezzano): software LVB cost, multi-mapping vs. forwarding-table-only.
- RC cycle collection: backup trace (LXR) vs. trial deletion — pick per spec.
- How `superblock` structure (axis 1) and side strata (`strata.md`) interact for
  Claimore's hierarchical remembered relationships.
