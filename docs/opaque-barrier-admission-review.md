# Opaque-reservation method admission: source review

## Finding

**Confirmed source defect.** A contribution may implement its reservation using
its own preallocated class and specialize its execution methods on that class.
The current builder rejects such otherwise valid methods because it substitutes
`NIL` for the unknown reservation. It also mistakes auxiliary-method presence
for an executable standard effective method.

Reviewed immutable input: `/tmp/clamsara-cas-staged-yik9o9qk`. This review did not load, compile or
execute Lisp, modify live/frozen sources, acquire a native slot, or delegate.
The **115 production/test/ASDF/paper file hashes** are recorded in
`source-pre-sha256.json`. New artifacts are confined to this review directory.
The cases below are **source-authored, not executed**.

## 1. What the paper permits and requires

- `overview.tex:36-40`: components implement their behavior through methods;
  one component's private representation is not another component's interface.
- `reading.tex:56-62`: unspecified private records, layouts and data structures
  are implementation choices. They are not additional public extension points.
- `construction.tex:95-100`: opaque contributions need their applicable
  description methods; no prescribed record class, layout, accessor or subclass
  is required.
- `execution.tex:129-141`: RESERVE returns a reservation. ADMIT, TRANSFORM,
  BEFORE, AFTER and CANCEL receive that reservation. No representation or
  requirement to accept a dummy `NIL` reservation is prescribed.
- `execution.tex:166-172`: reservations contain no location or managed reference;
  reserve is failure-atomic on retry, and completed reservations cancel in
  reverse order. Claims cover simultaneous ownership.
- `execution.tex:174-189`: the real reserved token reaches admission,
  transformation, exposure and terminal consumption/cancellation; the failure
  boundaries still apply.
- `construction.tex:143-153`: construction checks execution methods and claims
  before binding the immutable barrier. Removing all checks is not the repair.
- `construction.tex:188-217`: validation precedes publication; unsuccessful
  construction deactivates initialized components and unwinds real acquisitions.

The paper calls the **contribution** opaque explicitly. It does not name a
required reservation record/type: the reservation's representation is an owner
choice subject to its stated content, lifetime and behavior requirements.
An author-owned token class with a contribution-owner field and an active bit
can meet those requirements. Its class need not accept `NIL` as an instance.
It can be allocated before entry, returned by RESERVE, and consumed through
methods owned by the same contribution author. CLOS specialization itself does
not imply dynamic allocation of a token during entry.

This differs from specializing on another component's undocumented private
context/location/model record merely because the current implementation uses
that record. The latter creates a cross-component representation dependency,
not a portable protocol entitlement. Do not confuse the two cases or use the
foreign-representation restriction to ban an author's own token class. A
separately declared host/profile contract would be a different scope.

## 2. Exact false rejection

`src/runtime/barrier.lisp:32-35` says contribution methods must accept opaque
arguments and uses `NIL` as a probe. That comment invents a restriction absent
from the paper. Being opaque to the driver does not mean having the type NULL.

`make-composed-barrier:36-51` calls `COMPUTE-APPLICABLE-METHODS` with these
arguments (positions below are zero-based):

| Phase | Probe arguments | Real known positions |
| --- | --- | --- |
| RESERVE | `(actual nil event nil)` | contribution 0, event 2 |
| ADMIT | `(actual nil nil event nil)` | contribution 0, event 3 |
| BEFORE | `(actual nil nil event nil nil nil)` | contribution 0, event 3 |
| AFTER | `(actual nil nil event nil nil nil)` | contribution 0, event 3 |
| CANCEL | `(actual nil)` | contribution 0 |
| TRANSFORM, only for `:TRANSFORM` | `(actual nil nil event nil nil nil)` | contribution 0, event 3 |

For example:

```lisp
(defmethod barrier-contribution-admit
    ((rule owned-rule) (reservation private-token) context operation location)
  ...)
```

Suppose broad RESERVE returns this author's valid preallocated `private-token`,
and all other required phases exist. The constructor first finds RESERVE. At
ADMIT it asks whether the method applies to `(rule NIL NIL event NIL)`. It does
not: `NIL` is not a `private-token`. With no broad fallback, the method list is
empty and `:MISSING-BARRIER-EXECUTION-METHOD` is signaled. The real RESERVE is
never called, and no real token is inspected. ADMIT cannot repair this result.
Specializing BEFORE, AFTER, CANCEL or TRANSFORM alone produces the same defect
at that phase; the current probe order checks TRANSFORM last.

`src/construction/build.lisp:468-474` wraps that runtime rejection as
`:BARRIER-COMPOSITION-SIGNALED`, preserving the cause and contribution paths.
Composition is assigned before `%configuration-barrier-bound-p` becomes true
(`build.lisp:677-682`), so a composer error must leave it false. The enclosing
construction unwind is at `build.lisp:643-647` and the paper's rollback contract
is `construction.tex:206-217`.

