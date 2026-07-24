# Strata: the unifying metadata primitive

Status: design draft (Clamsara rewrite). Supersedes the scattered metadata
mechanisms of paper-v7 (card table, mark bitmap, Immix line marks, object-start
bits, log/pin/age fields, `vm-page-dirty-p`). This is a **general framework
primitive**, not a Claimore-specific construct — Claimore is one consumer among
many.

## 1. Motivation

paper-v7 has at least seven independent metadata mechanisms, each with its own
class, storage, and access protocol:

| Mechanism            | What it is                              |
|----------------------|-----------------------------------------|
| Mark bitmap          | 1 bit / object-or-word                  |
| Card table           | 1 byte / card, points-to-younger        |
| Immix line marks     | 1 byte / 128 B line, toggling state     |
| Immix block marks    | liveness / recyclability per 32 KiB blk |
| Object-start bits     | 1 bit / word (sweep, card scan)         |
| Log / pin / age       | per-object side fields                   |
| Dirty pages          | 1 bit / page (HW or query)              |

These do not compose, are specified imperatively per plan, and force every new
collector to hand-roll its own scan loops. Yet **all of them are the same
shape**: a typed array of small cells indexed by a coarsening of the address
space, with a tiny set of bulk operations (set, test, clear, propagate, reduce).

MMTk recognized part of this with `SideMetadataSpec`. We take it further: make
the stratum the *single* metadata abstraction, and express barriers, mark
phases, sweep, remembered sets, dirty-page tracking, and compaction-offset
computation as operations over strata.

The payoff is not elegance for its own sake. It is: **write the bulk loops once,
SIMD them once, prove them once.** Per-plan code then *configures* strata rather
than *reimplementing* metadata. That is the change that stops the rewrite from
re-growing v7's per-plan bug surface.

## 2. Definition

A **stratum** is a dense, typed metadata layer over the heap address space:

```
stratum := (name, granularity, cell-type, default, storage)
```

- **granularity** `g`: the address-space quantum each cell covers, as a power of
  two in words. `g = 1` → per-word. `g = object` is *not* allowed (variable
  size); object-granular data is stored per-word at the object-start word and
  read via the object-start stratum. Standard granularities:
  `word (1)`, `line (16)`, `card (512)`, `block (4 Ki)`, `page (512)`,
  `metablock (128 Ki)`, `superblock (32 Mi)`. (Values illustrative; VM-defined.)
- **cell-type**: `bit`, `byte`, `u4` (nibble, e.g. age), `u8`, `u16`, or
  `ref` (a coarse address / index — for forwarding-like strata).
- **default**: the post-reset value (almost always 0).
- **storage**: how the cells are physically held (§6).

A cell is addressed by `cell-index(stratum, addr) = (addr - heap-base) >> log2(g)`.

The mark "bitmap", the card "table", and "dirty pages" are then literally the
same type at three granularities and one cell-type (`bit`).

### 2.1 Strata are one metadata *location* among several

A stratum is **side** metadata. It is not the only place GC metadata lives, and
the framework must treat the *location* as an orthogonal, MOP-branched choice
(see `axes.md`, axis 2). The four locations:

- **side** — strata (this document). Mark, card, line, log, age, public bit.
- **in-header** — STW forwarding, type tag, header flags. VM object-model owns it.
- **in-pointer (colored pointers)** — metadata in the *reference* bits
  (marked0/marked1/remapped/finalizable). Required by C4/ZGC. This is a
  reference-valued primitive, not a stratum; the VM object-model exposes
  `ref-color`, `ref-set-color`, `ref-good-color-p`, `ref-strip`.
- **off-heap table** — a hash/array keyed by from-address: concurrent
  forwarding tables (C4) and Claimore-v2 refcounts. Note: an off-heap forwarding
  table also makes **headerless-cons forwarding a non-issue** — no in-CAR
  forwarding marker is needed, because forwarding lives outside the object.

Per-object data (public bit, age, refcount, mark) is the subtle case: it is a
*side stratum at the VM's minimum-object-alignment granularity, addressed by the
object's start address* — exactly how MMTk stores per-object metadata. The VM
object-model decides the minimum alignment, which bounds the finest granularity
(see §10 Q1, resolved).

## 3. Operations

The whole point is that consumers use these and never touch raw storage.

Scalar (hot path, inlined, possibly under CAS — §8):

- `s-get (s addr) -> cell`
- `s-set (s addr v)` / `s-set-bit`, `s-clear-bit`, `s-test-bit`
- `s-cas (s addr old new) -> bool`

