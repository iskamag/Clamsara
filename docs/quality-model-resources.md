# Model, resource, and capacity quality report

## Scope and authority

This report covers the independent regressions in
`test/quality/model-resources.lisp`. The tests load the canonical `:clamsara`
system and `test/quality/support.lisp`. They use the real hosted object model,
metadata stores, address-space installation, construction builder, SemiSpace
runtime allocation, resource manifests, and capacity account. They do not use a
replacement collector or object-model mock.

The checks implement the paper-v14 duties in:

- `paper-v14/chapters/clients.tex:114-209`: authoritative bindings, encoding
  validity, tag/interior reconstruction, borrowed locations, stable handles,
  staged copy, and non-failing admitted install.
- `paper-v14/chapters/metadata.tex:70-106`: charged backing and the sole
  authoritative object-start map.
- `paper-v14/chapters/construction.tex:113-126,163-217`: real capacity,
  ownership, publication, and unwind/account rules.
- `paper-v14/chapters/collectors.tex:33-49`: capacity independent of discovery
  order.
- `paper-v14/chapters/validation.tex:38-57,118-131`: failure atomicity,
  capacity-before-publication, recorded capacities, and the separation between
  hosted correctness and supervisor allocation proof.

No manuscript or benchmark fixture was changed. No production fix was made by
the quality worker.

## Test entry points

```lisp
(require :asdf)
(asdf:load-system :clamsara)
(load "test/quality/support.lisp")
(load "test/quality/model-resources.lisp")

(clamsara.quality.model-resources:run-model-resource-quality)
(clamsara.quality.model-resources:run-model-resource-array-stress
 :element-count 500000)
```

The normal suite uses 4,096 array elements. The separate stress entry uses
500,000 elements and must be coordinated before a memory-heavy run. It does not
reduce the plan trace bound, object-model capacity, resource charge, or declared
space extent to obtain a pass.

## Regression map

`RUN-MODEL-RESOURCE-QUALITY` checks:

1. An opaque encoding is admitted before publication, but cannot normalize
   until its exact authoritative start-map cell is set. Clearing that cell makes
   normalization stale without reclassifying the encoding as an immediate.
2. Integer immediates `1` and `257` are disjoint from opaque references.
3. Base, interior, tagged-base, and tagged-interior encodings normalize and
   rebuild with the exact tag and displacement, including at a new base.
4. Mapper and handle-resolver locations expire at callback return. Immutable
   handles resolve after the original borrow ends and become stale after source
   retirement.
5. Staging rejects insufficient byte capacity before changing its pool record.
   A valid staged install succeeds. A same-kind/different-size mismatch rejects
   before changing destination bytes or words.
6. Insufficient dense representation capacity rejects at binding. Variant,
   handle, borrowed-location and staging pool exhaustion preserves the already
   published state and does not advance the rejected record/cell.
7. Every closed simulator resource reports actual handle/padding/manifest/
   reserve bytes. The immutable account equals its final resource state. One
   object has one manifest owner.
8. Persistent framework and simulator service records have an explicit owner.
   External root-provider payload stays externally owned; the provider token,
   exact location snapshot, directory entries, and directory backing are
   service-owned.
9. Post-publication root registration neither creates unowned service records
   nor grows backing after manifest freeze.
10. Managed-layout and model-binding validation use deterministic operation
    counts, not timing. Adversaries cover unsorted exact-touch intervals, empty
    intervals, true overlap, reusable offers, and duplicate/missing/foreign
    bindings.
11. Managed cons, struct, reference-array, and numeric-array starts use
    precharged base encodings and fixed model planes. Per-guest allocation does
    not replace or resize those planes or change the immutable account.
12. Numeric payload does not retain a boxed host float or arbitrary host
    aggregate. Generic/numeric variable arrays cover every requested element
    with exact callback counts and endpoint lookup.

These tests establish hosted correctness only. They do not prove no allocation,
closed dispatch, residency, or IRQ safety for a supervisor entry.

## Native evidence

### Source compilation

Command (normal project ASDF environment):

```sh
sbcl --noinform --non-interactive \
  --eval '(require :asdf)' \
  --eval '(asdf:load-system :clamsara)' \
  --eval '(load "test/quality/support.lisp")' \
  --eval '(multiple-value-bind (fasl warnings failure)
             (compile-file "test/quality/model-resources.lisp"
                           :output-file "/tmp/model-resources.fasl")
           (format t "~&COMPILE ~S ~S ~S~%" fasl warnings failure))'
```

Actual status: exit 0, `warnings-p NIL`, `failure-p NIL`.

