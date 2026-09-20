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