Bulk (the loops we write once and vectorize):

- `s-clear (s [range])` — reset to default. Bulk mark-clear, card-clear.
- `s-fold (s range f acc) -> acc` — reduce; `popcount` for live-byte
  accounting, occupancy, dead-ratio heuristics.
- `s-for-set-cells (s range fn)` — iterate set bits (sweep, card scan,
  dirty-page enumeration). SIMD: load word, `while bits: tz = ctz; fn; bits &=
  bits-1`.
- `s-project (src dst reduce)` — **coarsen**: fold each `dst`-cell from the
  `src`-cells it covers (`reduce ∈ {any, all, sum}`). E.g. page-dirty =
  `any` over its card cells; block-live = `any` over its line cells.
- `s-refine (src dst)` — the inverse hint (a set coarse cell marks its fine
  cells "suspect"); used to bound fine scans by coarse dirtiness.

Relational (§5): operations between a stratum and a *matrix* stratum.

## 4. Catalogue — existing mechanisms as strata

Every v7 mechanism is a stratum + a choice of operations. No new machinery:

| v7 mechanism      | stratum (gran, type)     | ops used                         |
|-------------------|--------------------------|----------------------------------|
| Mark bit          | (word, bit)              | set/test, `s-clear`, `s-for-set` |
| Object-start      | (word, bit)              | set, `s-for-set` (sweep walk)    |
| Card table        | (card, bit)              | set (barrier), `s-for-set` (scan)|
| Dirty pages       | (page, bit)              | `s-project` from card, `s-for-set`|
| Immix line marks  | (line, u8 toggling)      | set, `s-fold` (count), project   |
| Immix block live  | (block, bit)             | `s-project` from line (`any`)    |
| Log bit           | (word, bit)              | set/test/clear                   |
| Pin bit           | (word, bit)              | test                             |
| Age               | (word, u4)               | get/set (incf, saturate)         |
| Live-young bytes  | derived                  | `s-fold popcount` over mark∧log  |

