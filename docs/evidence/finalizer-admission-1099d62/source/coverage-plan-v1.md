# Strict native-callback finalizer admission baseline — source only

Status: **unexecuted probe source for parent review**. No native command or ASDF
operation ran. Production, paper, existing tests and earlier evidence are intact.
Runtime input is frozen committed 1099; parent reports later 04bff62 is docs-only.

Source: `admission-baseline-draft-v1.lisp`.
Package: `CLAMSARA.FINALIZER.ADMISSION.BASELINE.V1`.
Entry: `(RUN-NATIVE-CALLBACK-ADMISSION world)`.

## Contract and precise first witness

Paper-v14 `chapters/clients.tex:373–390` requires a callable **managed** callback
and admission/capacity checks before exposure. Supply one fresh real core quality
world with a valid bound context, fresh registry and empty application roots.
The probe allocates a local node, publishes it in application root0, confirms its
allocated-local status and payload, and selects its ordinary native callback.
The callback is FUNCTIONP but explicitly fails the bound model's
VALID-REFERENCE-P. It has no captured guest references or user work.

REGISTER-FINALIZER must reject this callback before registry/root/barrier/token
state effects. The probe expects RUNTIME-REJECTION with
`:INVALID-FINALIZER-REGISTRATION` by default. That is a pinned implementation
reason, not a new public v14 reason policy; the keyword argument can select a
separately agreed exact reason. Arbitrary ERROR, a different reason, or a late
failure after state changes is not a successful refusal.

### Predicted current result — NOT a native observation

Source `src/runtime/finalizers.lisp:229–257` currently accepts this FUNCTIONP
callback after verifying the referent. It advances NEXT-TOKEN, writes the token
index and registration/callback/state arrays, and returns a token. Therefore
frozen1099 is expected to reach `:RED-ACCEPTED`, then signal the probe's
`:NATIVE-CALLBACK-WAS-ACCEPTED` failure. The runtime and returned token stay owned.
No such result has been executed or counted by this source-only task.

This is an invalid-native-callback admission witness. It is **not** a claim that
a valid managed callback was corrupted. A later fail-closed rejection would
establish this negative gate only, not callable managed finalizer support.

## Ownership and failure policy

The caller constructs and owns WORLD before entry. The probe immediately adds
an owner containing that exact world to `*ADMISSION-OWNERS*`, before setup actions.
If construction itself fails, the entry was not reached: the caller must retain
its construction observation and report zero reached admission cases, not a pass.

Do not use WITH-QUALITY-WORLD: the existing macro has unconditional teardown.
Do not invoke CLOSE-QUALITY-WORLD after catching this probe's failure: that helper
clears roots, drains finalizers and collects. This draft calls neither helper.
It performs no CANCEL-FINALIZER, drain, collection, root clearing, configuration
shutdown or restoration. Even a future correct refusal leaves a
`:REJECTED-RETAINED` owner; this is admission-only evidence, not lifecycle closure.

Unexpected errors preserve the actual condition. Registration's pre-unwind
condition and state are kept separately; a secondary observer error cannot
replace that original condition. A normal unexpected token return is retained
before the probe signals RED. No attempt is made to cancel away the failure.

Only uniquely installed observer method objects are removed during unwind.
Existing primaries, shared observation methods and protocol behavior are never
replaced. A collision with a pre-existing observer makes setup fail/unreached.

## What the oracle records

FNA-SNAPSHOT explicitly records:

- actual world/configuration/context/model/plan/root/registry identities;
- every registry plane and its elements, token-reserve identities and token
  owner/generation/index fields, root locations, pending head/count and history;
- application and registry physical root values;
- root-client provider/token/entry reserves, token generations/states, registration
  scratch, directory entries and related counters/admission state;
- configuration/plan/context status, composed barrier state/pins/reservations and
  callback-depth/failure counters.

Physical objects use EQ; numeric/value slots use EQL. Hash-table snapshots compare
key/value identities without assuming iteration order. Copied guest encodings
are comparison data only, never new GC owners. No LOAD-ROOT/STORE-ROOT is used:
those are snapshot-only. The snapshot reads this concrete hosted profile's
physical accessors and never opens a collector/root-snapshot operation.