The project diagnostic also compiled the same source through
`clamsara.debug:compile-source`. It reported `:STATUS :OK`, `:WARNINGS-P NIL`,
`:FAILURE-P NIL`, and no compiler conditions. This diagnostic allocates and is
compile evidence only, not an entry allocation/performance proof.

### Linear construction probes

A native exact-call probe on 8 and 16 real routed solutions produced:

```text
N=8  layout-route-calls=8  bind-match-calls=0
N=16 layout-route-calls=16 bind-match-calls=0
```

The former results were 36/128 and 136/512. They exposed
`src/host/address-space.lisp:86-96` as N(N+1)/2 and the old
`src/host/object-model.lisp:493-512` as exactly 2N^2. The current one-pass fixes
are green. The permanent regression also checks overlap, unsorted/exact-touch,
empty intervals, no mutation, reusable install, and binding coverage failures.

### Complete default quality run

Command:

```sh
sbcl --noinform --non-interactive \
  --eval '(require :asdf)' \
  --eval '(asdf:load-system :clamsara)' \
  --eval '(load "test/quality/support.lisp")' \
  --eval '(load "test/quality/model-resources.lisp")' \
  --eval '(clamsara.quality.model-resources:run-model-resource-quality)'
```

Actual status: exit 0. Durable output:
`/tmp/clamsara-model-resources-full.log`.

```text
MODEL-RESOURCE-QUALITY-OK
ELEMENT-COUNT                 4096
OBJECT-BYTES                  32784
SPACE-EXTENT                  66592
FIXED-MODEL-PLANE-BYTES       666672
ACCOUNT-PHYSICAL-BYTES        402240
ACCOUNT-AUXILIARY-BYTES       1593424
REFERENCE-CALLBACKS           4096
NUMERIC-STRONG-CALLBACKS      0
OBJECTS-DISCOVERED/MOVED      2/2
BYTES-MOVED                   65568
```

This run includes every regression listed above. Targeted root history,
guest-residency, manifest/charge, route/binding, and staged-capacity entries also
exited 0 independently. One parallel ASDF startup hit a Quicklisp local-project
index `.bak` race; the same manifest test rerun alone exited 0. That environment
race is not recorded as collector evidence.

## Defects found and resolved during this audit

### 1. Static manifest ownership and actual charges: fixed and green

The first native audit found no owner for clients (112 bytes), plan (256), roots
(96), coordinator (160), address-space client (80), atomics (64), diagnostics
(64), offered model (336), both spaces (176 each), both object-start and
forwarding objects (192 each), or registry (192). The builder and host-static
registrar now assign explicit owners without blanket graph traversal.

At the last stable milestone,
`TEST-MANIFEST-OWNERSHIP-AND-CHARGE` exited 0. It checks the concrete retained
configuration/runtime/service identities, one-owner uniqueness, closed fixed
manifests, discarded construction dedup tables, and equality between recomputed
SBCL primitive storage and every physical/auxiliary capacity entry. External
root-provider payload remains outside the framework charge; root-service records
are covered separately below.

Relevant paths:

- `src/construction/build.lisp`, `%register-builder-tree`
- `src/host/resources.lisp`, `%register-resource-auxiliary` and
  `%close-resource-manifests`
- `src/host/auxiliary.lisp`, host-specific static ownership

### 2. Root registration fixed reserves: fixed and green

The original permitted post-publication path allocated fresh token/location/
entry objects and grew a hash directory after manifest freeze. A native test
first reported a fresh unowned `SIMULATOR-ROOT-ENTRY` of 32 bytes.

`src/host/roots.lisp` now provisions finite historical tokens, root entries,
registration scratch, seen/directory backing, and free links before publication.
The dedicated quality world uses registration capacity 6 and root capacity 64.
Its native regression exits 0 and checks:

- a 70-root request reports `:root-capacity-exhausted` before enumeration;
- invalid enumeration and duplicate identity change no generation, historical
  token cursor, free-entry count, provider slots, or directory entries;
- token, directory, and directory-visible entries existed in the frozen owner
  index and retain one owner;
- unregister invalidates the token; re-register returns a distinct token and
  never revives the old one;
- repeated histories end at `:registration-history-exhausted` with no effect;
- directory primitive storage and immutable capacity account do not grow;
- external provider/location payload remains caller-owned rather than silently
  charged as framework state.

The test does not require the old private per-token locations vector. Shared
flat stores or linked entry pools are valid when their retained state is fixed
and charged.

### 3. Numeric raw-value boundary: fixed for the admitted host profile

The first native probe showed a double-float and arbitrary host cons accepted
and retained directly in the word plane:

```text
FLOAT store=1.5d0 status=:PRESENT reason=NIL raw=1.5d0 floatp=T
CONS  store-eq=T status=:PRESENT reason=NIL raw-eq=T consp=T
```

The stable model now admits `FIXNUM` for `:array-integer` and `SINGLE-FLOAT` for
`:array-single-float`. On the admitted 64-bit SBCL host, the regression verifies
the stored single-float has `SB-VM:SINGLE-FLOAT-WIDETAG`, an immediate word
encoding rather than a separate heap object. Double-float and host-cons stores
signal before changing the underlying word. Callback faults propagate; the
private resolver does not convert them into `:stale`.

The word plane still has element type `T`; its safety comes from the model's
pre-effect value admission, not from a specialized array declaration. The
raw numeric boundary does **not** admit boxed host bignums, ratios,
double-floats, arbitrary host aggregates, or every possible client-defined
numeric type. Those raw values reject. The workload's later managed-bignum ABI
stores fixnum limbs in managed objects; it does not relax this raw-word rule.
This is a narrow, tested boundary, not an all-guest-representations proof.

Relevant path: `src/host/object-model.lisp`, raw-value validation and indexed
numeric resolver.

## 500,000-element native stress

The parent approved one memory-heavy process. The first wrapper invocation did
not start SBCL because `/usr/bin/time` is absent. The direct retry was the only
heavy process started by this worker:

```sh
sbcl --dynamic-space-size 8192 --noinform --non-interactive \
  --eval '(require :asdf)' \
  --eval '(asdf:load-system :clamsara)' \
  --eval '(load "test/quality/support.lisp")' \
  --eval '(load "test/quality/model-resources.lisp")' \
  --eval '(clamsara.quality.model-resources:run-model-resource-array-stress
            :element-count 500000)'
```

Actual status: exit 0. The test was rerun after the root fixed-reserve and
numeric admission changes landed so the recorded capacity total belongs to the
then-current source milestone. Historical log:
`/tmp/clamsara-model-resources-500k-final.log`.

```text
ELEMENT-COUNT                 500000
OBJECT-BYTES                  4000016 (each array)
SPACE-BASE                    4096
SPACE-EXTENT                  8001056 (each semispace)
PACKING-QUANTUM               16
ARENA-ELEMENT-TYPE            (UNSIGNED-BYTE 8)
WORD-PLANE-ELEMENT-TYPE       T
FIXED-MODEL-PLANE-BYTES       80011312
ACCOUNT-PHYSICAL-BYTES        48132992
ACCOUNT-AUXILIARY-BYTES       160282704
REFERENCE-CALLBACKS           500000
NUMERIC-STRONG-CALLBACKS      0
OBJECTS-DISCOVERED            2
OBJECTS-MOVED                 2
BYTES-MOVED                   8000032
```

The test also checked the corrected root and inter-array edge, generic/numeric
endpoint values after movement, and stale source encodings. This is exact hosted
correctness and capacity evidence. The word plane's element type `T` is also why
the separate boxed-float/host-cons negative residency tests remain necessary.

## Dense representation admission update

The common model binder now requires capacity for every installed descriptor
cell, including reserve ranges. This is an explicit tightening of the hosted
profile. The fixed planes already had that geometry; only a missing admission
check allowed a smaller logical ceiling to interrupt copying after forwarding.
The offer is never silently clamped. Test fixtures explicitly provision their
existing layouts, and retain their independent smaller variant/location/handle/
staging limits. The old two-object logical-capacity failure is now a construction
rejection case. See [review-repair-status.md](review-repair-status.md) for the
proof, conservative limits, rollback and full-survivor tests.

A new 500,000-element run passes on the capacity repair. It keeps all object,
heap and trace geometry unchanged. Native log: `/tmp/clamsara-capacity-array-stress.log`.

```text
MODEL-REPRESENTATION-CAPACITY  1000132
MODEL-DESCRIPTOR-CELLS         1000132
FIXED-MODEL-PLANE-BYTES       80011312
ACCOUNT-PHYSICAL-BYTES        48133504
ACCOUNT-AUXILIARY-BYTES       160290512
REFERENCE-CALLBACKS           500000
NUMERIC-STRONG-CALLBACKS      0
OBJECTS-DISCOVERED/MOVED      2/2
BYTES-MOVED                   8000032
```

The model-plane bytes exactly match the earlier run. Whole-configuration charges
include the intervening service changes and are reported afresh, not copied
from that historical result. This remains hosted component evidence, not
benchmark or target admission.

## Corrected work and storage reporting