Note line "toggling state" (v7's 1↔2 trick to avoid clears) becomes unnecessary:
`s-clear` on a bit/byte stratum is a `memset`/SIMD fill, which is what the toggle
was avoiding. Keep toggling only if a profile says the clear dominates.

## 5. Relations: remembered sets as a matrix stratum

A **matrix stratum** records a relation between regions at some granularity:
cell `M[i,j]` = "region `i` may hold a pointer into region `j`". This is the
generalization of remembered sets, and the home for the 1-bit bitmap-remset
idea (iskamag.com/posts/remsets).

```
matrix := (granularity g, relation, storage = g-count x g-count bits)
```

- **Write barrier** sets `M[block(src), block(dst)]` (relation = points-to) or,
  for the classic young-remset, just the column-collapsed vector
  `R[block(src)] |= points-to-younger`. The v7 card table is exactly the
  collapsed, card-granular, points-to-younger projection of this matrix.
- **Low-resolution live set** = transitive closure from root-blocks:
  `live |= M[i] for i in live` iterated to fixpoint (or a fixed pass count —
  the remsets post uses 5 OR-passes; bounded, SIMD-friendly, conservative). This
  "peels" reachability at block granularity *without a mark stack* — directly
  relevant to the tracer-overflow soundness hole in v7 (a stackless coarse pass
  can bound or replace the per-object queue).
- **Compaction offset table**: `s-fold popcount` prefix-sum over the live
  stratum yields per-block destination offsets in ~one pass.
- **Train / collection-order hints**: `s-fold` over columns of `M` ranks blocks
  by in-degree; choose what to collect.

Crucially this is the *same* abstraction as §2 with a 2-D index. The diagonal
must be zeroed (self-references are not cross-region edges) — a stratum-level
invariant, asserted once.

**Generality check:** card-table generational plans, SATB (a per-object log
stratum + a queue), and bitmap remsets all fall out as configurations of one
matrix/vector stratum. None needs a bespoke class. That is what makes this a
general-framework primitive rather than a Claimore feature.

## 6. Storage and the immortal-allocation constraint

The collector cannot call the Lisp allocator (paper-v7 philosophy ch.). All
strata are allocated **once at boot** from the immortal/page resource, sized from
heap size and granularity:

```
cells       = ceil(heap-words / g)
bytes       = ceil(cells * bits-per-cell / 8)
```

Two storage policies:

- **contiguous**: one flat array for the whole heap range. Simplest; correct for
  small/simulator heaps. Cost: `bits-per-cell / (8*g)` of heap. A (word,bit) mark
  stratum is 1/64 of the heap; a (card=512,bit) card stratum is 1/4096.
- **two-level / sparse**: a directory of chunk-tables, chunks faulted in lazily.
  Required for the "petabyte virtual heap" target where a contiguous (word,bit)
  stratum is itself petabyte-scale. MMTk's two-level side metadata is the model.
  Choose per-stratum: mark may be sparse, card may be contiguous.

The storage policy is a stratum field, invisible to consumers — `s-get`/`s-set`
dispatch on it at boot-compile time (one branch eliminated per the
compile-to-functions story).

## 7. Barrier integration

A barrier is then *configuration*, not a class hierarchy:

```
barrier := list of (stratum, when, transfer)
```

e.g. generational card barrier = `[(card-remset, on-ref-write,
set-if-old→young)]`; SATB = `[(log, on-ref-write, set), (satb-queue,
on-ref-write, enqueue-prev)]`; bitmap-remset = `[(points-to-matrix,
on-ref-write, set-bit M[block src, block dst])]`. The compiled barrier emits the
straight-line stratum ops; no `barrier-note-write` generic dispatch on the hot
path. Hardware dirty-page tracking is just a stratum whose storage is "the
MMU" — `s-for-set-cells` reads PTE dirty bits, `s-clear` clears them.

## 8. Concurrency

For concurrent collectors, stratum cells touched by both mutator and collector
need atomicity. Policy is per-stratum:

- bit-set via `fetch-or` on the containing word (`s-cas` loop or native atomic
  or); idempotent sets (mark, card-dirty) tolerate races without CAS if the only
  transition is 0→1 and lost updates are impossible (a set never disappears).
- multi-bit cells (age, line state) need real CAS or must be collector-private.

This is why §3 lists `s-cas`. The simulator implements it trivially; Mezzano
backs it with `%sys.int` CAS. Stating the atomicity policy *at the stratum
level* is what makes the eventual concurrent/Claimore plans expressible without
re-auditing every metadata touch.

## 9. Simulator vs Mezzano representation

- **Simulator**: each stratum is a host `simple-array` of the cell-type (bit →
  `bit-vector`, u4 → `(unsigned-byte 8)` array packed 2/byte, etc.). Bulk ops use
  `bit-and`/`bit-ior`/`count` and loops; "SIMD" is whatever SBCL gives.
- **Mezzano**: strata are raw immortal pages; bulk ops are open-coded over
  `memref-unsigned-byte-64` with the AVX2 kernels from the remsets work for the
  matrix closure. Same protocol, different `storage`.

The protocol (§3) is identical across both; only `storage` differs. This is the
seam that lets the simulator validate Claimore-class logic before the Mezzano
backend exists.

## 10. Open questions (resolved 2026-06-14 marked ✔)

1. ✔ **Object-granular data** → a **side stratum at the VM's
   minimum-object-alignment granularity, addressed by object-start address**
   (the MMTk way). The VM object-model declares the minimum alignment/object
   size, which bounds the finest granularity; the stratum declares its own
   `log_num_of_bits`. This fits all targets: Iso's per-object public bit, the
   mark bit, Claimore age/log, and an RC count are all such strata. (C4's
   liveness is *in-pointer*, a different location — §2.1.)
2. ✔ **Matrix storage** → not a concern. Claimore-v2 (unpublished) handles
   refcounts with a conventional table and treats superblock 0 as root; block
   and metablock metadata sizes are acceptable. Use conventional tables; no
   sparse-row machinery needed initially.
3. ✔ **Peel is NOT the primary marking mechanism.** Keep conventional
   work-queue tracing (required by the textbook plans, Iso, and C4). The v7
   overflow hole is closed by **spilling the work queue to immortal storage**,
   not by peeling. The peel/matrix closure stays an *optional* Claimore-only
   accelerator. (Demoted from "spine" to "one consumer".)
4. **Toggling vs clearing** for line/mark strata — keep only if profiled.
5. ✔ **Granularity** → per-stratum declared (powers of two), MMTk-style, **not**
   a fixed ladder. The VM supplies the hardware/object-model-tied minimums
   (object alignment, page size); the framework derives the rest. See chat
   answer to Q4 and `axes.md`.

Remaining genuinely open: #4; and the C4 in-pointer/remap mechanics, which live
in `axes.md` not here.
```
