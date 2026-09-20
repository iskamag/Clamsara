# Independent whole-canonical-code-row acceptance tests

## Result and artifacts

The corrected suite is **RED against frozen `9dd8629`**:

```
108 cases; 44 pass; 64 fail; process exit 1
```

This is an acceptance suite, not a counterexample-observation script that treats
a defect as success. Each case asserts the proposed requirements. The runner
continues after individual failures to report the matrix, then signals an error
if any case failed.

Final runner: `bootstrap-02.lisp`.
Sources: `fixture.lisp`, `cases.lisp`, `generational-02.lisp`.
Native log: `native-red-02.log`.
Directory: `/tmp/clamsara-description-review-7p14doks/independent-review/variant-capacity/row-acceptance/`.

The runner prepends the frozen ASDF registry and asserts the exact selected
`:clamsara` source directory. It loads real quality support and the optional
real generational runtime. It does not load or modify the live implementation.
All 41 frozen source hashes match before and after. Earlier variant reports and
probes remain unchanged. The exclusive native slot was explicitly released.

## RED cases: 64

Eight configurations cover SemiSpace/MarkSweep × packed/scalar start maps ×
16/8-byte object-start granularity. The allocation quantum remains 16 and each
space extent remains 512. C is checked against the actual installed descriptor
plane length; representation capacity covers the complete domain.

Each configuration tests:

| Offer H | Required behavior | Frozen result |
|---|---|---|
| 0 | Bind base-only; reject nonbase creation atomically; collect base graph | constructor rejects H=0 |
| 1, C−1 | Reject at binding and unwind real resources/layout | construction incorrectly succeeds |
| C, 2C−1 | Admit one canonical code; reject a second before changes | second code incorrectly succeeds |
| 2C, 2C+3 | Admit two codes; reject a third; tail buys no row | third code incorrectly succeeds |

These are 56 failing cases. The first code is tag 1; descriptors `#x20000001`
and `#x20010001` must return the same record and leave state unchanged. The
second code is interior displacement 8. A third tag tests the unusable remainder.
Successful rejection is followed by real rooted graph collection, so rejection
must not damage later existing-code movement. Those post-rejection paths cannot
execute on the old implementation because it incorrectly returns a new value.

Eight further cases first create displacement 24 while another cell holds a
16-byte object. They retire that temporary model-test object, create a 64-byte
object at the same address, and rebuild the original code. SemiSpace also tests
an initially inactive reserve destination. These positive operations succeed on
the frozen source. The final assertion requires a different code to reject with
H=C, even though some cells near fixed range ends cannot fit displacement 24.
That assertion fails on the old sparse-per-address pool.

## Passing controls: 44

- **16 ordinary histories:** tagged/interior roots through three real cycles,
  both algorithms/maps/granularities. Check exact encoding roundtrip, canonical
  descriptor, expected moving/stable base history, parent/child IDs 501/502,
  real strong edge, and raw payload bytes `#xA7`/`#xB3`.
- **10 all-cell tests:** two passes across every descriptor cell with tag 1 and
  interior displacement 1, H=2C. Include reserve cells, address reuse, exact
  record identity, aliases, and unchanged historical address fields. These use
  public model initialization and explicit authoritative metadata publication;
  they are model-domain tests, not a claim that the ordinary allocator places
  objects at every finer-granularity cell.
- **8 staging histories:** reconstruct an admitted interior form for an
  initialized but unexposed destination; require normalization to reject before
  publication. Copy a real object to staging, rewrite its strong child edge to
  the admitted form, install, publish, and root the actual returned destination
  reference. Verify both staged graph and unchanged source graph. Successful
  temporary model destinations are explicitly retired before three real source
  graph collections and normal teardown.
- **4 builder-observer controls:** an independently insufficient representation
  offer C−1 provokes the existing real binding rejection. Verify acquired
  resource release, reverse transaction order, release-capability states, failed
  configuration/released context, and removal of the actual installed layout.
  Thus the rejected-H tests do not rely on an unexercised observation fixture.
- **2 mixed-granularity histories:** 8-byte source-map and 16-byte reserve-map
  granularity, C=96, through real semispace flips. The other two mixed cases are
  already counted in the ten all-cell tests.
- **4 optional generational histories:** packed/scalar × tagged/interior. Offer
  exactly C=192 across both nursery ranges and mature storage. Both parent root
  and real strong child edge retain the form during nursery-to-mature promotion,
  a second minor, and a major. Movement is 2/0/0; IDs, payloads, exact encodings,
  and mature-domain addresses remain correct.

The history/staging/generational controls execute 90 explicitly checked cycle
bodies, in addition to ordinary successful fixture teardown. All 44 successful
cases discharge normally. No run uses a replacement collector or model method.

## Independence and failure atomicity

Only existing hosted-private descriptor integers are used as reconstruction
inputs. No assertion implies that portable clients may manufacture opaque
protocol descriptors. Only actual admitted `rebuild-reference` results enter
registered roots or managed slots.

The suite does not inspect a code-to-row directory or require its representation.
Failure snapshots use existing hosted diagnostics: arena bytes, Lisp-word plane,
size/alignment/kind/generation/count planes, live/variant counters, and scalar
fields of all preallocated base/variant records. This detects field changes even
when a record keeps EQ identity. It deliberately does not claim a proof about
unobserved private directory internals or concurrent publication.

Lifecycle observers specialize only three test-owned subclasses: offered model,
client aggregate, and address-space client. They only observe real inherited
methods. They do not install colliding methods on existing production
specializer lists or replace primary effects. Parent may adapt observation to
its shared harness without adopting any new runtime representation.

On failure, worlds are kept in `*preserved-failures*` until the final process
error. Their real roots are not cleared and they are not force-closed. The final
run keeps 56 such worlds; H=0 fails before world creation. This is process-local
preservation, not a saved Lisp heap image. No unexpected returned reference from
a failed capacity assertion is placed in a root.

## Preserved test correction and limits

`bootstrap.lisp`, `generational.lisp`, and `native-red-01.log` preserve the first
run: 40 passes, 68 failures. Four extra failures were my mistaken requirement
that a second minor rediscover both already-mature objects. The collector had
completed correctly. `generational-02.lisp` instead checks the real graph after
every cycle and the correct movement history. The second minor reports zero
discovered; the major reports two. No implementation behavior was suppressed.

High-address/non-fixnum rejection is not tested: this simulator restricts address
width to at most 60, which already fits this 64-bit SBCL's fixnum address domain.
No artificial provider or private geometry mutation was introduced. Target
supervisor admission, concurrent/interrupted row publication, and fault-injected
mid-row rollback remain separate proof/gate work. This RED run does not validate
the parent's unpublished repair.
