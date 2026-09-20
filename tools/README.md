# Native Lisp diagnostics

Load the tools in the normal project environment (SBCL startup loads the local
ASDF source registry). No collector stubs or fallback methods are installed.

```lisp
(require :asdf)
(asdf:load-system :clamsara)
(asdf:load-system :clamsara/tools)

(clamsara.debug:write-report
 (clamsara.debug:read-source "src/host/object-model.lisp"))

(clamsara.debug:write-report
 (clamsara.debug:compile-source "src/host/object-model.lisp"
                                :output-file "/tmp/object-model-debug.fasl"))

(clamsara.debug:write-report
 (clamsara.debug:inspect-name "NORMALIZE-REFERENCE"))

(load "test/runtime/semispace.lisp")
(clamsara.debug:write-report
 (clamsara.debug:run-probe :semispace
   #'clamsara.runtime.test:run-v14-runtime-tests :trace-signals 'error))
```

- `read-source` reports reader positions/context, top-level definitions, and
  suspected definitions swallowed inside other bodies. Load packages first.
  It uses the native reader on trusted project source, including normal `#.`.
- `compile-source` checks native `failure-p`, even if a FASL was produced.
- `inspect-name` reports real bindings and generic method signatures.
- `run-probe` records condition slots and backtraces before unwinding.
  Optional `:trace-signals 'error` uses SBCL's `*break-on-signals*` and debugger
  hook to capture errors before inner `handler-case` clauses hide them. It
  continues the diagnostic break and leaves normal handlers in control.
  A correctly handled error is recorded but does not make the probe fail.
- `write-report` emits a readable S-expression. Redirect stdout for a durable
  log. Reports include elapsed diagnostic time, not benchmark timings.

These tools allocate and alter debugging behavior. They are not supervisor
entry code, allocation-freedom evidence, or benchmark measurements. Rerun
correctness tests without instrumentation and benchmark in a fresh process.

Tool regressions: `(asdf:test-system :clamsara/tools/test)`.
The deliberate compiler-error fixture is expected; it verifies that a normal
`compile-file` return with `failure-p` true is not called a successful compile.

## Full GCBench acceptance

From the repository root, in a fresh process:

```sh
sbcl --dynamic-space-size 8192 --noinform --non-interactive \
  --load tools/run-gcbench.lisp > /tmp/clamsara-gcbench.log 2>&1
```

This loads the unchanged checked-in Lisp translation and calls depth 18.
It uses the existing 32MiB active semispace (64MiB total semispace reserve)
and an 8MiB maximum object. The translation derives a depth-16 long-lived
tree and a 524284-element single-float array. The 8GiB SBCL limit is host
simulator space, not an increase in guest semispace capacity.

The runner requires actual automatic movement of at least the two long-lived
anchors' object/byte counts. It reports the automatic cycle and a final full
collection with zero discovered objects. It never erases roots to force that
result. It then requires successful shutdown. Workload and close errors are
reported separately and either makes the process fail. Only
`GCBENCH-ACCEPTED` together with exit 0 is this runner's acceptance result.
This is hosted workload evidence, not Mezzano or supervisor admission.

Keep the log and source revision. Verify the original fixture hashes in
`docs/fixture-sha256.json` before and after a reported run. Do not treat the
older temporary driver's `:STATUS :OK` with `:FINAL-COLLECTION-STATUS :NOT-RUN`
or a swallowed `GCBENCH-CLOSE-ERROR` as full acceptance.

## FRPOLY result oracle (fails with the default dependency)

```sh
sbcl --noinform --non-interactive --load tools/probe-frpoly.lisp \
  > /tmp/clamsara-frpoly-oracle.log 2>&1
```

This loads the unchanged fixture into separate native and managed environments.
It compares all original degree/base cases after real moving collections.
With the unchanged shared Maclina dependency, it stops at the first degree-2
mismatch. The same mismatch occurs before collection and with host conses.
An explicitly selected temporary compiler candidate passes all twelve cases;
see `docs/maclina-special-bindings.md`. The candidate is not auto-installed.
Returning NIL from all four TESTFRPOLY subtests is therefore not acceptance.
After the value comparisons, the probe also calls the original TESTFRPOLY
entry in the same environment. It never clears fixture globals for shutdown;
complete value comparisons and that entry's return establish computation,
not full benchmark lifecycle success.

## Upstream special-parameter regression (currently failing)

```sh
sbcl --noinform --non-interactive --load tools/probe-required-special.lisp
```

This loads only Maclina/Extrinsicl/Clostrum/Trucler, not Clamsara. It compares
required globally special assignment and nested rebinding with native Lisp.
It reports all three cases and exits unsuccessfully while any differ. Adding
an explicit SPECIAL declaration repairs only one of the two failing cases.
See `docs/workload-boundaries.md` before attempting an adapter workaround.

## Unapplied Maclina candidate and broader binding probe

`tools/patches/maclina-special-bindings.patch` is a dependency patch, not a
runtime override. Apply it only to an explicitly selected separate checkout.
`docs/maclina-special-bindings.md` gives the base revision, source-selection
steps, test evidence, remaining failures, and preserved positive logs.

- `tools/probe-maclina-special-tests.lisp` runs fourteen focused upstream
  checks in each of the native and cross VMs. It needs FiveAM and asserts that
  the patch's new tests exist. It does not claim a full upstream-suite pass.
- `tools/probe-special-bindings.lisp` compares thirty-four native/plain-VM
  cases without loading Clamsara. It remains a failing gate: fourteen cases
  differ with the original compiler; two nonlocal-exit cases still fail with
  the candidate. Errors are reported, not swallowed into passing results.
