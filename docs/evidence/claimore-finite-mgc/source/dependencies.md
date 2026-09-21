# Actual MGC dependencies against core 1099d62

Source-only dependency map. The finite model does not supply these services.
Core references are from the immutable `1099d6235d7cc2730ce5066fb404daaca0bd75d9`
snapshot. No MGC/OVC/Claimore or incoming-index implementation was found in the
inspected `src/client`, `src/runtime`, `src/construction`, and `src/metadata`
Lisp files. Declaration or method presence alone is not capability proof.

| Requirement from Claimore | Existing pieces to reuse/review | Missing or blocked for actual MGC |
| --- | --- | --- |
| Nursery-only `:mgc` algorithm and bounded state | COLLECT keyword/owner-bound reports and algorithm rejection (`runtime/cycle.lisp:556–568`); construction resource/auxiliary accounting (`construction/protocol.lisp:66–99`); metadata and space protocols | No Claimore plan, nursery granule occupancy/relation/dirty/unknown/seeds/work storage or MGC closure/reclaim candidate. Bind real algorithm admission; do not rename precise tracing as MGC. Geometry, full Q-charged extents and relation-word/capacity costs must be manifested. |
| Complete strong incoming index | Client `make-reference-location-handle`, `call-with-reference-location`, staged handles, normalization/rebuild operations (`client/object-model.lisp:9–28`); movement participant protocol (`runtime/protocol.lisp:54–59`) | Generation/key-specific nontracing entry before every outside/mature nursery-target exposure; fresh protected resolution; missing/stale/saturated policy; exact per-source retirement/tombstones. Typed weak entries and guarded ephemeron pairs are also missing. Each mover/sweeper must repair/tombstone before retiring its source. A generic handle is not an index or coverage proof. |
| Publication and mutation summaries | Composed barrier reserve/admit/before/after/cancel phases and canonical object services (`runtime/barrier.lisp:43–79`, `client/object-model.lisp`) | MGC relation/index contribution, additions before exposure, deletion dirtying, complete protected rescan, unknown saturation without wrap, and full-extent structural edges at allocation/publication. Need equivalence histories for stores, bulk operations, publication, movement, and failed CAS. No direct host write or Maclina-specific root scan may substitute for the client contract. |
| Covering stop, roots, incoming writers | REQUEST/AWAIT/RELEASE-SAFEPOINT (`client/coordinator.lisp`); WITH-ROOT-SNAPSHOT (`client/roots.lisp:9`); cycle stop/cancellation path (`runtime/cycle.lisp:466–507`) | Coverage must include incoming publishers and conditionals, not just nursery mutators. `:all` widens writer/root coverage, not nursery liveness/reclaim domain. An actual index/writer admission contract and proof remain blocking. No narrower/concurrent claim follows from a host stop helper. |
| MGC weak/ephemeron/finalizer policy | Descriptor enumeration/raw operations; bounded finalizer registry and candidate/pending roots (`runtime/finalizers.lisp`); exact conditional stage/validate operations (`runtime/cycle.lisp:212–355`) | Complete registered nursery plus typed indexed-external conditional enumeration. Seed all in-nursery registered finalizer referents and ephemeron values conservatively; preserve existing candidate/pending/running roots; select NO new finalizers. Judge a referent/key dead only when its full allocation is dead; dead keys clear paired values even out of scope under the key-clear policy. Current helpers consult precise trace state and must not silently run its judgment for MGC. |
| Common preflight/cancel/closed commit | RECLAIM/CANCEL-RECLAIM/FINISH-SPACE and movement participant methods (`runtime/protocol.lisp:50–59`); common prepare/cancel/finish sequencing (`runtime/cycle.lisp:359–430`) | MGC candidate must include dead units, surviving occupancy/rows/holes, exact conditional changes and incoming tombstones. All participants prepare before a non-failing common commit; cancellation leaves prior bytes/state. Scope must exclude mature liveness/movement/reclaim. These existing mechanisms need a real coarse candidate and compatible no-new-finalizer policy, not a parallel ad-hoc commit. |
| Honest statistics and host/target admission | Owner-bound result records, known bits and bounded resource provisioning exist | Same-protected-snapshot precise oracle is required before reporting exact conservative-retained bytes; otherwise unknown, not zero. Relation maintenance, conditional inspection and reserved state need their own counters/costs. Client storage authority, callback lifetime/no-allocation, order/atomic and Mezzano validation remain separate blockers. |

## Two substitutions that would violate the requested algorithm

1. `runtime/cycle.lisp:499–535` currently enters precise trace context, drains
   strong work, computes ephemeron closure, retains/selects finalizers, stages
   conditionals, and commits. Running this path unchanged and calling its result
   MGC would not execute Claimore's required coarse decision and no-new-finalizer
   policy. Reuse common mechanisms only with the correct explicit MGC phases.
2. The generational plan has one whole-mature dirty card
   (`runtime/generational.lisp:24–27`) and snapshots mature starts
   (`334–343`). That is not the required per-location typed incoming index and
   does not authorize mature liveness work during Claimore nursery collection.
   A full mature scan is not a silent alternate incoming algorithm here.

The incoming index/publication/conditional coverage obligations are hard
runtime admission blockers, not performance options that the finite oracle can
waive. The finite object's adjacency vector is research input only. It must
never become a host-supplied second liveness algorithm for a runtime collector.
