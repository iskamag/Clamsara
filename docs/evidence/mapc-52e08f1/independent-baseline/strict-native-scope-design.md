# MAPC native activation scope: bounded recommendation, not implementation

**Source-only. No design is approved or implemented. No native test ran here.**
The old `report.md` and `mapc-probe.lisp` are preserved byte-for-byte. Do not use
the old probe's unconditional cleanup after errors. The new source is
`mapc-strict-regression-draft.lisp` (static balance checked only).

## Recommendation

Reuse the existing activation owner mechanism for a private MAPC primitive
scope, subject to the capacity and callable obligations below. Do not add a
persistent registry, special-case two lists, add guest REST, or borrow temporary
slots 0..15. Scope management is Clamsara-owned; no Maclina patch is required.
This is a hosted adapter design, not allocation-free supervisor admission.

Evidence in committed code:

- `roots.lisp` provisions fixed FUNCTIONS, SAVED-VALUES, frame count, physical
  location tokens, and the identity-deduplicated control queue.
- `%provider-refresh` scans each active FUNCTIONS owner and each original
  SAVED-VALUES cons cell. `:values` locations read/write the CAR of that exact
  cell, not a copied reference. It follows known Maclina closures, functions,
  modules and lexical cells. It does not traverse arbitrary native containers.
- `%call-with-workload-function` (`control.lisp:4-41`) already uses activation
  slots for actual callable ownership and saved cleanup values. Its current
  admission checks only frame count; that is NOT enough for the proposed scope.
- `%provider-refresh` clears and retargets physical descriptors at protected
  snapshots. Do NOT call it casually as an admission probe.

## Proposed physical extent

For N input lists, reserve a disjoint active scope containing:

1. FUNCTIONS[frame]: the **actual resolved callback object**, not merely a
   wrapper returned by COMPUTE-INSTANCE-FUNCTION and not its name symbol.
2. SAVED-VALUES[frame]: a stable host control chain with 1 + N + N writable
   value cells: original first-list return owner, N cursors, N callback-row
   arguments. Keep these cells distinct even when their values initially alias.
3. Explicit ownership of the cell storage until this activation ends. A bounded
   setup-provisioned arena may supply it; nested extents cannot reuse live cells.
   Cells are interpreter control/root sources, not admitted host-list payload.

The argument row is the final N-cell suffix, so native APPLY can use that exact
host control list. Its CARs are the registered physical argument sources. Never
create a detached argument-value list and then allocate/collect before entry.
After callbacks return, advance each cursor from its **reloaded corrected**
cell. Return by reloading the separate original-first-list cell. Do not retain
managed cursor, leaf, result, or capture encodings in native locals across a
callback. Stable host *cell addresses* may be kept as control references.

Only the top activation can release its owned cells and slot. Nested MAPC and
ordinary interpreted callback activations share the index discipline without
sharing their live cells. Expected ERROR/THROW release those expired activation
extents and restore caller registers; they do not erase VM-VALUES or outer
owners. Multiple values in flight remain owned by their existing real VM / saved
value cells. An implementation must make return transfer allocation-free until
the caller receives it, or retain an explicit transfer owner.

## Capacity: necessary unresolved admission work

Counting a free frame is not reserving physical root tokens. Admission needs a
**separate, non-retargeting census**, with bounded dedup scratch, of the sources
that the next protected snapshot will actually enumerate. Count each physical
location, even when its value aliases another location. Dedup only control
objects exactly as the existing traversal does. Include:

- the fixed temporary token region (including 0..15), current stack prefix,
  VM value cells, dynamic cells, existing activation value cells;
- current property/global sources and published code/capture/literal sources;
- this scope's 2N+1 cells and the resolved callback's reachable known control
  objects and their writable captured/literal cells;
- the callback-entry stack requirement: N argument slots plus the template's
  LOCALS-FRAME-SIZE (`Maclina/vm-cross.lisp:116-138`) and its activation slot,
  in addition to the MAPC scope itself. Do not count only the callback name.

