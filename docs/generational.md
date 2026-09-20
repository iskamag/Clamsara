# Optional sequential generational profile

Select and test it explicitly:

```lisp
(require :asdf)
(asdf:test-system :clamsara/generational/test)
(asdf:test-system :clamsara/quality/generational/test)
```

## Collection policy and recovery

The implementation uses a copying nursery, a MarkSweep mature space, and a
conservative whole-mature-space remembered card. Surviving nursery objects
promote on their first **minor** collection. A **major** copies young survivors
within the nursery and traces/reclaims mature objects in the same cycle.
Mature survivors do not move. Heap generations are separate from stale
encoding/token checks.

The original implementation required promotion capacity even for a major.
A new independent test filled mature space, dropped its old object's last root,
and kept one young object live. Both minor and major returned
`:RETAINED/:PREPARING/:CAPACITY-EXHAUSTED`: the major could not reclaim the
mature garbage because it demanded free mature space first.

Majors now use the existing SemiSpace claim/copy/forwarding path for the nursery.
They do not need promotion reservations, but still check mature reclamation's
free-interval reserve before tracing. A major keeps the conservative mature
card dirty: corrected old slots can still point into the surviving nursery.
The next minor scans those edges and promotes their targets, then clears the
card once no young targets remain. No heap enlargement is used for recovery.
The obsolete promotion-destination plane was removed from storage and accounting.

## Native evidence

The original lifecycle/capacity suite remains selected separately. The new
`clamsara/quality/generational/test` runs real constructed hosted collectors,
not a host-only heap or simulated remembered set:

- Packed and scalar object-start maps.
- Full-mature capacity rejection, unchanged live references, explicit major
  recovery, successful later promotion, and completed fixture shutdown.
- Sole old-to-young edges through STORE and successful CAS; failed CAS does not
  write. Young leaves need no initializing stores that could accidentally dirty
  a card and hide a missing barrier.
- Root sharing, old-address stability, overwrite/deletion, unreachable old
  retention during minor, and mature reclamation during major.
- Major followed immediately by minor, with no intervening store, preserving
  an old-to-young edge left by the major.
- 32 weak combinations and 64 ephemeron combinations across both map profiles:
  holder/target/key/value generations, rooted/unrooted keys or targets, and
  minor/major scope. Unreachable mature values remain allocated during minor
  even when their conditional fields clear.
- Reverse-ordered mature ephemeron chains that require fixed-point work,
  correction/sharing of promoted keys and values, and later major reclamation.
- Independently written strong-graph histories from the fresh review: seeds
  731 and 15799, each on packed/scalar maps; 72 cycles per history, totaling
  **288 oracle-checked cycles: 216 minor and 72 major**, plus fixture cleanup.
  Geometry is Q=16, 256-byte nursery semispaces, 4096-byte mature space,
  32-byte nodes and eight roots. Mutations and every collection are compared
  with a separate host ID/edge oracle. Payloads, roots and edges stay managed.

See `test/quality/generational.lisp`, `generational-history.lisp`, and the
bounded independent review in `docs/review-ac22bdd.md`.

## Limits and known open defects

This is bounded sequential hosted evidence, **not complete profile admission**.
The profile shares the independently confirmed finalizer, copy-capacity
admission, allocation-validation and composed-CAS defects recorded in that
review. See `docs/review-repair-status.md` for subsequent fixes and remaining
open cases. The tests above do not repair or waive those common-core defects.

Explicit major recovery does not establish automatic recovery after every
minor reservation failure. In particular, a retained collection result must
not be blindly escalated. Broader failure, finalizer and callback-support
coverage remains necessary.

These tests do not establish concurrent writers, precise cards, sticky
generations, Immix, supervisor allocation freedom, or target residency.
The default `:clamsara` system does not load this implementation;
`:clamsara/generational` selects it.
