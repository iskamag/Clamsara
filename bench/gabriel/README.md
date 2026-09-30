# Gabriel benchmark harness

A development harness that runs the checked-in Gabriel workloads
(`bench/gabriel/reference/*.cl`) against the Clamsara reference collectors and
writes curves plus a Markdown report.

This is **not** a conformance or acceptance gate. It measures the real hosted
stack (guest compiler/interpreter + collector + host object model); host-GC
noise is part of the measurement, not removed.

## Run

```sh
python3 bench/gabriel/run.py                       # default collectors/workloads
python3 bench/gabriel/run.py --collectors semispace,immix --workloads takr,deriv
python3 bench/gabriel/run.py --extent-mib 2 --dynamic-space-mib 4096
```

Outputs (default under `bench/gabriel/results/`, git-ignored):

- `report.json` — raw per-workload and aggregate numbers.
- `REPORT.md` — aggregate and per-workload tables.
- `curve-*.svg` — one curve per metric across the workload sequence.

Single-collector runs can also be driven directly:

```sh
sbcl --dynamic-space-size 8192 --load bench/gabriel/runner.lisp \
     collector=immix extent=2097152 workloads=takr,deriv
```

## Design

`run.py` spawns one fresh SBCL process per collector through
`runner.lisp`. One process runs one collector because the hosted Maclina VM is
a fixed, image-global resource; a fresh process also isolates host-allocation
measurement. The runner prints one `RESULT` JSON line per workload and one
`SUMMARY` line at the end.

## Collectors

| key | plan | reclamation |
|---|---|---|
| `semispace` | two equal copying halves | moving, full stop |
| `marksweep` | nonmoving mark-sweep | free list, mark epoch |
| `immix` | nonmoving mark-region | line/block holes |
| `generational` | copying nursery + mature MarkSweep | minor/major |
| `nogc` | monotone bump | none (exhaustion is normal) |

`nogc` cannot complete a workload that allocates and keeps a result: it
publishes no reclamation and its close honestly rejects with
`reachable-objects-not-discharged`. It is included for the allocation-path
curve, not for speed.

## Metrics

Per workload the runner records:

- `elapsed` — wall seconds in the workload entrypoint;
- `host-bytes` — host bytes consed (`sb-ext:get-bytes-consed`) over the run,
  including the guest compiler, so it is a whole-path figure;
- `gc.count`, `gc.time`, `gc.pause-max` — collection cycles entered, wall time
  inside them, and the longest single pause.

Objects-moved and bytes-moved per cycle are available from the plan's
`cycle-result-count` for a caller that wants collector-internal work; the
curve report currently plots the four metrics above.

## Caveats

- Pauses are measured inside the `collect` call, which includes the guest
  safepoint handshake; this is not a target pause-time claim.
- The managed extent is charged to the layout once. `semispace` halves it, so
  its usable heap is half the others at the same `--extent-mib`; compare
  `host-bytes` and pause shape, not only elapsed.
- Some checked-in files fault on unimplemented guest features under these
  collectors; a failed workload is recorded as `status: "error"` and does not
  abort the run.
