# Source-only capacity/ownership regression draft

Reviewed `/tmp/clamsara-mapc-draft-wd3ba0th`, specifically its frozen
`src/workload/{roots,control,maclina}.lisp` overlays and setup order. No native
process, production edit, dependency edit or fixture edit occurred here.
`reviewed-draft-sha256.json` pins the inspected files.

## Files and status

`capacity-ownership.lisp` is NEW, unexecuted source. Static parenthesis balance
is zero. It is not a native reader/compiler result or a passing test report.
It defines three explicit runners, with no automatic execution:

- `CAP-RUN-BOUNDARY-MATRIX`: a roomy calibration plus 12 fresh exact/one-short
  constructions over six physical dimensions: tokens, frames, native cells,
  snapshot control queue, census control queue, VM stack.
- `CAP-RUN-SNAPSHOT-WITNESS`: shared callable aliases, real full collection,
  current census versus protected snapshot descriptors/control count, and a real
  ML callback-entry collection bounded by its pre-entry reservation.
- `CAP-RUN-NESTED-REJECTION`: a real five-cell outer MAPC scope; inner nonempty
  MAPC rejects for lack of another five-cell extent, then collection moves outer
  payload before the ML callback reads its arguments and capture again.

The matrix is not merely checking that the helper returns its own arithmetic:
all short dimensions also exercise the actual nonempty MAPC entry. Exact
non-stack dimensions execute an actual ML callback with checksum 65. The exact
stack case tests entry admission only; the contract does not bound later operand
stack growth. Real movement and protected snapshot observations are separate
checks, not inferred from successful helper return values.

## Construction and observation seams

The provider INITIALIZE-INSTANCE :AFTER method replaces only actual frame,
SAVED-VALUES, native cons-cell arena, and walk queue/seen arrays. It checks zero
counts and never changes LOCATIONS, provider CAPACITY, or counters. The normal
ROOT-CAPACITY option constructs the physical token dimension. Native cell storage
uses the production setup constructor, producing actual distinct cons cells.

The VM does not exist during provider initialization. A separate fixture-scoped
workload-environment :AFTER method sets STACK-SIZE before normal INITIALIZE-VM
allocates and binds that VM. This is not live stack resizing. Note the distinction:
the provider has already been registered by then, but the VM has not been created
or bound to it. This additional construction seam should be reviewed explicitly
before execution; it is not described as pre-registration provider mutation.

Test-only additive :BEFORE observers count ALLOCATE-OBJECT and BARRIER-STORE
attempts during admission/rejection extents. A MAP-PROVIDER-ROOTS :AFTER observer
is reached only through real COLLECT, when the normal protected snapshot path
has installed descriptors. No test calls %PROVIDER-REFRESH directly.
All methods assert no prior exact qualifier/specializer method, are dynamically
guarded, and remove only their own method objects. No production primary is
replaced. Removing a fixture method on unwind does not clear a runtime owner.

## Checks intended to falsify claims

- Before/after admission snapshots compare actual vector/token/native-cell/root
  source identities with EQ, plus values, source kinds, source indexes, native
  chain links, active frame/cell counts, VM registers/stack/values/dynamic stack,
  and snapshot queue/count/seen. The census must leave its separate scratch empty.
- Rejection must not invoke callbacks, allocate managed objects, or call guest
  barrier stores. It must not publish a scope or change any captured descriptor
  or physical owner identity.
- The small physical configuration remains small for an ordinary empty MAPC
  retry. After the expected rejection has been proved, the application releases
  only its own callback definition, allowing even the deliberately short control
  queue to collect the still-owned two input lists. Both must move and retain
  their expected 11/13 payloads before final consumption and close.
- An extra operator alias for the exact same ML callback must not duplicate its
  control graph. The current source census must equal the actual active token
  count and control count observed inside a protected snapshot during COLLECT.
- The callback-entry witness computes admission in a test wrapper immediately
  before calling the real primitive, then performs a real collection as the
  callback's first zero-argument observation call. Snapshot demand must not exceed
  that reservation. The wrapper transfers inputs before managed execution and
  never reads its native input locals after the call. This is a specific test
  boundary, not a general native callback/local safety claim.
- The nested inner call must reject with the exact cell-capacity reason, not a
  callback error or wrong arity. It observes unchanged outer cells and descriptors,
  then moves the outer graph. Two callbacks must yield checksum 47 and preserve
  the returned two-leaf list. Temporary slots 0..15 receive no test sentinels and
  are never used as scope storage by this fixture.

## Ownership and limitations

Each case records an owner before construction, including a partial provider
handle if construction fails, and retains the returned runtime before test work.
Unexpected errors retain condition and phase and propagate. No unexpected-failure
path evaluates NIL, removes guest definitions, collects for discharge, or closes.
Only a proved successful history releases its exact fixture-owned definitions,
consumes its result, requires zero discoveries and closes. Partial construction
beyond the captured provider still needs the normal construction owner's recovery
contract; the test does not pretend it can reconstruct a runtime never returned.

Calibration uses a roomy same-source environment and replays those integer bounds
in fresh physical constructions. Setup failure, capacity drift, or syntax/wiring
failure is a failed/unreached test, never an accepted capacity rejection. Exact-fit
entry admission is not a proof of minimal possible capacity: the actual existing
future locals may conservatively retain extra controls. No capacity claim is made
for arbitrary later callback work.

Current census/snapshot equality alone cannot detect a source omitted by both
walks. The actual managed callback/capture, nested movement and retained-input
checks are therefore required independently. Native FUNCTIONP callback
compatibility is not managed native-local/capture safety evidence.

## Source review findings on the production draft

No definite supported-ML admission undercount was found in this pass. The draft
uses a shared source classifier, separate cleared census scratch, both queue
bounds, current active extents, actual projected argument/local slots, and actual
future local control contents. The proposed tests remain necessary to validate
that reasoning. This is not approval or conformance acceptance.

Source-specific risks retained for falsification: constructor method timing,
calibration under a smaller physical arena, read-only descriptor/queue identity,
real callback-entry demand versus reservation, and nested rejection preserving
outer data across collection. Native callback captures and unbounded later VM
work remain explicit separate boundaries, not hidden exemptions.
