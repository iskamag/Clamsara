# Maclina special-binding candidate

## Status and scope

`tools/patches/maclina-special-bindings.patch` is an **unapplied dependency
patch** against Maclina `d92e9254b45da4e508503b984f02403c6fb6677a`. It was tested
in a temporary copy. The shared Maclina checkout remains unchanged. Clamsara
does not install this patch, replace global compiler functions, or silently
select another dependency. Permission to change the shared checkout is still
pending.

The two production changes are:

- Query the global environment for a global SPECIAL proclamation. A local
  description must not hide it from nested bindings.
- Describe every special required parameter as special after creating its
  lexical argument carrier. Body and default-form compilation must not read
  or assign that carrier instead of the dynamic binding.

The patch also adds eleven upstream regression cases and a proclaimed test
variable in the upstream cross-test environment. Existing locally special
shadowing tests are unchanged. No Clamsara source, paper, benchmark fixture,
or benchmark parameter is changed by the patch.

## Observed evidence

Clamsara production source was `1f65ba5`; SBCL was `2.6.8.3-db35d4561`.
“Candidate” below means the explicit temporary dependency, not the default
shared checkout.

| Check | Original compiler | Candidate |
| --- | --- | --- |
| Dependency-only required-special probe | 2 of 3 cases differ | All 3 agree |
| Same 14 upstream SPECIAL checks, cross VM | 7 pass, 7 fail | 14 pass, 0 skipped |
| Same 14 checks, native VM | Not measured | 14 pass, 0 skipped |
| Broad native-oracle binding matrix | 14 of 34 differ | 2 of 34 differ |
| Original FRPOLY polynomial oracle | First degree-2 case differs | All 12 cases agree after collection |

The broad matrix is `tools/probe-special-bindings.lisp`. It still exits with
failure in the candidate. Its two remaining cases are THROW and
UNWIND-PROTECT/THROW inside VALUES argument evaluation. Both also fail with
the original compiler: a VM stack operation encounters -1 where an unsigned
index is required. The matrix reports errors as failures and uses a fresh VM
per case, so a failed case cannot corrupt the next case's registers. These
failures are not waived or counted as passing special-binding tests.

The full upstream test system could not load with either compiler on this
SBCL. Native compilation of unchanged `test/fasl/externalize.lisp` exhausts
the control stack in repeated `SB-KERNEL:CTYPE-OF` calls on circular conses.
Therefore **no full upstream-suite pass is claimed**. The focused tool loads
real ASDF components and runs the actual upstream FiveAM SPECIAL suite. It
asserts that all eleven new regressions exist, rather than accepting only the
old three tests.

With the candidate, the existing Clamsara main, tools, six workload suites,
optional generational suite, and optional-loaded structural checks pass.
These include 105 construction checks, 100 stateful oracle collections,
14 tool checks, 36 adapter checks, 9 value-lifetime cases, 5 teardown cases,
4 published-code cases, 95 selector checks, and 62 numeric checks. This is
component evidence, not acceptance of all benchmarks or target admission.
The same Clamsara component command also passes with the unchanged shared
dependency. All twenty benchmark fixture hashes remain unchanged.

The FRPOLY probe compares the original degrees 2, 5, 10, 15 for R, R2, and R3.
Its twelve explicit cycles move 10743 objects in total. All corrected results
match native execution of the unchanged fixture. The guest runtime remains
1MiB active, with a 512KiB maximum object and 1024 roots. The fixture's live
globals are preserved; close correctly rejects them. The original TESTFRPOLY
entry also runs in that same environment after the twelve comparisons and
returns NIL; that return is not used as the polynomial oracle. This establishes
**computation only**, not a complete FRPOLY lifecycle, the full Gabriel suite,
or current-tree GCBench acceptance.

Verbatim positive logs:

- `docs/maclina-special-focused.log`
- `docs/frpoly-maclina-special-candidate.log`

The recorded temporary paths identify the tested image. The patch was also
applied to a fresh copy of the four original files; all resulting bytes match
the tested candidate. The shared dependency was not used as the patch target.

## Reproduce without changing the shared checkout

Make a separate checkout at the base revision, then apply the patch there:

```sh
git -C /path/to/private/Maclina apply --check /path/to/Clamsara/tools/patches/maclina-special-bindings.patch
git -C /path/to/private/Maclina apply /path/to/Clamsara/tools/patches/maclina-special-bindings.patch
```

From the Clamsara root, explicitly select that checkout in each fresh image:

```sh
sbcl --noinform --non-interactive \
  --eval '(require :asdf)' \
  --eval '(push #P"/path/to/private/Maclina/" asdf:*central-registry*)' \
  --eval '(format t "~&MACLINA-SOURCE ~A~%" (asdf:system-source-directory :maclina/compile))' \
  --load tools/probe-required-special.lisp
```

Check the printed source directory. Loading a candidate ASD alone was not
sufficient here: ASDF rediscovered the shared primary system until the private
directory was put first in `asdf:*central-registry*`. The actual test preludes
also asserted the selected directory's truename before loading the probes.

Use the same startup options with `tools/probe-maclina-special-tests.lisp`
(requires FiveAM), `tools/probe-special-bindings.lisp` (still fails on the two
nonlocal-exit cases), or `tools/probe-frpoly.lisp`. Serialize native startups.
The first two probes load no Clamsara implementation.

FiveAM was initially absent, and the configured Quicklisp proxy refused its
connection. Tests used temporary copies of the installed distribution's exact
FiveAM `20241012-git` and asdf-flv `2.2` releases, fetched over HTTPS and checked
against the local distribution's archive lengths and MD5 values. No proxy
configuration or shared compiler source was changed.
