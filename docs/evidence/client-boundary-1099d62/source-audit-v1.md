# Client boundary audit of committed 1099 — source only

## Answer

**The client decides object/reference representation and host mechanisms, not all
collector storage policy.** The graph chooses spaces, allocators, metadata and
work-buffer requirements. Construction binds those requirements to admitted
client storage and capabilities.

I found no Maclina-specific execution or storage knowledge in the committed core
outside `src/workload`. The real coupling is broader: **the current core is wired
to the concrete hosted object model, resource accounting and root-access hooks**.
It is a hosted vertical slice, not evidence that arbitrary conforming opaque
clients can replace those services. The finalizer registry also has a distinct
managed-callback/root-publication gap.

No code, native/ASDF execution or delegation occurred. All code references below
are to `/tmp/clamsara-list-baseline-1099d62-xzks71ws` (committed 1099). The actual
paper was read from `/home/iskam/src/vibe/Clamsara/paper-v14`; that directory is
absent from the frozen code snapshot. Held live model WIP is discussed separately.

## What paper-v14 assigns to whom

- `chapters/construction.tex:7–12`: Clamsara owns identity, allocation, liveness,
  metadata, barriers and collector state. The host supplies representation,
  location access, roots, coordination, atomics, reservations and diagnostics.
- `chapters/construction.tex:259–261`: the implementation supplies legal virtual
  ranges/reservations; collector spaces choose nursery/mature/metadata/reserve
  geometry.
- `chapters/construction.tex:118–126,318–327`: resources must meet the selected
  representation/capacity/context policy. Simulator arrays and target reserved
  storage are both allowed. Queue contents/invariants remain library concerns.
- `chapters/clients.tex:4–10,83–88`: capability facts are checked; components may
  not infer an unlisted operation. Object-model methods interpret kind/layout
  rules. There is no universal host object layout hidden behind those words.
- `chapters/overview.tex:64–68`: meet the contracts or reject the unsupported
  composition before use. A private example queue/layout is not automatically
  a public extension point.

Thus a selected hosted component requesting a SIMPLE-VECTOR is not, by itself,
a leak. Calling one particular host's implementation-only decoder/accountant
from an otherwise generic construction/runtime path is a different matter.

## Findings: severity and exact scope

### A. High portability limitation: generic construction requires hosted accounting

`src/construction/build.lisp:499–506,673–676` unconditionally sends the bound
object model to the ordinary function `%REGISTER-BOUND-OBJECT-MODEL-AUXILIARY`.
Its only implementation, `src/host/object-model.lisp:2045–2079`, begins with
`%HOST-BOUND-MODEL` and explicitly reads hosted routes, arena/word planes,
descriptor arrays, reference records, handles and stages. A client implementing
only the paper's opaque model generics does not thereby satisfy this call.
It is not a model-dispatched accounting protocol.

Likewise `src/construction/build.lisp:324–330,546–553` requires the global host
accounting functions `%REGISTER-RESOURCE-AUXILIARY` and `%CLOSE-RESOURCE-MANIFESTS`.
The former checks the release capability is `%SIMULATOR-RESOURCE`
(`src/host/resources.lisp:90–101`), not just that the chosen resource handle
satisfies its declared representation and capacities.

**Scope qualification:** `construct-plan` explicitly rejects any profile other
than `:SEQUENTIAL-HOST` at `build.lisp:598–610`; the host provider also explicitly
restricts its policy at `host/resources.lisp:12–19,49–68`. These are disclosed
limits. They do not establish that every opaque model/resource supplier which
can meet sequential-host semantics is supported. This is not evidence of a
corruption bug in the existing hosted runs, or a claim of undisclosed full
conformance (`docs/migration.md:30–31` expressly disclaims it).

### B. High portability limitation: allocator/collectors call hosted representation DEFUNs

These are concrete call chains, not a name-count argument:

| Caller | Forced hosted function | Concrete assumption |
|---|---|---|
| `runtime/allocation.lisp:68–85` | `host/object-model.lisp:1134–1154`, `RUNTIME-OBJECT-ALLOCATION-REJECTION` | bound hosted model/kind, hosted size/offset rules |
| `runtime/spaces.lisp:338,568`; `runtime/generational.lisp:304,330,505` | `host/object-model.lisp:1955–1963`, `RUNTIME-START-REFERENCE` | address-to-base decoding through hosted route/descriptor/base-reference tables |
| `runtime/allocation.lisp:119`; `runtime/spaces.lisp:312,376–377,622`; `runtime/generational.lisp:490` | `host/object-model.lisp:1965–1985`, `RUNTIME-RETIRE-OBJECT-REPRESENTATION` | HOST-REFERENCE accessors and clearing hosted descriptor planes after start-map removal |

