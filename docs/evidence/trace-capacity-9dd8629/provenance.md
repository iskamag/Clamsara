# Frozen trace-capacity diagnostic artifacts

These are unchanged copies of the independent review's probe, runner, six
completed run logs and pooled rounded-run summary. See
../../trace-capacity-review-9dd8629.md **with**
../../trace-capacity-review-addendum.md. The addendum corrects the fixture,
process count, cycle count and strength of the timing interpretation.

This directory is archival evidence, not a current-tree benchmark runner. The
probe expects the original selected frozen source directory and review manifest;
its default temporary paths are intentionally preserved. It is not part of
Clamsara's ASDF dependency closure. Source pins in the scripts/logs refer to
9dd8629, not the geometry repair or current HEAD. Reproduction needs that source
and the normal native Lisp dependencies. No dependency substitution is implied.

There were fourteen SBCL processes, including failed and diagnostic invocations.
Only the six completed comparison logs were retained. No missing log has been
reconstructed. The copied probe is the final rounded-median version, hash
`9d531948...`, used by the three canonical logs. The earlier exact-median logs
pin `c8bf7492...`; that earlier probe source is not included here. Do not treat
those six logs as executions of one byte-identical probe. sha256.json identifies
the files copied here.
