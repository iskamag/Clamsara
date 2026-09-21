# LIST v3 paused: bounded source notes only

Paused on the parent's framework-correctness priority pivot. No native rerun,
production implementation, dependency/fixture edit, or v3 Lisp source was made.
V2 and native baseline PID21361 remain unchanged. Native slot remains FREE.
These are incomplete design notes, not an approved test or implementation.

## Original-signal observation

V2 WITH-OWNER catches errors in HANDLER-CASE and then rethrows. The baseline's
outer handler therefore records the rethrow after the inner unwind. Its
PRE-UNWIND label cannot mean original instruction state.

Planned correction, not implemented: put HANDLER-BIND inside WITH-OWNER's
HANDLER-CASE around constructor and action. Capture only fixed-size scalar
records: phase/site, condition type, scalar operation/reason, runtime/provider
presence, published configuration/token state when available, frame/native
counts and physical lengths, and published VM stack/frame/PC/argument registers.
Do not print conditions, guest values, code graphs, or arbitrary host objects.
Use bounded preallocated records and an overflow/capture-failure flag.

A handler outside an action's own HANDLER-CASE still does not see errors that
that inner handler handles first. Expected capacity conditions need the
existing LIST-boundary handler to record the same bounded scalar context before
its local HANDLER-CASE catches them. A first-error-only record also loses later
unexpected recovery failures; preserve a bounded event sequence instead.
Published VM-PC is not automatically the interpreter's current local IP. Any
new report must state this limit rather than call it exact instruction tracing.

## Capacity fixture attribution

V2's 2 direct / 4 nested frame counts describe its proposed native N+2 extent
plus caller/MAPC/callback scopes. They are not CL minima or measured needs of the
unchanged guest LIST/BUILD implementation, which adds interpreted activations.
The baseline's frame failures cannot validate that proposed native design.

Construction can succeed while later seed creation, target compilation,
MAPC entry, callback entry, or LIST fails. V2's failure phase overwrites the
previous stage. The baseline did not dump LIST-entry snapshot presence or the
previous phase. Twelve N17 owners retaining root15 proves owned seed data was
established, not that all reached LIST admission. Add distinct stage/site
records in a future new source version; do not loosen baseline assertions.

## Movement/store witness limits

The existing movement forms and witnesses were not edited. They test argument
and result graphs through allocation pressure, but do not isolate every fresh
node staging interval and both individual store completions.

A separate input/accumulated-tail witness can request a real collection in a
scoped ALLOCATE-OBJECT observer **before** the primary allocation, once all
inputs and the existing result are published. It must use real registered
sources and prove actual changed encodings plus corrected graph identity.
No new object from that allocation exists yet, so this does not independently
prove fresh-node staging across collection.

Do not force collection after ALLOCATE-OBJECT returns but before the builder
publishes its fresh reference: that injects a collection into an unowned return
handoff. Do not force collection inside a borrowed BARRIER-STORE location:
that can violate the pin/borrow contract instead of testing the builder.
Observing a completed store does not itself authorize a safepoint there.

An isolated fresh-node / between-stores movement witness needs an explicitly
reviewed safe point after publication and outside the complete borrowed write
operation. No such test seam was selected or added. Both-store tests should
separately observe committed CAR and CDR operations, reload the corrected target,
and verify final order/sharing. Merely counting attempts is not completion
proof, and graph equality alone does not isolate an untested intermediate
lifetime. These tests remain design work, not coverage evidence.

No arbitrary-barrier, general REST, full callable, supervisor/target, or LIST
performance claim follows from these notes. Current census clears provisioned
queue/hash scratch; active-only work is not established.
