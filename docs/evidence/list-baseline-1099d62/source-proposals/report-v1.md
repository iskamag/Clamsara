# LIST / guest REST: source-only next step

Status: **design and unexecuted regression draft only**. No implementation,
native command, fixture edit, dependency edit, or subdelegation was performed.
The frozen MAPC draft is not accepted by this report. Its physical capacities
still require independent execution. No TESTDDERIV or general callable claim.

## Immediate failure and smallest repair scope

The supplied `native-02.log` shows `%GUEST-CAR` receiving the **host** list
`(// 0 3)` in guest `LABELS BUILD`. The supplied driver computed the native
oracle first and retained its runtime owner on failure. This investigation
did not replay it.

In the frozen `src/workload/maclina.lisp`:

- 697–699 and 801 install native `LIST-FN`, using recursive `%LIST*`.
- 865–871 then overwrite LIST with `(lambda (&rest values) ... (car tail) ...)`.
- In read-only Maclina `vm-shared.lisp:87–89`, `LISTIFY-REST-ARGS` uses host
  `LOOP ... COLLECT`. `vm-cross.lisp:452–456,648–652` pushes that host list.
  `compile/compile.lisp:1815–1823` emits the opcode before binding REST.

Repair only Clamsara's installed LIST: retain a native, strict managed LIST
entry and remove its later guest-REST overwrite. Replace its unsafe builder
with an arena-backed builder. Do not redirect guest CAR/CDR to host operators,
traverse arbitrary host containers as roots, or change the fixture. Keep
`%WORKLOAD-INSTALL-DATA-FUNCTION` so compiler source mode still selects CL:LIST.
A direct/first-class native LIST repair does **not** repair user `&REST`, APPEND's
separate guest REST lambda, keyword binding, or a general APPLY boundary.

Merely removing the overwrite is insufficient. `%LIST*` (248–252) evaluates
FIRST before recursive allocation; that evaluated value and the host REST
spine do not become correctable roots. `%HOST-LIST->GUEST` (272–317) is not a
safe drop-in either: its `count+2` bound with the default 16 temporaries means
14 inputs, it uses temp0/1 and temp2 onward without an extent allocator, and it
leaves temp1 live until an unspecified caller handoff. WORKLOAD-WRITE-SLOT owns
temp0 (protocol.lisp:231–271). Existing `%CONS*`/`%ALLOCATE-GUEST` also borrow
fixed temporaries. Do not silently introduce a LIST arity limit of 14 or reuse
these slots across live/nested operations.

## Bounded arena design (not approved code)

Yes, the MAPC arena can supply an N-element correctable input row and a result
root. The important fact is **publication through SAVED-VALUES**, not merely
incrementing NATIVE-CELL-COUNT. `roots.lisp:371–375` scans original cons CARs;
`193–239` reads/writes those same sources. `control.lisp` already owns disjoint
LIFO extents with fixed links. Use that discipline, not a detached host copy.

A straightforward design uses **N+2 native cells**: N inputs, result, and fresh
object staging. One activation frame publishes the entire fixed chain through
SAVED-VALUES; FUNCTIONS may be NIL because LIST calls no guest callback.

1. Require the correct open environment/VM. For N=0 return NIL without taking
   an unused extent. Validate inputs as admitted managed references or supported
   immediate words, not arbitrary host payload (`host/object-model.lisp:404–411,
   1408–1417`). A transient host argument *spine* is control, not guest data.
2. Before modifying the arena, frames, or heap, check actual native-cell vector
   length and **both** FUNCTIONS/SAVED-VALUES vector lengths. Use the shared
   non-retargeting census for current roots/control owners, and check current
   demand plus the exact new chain size against logical capacity and actual
   LOCATIONS length. Census must use its separate physical scratch; it must not
   refresh/retarget live descriptors. No future callback/local-frame demand is
   needed: this leaf primitive calls no guest code. Existing checks report
   WORKLOAD-MAPC in places; a shared check should not mislabel LIST failures.
3. Initialize only the unowned extent, copy arguments before the first managed
   allocation, then publish its frame/chain/counts. Never consult the host REST
   elements again. A nested census sees the actual published extent.
4. Build right to left. Every allocation can move both input values and the
   accumulated tail. Publish the new object in staging immediately on return.
   For each write, reload the target from staging and the payload from its
   input/result cell. Set CAR/CDR through the existing configured barrier path.
   Do not reuse the target encoding from the previous write. Only after both
   writes publish it as the new result. Keep chain links fixed during the extent.
