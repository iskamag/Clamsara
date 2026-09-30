Clamsara (pre-alpha)

This is a composable framework for garbage collectors on Common Lisp. Similar to MMTK, but primarily targeting CL implementations.

The engine is there, and the four reference collection-plan roles of the
specification (`paper-v14`) are implemented: no-GC, the SemiSpace moving
baseline, the nonmoving MarkSweep and Immix mark-region plans, and the
generational composition. Optional profiles from the specification (Evha,
Claimore, checkpoint persistence, concurrent tracing) are not implemented.

There is a paper documenting the specification, but it's not yet public.

Load it via asdf

```sh
(asdf:load-system :clamsara)
(asdf:test-system :clamsara)
```

A benchmark harness over the checked-in Gabriel workloads compares the
collectors (`bench/gabriel/README.md`).

Hold your expectations low.
