# CORRECTION: host-layer bridges are not generic dispatch (A.5 narrowed)

Requested factual correction, source-only, first-hand. Preserves `REPORT.md` and
`ADDENDUM-normative-vs-private.md` unchanged. No native command, no code/paper
edit, no delegation. Rev `04bff62db4ef86868dc6d5d917e8704f9d90b62e`.

## C.1 Withdrawal

`ADDENDUM` §A.5 said: "no host concrete name is used in the runtime or metadata
layers — searching `simulator|host-object-model|%host-|make-host` in
`src/runtime/*.lisp` and `src/metadata/*.lisp` returns nothing. Dispatch really is
through client generics." **Withdrawn.** The search only showed that one set of
class/accessor names does not appear as text; it cannot establish that the runtime
does not call host-layer *function* entry points. Substitute evidence was absent.
Rule kept: do not infer replaceability from a missing class `typep`, a missing
name, or an `fboundp` check.

## C.2 Verified three-way classification of what runtime/metadata call into host

(a) **Client-declared generics — dispatch really holds** (declared in `src/client/`,
methods in `src/host/`; the argument that selects the method is the bound model or
the client object):

* object model, all used from runtime: `valid-reference-p` (`src/client/object-model.lisp:11`),
  `normalize-reference` (:12), `rebuild-reference` (:13), `reference-address` (:14),
  `object-size` (:15), `object-alignment` (:16), `object-kind` (:17),
  `object-kind-descriptor` (:18), `map-reference-locations` (:19),
  `map-weak-descriptors` (:20), `map-ephemeron-descriptors` (:21),
  `load-reference` (:22), `store-reference-raw` (:23), `initialize-object` (:29),
  `copy-object-representation` (:30), `reference-encoding-equal-p` (:36).
* finalizers: `map-finalizer-registrations`, `correct-finalizer-referent`,
  `freeze-finalizer-candidate`, `publish-pending-finalizers`
  (`src/client/finalizers.lisp:8-13`; used `cycle.lisp:162,196,408,410,425`).
* metadata offered fields: `describe-metadata-field-offer`, `field-read`,
  `field-write`, `field-cas` (`src/client/metadata.lisp:10,12,13,14`; used
  `metadata.lisp:381-383,607`).
* coordinator: `request-safepoint`, `await-safepoint`, `release-safepoint`
  (`src/client/coordinator.lisp:8-10`; used `cycle.lisp:469,479,433`).
* roots: `with-root-snapshot`, `map-root-locations`, `load-root`, `store-root`,
  `register-root-provider`, `unregister-root-provider` (`src/client/roots.lisp`;
  used `cycle.lisp:502`, `records.lisp:243`, `trace.lisp:244,247`,
  `finalizers.lisp:181,190`).
* diagnostics: `fatal-diagnostic` (`src/client/diagnostics.lisp:6`; used
  `barrier.lisp:114`).

Not a client generic, worth naming so it is not mistaken for one:
`space-of-reference` is declared in the **construction** protocol
(`src/construction/protocol.lisp:145`), method `host/address-space.lisp:150`,
used `cycle.lisp:88`, `finalizers.lisp:220`, `trace.lisp:223`.

(b) **Ordinary host DEFUNs called directly — no dispatch at all.** Merely
implementing the client generics above cannot replace them:

| host definition | runtime/metadata call sites |
|---|---|
| `runtime-object-allocation-rejection` — `src/host/object-model.lisp:1134` | `src/runtime/allocation.lisp:85` |
| `runtime-start-reference` — `src/host/object-model.lisp:1955` | `src/runtime/spaces.lisp:338,568`; `src/runtime/generational.lisp:304,330,505` |
| `runtime-retire-object-representation` — `src/host/object-model.lisp:1965` | `src/runtime/allocation.lisp:119`; `src/runtime/spaces.lisp:312,376,622`; `src/runtime/generational.lisp:490` |
| `%register-resource-auxiliary` — `src/host/resources.lisp:90` | `src/runtime/finalizers.lisp:138,144,168,171,176`; `src/runtime/records.lisp:317,319,464,466,468,470,473`; `src/runtime/spaces.lisp:82,198,482,493`; `src/runtime/generational.lisp:156,168` |

Each of the three `runtime-*` functions calls `%host-bound-model`
(`src/host/object-model.lisp:211-215`), which requires `host-model-bound-p`, and
then reads hosted route/descriptor/kind tables. Add to these the six remaining
name-bound hooks already listed in §A.5 (`make-composed-barrier`,
`%register-installed-layout-auxiliary`, `%register-bound-object-model-auxiliary`,
`%close-resource-manifests`, `%close-configuration-runtime`,
`%drain-configuration-runtime`; `build.lisp:447,483,500,549,725,730`).

(c) **Host-layer generic outside the client protocol:**
`host-root-value` (and its setter) — `defgeneric` at `src/host/roots.lisp:9`,
implemented at `src/host/roots.lisp` for host locations and extended by the runtime
at `src/runtime/finalizers.lisp:12,19` for `finalizer-root-location`; the composed
barrier's raw load/store uses it at `src/runtime/barrier.lisp:100,105`. It is
dispatched, but the host layer owns the generic and the client root protocol does
not mention it. So "dispatched" ≠ "client-protocol surface".

(d) **Host-internal inventory of a concrete representation:**
`%register-bound-object-model-auxiliary` — `src/host/object-model.lisp:2045`
— calls `%host-bound-model` and then walks `host-model-bindings`,
`host-model-routes`, `host-model-arena`, `host-model-words`, `host-model-sizes`,
`host-model-alignments`. The builder calls it by name (`build.lisp:500`). No client
method covers this inventory, so a substituted object model must supply these
names/concrete fields or the builder must be edited.

## C.3 Cross-reference and net effect

`docs/client-boundary-audit.md:71-77` lists the same three DEFUN chains and states
at line 80: "All three are ordinary DEFUNs, not methods selected by a client's
model." Its section C (lines ~94-100) records the `host-root-value` path. My
anchors were checked first-hand against the source and agree with that document;
they are not derived from it.

Net effect on classification: **wider substitution limit, same category.** The
limit is not only concrete classes and client generics but also host-layer function
names and one host-layer inventory. Under `reading.tex:56-62` these remain
permitted private machinery (the paper names none of them), so the items stay
P-choice, not N-violation; the corrected reporting claim is that host integration
is name-bound, not class-bound.

Claim set from §A.5 that still stands, re-checked this turn: profile value
`:sequential-host` required (`build.lisp:601-603`, `host/resources.lisp:51`,
`host/coordinator.lisp:156`); root-client `eq` identity (`trace.lisp:241`);
metadata storage handle/role constraints (`metadata.lisp:590,649,609,643,437,549`;
`spaces.lisp:187`).
