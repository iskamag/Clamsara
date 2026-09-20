# Callable managed finalizers: bounded source-only note

Scope: original fixed snapshot `/tmp/clamsara-independent-review-3ygbx_br` and
its paper-v14; registration overlay `/tmp/clamsara-finalizer-registration-review-o4ld9ifa`.
No changing sources/dependencies were read, no native work was started, and no
project files were edited. Queue ownership is not reviewed here.

## Conclusion

**There is no honest registry-only fix in this hosted model.** A callback must
be both a real callable value and a reference to an allocated Clamsara object
whose support graph the model scans and corrects. The current two sets do not
intersect: `host-reference` is a non-callable structure
(`src/host/object-model.lisp:61-67`), and `valid-reference-p` recognizes only that
structure and its owning model (`:784-786`). Adding `FUNCTIONP`, storing an SBCL
function in a root slot, or filling `SUPPORTS` with an environment does not make
the callback itself managed.

The existing public protocols are sufficient *interfaces*. Implementing their
callable representation needs an **object-model/client change**. Supporting
arbitrary guest Lisp/Maclina closures additionally needs a language/runtime
representation and activation-root change. No new public Clamsara invocation
protocol is needed or supplied by v14.

## Explicit requirements

Paper references below are under `paper-v14/chapters/`:

- `clients.tex:373-378`: context-selected composed registry writes; allocated
  local referent; callable managed callback; admission/capacity before exposure.
- `clients.tex:388-395`: at most **2F registry root locations**: callback roots in
  every nonterminal record, plus referent roots in candidate/pending/running
  records. Registered referents are not roots (`:386`).
- `clients.tex:401-407` and `execution.tex:428-435`: invoke
  `(funcall callback corrected-referent)` only in admitted mutator execution;
  retain callback/support before source reuse.
- `clients.tex:128-149,166-182`: model-recognized encodings, authoritative starts,
  reconstruction preserving interpretation, and complete writable layouts.
  Function environments, code constants, class/layout references cannot be
  hidden from scanning merely because the host retains their containers.
- `clients.tex:303-335`: actual execution/root slots must be writable and covered.
  A registry root does not correct an untracked local argument across callback GC.

Consequently, a callback that strongly captures its own registered referent can
keep it live. Delaying callback rooting until pending selection would incorrectly
change that semantics.

## Minimal honest hosted seam — a design choice, not existing functionality

A small, explicitly admitted callable kind is enough; it need not implement all
Lisp closures at once:

1. Allocate a **managed closure payload** through `allocate-object`. Define its
   captures/environment through `make-object-kind-description` and the ordinary
   strong/conditional mappers. Captures live in the real managed word plane, not
   in a native lambda's lexical environment. A finite code identity may select
   a prebound host entry containing no hidden managed captures.
2. Add a **callable reference encoding** for that payload. One SBCL-hosted option
   is a funcallable instance using `SB-MOP:FUNCALLABLE-STANDARD-CLASS` and
   `SB-MOP:SET-FUNCALLABLE-INSTANCE-FUNCTION`. This is a host mechanism, not a new
   Clamsara protocol. Its model/address/form identity and installed trampoline
   stay fixed after publication. It is an immutable reference encoding, **not**
   a proxy whose target slot is rebound when the object moves.
3. A callable tagged form can normalize to the existing canonical start.
   Extend `valid-reference-p`, `normalize-reference`, `rebuild-reference` and
   the model's admitted-value checks so tracing rebuilds a *new callable encoding*
   at the destination. Ordinary copy/scan work can still use the canonical start.
   `copy-object-representation` preserves the closure's actual payload.
   Prepare/charge callable encodings and trampolines before collection; copying
   must not allocate host functions after forwarding. Do not invent a second
   writable allocation map for them.
4. The trampoline may capture immutable administrative coordinates such as the
   bound model and cell identity, but **not guest captures** or a mutable hidden
   self-reference. On entry it validates the managed closure and establishes an
   admitted activation root frame before any safepoint. The runtime roots/reloads
   self, referent argument, captures and live temporaries through existing root
   provider operations. It must reload corrected values after allocation/GC.
   Prebound code can interpret a bounded callback subset; arbitrary native
   callbacks need genuine stack-map/capture coverage, not an assertion.

This requires extending the hard-coded representation paths in
`src/host/object-model.lisp`, not just defining a new object kind. The public
make/describe kind, allocation, normalize/rebuild, scan/raw-location and root
provider APIs already provide the required seams. Construction must admit the
selected callable representation and its work/storage bounds, or reject it.

## Registry integration once that seam exists

Use **one actual callback root slot and one conditional referent root slot per
record**. The slot read for invocation must be the callback slot that `store-root`
corrects. Current provider locations expose only REFERENTS/SUPPORTS
(`src/runtime/finalizers.lisp:11-24`), while registration writes CALLBACKS and
sets SUPPORTS to NIL (`:181-184`); that is not callback coverage. Repurposing the
support root as the actual callback slot is possible. Keeping an authoritative
uncorrected callback copy elsewhere is not.

The callback object's ordinary scanned fields retain all support. An additional
independent support-root plane is unnecessary and would exceed 2F if added to
callback plus referent roots. Historical token records must remain nontracing.

Use `root-provider-store` for public callback-root insertion with the supplied
context, and the existing configured barrier path for conditional registry
record writes. The private `%barrier-store-operation` already has a `:root-store`
route (`src/runtime/barrier.lisp:70-78,163 onward`); it is a mechanism to reuse,
not permission to skip record/location ownership or reserve checks. Active
registered referents must remain conditional, not permanent strong provider
roots. Reserve/validate the whole registration before publication: two separately
fallible stores do not automatically provide failure-atomic registration.
Collector corrections use the existing protected snapshot/closed-commit rules.
This needs a private integration design, not a new public finalizer API.

## What the existing workload adapter does not supply

`src/workload/maclina.lisp:3-7` explicitly distinguishes host Maclina functions
and closures from managed references. `compute-instance-function` extensions
(`:41-52`, `src/workload/control.lisp:42-48`) and
`%call-with-workload-function` (`control.lisp:4-40`) are useful client-specific
invocation/activation seams. They do not make the returned host lambdas managed.
The root provider follows known active/global Maclina control owners and their
literal/environment slots (`src/workload/roots.lisp:266-310,313 onward`), not
arbitrary native closure environments or every deferred registry callback.

Wrapping one of those entries in another host closure, globally overriding VM
FUNCALL, or registering all closure captures forever is not the missing proof.
A deferred callback needs its own reachable managed owner before invocation,
and language call/closure creation must preserve that ownership. Location handles
are nontracing and explicitly do not root their source (`clients.tex:195-198`);
they cannot substitute for callback ownership either.

## Underspecification and narrow acceptance evidence

v14 does not prescribe an SBCL callable encoding, a callable-kind constructor,
or a host-code table. Those are client choices. It also has no public callback
invocation generic or `(callback, support)` registration pair. Changing the
specified FUNCALL contract to accommodate a non-callable reference would require
a specification change, not a registry workaround. SBCL's own GC is not evidence
of Clamsara liveness or writable correction.

Before claiming this seam works, test: a callback and captures with no other
roots survive and move; the corrected callback is still FUNCTIONP and invoked;
callback-triggered GC preserves actual argument/capture uses; cancel/done releases
the graph; a strong callback-to-referent capture prevents premature selection;
plain host lambdas and unsupported guest closures reject; capacities fail before
publication; and composed insertion coverage is observed. Keep queue/at-most-once
repair and target admission as separate gates.
