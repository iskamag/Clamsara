# Independent source review: shared copying action (candidate V1)

Reviewer: independent, source-only. Judged **only** as a private shared-action
refactor of the sequential runtime, **not** as protocol compliance. No code edit,
no native command, no ASDF load, no subdelegation. Broader coupling is left
unresolved by instruction.

Candidate root: `/tmp/clamsara-shared-copy-04bff62-xzksq1om`
Baseline root: `/home/iskam/src/vibe/Clamsara` (clean, rev `04bff62db4ef86868dc6d5d917e8704f9d90b62e`).

## Inputs and hashes (computed from bytes in this review turn)

| input | sha256 |
|---|---|
| `src/runtime/spaces.lisp` (candidate) | `27bd725e7c2c4b280944841e44fb20407f32880d8347036fd7f204d975126bfc` |
| `src/runtime/generational.lisp` (candidate) | `a8d070dfdf1b0e09940ecd586cfd2d7cce183cea748f288278ccb13e5644ed53` |
| `src/runtime/spaces.lisp` (baseline) | `3a92db035fcc6873d0a62e6fbe6331f04d131d76782cb83cd63836884ff671f6` |
| `src/runtime/generational.lisp` (baseline) | `1c3fbedeae853d0d2531da3f2655544dffbc2b22823bdd9cc1c0feb150792ad1` |
| `independent-review/shared-copy/shared-copy-v1.patch` | `b58c96a32303aaf929872660729d06265efcace43aeb1da7aa352caa122aaa0b` |
| `spaces-v1.diff` | `768fb9755ba6c4f89e12df629606013a7db7b0d142f7466011f91a3e54bce7cb` |
| `generational-v1.diff` | `efddd10b23a6765d6742ebda2b5111361a4ace1d00a79a07a675b346a52f4781` |
| `design-ownership-v1.md` | `4817b821acedc280185cee23c12bd383e5f43492428620cc80224d6cd9cf6bab` |
| `provenance-v1.json` | `aba196ee842a752ee3c73289da7eec9479f924845e6a477b6472aa439e37edc1` |
| `source-checks-v1.json` | `1cc28cc99b660dbec32f63ccf2356210db2413f5b29140d9ac85f93b7f1027ec` |
| `final-verification-v1.json` | `4614ef35524e6936cb128628854d9ac54a3a7638dff033d28940fecb93b09a09` |
| `head04bff62.tar` | `7aeeecd092aa9fc967b6c4dbd80dce5568d1d307651b455d7169cf294c110bf8` |

Recorded provenance agrees with the bytes: candidate file hashes equal
`provenance-v1.json` `production_candidate_hashes`; baseline files equal
`production_input_hashes`; patch and archive hashes match. `input-sha256.json`
and `live-input-post-sha256.json` are byte-identical (`e208fa10403426a61f8f22421053a8836015d1235ba67c7be1ea3edc42657b1b`).

## Scope verified independently

* `git ls-files` in the baseline = 543 files; none missing from the candidate, and
  exactly two differ: the two stated production files. No third production change.
* `shared-copy-v1.patch` payload (all `+`/`-` lines, hunk headers excluded) is
  **sequence-identical** to the diff recomputed from baseline vs candidate bytes:
  226 payload lines in both, identical order. Hunk-header line numbers differ by
  one from `difflib`'s recomputation; payload is unaffected. Two files only.

## Required checks

1. **Claim seen/failed preserved — PASS.**
   `%trace-copy-object` (`spaces.lisp:261-332`) keeps the original dispatch:
   `:seen` (`:270-275`) awaits the claim, re-fails `:fatal-invariant` on a
   non-`:complete` await, then reads source forwarding (or fails the context);
   `:failed` returns `start` (`:276`); `:first` (`:277-332`) carries the whole
   copy. Neither `:seen` nor `:failed` calls the reservation function, allocates,
   or receives capabilities. Baselines `spaces.lisp:243-317` and
   `generational.lisp:428-503` did the same.
2. **Policy invoked only on FIRST — PASS.**
   Single call site: `funcall reserve-destination` at `spaces.lisp:284`, inside
   `(:first ...)`. `grep` shows the only references to the two policies are the
   method bodies (`spaces.lisp:336`, `generational.lisp:452`), which are reachable
   only through `:first`. No branch hoists reservation onto seen/failed paths.
3. **No mistaken mature allocator ownership — PASS.**
   `%reserve-promotion-copy-destination` returns `owned-allocator` = NIL on success
   (`generational.lisp:445`) and never calls `allocate-raw`; the common action
   commits only `(when owned-allocator ...)` (`spaces.lisp:303-304`) and cancels
   only `(when owned-allocator ...)` (`spaces.lisp:328-329`). Promotion therefore
   performs no raw commit and no raw cancel against the mature free-list allocator.
   Semispace returns the exact destination allocator only after `allocate-raw`
   success (`spaces.lisp:257-258`). The preflight reservation machinery
   (`%gen-reserve-promotions`, `%gen-scratch-allocate`, `%gen-copy-active-free-list`)
   is byte-identical to baseline — the generational diff has one hunk only.