The historical output above is preserved, not retroactively relabeled. Its
`REFERENCE-CALLBACKS` and `NUMERIC-STRONG-CALLBACKS` fields printed expectations,
not measured whole-workload totals. The two explicit reference scans each
asserted N callbacks, and the explicit numeric scan asserted zero. Real GC also
scans the reference array; the old number did not count all of that work.

The current test retains and prints the actual local callback count from each
explicit mapping call. It labels collector callback counts `:NOT-MEASURED`.
Its single-size count/order and endpoint assertions no longer describe
themselves as complexity proofs. The independent accessor-count checks elsewhere
remain bounded evidence for the particular quadratic loops they replaced.

`TOP-LEVEL-MODEL-PLANE-BYTES` is the shallow sum of the named plane vectors.
The base-reference vector's elements are separate 64-byte records on this SBCL.
Stage records also retain separate byte/word backing arrays. They were already
in the auxiliary account, but were not in the plane figure. The test now sums
those actual primitive objects and prints an explicitly **partial** model
subtotal. It still excludes model/route/kind headers and other fixed records.
Do not read it as all retained model storage.

The rerun on the `6e268e4` implementation with the reporting-only test edits
passes both the 4,096-element group and the unchanged 500,000-element stress.
Logs: `/tmp/clamsara-model-metrics-components.log` and
`/tmp/clamsara-model-metrics-500k.log`. The latter reports:

```text
TOP-LEVEL-MODEL-PLANE-BYTES      80011312
BASE-REFERENCE-RECORD-BYTES      64008448
STAGING-BACKING-BYTES            8000064
PARTIAL-MODEL-SUBTOTAL-BYTES     152019824
ACCOUNT-PHYSICAL-BYTES           48133504
ACCOUNT-AUXILIARY-BYTES          160292368
EXPLICIT-REFERENCE-SCAN-CALLBACKS (500000 500000)
EXPLICIT-NUMERIC-SCAN-CALLBACKS  0
COLLECTOR-SCAN-CALLBACKS         :NOT-MEASURED
OBJECTS-DISCOVERED/MOVED         2/2
BYTES-MOVED                      8000032
```

Heap geometry and descriptor count are unchanged. The 1,856-byte auxiliary
increase since the capacity repair belongs to the geometry snapshot state,
not this reporting change. Summing a million primitive records also adds test
bookkeeping outside collection; the roughly six-second process time includes
startup and is not an isolated performance measurement.

### Independent trace-capacity diagnostic

Read [the original report](trace-capacity-review-9dd8629.md) together with
[its corrective addendum](trace-capacity-review-addendum.md). The measured
fixture is an **8-object chain in 128-byte semispaces**, not a 4,096-element array.
The original proposed trace bound 128 is inadmissible for that array's 66,592-byte
spaces: the minimum is 4,162. A legal 4,162-versus-8,324 array comparison was not
run. The smaller chain compares admitted trace capacities 128 and 8,324.

Measured plan-vector lengths are 2,384 and 84,344 words, with physical charges
19,088 and 674,768 bytes; plan auxiliary charges are identical at 19,568 bytes.
The probe also measures a base-reference record at 64 bytes. These structural
observations support the accounting decomposition. They do not prove full
storage admission or complexity at other geometries.

Each world completes 25 survivor collections and one empty discharge. Six
completed runs are retained; the pooled timing table uses only the three later
runs, with 144 samples per capacity. The median difference is 16 microseconds,
but ranges overlap and include unexplained process-level outliers. The extra
49,176 fill slots are **source-derived**, not counted writes. The timings are
compatible with that work, not a causal isolation of it. No Gabriel, GCBench,
array-performance, no-allocation or target acceptance follows. Unchanged probe,
runner, six logs, pooled data and hashes are in
`docs/evidence/trace-capacity-9dd8629/`; eight earlier process logs are unavailable.

## Evidence limits

- The complete combined entry and the 500,000-element stress are green at the
  recorded stable milestone. This does not extend the proof beyond their named
  profile and values.
- The model planes are hosted fixed backing. Their fixed, charged overhead is
  distinct from guest allocation. Identity/length/account checks prove no
  per-object host container was installed for the exercised cons, struct,
  reference array, integer array, and single-float immediate paths. They do not
  prove that every possible guest kind is guest-resident.
- External root-provider payload is intentionally caller-owned. The test proves
  the framework's registration records and backing are charged; it does not
  add external memory to the framework account.
- These runs are hosted semantic/capacity evidence. They do not prove target
  residency, no dynamic allocation, closed dispatch, memory ordering, or IRQ
  safety.
- No generational collector claim is made here. Address reuse and handle/root
  generations are not a generational heap implementation.
