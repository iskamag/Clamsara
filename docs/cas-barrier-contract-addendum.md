# CAS contract addendum — repair boundary after independent review

Current scoped result: independent176 PASS and source-only184-case integration
ACCEPT; parent exact-staged full/184/176/repeat184 PASS (PID13509). See
`cas-barrier-final-review.md`, `cas-barrier-integration-review.md` and
`cas-barrier-integration.md` for exact revisions, failures and remaining limits.
The progress notes below retain their historical scope; they are not blanket
admission of opaque authors, the held model changes, benchmarks or Mezzano.

The earlier `cas-barrier-repair-design.md` remains a proposal. Its two-reserve
READ+CAS model and blanket recoverable pre-effect exception handling are not
accepted contracts. See the unchanged independent source/spec report in
`cas-barrier-contract-review.md` (actual frozen paper,41 production hashes and
14 TeX hashes checked; no native test claim by that review).

## Clear implementation repairs

- Traverse disjoint READ/CAS contributors in frozen contribution order for
  before exposure (`execution.tex:182-186`), not all READ then all CAS.
- Cancel write-only mismatch reservations in reverse order (`166-178`).
- Keep a context's invocation scratch owned before any clear or reserve. A
  same-context nested entry cannot alter outer ownership. This is private
  machinery, not a new protocol or concurrency proof.
- Detect abnormal exits with unwind protection, including THROW, on matched and
  mismatched CAS, reads and stores. A caught hosted diagnostic cannot reopen
  allocation, binding or collection after an exposure fault.
- Use a distinct closed fatal state, not a fabricated retained collection or
  stop token. Preserve unresolved reservation/context ownership; do not release
  it as if ordinary cancellation undid published effects.
- Protect active context scratch against unbind, and prevent a safepoint or
  ordinary managed allocation while a live protected invocation retains it.

For disjoint subscribers the current composer admits EQL event-specialized
methods. Sending READ-only reserve/admit :CAS while its later methods receive
:READ contradicts that admitted route. A consistent selected-event convention
repairs this source mismatch. The paper calls the argument OPERATION without an
explicit outer-operation-versus-path definition. That wording gap is reported,
not falsely quoted as an explicit keyword mapping or a new portable promise.
Likewise the text explicitly orders BEFORE; using the same order for AFTER is
consistent with the single contribution order, not a separate quoted sentence.

## Do not invent dual-subscriber semantics

`execution.tex:166-178` describes a union but does not choose one versus two
reserve calls for a dual READ+CAS contribution, shared consumption, callback
cardinality/tie order, or mismatch settlement. A shared token might internally
aggregate work; two independent calls might exhaust an author's valid one-entry
compound reservation. The cancel operation has no event argument. Neither
model can be assumed for every opaque author. Under `reading.tex:48-51`, report
this gap and reject affected construction before publication until resolved.
Do not double claims or provision2N to make an invented contract appear valid.

## Pre-effect fault handling is not an invented retry path

A returned :RETRY is failure-atomic for its failing reserve and lets the driver
reverse-cancel known prior tokens. Arbitrary ERROR/THROW before a reserve returns
a token is not proved to leave no unknown state. Unexpected statuses or exits
must not become retry or reopen the heap on that assumption. A runtime violation
with unknown state requires invariant-fatal handling. No generic cleanup may
cancel effects after exposure or call a consumed reservation a second time.

The planned private lifecycle must distinguish recognized retry/success from an
unknown abnormal exit; retain ownership on fatal; and make normal completion
consume/cancel each owned reservation once. Counter/flag and record growth must
be accounted. No new public operation is needed for that machinery.

## Current native evidence

Parent baseline: `/tmp/clamsara-cas-boundary-red-5tso_czk/`.
`bootstrap-02.lisp` selects the actual ASDF source; `cases-02.lisp` uses real
builder-composed rules, managed source/old/new objects and genuine roots.
A fixed384cell symbol-only observer replaces the first runner's host-cons log.
Original files are preserved separately. No target/no-allocation conformance is
claimed for the harness or runtime.

The strict bounded-observer run (launcherPID9654, SBCLmain-threadtid9656, exit1,
0.646561s) fails8/8 cases and retains8 failed worlds. It demonstrates global
before-order inversion, forward mismatch cancellation, mismatch ERROR and matched
THROW not poisoning, same-context reentry erasing ownership, unbind during an
active callback, successful allocation after an exposure fault, and an admitted
EQL READ method receiving the wrong reserve operation. Source/test/ASDF pins are
unchanged. The first runner also failed8/8, but its allocation behavior is not
used as bounded-observer evidence.