4. **Ordering: object-start before forwarding before destination-work commit — PASS.**
   In the common action: `initialize-object` (`:293-294`), `copy-object-representation`
   (`:295`), destination `metadata-set` object-start (`:296`), `destination-start-p`
   (`:297`), source forwarding `metadata-set` (`:300-301`), cycle publication flag
   (`:302`), owned raw commit (`:303-304`), movement (`:305`), bytes counter
   (`:308`), `trace-commit-object` with destination space/start (`:309-311`).
   This is the same order as both baselines.
5. **Movement/counters — PASS.**
   One `%record-cycle-movement` call and one `%cycle-counter-incf ... :bytes-moved`
   per successful first copy (`spaces.lisp:305, 308`), reachable only on success;
   `:seen`/`:failed` add none. Occurrence counts in the candidate, with locations:
   in `spaces.lisp`, `initialize-object` 1, `copy-object-representation` 1,
   `%record-cycle-movement` 1, and inside the shared action one each of
   `trace-claim-object` (268), `trace-abandon-object` (286, 330),
   `%commit-raw-allocation` (304), `trace-commit-object` (310),
   `%cancel-raw-allocation` (329). The other hits in `spaces.lisp` are the
   unchanged helpers (`%commit-raw-allocation` definition 160;
   `%cancel-raw-allocation` generic/methods 147-153) and the untouched
   `marksweep-space` method (`trace-claim-object` 544, `trace-commit-object` 554,
   `trace-abandon-object` 558). `generational.lisp` now has 0 occurrences of every
   one of those names: no duplicated copy sequence remains there.
6. **Prepublication rollback vs cycle-wide post-publication fatal — PASS.**
   `handler-case` begins after a destination exists and covers object-kind lookup,
   initialization, copy, publication, movement/counter and work commit
   (`spaces.lisp:290-314`). On error while `%cycle-forwarding-published-p` is NIL
   it clears the object-start fact if set, retires the exact new representation if
   created, cancels only an owned raw reservation, then abandons the same
   capabilities with `:preflight-failed` (`:320-331`). If the cycle-wide flag is
   already true it only fails the context with `:post-publication-failure`
   (`:318-319`). Reason precedence (`:capacity-exhausted` from the policy vs.
   `:post-publication-failure` from the caller) is unchanged.
7. **Major CALL-NEXT-METHOD — PASS.**
   `generational.lisp:446-452`: the `:all` scope guard remains the first form and
   still `return-from`s `call-next-method` before any claim; only the minor path
   routes into the shared action. Unchanged from baseline (`generational.lisp:428-433`).
   The `marksweep-space` `trace-object` method is byte-identical to baseline
   (`spaces.lisp:541`); the semispace file diff has exactly one hunk.

## Behavioural deltas observed (all inconsequential, stated for completeness)

* The action captures the destination allocator at reservation time and reuses it
  for commit/cancel, where baseline re-read `(%space-allocator destination)`
  (`spaces.lisp:303-304, 328-329`). Between reservation and commit the only
  executing code is host ABI publication; no path mutates that slot, so the
  captured owner is equivalent — and it is the more precise owner for the
  promotion case.
* `(%space-model space)` is read a few forms earlier than baseline; the same
  value is used afterward. No observable difference.
* Both policies return exactly the same 5 values on success and refusal
  (`spaces.lisp:251-252, 257-259`; `generational.lisp:439-440, 445`), so the
  action's `when reason` guard cannot mis-handle arity.

## Pre-existing behaviour carried over unchanged (not candidate regressions)

* Reservation runs **outside** the copy handler in both baseline and candidate, so
  a signal from `allocate-raw` (for example `:barrier-busy` from
  `%check-raw-allocation-barrier-boundary`, or the free-list `:invalid-alignment`
  rejection) escapes with the trace claim unresolved, exactly as before.
* The cycle-wide flag still relabels a pre-forwarding fault after any earlier
  forwarding as `:post-publication-failure`; stated deliberately in the candidate
  comment (`spaces.lisp:316-318`).
* Promotion validates `address + bytes <= limit` on raw bytes while preflight
  charged `align-up(bytes, Q)`; unchanged from baseline and acknowledged in
  `design-ownership-v1.md`.

## Limits of this review

* Source-only. No reader, compiler, ASDF load, or execution evidence exists, and
  none is claimed here. Everything above rests on the bytes hashed in this file.
* The sharing seam is a function argument to a private DEFUN, not a generic; the
  design document does not claim otherwise. A third space type still needs its own
  `trace-object` method, as before.
* Broader unresolved coupling is untouched and not re-judged here: generational
  still writes MarkSweep private reclaim state, `%plan-movement-participants` stays
  empty, and the layout ownership-update APIs remain uncalled. No protocol or
  conformance claim follows from this candidate.

## Verdict

**No blocking findings.** Within the paths examined, the candidate is a
behaviour-preserving extraction of the SemiSpace/minor-promotion copying sequence
into one private action, with claim dispatch, reservation-only-on-first,
allocator ownership, publication ordering, movement/counter bookkeeping, failure
branching and the major delegation all intact. A native witness would be needed
only if execution evidence is required; that needs explicit authorization and is
outside this source review.
