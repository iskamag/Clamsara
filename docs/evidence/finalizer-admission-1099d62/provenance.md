# Finalizer callback admission: strict native failure

This preserves a completed core-only baseline, not a repair.
Runtime revision1099d6235d7cc2730ce5066fb404daaca0bd75d9; original source/run paths
and exact input hashes remain in the unchanged records under `source/` and `native/`.

PID22799 exited1 in2.1537612070096657s. The fresh local referent was valid and
rooted. Its proposed callback was FUNCTIONP but not a reference recognized by the
bound model. REGISTER-FINALIZER nevertheless returned token0, advanced history
0->1, and changed states FREE/FREE to ACTIVE/FREE. Before/after state differed.
All eight observed effect-entry counters were zero despite direct registry writes.
The callback was never invoked. This was not a construction/harness failure.

One actual world/owner and both active root tokens remained retained through the
process summary; no cancel, drain, collection, root clearing, close or restoration
followed. There is no surviving core/live-process claim. The before-state was
asserted as fresh and retained in memory, not separately dumped as a states array.
Only :clamsara/quality/support and its core dependencies loaded; no workload or
Maclina system/package. All input pins were unchanged.

This witnesses invalid admission and mutation, not capture loss. The stock model
still lacks a callable managed-reference domain; rejecting unsupported callbacks
would not itself implement managed finalization. Existing native callback queue
bookkeeping tests must not be relabeled as managed-callback acceptance. No new
mandatory invocation hook or compiler representation is licensed by this result.

Historical runners retain original absolute paths. Original draft comments say
unexecuted because they predate the separate native run. See the original report
for the command, precise scope and ownership observations.