## Uncommitted implementation and scoped verification

The runtime now has one scratch owner per context and a plan pin count, with
recognized retry/success settlement and a distinct sticky fatal state. It uses
N existing contribution slots, not two independently invented event lifecycles.
Dual READ+CAS construction rejects. Ordinary allocation, binding, collection,
raw allocator/refill and finalizer entry cannot bypass a live pin or fatal
closure. Fatal shutdown retains the real resources without a fabricated GC
cycle. These are hosted implementation changes, not Mezzano admission.

An independent baseline added94 histories (58pass/36fail). Parent replay of the
unchanged cases on the draft passes94/94: PID10497 exit0,2.396640s, zero failed
worlds and23 deliberately retained expected-fatal worlds. The parent8 cases
also pass, with3 expected-fatal worlds retained separately. The first component
run passes main/tools/workload/288 generational cycles/structure: PID10603 exit0,
5.934212s. Each run has unchanged source pins. These are different drafts, not
a final reviewed revision. The later combined run, PID10716 exit0/6.314711s,
passes that full component gate plus the unchanged94 independent and8 parent
histories on one pinned six-file draft. It retains23+3 expected-fatal worlds,
with no failed worlds. Frozen independent repair review is now pending.
Existing deliberate tool/workload diagnostics are not a new clean-warning claim.

The new tests are not yet integrated into ASDF. Extra raw/finalizer-entry tests,
real resource-claim union coverage, storage accounting and frozen repair review
remain to be completed. Fixed ownership-marker tests do not prove resource
capacity or target no-allocation behavior. See the unchanged independent
baseline report in `cas-barrier-independent-baseline.md`.

The indexed/name/handle quota/domain work remains separately blocked and
uncommitted. CAS success will not establish those contracts, current benchmarks,
or Mezzano admission. Nothing in this repair is committed yet.

## Frozen repair review found a shutdown result defect

The first six-file frozen review passes155/156 histories but fails the precise
fatal shutdown check (PID11176 exit1). The earlier no-release assertions were
not enough: `:RETAINED` is reserved for a recoverable retained movement/image
obligation (`construction.tex:391-394`). The draft returned it for an
irrecoverable barrier fatal and changed configuration/construction state from
:PUBLISHED to :CLOSING. Resource release remaining0 does not validate that
return contract. Original logs and the failed frozen revision remain intact.

The live correction rejects post-fatal shutdown with the existing
`:FATAL-INVARIANT` runtime reason before changing shutdown state; defensive drain
also rejects. It preserves existing fatal closure, roots, pins and resources,
without reporting a recovery result. Parent PID11332 exit0/8.300596s passes the
full component gate, the first102 integrated histories twice, and all156 unchanged
independent histories. The precise check now observes :REJECTED/:FATAL-INVARIANT,
unchanged :PUBLISHED configuration/construction and release0->0. The old phrase
“fatal shutdown retains” above must not be read as permission to return the
recoverable `:RETAINED` status. The later62-case permanent integration still needs
native validation; independent final repair/claim/transform review is running.

## Later result: final independent and permanent-suite verification

The earlier pending paragraphs record earlier drafts. They are superseded by
`cas-barrier-final-review.md` and `cas-barrier-integration.md`:

- Final independent176/176 PASS, PID12020. This clears the narrow fatal-shutdown
  defect and adds actual acquired-pool/public-claim and rooted transform/GC proofs.
- Permanent184 histories, full components, unchanged archived176 and repeat184
  PASS, PID12601. The two integration mistakes remain documented with their logs.
- The CAS-only a3a0bae candidate excludes blocked model/indexed changes. Its full
  native verification and source-only integration review are still pending.

The private plan pin is included in measured construction storage. Post-bind
context state and its N/N vectors are measured separately, not folded into the
immutable account. This does not establish aggregate dynamic-context accounting.
Opaque NIL-probe admission, OPERATION wording and Mezzano synchronization,
residency and supervisor allocation freedom remain open. The actual claim tests
are not a proof of optimal admission for all mutually exclusive event sets.

The later CAS-only candidate now also passes: PID12981 exit0/16.430080204s,
full components +184 permanent +176 archived +184 repeat, with unchanged pins.
See the integration report for exact12-file partition, preserved harness failures,
warning scope and separate documentation packaging. The held indexed/name/ledger
changes are absent from that candidate. Scoped source-only integration review is
separate from this parent-native result.
