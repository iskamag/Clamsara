# Source-only MAPC permanent integration review

## Verdict

**No blocking source-integration defect identified in corrected candidate
`/tmp/clamsara-mapc-integrated2-0gtrq1cb`.** Independent test bodies, their assertions, scoped fixture
method cleanup and failure-owner retention are preserved. New wrappers enforce
the requested 9/5/17 count guards. The workload-only ASDF wiring is consistent.
This is a source review, not a claim of independent native integration execution.
Parent PID 19986 remains the separate native gate and its logs are authoritative.

## Preserve the first failed candidate

`/tmp/clamsara-mapc-integrated-tard99a7` remains the failed original. Parent PID 19852 stopped on
an EOF in the new behavioral wrapper before MAPC ran. Source comparison confirms
the capacity wrapper had the same missing close. The corrected candidate adds
exactly one closing parenthesis in each new wrapper. It does not edit the copied
independent bodies or any production file. The two correction diffs are retained
here. No pass is inferred for the original candidate from a later retry.

Static balance is now zero, with no unterminated string, in all six changed
code/test/ASDF files. This is a cheap source check, not a substitute for native
read/compile/load or test execution.

## Exact source preservation

Comparing the original `52e08f1` code snapshot (parent identifies HEAD `3a5a867`
as a docs-only successor), exactly six src/test/ASDF paths differ:

- `src/workload/roots.lisp`
- `src/workload/control.lisp`
- `src/workload/maclina.lisp`
- `test/workload/mapc.lisp`
- `test/workload/mapc-capacity.lisp`
- `clamsara.asd`

The three production files are byte-identical by hash to the frozen draft
executed in independent capacity PIDs 19086 and 19747. No other production/model
Lisp file differs. All 20 reference fixture hashes match the original committed
manifest. The shared Maclina source hashes still match PID 19747's unpatched
pre/post pins. This review made no source, dependency, fixture or model edit.
The docs-only baseline evidence bootstrap is not a production/test/ASDF overlay.

Behavioral V2, from its first DEFSTRUCT through the complete strict-case runner,
is **byte-identical** to the permanent copy after excluding the normalized
header/package and new wrapper. All **50 textual ASSERT forms** remain.
The removed footer only described the then-unimplemented separate capacity gate;
it contained no test body or assertion.

Capacity V3, from its first DEFSTRUCT through its final scope-limit comments, is
**byte-identical** to the permanent copy after excluding the normalized
header/package and new wrapper. All **104 textual ASSERT forms** remain,
including descriptor SOURCE EQ / SOURCE-INDEX EQL, the synthetic observer
self-check, physical boundary checks and both nonempty recovery histories.
These are source-form counts, not executed assertion or runtime-case counts.

The new packages consistently replace only the old test package names. No test
helper is installed as a production definition. Original condition, callback and
owned guest names are read together in each distinct test package. Package/export
names match the ASDF symbol calls.

## Wrapper counts and ownership

`RUN-WORKLOAD-MAPC-TESTS` asserts the nine-case inventory before it starts. It
creates each runtime, publishes the runtime handle in `*MAPC-TEST-RUNTIMES*`, then
passes it to the unchanged owner-adopting strict runner. It only increments PASS
after that runner returns and the runtime configuration is NIL. It requires
zero failures and exactly nine passes and nine new owners.

`RUN-WORKLOAD-MAPC-CAPACITY-TESTS` first requires the synthetic observer self-check
to return normally. It then invokes exactly five runtime groups: boundaries,
snapshot, nested rejection, smaller nonempty recovery and post-outer recovery.
It requires zero failures, five passes and exactly 17 new owners. Every new owner
must be `:COMPLETE`, have no recorded condition and have NIL runtime configuration.
The 17 consist of roomy calibration + 12 boundary cases + four witness/recovery
owners. The synthetic check creates no runtime and is not a sixth runtime group.

Both wrappers use LDIFF against the pre-call owner-list tail. Repeated calls count
only newly added owners without clearing prior handles. Their ERROR handlers
report and count failures; they do not release definitions, erase roots, consume
results, collect or close a failed world. A constructor failure is a failure,
not a completed owner or capacity pass. The unchanged capacity constructor
publishes its owner before construction and captures a partial provider when
available. The unchanged strict runner adopts each successfully created runtime
before its case starts.

## Scoped methods and success-only cleanup

CAP-WITH-UNIQUE-METHOD still asserts that no method with the same qualifiers and
specializers exists. It records the actual method object it adds, and removes
only that object in UNWIND-PROTECT. Nested installation unwinds each owned method
on success or error. No primary is replaced. Dynamic guards restrict construction
resizing, effect counting and protected-snapshot observation to the current test.

Removing a test method is not owner discharge. CAP-GUARD still only records the
actual error. The strict runner still records the actual error and pre-unwind
registers before unwinding. Successful histories alone call CAP-FINISH or
FINISH-SUCCESS, which release case-owned definitions/results, prove zero discovery
and close. No unconditional failure cleanup has been introduced by integration.

The permanent/archived packages define separate test state. Their temporary
methods target the same generic functions, so the parent's permanent -> archive
-> permanent replay is a useful separate native check of cleanup and isolation.
Source preservation alone does not claim that replay passed.

## ASDF and parent replay source

Only `clamsara/workload/test` changes. Its existing dependency on
`clamsara/workload` is unchanged. It adds the two explicit test components and
two matching exported test calls to the existing AND gate. A false result or
error cannot silently become a pass. The files have no cross-file test helper
dependency, so no new serial ordering requirement is introduced. No indexed WIP
component or call is present; no other ASDF subsystem changes.

The parent bootstrap in `/tmp/clamsara-mapc-integration2-native-ro_f9w5j` selects the corrected candidate
ASDF root and private cache, asserts the shared Maclina path, runs the full
component/workload/generational/structure gates, then loads the unchanged
archived V2/V3 source and runners and repeats both permanent wrappers. I inspected
that source only. I did not start, poll, or take credit for the parent's process.

Archived MAPC evidence is still outside this candidate and is referenced by
absolute preserved paths in that bootstrap. The missing archive copy is disclosed,
not hidden by a claim that the candidate tar is self-contained. Candidate tar and
manifest are extras; they do not change source/test/ASDF behavior.

## Scope limits

This review approves the source preservation/integration of the bounded MAPC
work, not full Gabriel or target conformance. Exact-stack capacity remains entry
admission only. Arbitrary future callback work, arbitrary native captures,
Mezzano/supervisor admission, LIST and the other recorded compiler/ownership holds
remain outside this evidence. Any eventual shipped tree must match these source
pins and keep failed/retry native records distinct.

Artifacts here: `source-checks.json`, wrapper correction diffs and
`workload-test-asdf.diff`. All original evidence remains unchanged.