All three are ordinary DEFUNs, not methods selected by a client's model. Merely
implementing the public initialize/copy/normalize/scan operations cannot replace
them. Some are labeled private hosted bridges in their own source; that label is
accurate, but their callers extend the hosted dependency into the runtime and
collectors. `clamsara.asd:50–58` loads runtime over host-base; the top-level system
also loads the hosted object model at `70–83`.

These calls do not import Maclina's VM or decide Lisp LIST semantics. They are
representation/backend coupling and need to be treated as such.

### C. High integration limitation: ordinary root exposure requires private host access

The stock store path is:

1. `host/roots.lisp:291–297` validates token/location and calls STORE-PROVIDER-ROOT.
2. `runtime/finalizers.lisp:397–411` checks context/selected root-client and enters
   the composed `:ROOT-STORE` operation. Its client specializer is T.
3. `runtime/barrier.lisp:98–106` reads/writes the location with HOST-ROOT-VALUE
   and its SETF, not a root-client-dispatched raw-access capability.

Those private generics are declared in `host/roots.lisp:9–12`. They are not in
`src/client/roots.lisp` or the paper's client interface. An opaque location whose
client implements all stated root operations still needs this additional hook
(or another integration of the composed path) to use the stock route. The client
argument cannot change dispatch at the raw access step: that helper receives the
location and calls the private location accessor.

The finalizer provider reinforces that concrete pairing: its private location
class implements HOST-ROOT-VALUE/HOST-ROOT-KIND at `runtime/finalizers.lisp:4–24`
and registers these locations at `179–198`. The workload provider implements the
same host hooks at `workload/roots.lisp:250–259`. This works as a concrete hosted
provider/root-service agreement; it is not a public obligation on every client.

**Do not replace this with ordinary LOAD-ROOT/STORE-ROOT calls.** Paper
`clients.tex:278–292` reserves those operations for an active snapshot callback.
The committed host correctly enforces that at `host/roots.lisp:316–329`.
Ordinary root-store also must not recursively re-enter itself or bypass the
composed reservation/transform/single-exposure path.

This is source-proved dependency, not a newly executed opaque-client failure.
A future native witness must separately prove what can construct, what fails
before access, and what extra private hook the stock path requires.

### D. High correctness/contract gap if managed finalizers are claimed

Paper `clients.tex:373–390` requires allocated local referent, callable managed
callback, configured root/barrier writes and writable callback roots.

The committed registry checks the referent against the model/start map
(`runtime/finalizers.lisp:210–227`), which is correct. But registration only tests
FUNCTIONP for the callback (`229–239`). It then directly stores CALLBACKS while
setting SUPPORTS NIL (`251–256`). Its root locations read REFERENTS or SUPPORTS,
not CALLBACKS (`12–24,195–198`). Drain later performs native FUNCALL on CALLBACKS
(`380–388`). There is no ordinary root-store call in that registration path.

Consequently the source supplies no managed callback/capture ownership through
those callback root slots, and native FUNCTIONP is not that ownership proof.
Host closures used merely for native test bookkeeping do not validate managed
callbacks. A host closure capturing a guest encoded reference is a relevant
future negative witness; no such run was performed here.

The source itself says “managed-callback admission remains open” at line 1.
Keep this as the documented hosted-registry limitation, not a claim that the
paper allows arbitrary native callbacks or unrooted captures. **The solution is
not to teach the core to decode Maclina closures.** Admission/invocation/root
ownership must be justified by the client integration and existing contracts,
or the unsupported composition must be rejected.

## Counterexamples: choices that are in the right layer

1. **Representation/scanning is normally dispatched correctly.**
   `runtime/trace.lisp:216–237` uses VALID-REFERENCE-P, NORMALIZE-REFERENCE,
   REFERENCE-ADDRESS and REBUILD-REFERENCE. `249–254` uses model-dispatched
   location load/store. The object-start map stays authoritative. Those paths
   do not inspect a Maclina function, VM stack or guest cons layout.

2. **Collector root correction uses the proper snapshot path.**
   `runtime/cycle.lisp:492–503` acquires WITH-ROOT-SNAPSHOT under completed
   coverage; `runtime/trace.lisp:239–247` calls LOAD-ROOT/STORE-ROOT there. This is
   a correct counterexample to the ordinary-root raw-access dependency above.

