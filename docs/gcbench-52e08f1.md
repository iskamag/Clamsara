# Current depth-18 GCBench evidence — 52e08f1

**The unchanged strict runner passes on committed `52e08f1`.** This is a new
revision-specific result, not a transfer of the older `113aa6a` result.

- Native PID 16350: exit 0, process 1170.6189206150593 seconds.
- Reported workload duration: 1152.5149 seconds; returned value: T.
- Unchanged checked-in Scheme-to-Common-Lisp translation, depth 18.
- Active semispace 32 MiB; reserved semispace storage 64 MiB; maximum object 8 MiB.
  Host SBCL dynamic-space limit 8 GiB is separate, not measured residency.
- Shared Maclina remains unpatched at `d92e9254`; no private candidate selected.

## Managed collection and ownership

The final automatic collection report is `:COMPLETE`:
196,611 objects discovered and moved, 16,777,328 bytes moved, 262,142 objects dead.
These are **one recorded automatic cycle**, not whole-run totals. They exceed
the unchanged runner's required long-lived-tree/array movement thresholds.

After the benchmark returns, the runner performs an explicit collection without
clearing globals, VM frames, temporary roots or benchmark anchors. It completes
with zero discoveries/moves/bytes moved and 262,143 objects dead. Normal
`close-workload-runtime` then completes and clears the runtime's configuration
through its existing owner-driven lifecycle. No close error was swallowed.

The log includes `GCBENCH-ACCEPTED`, `GCBENCH-CLOSE :COMPLETE` and
`GCBENCH-CURRENT-STRICT-RUNNER-RETURNED`. The process exits 0.

## Provenance and replay scope

`docs/evidence/gcbench-52e08f1/` contains the complete native log, bootstrap,
command/result metadata and before/after input hashes. The native working tree
is a Git archive of `52e08f118de9c121a5b9c81cbfb2bb843c117c53`, not the mixed
working tree with held indexed/name/ledger changes. All pinned files remain
byte-identical, including the runner, fixture, Clamsara sources and shared
Maclina Lisp/ASDF sources. The bootstrap asserts exact Clamsara/workload/Maclina
ASDF source selection and uses a private non-colliding FASL cache.

The fixture SHA256 remains:
`0a2af82bc5a1c0e2246d3d0709111c43a67577a51445b7ab2860abb346603153`.
The strict runner is `tools/run-gcbench.lisp`. No fixture assertion, depth,
geometry, allocation path or cleanup gate was changed for this run.

## Limits

This establishes the committed strict runner's managed movement, original
fixture assertions, discharge and close gates. It does not add a complete
per-element array/tree oracle, prove full Common Lisp semantics, or establish
whole storage accounting, isolated performance or Mezzano admission. The
workload ASSERT shim currently returns T on success instead of Common Lisp NIL;
the reported T is not an independent native return-value oracle. That language
semantics defect is not waived by the benchmark's original assertions passing.

Compilation, dependency and unknown-operator warnings remain in the full log.
This is one unisolated run; no speedup/regression claim is made against 113aa6a.
All 19 Gabriel correctness/discharge and the broader model, compiler ownership
and paper/target obligations remain open.