Validate actual physical token-vector bounds, activation-array bounds, owned
cell-arena capacity, VM stack bounds, and deduplicated control-queue bounds.
Reserve the accepted scope demand so nested admission cannot spend it twice.
Use the same source classification/count rules as the snapshot enumerator,
without clearing/retargeting descriptors, staging the new scope as if admitted,
or mutating guest/VM state to see whether collection would fail. A bounded
scratch-overflow is an admission failure, not permission to truncate the census.
A two-pass/shared read-only enumeration specification is plausible; it is NOT
presently implemented or proved equivalent to the snapshot walk.

Reject a proposed extent before its callbacks, managed allocations, guest stores,
or publication if this current demand cannot fit. Callback execution may create
additional frames/control roots later. An entry census cannot promise that
arbitrary future callback execution fits. Each new extent needs its own admission
contract. If the requirement means reserving **all possible future callback
work before the first MAPC callback**, the current interfaces do not establish
that stronger bound; do not silently claim it. This distinction is an explicit
remaining design question, not a capacity waiver.

## Callback boundary

A symbol designator resolves via the current workload client's Clostrum
FDEFINITION, with normal undefined-function failure. No host FDEFINITION fallback.
Keep the returned Maclina function/closure object as FUNCTIONS owner; those two
classes are separate funcallable-standard-object classes, not a subtype pair.
Use the closure's actual template/environment and existing control traversal.

The scope's argument CARs can be corrected while an interpreted callback runs:
Maclina also copies arguments into real VM slots, which the provider scans.
That fact does NOT repair a native CL callback's ordinary lexical locals or
uninspectable captures. FUNCTIONP alone proves neither payload ownership nor
argument reload. Do not silently admit arbitrary host closures/generic callable
instances based on this design. Supporting such callbacks requires an explicit
separate no-managed-allocation/reload/capture boundary, or an explicit unsupported
capability result. The new draft establishes only the tested Maclina callable
shapes, not general callable/capture or full ANSI MAPC admission.

## Strict new source and failure ownership

`mapc-strict-regression-draft.lisp` takes an already caller-owned runtime. It
records the actual runtime/provider handle in `*OWNERS*` **before** test actions.
Unexpected errors record the condition, phase and pre-unwind scalar registers,
then propagate. There is no unconditional UNWIND-PROTECT cleanup, EVAL NIL,
collection, root clearing, definition removal or close on that path. The caller
must stop and inspect that owner; do not continue the suite on the failed runtime.
This does not promise to extend guest dynamic extents beyond normal unwinding.
Constructor-internal partial ownership is outside this function; the parent
must own runtime construction before handing it in.

Only successful semantic histories release exactly their case-owned definitions
or four DDERIV properties, consume their proven result, require zero-discovery
discharge and close. Any later discharge/close failure also leaves the runtime
handle retained. The old unconditional-cleanup probe remains historical only.

The case selector covers:

- direct installed function / callback / NIL / NIL arity;
- one, two and three lists; NIL in each position; native oracle for order,
  shortest traversal, ignored callback multiple values and first-list identity;
- real automatic GC in callbacks; corrected six-cons return graph and scalar
  checksum; nested MAPC forces CONS scratch activity without test-owned sentinels
  in slots 0..15;
- a callback that solely owns a managed capture; an environment-resolved symbol
  callback whose same-name native definition signals a poison condition;
- exact intended callback ERROR, THROW with two managed values, physical root
  correction, restored caller registers and successful retry of an ordinary call;
- the entire unchanged DDERIV source load and its four exact property/function
  identity relations, checked before and after a real full collection. This is
  a setup gate, not the 5,000-call benchmark or full Gabriel acceptance.

No callback mutates a traversed list. No circular/dotted/invalid-input behavior is
claimed. The draft has not been read or compiled by Lisp; even passing its static
parenthesis check is not native syntax or semantic evidence.

`mapc-capacity-regression-contract.lisp` lists the exact-fit / one-short and
nested admission obligations as SOURCE DATA ONLY. It deliberately invents no
production API and does not fake FRAME-COUNT or call the snapshot walker outside
its boundary. Those gates require an agreed test-only physical construction /
admission observation seam before they can become executable assertions.
