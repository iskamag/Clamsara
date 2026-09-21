# LIST / REST source-only revision 2

**Unexecuted test draft. No implementation or native run is authorized.**
MAPC integration/review comes first. N+2 is the preferred conservative LIST
proposal, not approved code. General guest REST and the shared special-binding
patch remain separate and untouched.

## Files

- Current revised source: `regression-draft-v2-construction.lisp`.
- Preserved v1: `regression-draft-v1-fault-injection.lisp`, `report-v1.md`,
  `source-manifest-v1.json`. The original `regression-draft.lisp` also stays v1.
- New provenance: `source-manifest-v2.json`.

## Construction fixture

V2 follows the supplied MAPC source seam:
`/tmp/clamsara-gcbench-52e08f1-tfa6uf75/independent-review/gabriel-next/capacity-strengthening-v3/capacity-ownership-v3.lisp`.
It uses NEW package `CLAMSARA.LIST-NEXT.DRAFT.V2` and fixture-local dynamic flags.

The temporary `INITIALIZE-INSTANCE :AFTER` method provisions real native-cell
and FUNCTIONS/SAVED-VALUES arrays before provider registration. The constructor
still fills its unchanged location-token vector. No live array is resized or
restored. No location-token vector or advertised root capacity is shrunk.
Each method installation first asserts that the exact method does not exist.
Only its own returned method object is removed on unwind. It never overwrites
an existing method, primary method, VM, or upstream compiler function.

Tiny-array construction or compilation may fail before reaching LIST. Such a
case is failed/unreached, not a capacity pass. Partial provider and runtime
owners are retained as far as construction reached. Setup minima are untested.

## Expected refusal is not enough

The proposed N+2 capacity cases now require this complete history:

1. Establish a shared managed input graph in case-owned root15. Save its native
   graph oracle. Build the target inside the physically bounded runtime.
2. Observe the LIST boundary after argument evaluation. On expected refusal,
   compare actual source/token/vector identities, values, stack/registers,
   native/frame extents, allocation maps/cursors, and the owner graph.
   Unique additive observers also require zero attempted allocation/store calls,
   including cleanup before return to the caller. No runtime counter is faked.
3. Verify the same owned graph after unwind. Verify unchanged physical arrays.
4. Without enlarging storage, call the same LIST with **one managed argument**.
   This smaller native entry needs no guest caller frame. Transfer its result
   immediately to case-owned root14. Require a real allocation and correct
   sharing between result and original input. Force a real collection, reload
   both roots, and check the graph again. This is not an empty fast-path retry.
5. Only after these checks, release the case-owned definitions and root14/root15,
   consume its result, prove zero discoveries, and close successfully.

Unexpected failures do none of step 5. They retain their runtime, configuration,
root token, case roots, phase and condition. The expected condition is recorded
separately and is not called a pass before recovery and discharge finish.

The original behavior cases remain: native order/sharing oracles, N=0/N=31,
nested evaluation, and actual allocator filling to force movement in LIST and
inside a live MAPC extent. These are unchanged regression goals, not evidence
that any implementation passed them. Host-payload and general REST diagnostics
remain separate; their rejection does not imply a successful capacity history.

## Limits

No new native validation occurred. A Python parenthesis scan is not a Lisp
read/compile check. All syntax/runtime assumptions need the parent's later
review and exclusive native slot. V1 is preserved, including its limitations.
The draft covers selected actual arena/frame bounds, not every provider,
control-queue, or VM limit and not whole-heap admission.

Current census calls full provisioned-queue `FILL` and `CLRHASH` on its scratch
at entry and exit. There is **no active-only work or LIST performance claim**.
There is no host-allocation-free, arbitrary callable, full REST, supervisor,
paper, DDERIV benchmark, or lifecycle acceptance claim from these source drafts.
