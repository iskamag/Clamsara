# Finite Claimore MGC model — source draft

**Unexecuted.** This directory is outside live `src/` and `test/`. It loads no
Clamsara system or dependency. No native Lisp, ASDF, fixture, production, paper,
or dependency edit/run occurred during this task.

Authority: the actual `paper-v14/chapters/claimore.tex`, especially lines 48–129
(nursery, closure, spans, unknowns, example, negative controls) and 261–277
(conformance gates). Read `dependencies.md` before proposing a runtime MGC.

## Later command, only after native authorization

```text
sbcl --noinform --non-interactive --load /tmp/clamsara-list-baseline-1099d62-xzks71ws/independent-review/claimore-mgc-model/run.lisp
```

`run.lisp` loads `model.lisp` and `tests.lisp`. Failed assertions remain errors;
there is no expected-red success exit. Successful execution would print one
bounded report with both required counterexamples. No execution result exists
yet. Python parenthesis/count checks are not native Lisp read/compile authority.

## Two independent decisions

- MGC reads only complete seeds and a granule relation to its fixed point.
  Strong edges use canonical object-start granules. Separate permanent
  structural rows join every spanning allocation's start to each touched
  granule **in both directions**. Occupancy includes the full Q-rounded charge.
- The oracle uses a bounded object-identity BFS over the concrete pointer graph.
  It never reads the granule relation, dirty/unknown flags, or span edges.
  It constructs every reachable allocation's charged extent unit by unit.
- Safety requires no oracle-live unit be reclaimed. A second property requires
  **every** allocation intersecting retained units to be wholly retained, even
  if the allocation itself is unreachable but shares a retained granule.
  Checking only live starts would miss both failures.

The nursery base is 0 and Q-aligned. Geometry is bounded to 16 units/granules
and 4 objects. Enumerated fixtures use at most 3 objects. Nonoverlapping layouts
can have gaps. An out-of-scope target bit has no M column; neither decision
traverses mature storage.

Unknown/saturated rows reach every granule when visited, but do not seed
unvisited rows. Unknown incoming coverage in this model has whole-nursery
scope and therefore retains all granules. This is an explicit conservative
policy, not evidence of a real incoming index's coverage.

Deletion removes the actual pointer but keeps old relation bits and dirties
the canonical source row. Only a protected complete row rebuild removes stale
strong edges; structural edges remain. Partial/unprotected rebuilds reject
before changing facts. The model does not implement reclamation/publication.

## Planned coverage, not observed results

Two full finite domains: `(H,G,Q)=(3,1,1)` and `(4,2,1)`. For each, enumerate all
ordered disjoint positive allocation extents (0–3 objects), all directed strong
graphs including self-edges, every local-root and incoming subset independently,
and every unknown-row subset. Expected combinatorial counts:

| Geometry | Layouts | Graphs | Coarse decisions | One-edge deletion histories |
| --- | ---: | ---: | ---: | ---: |
| 3,1,1 | 13 | 605 | 272776 | 150040 |
| 4,2,1 | 33 | 3845 | 933188 | 1039912 |
| Total | 46 | 4450 | 1205964 | 1189952 |

Each deletion history also performs a protected complete source-row rebuild.
The suite asserts these counts, fixed-point idempotence, complete live-extent
coverage, whole-allocation retention, and deletion/rescan conservatism.

Named checks cover the paper's four-granule C–D cycle, its spanning-B variant,
known two-byte allocated false positive, reached/unreached unknown rows,
incomplete policy probes, dead spanning allocations sharing a live granule,
short last granules, Q-rounded padding, invalid/overlapping layouts, incoming
seeds/unknown coverage, out-of-scope targets, extra conservative seeds, and
structural-edge persistence through row rebuilds.

The two genuine negative controls search finite layouts/graphs/seeds, removing
one local root or exactly one directed structural edge. Each **must** find and
retain an explicit counterexample with missing live units. Missing witnesses
fail the suite. The spanning counterexample retains the object's start but
loses part of its allocation, distinguishing this test from start-only checks.

## Strict limits

This is a finite research model, not a runtime collector, host liveness service,
callback/index/barrier/history proof, storage-authority proof, memory-order or
Mezzano/supervisor proof. Arrays/queues are ordinary host research data.
Finalizer/ephemeron registry semantics are not implemented; extra seeds only
exercise monotonic conservatism. Conditional staging/clears, common commit,
incoming handle generations, allocation publication, bulk/CAS histories, and
coverage admission remain runtime dependencies. OVC and mature/shared-space
algorithms are not implemented or silently substituted for MGC.