The converse matters too. A method specialized on NULL can pass the NIL probe
and fail for the actual non-NIL token. A broad primary that signals, or invokes
CALL-NEXT-METHOD without a valid next method, can also pass. The current probe
is neither necessary nor sufficient for actual effective execution.

## 3. Minimal correction, with an honest boundary

Replace fabricated-value applicability with a **private, construction-time
necessary signature check**. Do not add a public declaration, registration API,
prototype reservation, sample-token provider, compulsory superclass, dummy NIL
fallback, or author obligation to accept arbitrary foreign values.

For each described event and required phase:

1. Inspect that generic function's method metadata using a construction-host
   adapter. Construction may allocate and use CLOS (`overview.tex:54-57`).
2. Keep candidate methods compatible with the **actual contribution** and, when
   present, the **actual described event** at the positions in the table.
   Respect both class/inheritance specializers and EQL specializers. A class
   need not match by exact class identity; the actual can be a subclass. A
   contribution itself can be an opaque EQL-specialized value, not only a
   standard-object instance.
3. Leave reservation, context, location and value positions **unknown**. Do not
   replace them with NIL, T, a universal dummy object, a guessed class, or a
   token borrowed from a different phase/author. For this necessary test,
   restrictions on unknown positions do not establish incompatibility.
4. For the presently declared **STANDARD** generic functions, require at least
   one primary candidate compatible with those known positions. Auxiliary
   methods alone do not supply the required primary.
5. Preserve per-event checks. For example, an EQL `:STORE` method cannot support
   the only declared `:READ` event. Preserve the existing conditional requirement
   for TRANSFORM: an observing rule need not implement it. CANCEL has no event
   parameter. Keep the unrelated dual READ+CAS ambiguity rejection unchanged.
6. Reject an absent compatible primary with the existing stable missing-method
   reason and normal construction wrapper/unwind. An unavailable host
   introspection capability is not evidence that an author's method is missing:
   report an unsupported admission capability rather than misdiagnosing it.

This is a small repair to a false structural rejection, **not a proof of complete
admission**. ANSI CLOS does not provide a portable wildcard-valued partial
`COMPUTE-APPLICABLE-METHODS` call or a portable all-method enumeration interface.
An implementation-specific method-metaobject adapter is an internal host
construction mechanism, not a new contribution contract. It must not become
runtime supervisor dispatch or an implicit SBCL-only target claim.

A primary surviving this filter is only a possible method for unknown argument
positions. The filter does not establish that the RESERVE result domain overlaps
every later method domain, that an effective method can execute, that a method
body is non-failing, that all applicable auxiliaries are safe, or that the entry
allocates nothing. For example, a primary on token A and an around method on
disjoint token B do not provide a primary for B. Independent per-phase candidate
existence cannot infer that RESERVE never returns B. Neither a union of
specializers nor a single fabricated/prototype execution proves coverage.

The component/host still owns its existing behavioral validation and target
admission duties. If those cannot be established, retain the limitation or
reject the affected unsupported construction with an accurate reason. Do not
rename this necessary check as proof of them. There is no general complete
method-body/domain proof hidden in method presence, and this review does not
invent a public API to request one.

## 4. Method combination: necessary primary, not sufficient execution

The six `DEFGENERIC`s at `src/runtime/protocol.lisp:33-43` specify no custom
method combination, so ordinary STANDARD combination applies.

The Common Lisp HyperSpec, section 7.6.6.2, states that an applicable method
without an applicable primary signals an error under standard combination.
The reference was fetched as static HTML into
`clhs-standard-method-combination.html` from:
https://www.lispworks.com/documentation/HyperSpec/Body/07_ffb.htm

Therefore a nonempty list returned by COMPUTE-APPLICABLE-METHODS that contains
only `:BEFORE`, `:AFTER` or `:AROUND` is not enough. An around-only body that
would return directly does not waive the standard primary requirement.
Ordinary authors can still compose valid primary, before, after and around
methods; the checker must not require every method to be unqualified.

The parent independently reported a **host-CLOS-only** probe, PID 14391, exit 0,
at `/tmp/clamsara-opaque-admission-probe-zummes5x/mop-semantics.log`. It observed
NO-PRIMARY-METHOD-ERROR for before-only, after-only, all around-only variants,
and the token-B side of a disjoint-primary/around pair. The parent explicitly
corrected its earlier hypothetical around-only wording. That correction is
preserved here. I did not run or independently inspect that native process;
my source conclusion also follows from the fetched standard text.

Custom method combination is a distinct question, not a reason to admit
auxiliary-only implementations of these standard generic functions. Do not
silently apply a standard-primary rule to a truly different combination and
claim general CLOS support. Changing a public generic's method combination is
not exercised or authorized by the acceptance cases here. Primary presence
also does not make CALL-NEXT-METHOD chains, signaling primary bodies, or unsafe
auxiliary bodies valid.

