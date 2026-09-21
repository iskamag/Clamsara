# EVIDENCE ERRATUM: A.0 vs A.7 hash statements (resolves the contradiction; nothing silently replaced)

Applies to `ADDENDUM-normative-vs-private.md` §A.0 and §A.7 in this directory.
Both originals are preserved unchanged. This file adds no new digest claims about
files I did not hash in this turn.

## E.1 The contradiction, resolved

* §A.0 (final revision of the table): "All digests were computed in-session with
  `hashlib.sha256` over the file bytes at rev 04bff62…" — **accurate as a statement
  about the final revision of §A.0**, and confirmed independently: the parent's
  verification found 22/22 reported file digests matching actual bytes
  (`parent-pin-verification.json`).
* §A.7: "the hash table in A.0 contains hand-copied digests that were not all
  recomputed in-session — only the prefixes recorded in the session log are
  reliable; re-hash before citing." — **stale**. That sentence was written against
  the *first* revision of §A.0 (same file, same session, before the table was
  replaced with computed digests). It was true of that revision and is false as a
  description of the current file. **Withdraw it**; do not read it as an assertion
  that the final table contains a wrong digest.
* Neither statement asserts a numerically incorrect digest, and none was observed.
  There is no digest to retract.

## E.2 One row is out of scope of the verification and must not be cited

The table has 23 rows. The parent verified 22 file digests (all matching). The
23rd row is the ADDENDUM's own self-row, recorded **before** the table was inserted
and therefore stale:

* row as written: `043d2e3c1227b5d52e3daa76803e079c873c7e21b146a3b2dec98fbfd9b3db0f` — pre-table value, **do not cite**;
* current ADDENDUM bytes, computed now in this turn:
  `f2803d58d5508edcf423415bddb1ded837e295b06d1ae603bfbcdf9df9700fee`
  (size 20605, mtime 09:31:43);
* `REPORT.md`, unchanged since 09:22:21 (size 24216):
  `c7d5db3b3dbcbb7b30788258021b98a56f604ec8dd5f814ac7caeeae9130c4e2`.

## E.3 Provenance limits, stated precisely

1. A digest matching now verifies the **current bytes** of a file. It is not
   retroactive proof of what was inspected earlier in the session.
2. A 16-hex-digit prefix is never sufficient to reconstruct a full digest; the
   first revision of §A.0's table is withdrawn on exactly that ground.
3. Rule for any later review, including the pending shared-copy candidate: cite
   only digests computed in the same turn, or expressly omit them. Do not expand
   prefixes.
4. `docs/client-boundary-audit.md` and `parent-pin-verification.json` remain the
   parent's own records; this erratum does not restate or vouch for them beyond
   "the 22 matching file digests are the ones listed in §A.0's table".
