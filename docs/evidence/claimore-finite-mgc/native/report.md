# Finite MGC model: first native execution

Parent ran the unchanged source draft with SBCL, no Clamsara/ASDF load.

- Run: `/tmp/clamsara-mgc-model-native-aghitgie`; PID 25951.
- Exit: 0; process duration: 3.3870751750655472 seconds (not a collector-performance measurement).
- All pinned input bytes unchanged.
- Native report: 46 layouts, 4,450 graphs, 1,205,964 coarse decisions,
  1,189,952 deletion histories and 1,189,952 protected rescans.
- Omitted-root negative control found one rooted one-unit allocation losing its unit.
- Omitted-span-edge negative control found rooted allocation (start 0, charged 2),
  retained its start granule but lost unit 1 after omitting edge 0->1.
- Both are required observed counterexamples, not expected-failure exit suppression.

This is the finite research-model gate only. It is NOT runtime MGC, incoming-index,
barrier, finalizer/conditional, common-commit, managed-storage or target proof.
Original README/source `unexecuted` comments describe draft provenance; unchanged
originals are preserved and this record reports the later execution separately.