`metadata.tex:44-55` explicitly requires concrete primaries and whole-domain
coverage for metadata. That is useful corroboration of the distinction but is
**not** a blanket new barrier policy copied from another protocol. For barriers,
the current standard generic semantics themselves require a primary; the paper
requires their execution contracts to work.

## 5. Authored bounded acceptance scope

Canonical file: **`acceptance-source-02.lisp`**. It defines an isolated package
and an explicit `run-opaque-admission-tests` entrypoint. Load the existing
`clamsara/quality/support` and this artifact only when native execution is
separately authorized. It changes no ASDF system or production method. No test
runs at file load. Delimiter scans are balanced; **no Lisp reader, compiler or
runtime validation has occurred**, so harness defects may still be found.

**34 histories: 20 positive, 14 negative.**

| Scope | Histories |
| --- | ---: |
| Broad, untyped-reservation control: completion and transform-retry/cancel/reuse | 2 |
| Only one of ADMIT/TRANSFORM/BEFORE/AFTER/CANCEL token-specialized, each with completion and retry path | 10 |
| All five phases token-specialized, completion and retry/cancel/reuse | 2 |
| Subclass instance accepted by the author's token-class specializer | 1 |
| All phases typed with EQL `:READ` events, completion and retry | 2 |
| `:OBSERVE` rule with no TRANSFORM method | 1 |
| Typed primary plus valid before/after/around auxiliaries, completion and retry | 2 |
| Each required phase absent under `:TRANSFORM` policy | 6 |
| Wrong EQL event for each event-bearing required phase | 5 |
| ADMIT has only before, only after, or only around methods | 3 |

The private RULE base has **no execution methods**. Each generated class owns
its complete method set, and a typed phase has **no broad token fallback** that
could accidentally satisfy the old NIL probe. All classes/methods are defined
before any world is built; cases do not add/remove methods around active worlds.
The broad control uses the same real token representation but untyped method
lambda lists, isolating applicability from token contents.

The fixture uses the real shared `make-quality-world :configure-plan` seam,
real SemiSpace plan, ordinary construction/accounting/publication, registered
roots, managed allocation and reference locations. The fixed token, rule,
condition and counter vectors are mapped as actual construction auxiliary
storage. Token state contains no managed reference or borrowed location.
These are fixed private ownership markers, not a new public-resource-capacity
proof or a concurrency claim. Busy reserve returns failure-atomic retry.

Successful histories prove exact primary/callback counters, one real raw load
and no store, observed value, consumption or cancellation exactly once, token
reuse after retry, idle context and zero plan pins. They perform a genuine
post-entry collection and check the rooted `801 -> 802` graph. Entry argument
bindings end before that collection. Valid method-combination cases separately
check all four auxiliary boundary counters.

Negative histories require `:BARRIER-COMPOSITION-SIGNALED` with the nested
`:MISSING-BARRIER-EXECUTION-METHOD`, contributor paths, unpublished/failed
configuration, barrier not bound, released construction and an entirely released
nonempty acquisition log. Construction must not invoke execution callbacks or
reserve a token. Failed worlds and rejected construction evidence stay rooted
in persistent lists across runner repetitions; there is no forced cleanup.
The runner enforces the exact count and zero failures.

`authored-token-probes.lisp` is an optional metadata witness after loading the
canonical cases. It constructs **only this fixture author's own values**, never
executes a barrier method, and compares NIL arguments with those actual tokens.
It distinguishes an empty method list `NIL` from one primary's qualifiers
`(NIL)`. It is **not** a suggested production sample-token interface. It also
has not been executed.

Expected current failure mechanisms are the five token-phase false rejections
and the three auxiliary-only false acceptances. The cases demand intended valid
construction and real behavior; they do not call current rejection a PASS for
the sake of a green baseline. No empirical pass/fail count is claimed yet.
Unknown-domain incompatibility and signaling/CALL-NEXT-METHOD bodies remain
explicit insufficiency examples, not invented signature-only acceptance policy.

## 6. Scope and unchanged holds

This is a bounded correction proposal, not implementation or full admission
conformance. Existing CAS reservation/lifecycle results, disjoint-event
conventions and dual-event ambiguity rejection remain separate. The `:READ`
EQL cases deliberately use ordinary READ, where outer operation and selected
event coincide; they do not resolve the paper's broader OPERATION wording.
No broader model/name/index/ledger/staged-handle, benchmark, concurrency,
allocation-freedom, residency or target hold is cleared. Construction CLOS use
is permitted; supervisor open CLOS and allocation remain forbidden
(`validation.tex:123-141`). Previously established wired-EMFUN Mezzano evidence
is acknowledged but does not validate this new admission code or its lifetime.

Artifacts: this report, `source-evidence.json`, before/after source hashes,
canonical cases and the optional fixture-only probe. No native permission was
requested or assumed.