The probe compares before/at-signal and before/after-unwind states. Eight effect
counters cover attempts at:

0. ROOT-PROVIDER-STORE;
1. private STORE-PROVIDER-ROOT entry;
2. ordinary object BARRIER-STORE;
3. raw finalizer-root writes;
4. ALLOCATE-OBJECT;
5. COLLECT/AUTOMATIC-COLLECT;
6. REQUEST-SAFEPOINT;
7. raw simulator-root/object stores through quality support's existing observer.

Callback invocation is counted separately. All must be zero for an accepted
refusal. State comparison remains necessary: current registration's direct array
writes can change registry/token state even when the store-entry counters stay
zero. These observers are negative-effect evidence, not a positive publication
coverage proof or a universal detector of transient private writes restored
before observation.

## Proposed future native scope, after approval only

1. Use a new process/cache, frozen1099 ASDF root and source hashes. Load only
   `:CLAMSARA/QUALITY/SUPPORT`, then this source. Do not load workload/Maclina or
   execute any existing positive finalizer suite as this admission witness.
2. Construct one fresh quality world, for example :SEMISPACE/:PACKED with
   extent 2048, root-count 2, finalizer-capacity 2 and registration-capacity 4.
   Publish the caller's actual world handle before invoking this probe.
3. Run this one entry. Catch only at the outer runner to save/print status via
   FNA-SUMMARY. Report **one reached admission case and one retained owner** if
   setup reaches the call, not a profile matrix or completed/closed owner.
4. Current normal acceptance must make the run RED/nonzero, even if it matches
   the predicted bug. Preserve logs, command/PID, pre/post source pins, exact
   condition and returned token ownership. No diagnostic cleanup of the world.
5. Any harness correction gets a new file/run; V1 and failed attempts stay intact.

Static checks so far: balanced parentheses and all named top-level forms at
nesting depth zero. This is not a Lisp read/compile check. Constructor, symbol and
method assumptions still require parent review and the later native authority.

## Separate consequence witness: considered, not supplied or run

A native callback capturing a guest encoded reference could demonstrate the
consequence of invalid callback admission. It must use a **different owned world**
and must be labeled exactly that: unsupported native-callback admission and its
consequence, never valid-managed-client corruption.

Do not continue the first RED owner through collection, root release or drain.
Do not remove roots after detecting an unexpected failure to manufacture the
consequence. Any future separate diagnostic would have to establish its intended
root graph before the admission call and obtain explicit permission for its
post-admission observation policy. It must stop and retain its owner at the first
unexpected error. This draft intentionally does not encode that continuation.

## Positive publication witness is blocked on the stock model

`docs/finalizer-callback-design.md` already records the essential fact. In the
committed model, HOST-REFERENCE is a non-callable structure and
VALID-REFERENCE-P recognizes those model-owned structures. Native FUNCTIONP
callbacks are not model references; the stock model has no supplied member of
FUNCTIONP AND model-reference. Defining another kind does not change that fact.

Therefore a genuine positive witness for writable callback roots, correctable
capture closure, callback-triggered GC and composed publication is **blocked**.
No fake reference predicate, support slot, callable wrapper permission, global
root registration, or altered primitive is introduced here. A truly admitted
callable representation/client integration must exist and be separately reviewed
before that positive domain can be tested.

Existing `test/quality/finalizers.lisp` and `finalizer-drain.lisp` use native
bookkeeping callbacks and explicitly disclaim managed callback admission. Their
old outcomes remain machinery evidence. This task does not edit their inputs,
weaken their assertions or relabel their counts. A future admission repair must
explicitly reconcile those public-entry positives with the admitted domain; it
cannot quietly preserve them by forging managed status.

## Inspected sources/provenance

Read the frozen callback-design note, quality support and both existing finalizer
suites, plus their actual registry/root/context/barrier definitions. The current
paper contract was already read from the pinned live paper-v14. `source-pins.json`
records the immutable inputs and this new draft. No implementation is proposed
by this probe, and no lifecycle, full finalizer or target conformance is claimed.
