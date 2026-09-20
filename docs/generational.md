# Optional sequential generational profile

Select and test it explicitly:

```lisp
(require :asdf)
(asdf:test-system :clamsara/generational/test)
```

The implementation uses a copying nursery, a MarkSweep mature space, and a
conservative whole-mature-space remembered card. Surviving nursery objects
promote on their first minor collection. Major collection includes mature
reclamation. Heap generations are separate from stale encoding/token checks.

The initial native matrix passes, including promotion, old-address stability,
old-to-young retention/correction, mature conditional sources, major
reclamation, and pre-effect promotion-capacity rejection. The capacity test
is a separate runner invoked by the same ASDF test operation.

This is an optional implementation checkpoint, not complete profile admission.
Independent expanded/adversarial review remains open. It does not establish
concurrent writers, precise cards, sticky generations, Immix, supervisor
allocation freedom, or target residency. The default `:clamsara` system does
not load this implementation; `:clamsara/generational` selects it.
