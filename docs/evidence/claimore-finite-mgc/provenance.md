# Claimore MGC finite research model: native evidence

This is the paper's bounded finite-model check, NOT an implemented runtime
collector. `source/` is the unchanged independently authored model/tests and its
original source-only status. `native/` records the later parent SBCL execution.

PID25951 exited0 in3.3870751750655472s. The exact native report checked46 layouts,
4,450 graphs,1,205,964 coarse decisions,1,189,952 one-edge deletion histories and
1,189,952 protected rescans. Both required negative controls found real missing-
unit counterexamples: omitting one root lost a rooted allocation, and omitting
one directed span edge retained a live allocation's start but lost its next unit.
All source/paper input hashes remained unchanged. No Clamsara system or ASDF was
loaded by this standalone model run. Duration is not a collector-performance result.

The object-level oracle walks concrete edges and complete charged extents, not
MGC's relation matrix. Exhaustive geometry is bounded as described in the source
README; named cases add padding, short-last-granule and conservative-seed checks.
Runtime incoming-index coverage, barriers, handle lifetime, allocation publication,
weak/ephemeron/finalizer judgment, common commit and target behavior are NOT proved.
OVC, hierarchical mature/shared collection and runtime MGC remain absent.

Historical runner/source paths are preserved, not asserted portable. For model
replay from the repository, run SBCL with --no-sysinit --no-userinit --non-interactive
--load docs/evidence/claimore-finite-mgc/source/run.lisp. No fixture or paper changes
are required. `source/dependencies.md` describes inspected1099 runtime dependencies,
not a new implemented collector; the later shared-copy refactor is separate.