3. **Declared vector storage is not a hidden universal representation.**
   `runtime/records.lisp:398–421` declares `:RUNTIME-OBJECT-VECTOR` and
   `:RUNTIME-INDEX-VECTOR`; `432–458` checks those handles and builds fixed views.
   `metadata/metadata.lisp:568–592` similarly selects packed/scalar/forwarding
   vector representations and checks their concrete handles. The selected host
   provider provisions those exact offers (`host/resources.lisp:62–88`). These
   are concrete component/backend choices. Arbitrary replacement storage must
   satisfy the selected representation or use another admitted component; a
   SIMPLE-VECTOR check alone does not violate the paper.

4. **The concrete host model owns its word ABI.**
   `host/object-model.lisp:404–411,1408–1417` admits its reference encodings and
   symbols/fixnums/characters/single-floats in represented reference words, with
   a narrower numeric-word rule. `904–906` recognizes its HOST-REFERENCE values.
   This does not mean every Common Lisp object or every descriptor token must
   fit that hosted guest-word representation.

5. **Maclina-specific roots and policies are in the optional workload adapter.**
   `workload/roots.lisp:284–328,331–425` knows the VM/control classes and actual
   physical source slots. That is client root-provider knowledge, not collector
   scanning. `workload/setup.lisp:43–94` selects the hosted clients, 32-byte CONS
   kind, CAR/CDR offsets and indexed arrays. Those choices bind this test client.
   `workload/protocol.lisp:169–205` openly uses its private hosted indexed resolver;
   it is not a universal model operation.

6. **The Lisp operation wrappers do not replace global CL definitions.**
   `workload/maclina.lisp:62–85` installs through the current Clostrum environment.
   Compiler hooks at `workload/control.lisp:159–182` only emit workload cleanup
   when the current client is WORKLOAD-MACLINA-CLIENT. The adapter necessarily
   implements glue for managed operations, but that is different from core
   collector dependence on their semantics.

`clamsara.asd:190–201` makes Maclina/Clostrum/Trucler dependencies optional under
`clamsara/workload`; the core system has no dependency back to it. The source-name
locator found no direct Maclina/Clostrum/Trucler/workload symbols outside
`src/workload`, and the call paths above give the semantic evidence. Shared
exports of host constructors in `src/package.lisp:17–30` are API co-location,
not proof that the collector understands a VM.

## Held live WIP: separate domain, separate status

The live `src/host/object-model.lisp` differs from committed 1099 and was not used
as the audited implementation. Its new `%HOST-DESCRIPTOR-ATOM-P`,
`%HOST-LOCATION-IDENTITY-P` and `%HOST-COPY-NAME-VALUE` are at live lines
252–314. They add identity/name type/shape restrictions. They are held WIP, not
committed defects or validated results.

The guest raw-word ABI and construction descriptor identity/name domains are
different. Paper `clients.tex:90–112` requires non-NIL EQL identities, stable
keys and no hidden managed references in descriptor tables. It does not derive
those identity types from the guest word-plane whitelist. For example, an inert
opaque identity token need not be a guest value stored in an object field.
Conversely, permitting a metadata name to contain a host cons does not permit
that cons as a guest payload or authorize scanning it as a root.

A concrete descriptor grammar/inertness or ownership restriction must be
justified on its own interface/capability terms. If the intended paper contract
requires a broader token domain, flag that mismatch or clarify the seam; do not
quietly turn the held whitelist into a universal Clamsara argument policy. No
WIP change is proposed or approved by this audit.

## Next-step requirements — not an implementation proposal

- State which hosted combinations are admitted and which public-looking paths
  still require private backend integration. `:SEQUENTIAL-HOST` alone does not
  establish arbitrary opaque-model support.
- For each model bridge, identify an existing paper operation or justified
  private ownership handoff. Address-to-base reconstruction and representation
  retirement need particular care. Do not blindly turn the three DEFUNs into
  new required public generics without specification authority.
- Preserve exact model/configuration/resource accounting. Replacing the hosted
  traversal with an empty default visitor would lose retained storage and is
  not a boundary repair.
- Resolve ordinary root raw access without misusing snapshot-only operations,
  recursively calling the public root store, or bypassing the configured barrier.
  Keep token/generation validation and bounded single exposure intact.
- Resolve managed finalizer admission, callable lifetime and writable callback
  roots without importing Maclina/CL closure decoding into the collector.
- Only after a concrete seam is agreed, use a bounded native opaque-model/root
  client witness to test admission and operation paths. That future evidence
  must not be described as already obtained by this source review.

No full paper, benchmark, target/supervisor or generic-client acceptance claim
follows from these findings. LIST design extension stopped when the task pivoted;
its saved report is separate. Settled MAPC evidence and counts are unchanged.
