# Hosted allocation-geometry snapshots (work in progress)

Base revision: `9dd8629`. This repair is not full object-model admission.
The normative paper and benchmark fixtures are unchanged.

## Defect and scope

Accepted fixed size/alignment functions previously ran again during allocation
and copying. A legal change to their caller-owned lexical environment could
change the ABI of an existing object or stop copying after forwarding a parent.
A caller-created private variable-size-rule input could change a copied array's
slot count and lose a last-slot child while collection reported complete.

The original native review is preserved in `object-kind-snapshot-review.md`.
It separates exported function-rule inputs, private hosted rule inputs, and
invalid writes to opaque returned records. The last category is not a public
contract counterexample.

## Implementation

The hosted model owns a separate executable catalogue at binding:

- Resolve each fixed callable size/alignment rule once for its kind.
- Copy finite variable geometry, normalized strong layouts, and conditional
  records. Recheck size/layout coherence at binding as well as description
  creation, since a caller can change an offered variable rule in between.
- Keep original opaque allocation tokens. An EQ table maps admitted originals
  and internal snapshots to their executable descriptions. Initialization
  validates exact descriptor aliases, not the name-resolution fallback.
- Allocation checks, initialization/copy, ordinary mappings, and staging use
  the same bound descriptions. The allocator does not interpret opaque rules.
- Account for both the original token graph and the copied executable graph.
  Tokens still retain their original descriptions even when execution no longer
  uses those fields. One shared storage visitor serves both accounting paths.

This does not deep-copy arbitrary closure environments. Indexed identity
callbacks still run at execution, and general mutable compound kind names are
not yet snapshotted. These remain separate open defects. Retaining an opaque
original is not permission to read its mutable rules during execution.

## Construction exits

Moving callable-rule evaluation into binding exposed an existing ERROR-only
construction cleanup boundary. Independent probes found eight real leaks after
THROW: construction context `:building`, configuration `:private`, no bound model,
zero releases among 11 semispace or 9 marksweep resources, and an active owned
layout. The old `9dd8629` control never called those functions during binding.
It returned a world whose ordinary shutdown released resources normally.
See the unchanged historical report `geometry-snapshot-review.md`.

The builder now owns an UNWIND-PROTECT guarded by actual configuration
publication. Cleanup does not unconditionally signal the original condition.
For ERROR, the builder saves the condition, cleans up, and then re-signals that
same condition. Thus an outside non-unwinding HANDLER-BIND observer sees cleanup
already complete. Other nonlocal exits and their multiple values pass through.
A cleanup-contract fault remains an explicit failure. Successful published
configurations are not rolled back.

## Evidence so far

- `/tmp/clamsara-kind-geometry-red2.log`: exact geometry regressions on the
  selected frozen `9dd8629` source fail all 12 cases. This fixture's alignment
  mutation changes the resulting alignment rather than necessarily retaining
  the stop; the earlier independent fixture used different placement.
- `/tmp/clamsara-kind-unwind-red.log`: the original geometry patch passes its
  geometry cases but fails the new resource-release assertion after THROW.
- `/tmp/clamsara-kind-unwind-green.log`: 12 geometry histories, 8 ERROR
  rejections, 8 THROW cleanups, and 105 construction checks pass. Source hashes
  recorded in `/tmp/clamsara-kind-unwind-source-hashes.json` agree before/after.
- `/tmp/clamsara-kind-unwind-components.log`: main, tools, workload, optional
  generational, and structure gates pass, including all 288 generation histories.
- Independent geometry review passed 35 composed binding, lifetime, staging,
  handle, alias, malformed-input, and ownership cases before finding the THROW
  blocker. The cleanup-fix follow-up on
  `/tmp/clamsara-geometry-unwind-review-hu77pd9y` passes the same 35 cases,
  all 8 former leaks with real release assertions, and 9 late-hook/ERROR/
  cleanup-fault/success-guard cases. The report is preserved unchanged as
  `geometry-unwind-review.md`. Parent integration of the independent 35+9
  histories uses shared test observers to avoid CLOS method replacement.
  `/tmp/clamsara-kind-snapshot-integrated.log` passes those 35+9 cases with
  the parent 12+8+8 cases and 105 construction checks. The subsequent
  `/tmp/clamsara-kind-snapshot-integrated-full.log` passes the complete
  main/tools/workload/optional-generational/structure gate, including
  288 generation histories.

The two always-signaling rule cases formerly tested at allocation now reject
binding. They were moved, not discarded: both collectors and maps check real
resource/layout unwind and error identity. The remaining allocation suite has
160 rejected requests, 36 valid controls, and 4 valid space-exhaustion controls.

## Storage and performance boundaries

The unchanged 500,000-element stress on the geometry patch passed in
`/tmp/clamsara-kind-geometry-array-stress.log`. Heap geometry, 1,000,132 descriptor
cells, 80,011,312 fixed-plane bytes, 48,133,504 resource-physical bytes, and
8,000,032 moved object bytes did not change. Auxiliary accounting increased from
160,290,512 to 160,292,368 bytes: 1,856 bytes for the added retained snapshot state.
That run predates the builder-only cleanup change. Its 6.024-second process time
includes startup and is not an isolated benchmark measurement.

`performance-storage-review-9dd8629.md` preserves DeepSeek's source/log review.
The fixed-plane number is a shallow category, not all retained model storage.
Base-reference records and staged backing are charged elsewhere in auxiliary
accounting. The old printed callback fields are constants whose per-pass
expectations are asserted in the test; they are not measured whole-workload
callback totals. Clearer counters and a small controlled trace-capacity timing
experiment are pending. No current-tree GCBench, all-19 Gabriel, Mezzano, or full
conformance acceptance follows from these component gates.