5. Reload the final result, then release only this frame/extent. No managed
   allocation, guest call, barrier slow path, or fallible census may intervene
   before transfer into the caller's VM result/operand source. Cleanup must
   neither overwrite VM-VALUES nor restore a stale copy. "Allocation-free"
   here means the bridge's guest-allocation-free handoff: upstream VM CALL uses
   host MULTIPLE-VALUE-LIST/gather, so this is **not** a host no-consing claim.

An N+1 layout is also possible in principle: a consumed input cell can become
fresh-object staging. It needs an explicit no-safepoint payload handoff into
the leaf write's temp0 before that input value becomes unrooted. Alternatively
it needs a separately owned leaf scratch root. Do not claim N+1 from a sketch
that loses either the input, old tail, or new object during a moving write.
N+2 avoids that extra proof and does not impose an arbitrary input count.
The existing barrier helper contracts still apply; this report is not proof
of arbitrary moving barriers or supervisor safety.

The finite bound is physical storage shared with existing activations, not
N<=14. Allocation exhaustion can still occur after partial construction;
pre-effect *root-capacity* admission is not a whole-heap reservation guarantee.
Failure cleanup may release a primitive's internal extent, but tests must keep
the external runtime/configuration/root token for diagnosis.

## Broader REST: genuine hooks, and missing universal hook

Read-only upstream provides real generics `COMPILE-COMBINATION` (743),
`COMPILE-SPECIAL` (825), `COMPILE-SYMBOL` (656), `COMPILE-SETQ-1` (1187),
`LOAD-LITERAL-INFO` (2133), and machine `COMPUTE-INSTANCE-FUNCTION`
(`structures.lisp:44`). Existing Clamsara methods demonstrate workload-client
isolation. FUNCTION (1310), FLET (1092), and LABELS (1125) have COMPILE-SPECIAL
methods. These are real seams for a separate, carefully scoped lowering.
Clostrum compiler-macro/Trucler descriptions also participate in the actual
COMPILE-COMBINATION path; this is not permission to replace compiler internals.

There is **no single generic REST-prologue hook** here. COMPILE-FORM dispatches
direct lambda calls straight to nongeneric COMPILE-LAMBDA-FORM (626–644).
COMPILE-INTO, COMPILE-LAMBDA, %COMPILE-LAMBDA-EXPRESSION,
COMPILE-WITH-LAMBDA-LIST, ASSEMBLE, VM-SHARED:LISTIFY-REST-ARGS, and VM-CROSS:VM
are DEFUNs. Do not add purported methods to them or replace their global
fdefinitions. A compiler-special extension alone misses direct lambda calls,
top-level COMPILE/EVAL entry and macro-generated lambdas. A future design must
cover those routes or explicitly reject its unsupported scope. Moving managed
REST construction also needs prologue VM-state publication: the stock listify
opcode currently assumes only host allocation, while CALL explicitly publishes
VM-STACK-TOP before native entry (`vm-cross.lisp:327–336`). Linking/runtime
wrappers alone cannot retroactively convert the REST local at the correct point.
Source macro REST must remain host syntax; optional/key/default timing,
closures, mutation, special bindings, and nonlocal exits are separate tests.
The unanswered upstream special-binding patch remains untouched and unresolved.

## New regression draft

`regression-draft.lisp` contains definitions only, with no load-time test run.
It is unexecuted and requires a separately approved implementation and native
slot. It owns a runtime before setup actions, retains owners/conditions on any
failure, compares native graph order **and sharing identity**, rejects host
cons leakage, checks N=0/N=31 and nested LIST evaluation, and forces real LIST
movement by filling the actual allocator to two cons cells using real discarded
allocations. A MAPC callback variant keeps an outer native extent live.

The physical-capacity cases narrow **actual preallocated vectors at idle** in
a case-owned runtime, not logical counts. This is explicit white-box fault
injection, not production geometry. Caller supplies the implemented extra-cell
count (1 or 2); there is no assumed accepted layout. Exact/one-short arena and
FUNCTIONS/SAVED-VALUES cases take pre-signal snapshots at the LIST boundary,
including real allocation maps and allocator cursors. Expected rejections also
retain owners; they are never cleaned to turn failure into success.

These drafts do not prove all census/control/VM limits. Whole-provider and
control-queue capacity tests still need independent cases with genuine live
owners and actual construction bounds. Return-transfer allocation freedom
needs source review plus native observation, not a fake counter test. The
separate general-REST forms are diagnostic expectations, not a LIST repair gate.
Recheck unchanged fixture hashes before any later DDERIV attempt. Full benchmark
and lifecycle acceptance remain separate.
