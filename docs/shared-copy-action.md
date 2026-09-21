# Shared SemiSpace / nursery copying action

## Change

SemiSpace and minor promotion now use one private `%trace-copy-object` action.
The two existing `trace-object` methods pass top-level reservation functions.
Major generational collection still delegates to the SemiSpace method.

- Claim/seen/failed handling precedes destination reservation.
- Only a first claimant reserves a destination.
- SemiSpace returns its actual owned raw allocator. Promotion returns NIL: its
  address was reserved by plan preflight, not by a new mature allocation.
- The common action initializes/copies, publishes destination start then source
  forwarding, records movement and commits the original work reservation.
- Before any forwarding, failure retires the unpublished representation and
  cancels only an owned raw allocation. After any forwarding in the cycle,
  failure retains the state/stop instead of pretending rollback succeeded.

Only `src/runtime/spaces.lisp` and `src/runtime/generational.lisp` change in
production. No public generic, phase, retained array, or client obligation is added.
This removes duplicated implementation; duplication alone was not established as
a normative violation. It is NOT a completed protocol-composability repair.

## Validation

Baseline: master04bff62 (runtime1099). Independent source review: ClosedRouter
`charm/deepseek-v4.1-flash`, no blocking findings in the scoped refactor.

| Native run | Result |
| --- | --- |
| Unchanged baseline focused16, PID26916 | exit0, 2.388669759s |
| Same focused16 on candidate, PID26954 | exit0, 2.393493431s |
| Candidate existing core/tools/gen/quality/structure, PID26689 | exit0, 6.524731152s; includes288 mixed cycles |

Durations are process observations, not comparative performance measurements.
All run input pins remained unchanged. Two earlier parent runner failures are
preserved in the evidence; neither required a production or test-assertion change.
Permanent test bodies match the independent source after package/header changes.
A wrapper checks each new16-world group without erasing previously retained worlds.
The permanent entry is part of `:clamsara/quality/generational/test`.

Focused cases cover packed/scalar maps, genuine sharing/cycles, promotion,
nursery copying during major collection, and first/second-copy errors in each
route. Four graph configurations complete; twelve actual failed worlds remain
published and rooted, including six retained-stop worlds. Even successful fixture
configurations retain their client-owned root-provider registration. This is
NOT complete client-owner or benchmark discharge evidence.

Exact integrated source run PID27165: exit0,
6.961651149s. Core suites,288 mixed generational cycles,
permanent16, archived16 selected from the integrated evidence, and permanent16
repeat passed. The four integrated code/test/ASDF hashes match the live files.
This is48 copy-case worlds:12 completed configurations and36 deliberately
retained failed worlds (18 covered stops). Source/paper pins remained unchanged.
Counts exclude separate expected-fatal worlds in the existing core suites.

## Limits and next work

Concrete-family and hosted-model dependencies remain. Finalizer callback admission
is still strict RED; the held indexed/name/handle work remains unaccepted on its
separate WIP branch. Missing Immix/Sticky Immix, Claimore MGC/OVC, Evha and
Iso/request-private profiles are not supplied here. Language expansion stays paused.

The coarse Claimore finite model has separate native evidence, but that is not a
runtime collector. No full-paper, Mezzano/supervisor, whole-accounting or new
Gabriel/GCBench acceptance follows from this change.

See [evidence](evidence/shared-copy-04bff62/README.md). The archived protocol report
must be read with its corrections; its initial broad execution verdict was qualified.
