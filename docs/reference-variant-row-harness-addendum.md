# Addendum: aggregate acceptance-runner truth test

The parent reported that its first repaired-implementation gate executed all
108 cases successfully (`PASSED 108 FAILED 0 PRESERVED 0`), then exited 1 in
my aggregate runner. This is a test-harness bug, not an implementation failure.
The parent's integration result is reported here second-hand; I did not run or
inspect its native gate.

In the original `cases.lisp`, the final check is:

```lisp
(when *failed*
  (error "Whole-code-row acceptance failed: ~D requirement failures (~D passes)"
         *failed* *passed*))
```

Common Lisp treats integer 0 as true. Since `*failed*` is a nonnegative count,
this check incorrectly signals even when all cases pass. The correct check is:

```lisp
(when (plusp *failed*)
  (error "Whole-code-row acceptance failed: ~D requirement failures (~D passes)"
         *failed* *passed*))
```

The parent will apply this change only to its own integration copy and rerun.
No original acceptance source, runner, report, log, or hash record was changed.
The frozen RED evidence still contains 64 actual per-case requirement failures
and 44 passes; the aggregate truth-test bug does not create or explain those
individual failures. However, the original aggregate runner cannot produce a
successful process exit on a green implementation until this check is corrected.

No new native process was started. The native slot remains with the parent.
