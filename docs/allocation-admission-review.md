# Bounded source-only allocation admission review

Snapshot: `/tmp/clamsara-allocation-review-uwn68jjg`, base de22e51 plus five
overlays in `review-snapshot.json`. All five SHA-256 hashes matched. No source or
dependency edits, subdelegation, or native execution. I inspected the supplied
red/green logs; their executions are parent evidence, not my own snapshot run.

## Conclusion

**No new concrete defect found in the requested allocation-validation slice.**
For stable admitted hosted descriptions, the repair moves the reviewed size,
alignment, rounded-charge and fixed-word checks before raw reservation, refill
and automatic collection. This is not approval of complete object-model
admission, description snapshotting, function-rule stability, representation
capacity, or target/no-allocation execution.

## Source checks

### Private model bridge

`src/runtime/allocation.lisp:68-86,126-139` verifies the kind/descriptor identity,
positive integer bytes, requested alignment and route, then calls the private
`runtime-object-allocation-rejection`. Failure returns
`NIL,:FAILED,<reason>` before `%attempt-object-allocation` can change the context's
allocator or reserve storage. No new public protocol is introduced.

`src/host/object-model.lisp:991-1011` owns the opaque description interpretation.
It uses the same `%host-kind-size-count` and `%host-kind-offsets-fit-p` helpers as
initialization, rather than teaching the plan about fixed/variable size-rule
structures. It checks the model's maximum object bytes. Fixed sizes must equal
the rule result; variable sizes must meet header, stride, minimum and maximum
count conditions. Ordinary errors evaluating the size/alignment rules become
the corresponding invalid-request reason. The caller has already established
local kind/descriptor identity before the bridge's private kind lookup.

This is intentionally a hosted bridge, not a new portable model capability.
Other existing hosted runtime bridges already assume that model. The source
still evaluates function rules again during initialization; identity/snapshot
and rule stability are expressly outside this repair.

### Requested alignment

The implemented policy is `kind-required <= requested <= plan-Q`, with all three
positive powers of two. This treats requested alignment as a minimum placement
requirement, not an exact equality to the kind's ABI alignment. A stricter
request is valid; a request weaker than the kind is rejected. Paper-v14
`execution.tex:97-114` requires alignment validation but does not spell out this
inequality; the hosted policy is now stated in the repair documentation.

The actual allocation reserves at plan-Q (`allocation.lisp:95-98`). Positive
power-of-two ordering implies divisibility, so this satisfies both requested
and ABI alignment. The current constructors equate plan-Q with the participating
space quanta (`spaces.lisp:384-388,620-622`; `generational.lisp:183-186`). Thus the
reviewed copying paths keep the guarantee even though the representation stores
the kind's required alignment, not the stronger caller request. No claim is
made for a future heterogeneous-quantum composition.

### Target-domain rounded charge

`allocation.lisp:72-83` checks
`bytes <= maximum - (Q-1)` before computing the charge. The construction maximum
is `2^address-width - 1` (`src/construction/layout.lisp:5-8`); the admitted Q is a
power of two. Hence the maximum Q-aligned charge is exactly `maximum-(Q-1)`.
The check is sufficient, and not an extra one-quantum truncation: it permits the
highest representable charge and prevents overflow of the usual intermediate
`bytes+Q-1`. It does not confuse Lisp bignum support with target arithmetic.

An otherwise valid size larger than a particular space remains a real allocation
attempt that can exhaust normally. It is not mislabeled `:INVALID-SIZE` simply
because it exceeds that space's extent.

### Full fixed reference-word spans

`object-model.lisp:973-989` now checks `offset <= size-8` for every fixed strong,
weak, and both ephemeron words. This is the correct full-span check for the
hosted eight-byte reference word, rather than merely `offset < size`. An object
smaller than eight bytes with no reference locations need not be rejected.

The indexed branch is not this fixed-span change: admitted indexed variable
layouts already tie the header/base and eight-byte element stride together at
kind construction (`:333-351`), and size admission determines the element count.
No generalized construction/layout audit is implied.

## Tests and supplied native evidence

`test/quality/allocation.lisp` contains 38 invalid, six valid and one valid-
exhaustion request per profile, giving **152 + 24 + 4** over SemiSpace/MarkSweep
and packed/scalar maps. ASDF includes it in the main test operation.

Useful strengths:

- Tests call the actual collectors. Around methods record raw/refill/automatic
  collection entry and delegate with `call-next-method`; they are not stubs.
- Invalid cases assert the exact returned triple, no entry to those methods,
  unchanged root/model planes/descriptor generations/allocator/context snapshots,
  and preserved rooted payload.
- Positive controls cover computed rules, variable endpoints, and a request
  aligned more strictly than its kind. The valid-too-large-for-space case must
  enter refill/collection once and return `:HEAP-EXHAUSTED` while preserving roots.
- No callback ERROR-swallowing issue applies to these direct assertions.

`/tmp/clamsara-allocation-admission-red2.log` shows the old positive size=1 request
for the 32-byte node escaping as `Invalid hosted object initialization`.
`/tmp/clamsara-allocation-admission-components.log` contains all four admission
pass markers, the final admission marker, and component/workload/generational
pass evidence. Its expected tools compilation error is not an allocation test
failure. I did not reproduce those runs, authenticate a log-to-source hash link,
or independently infer an exit code from the text alone.

## Small coverage additions worth keeping separate from the verdict

- Test `maximum-(Q-1)` versus its successor. For the current small fixed kind,
  the first should reach kind-size rejection, not arithmetic-overflow; the second
  should report arithmetic-overflow. Existing cases use maximum and larger values.
- Test exact `max-object-bytes` admission alongside the existing over-limit case.
- Add exact-boundary valid weak/ephemeron word spans and a nonzero-offset
  truncated fixed strong word. Existing ordinary quality suites cover many valid
  conditional objects, but the new focused fixture emphasizes the negative cases.
- Literal malformed alignment and stable computed rules are covered; an ordinary
  signaling rule could directly exercise the new handler paths. Do not advertise
  this as testing arbitrary function-rule effects or stability.

The snapshots do not enumerate every metadata/diagnostic field. The no-entry
sentinels and the inspected straight-line bridge support this bounded pre-effect
claim, not a universal proof about arbitrary opaque rule callbacks. As requested,
binding's retained description identities and function-rule stability remain a
separate follow-up. Representation-capacity admission remains separate too.
