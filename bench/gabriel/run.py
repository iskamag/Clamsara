#!/usr/bin/env python3
"""Gabriel benchmark driver over the Clamsara reference collectors.

Runs one fresh SBCL process per (collector) -- the hosted Maclina VM is a
fixed, image-global resource, and an isolated process also isolates host
allocation measurement -- using bench/gabriel/runner.lisp.  Parses the
machine-readable RESULT/SUMMARY lines and writes a JSON report, per-workload
and aggregated curves in SVG, and a Markdown summary.

This is a development harness, not a conformance or acceptance gate.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from typing import Optional

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RUNNER = os.path.join(REPO, "bench", "gabriel", "runner.lisp")
RESULTS = os.path.join(REPO, "bench", "gabriel", "results")

COLLECTORS = ["semispace", "marksweep", "immix", "generational", "nogc"]
# Workloads exercised by the hosted guest (any of the 19 files may be named).
DEFAULT_GC_WORKLOADS = ["tak", "takr", "takl", "dderiv", "deriv", "destru"]


@dataclass
class WorkloadResult:
    collector: str
    workload: str
    status: str
    value: object
    load: float
    elapsed: float
    host_bytes: int
    gc: dict = field(default_factory=dict)


def run_collector(collector: str, extent: int, workloads: list[str],
                  dynamic_space_mb: int, quiet: bool,
                  repeats: int = 1) -> tuple[list[WorkloadResult], Optional[dict]]:
    # Repeating the workload list in one process keeps the guest warm and lets
    # the driver take a median; the collector runs once per collector either way.
    argv = [
        "sbcl", "--dynamic-space-size", str(dynamic_space_mb),
        "--noinform", "--non-interactive",
        "--load", RUNNER,
        f"collector={collector}",
        f"extent={extent}",
        f"workloads={','.join(workloads * max(1, repeats))}",
    ]
    proc = subprocess.run(argv, cwd=REPO, capture_output=True, text=True)
    results: list[WorkloadResult] = []
    summary = None
    for line in proc.stdout.splitlines():
        line = line.strip()
        if line.startswith("RESULT "):
            payload = json.loads(line[len("RESULT "):])
            results.append(WorkloadResult(
                collector=payload["collector"], workload=payload["workload"],
                status=payload["status"], value=payload["value"],
                load=payload["load"], elapsed=payload["elapsed"],
                host_bytes=payload["host-bytes"],
                gc=normalize_gc(payload["gc"])))
        elif line.startswith("SUMMARY "):
            summary = parse_lisp_summary(line[len("SUMMARY "):])
    if not results and not quiet:
        sys.stderr.write(f"[{collector}] no results; exit={proc.returncode}\n")
        sys.stderr.write(proc.stderr[-2000:])
    return results, summary


def normalize_gc(gc) -> dict:
    if not isinstance(gc, dict):
        return {}
    return {k: v for k, v in gc.items() if k in
            ("count", "time", "moved", "bytes", "dead", "discovered", "pause-max")}


def parse_lisp_summary(text: str) -> dict:
    """Parse the harness's Lisp plist SUMMARY line without a Lisp reader.

    Only the scalar fields the driver needs are extracted; the workload vector
    is already captured from the RESULT lines.
    """
    def number(key):
        m = re.search(rf":{re.escape(key)}\s+(-?\d+(?:\.\d+)?)", text)
        return float(m.group(1)) if m else None

    return {
        "collector": (re.search(r':COLLECTOR\s+"([^"]+)"', text) or [None, None])[1],
        "extent": number("EXTENT"),
    }


def percentile(values: list[float], fraction: float) -> Optional[float]:
    if not values:
        return None
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, round(fraction * (len(ordered) - 1))))
    return ordered[index]


# --- SVG curve rendering -----------------------------------------------------

PALETTE = ["#1f77b4", "#d62728", "#2ca02c", "#9467bd", "#ff7f0e", "#17becf"]
SVG_TEMPLATE = """<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}"
 viewBox="0 0 {w} {h}" font-family="sans-serif" font-size="12">
<rect width="{w}" height="{h}" fill="white"/>
<text x="{cx}" y="18" text-anchor="middle" font-size="14" font-weight="bold">{title}</text>
<text x="{xlabel_x}" y="{xlabel_y}" text-anchor="middle">{xlabel}</text>
<text x="16" y="{ylabel_rot_y}" text-anchor="middle" transform="rotate(-90 16 {ylabel_rot_y})">{ylabel}</text>
<line x1="{mx}" y1="{bottom}" x2="{right}" y2="{bottom}" stroke="#333"/>
<line x1="{mx}" y1="{my}" x2="{mx}" y2="{bottom}" stroke="#333"/>
{xticks}
{yticks}
{series}
<g>{legend}</g>
</svg>
"""


def nice_ticks(lo: float, hi: float, count: int = 5) -> list[float]:
    if hi <= lo:
        return [lo]
    raw = (hi - lo) / count
    magnitude = 10 ** int(_floor_log10(raw))
    for multiple in (1, 2, 2.5, 5, 10):
        step = magnitude * multiple
        if step >= raw:
            break
    ticks = []
    value = lo - (lo % step) + step
    while value <= hi + step * 0.5:
        if value >= lo - step * 0.5:
            ticks.append(round(value, 10))
        value += step
    return ticks


def _floor_log10(x: float) -> float:
    import math
    return math.floor(math.log10(x)) if x > 0 else 0


def render_curve(path: str, title: str, xlabel: str, ylabel: str,
                 series: dict[str, list[tuple[float, float]]],
                 x_is_category: bool = False) -> None:
    w, h = 900, 480
    margin = dict(left=80, right=220, top=40, bottom=60)
    mx, my = margin["left"], margin["top"]
    cw = w - margin["left"] - margin["right"]
    ch = h - margin["top"] - margin["bottom"]

    points = [(x, y) for ser in series.values() for x, y in ser if y is not None]
    if not points:
        points = [(0, 0), (1, 1)]
    xs = [p[0] for p in points]
    ys = [p[1] for p in points]
    xlo, xhi = min(xs), max(xs)
    ylo = min(0.0, min(ys))
    yhi = max(ys) * 1.1 or 1.0

    def sx(x):
        return mx + cw * ((x - xlo) / (xhi - xlo) if xhi > xlo else 0.5)

    def sy(y):
        return my + ch - ch * ((y - ylo) / (yhi - ylo) if yhi > ylo else 0.5)

    parts = [SVG_TEMPLATE]

    xticks = []
    for tick in nice_ticks(xlo, xhi):
        px = sx(tick)
        label = tick if tick == int(tick) else f"{tick:.4g}"
        xticks.append(f'<line x1="{px:.1f}" y1="{my + ch}" x2="{px:.1f}" y2="{my + ch + 5}" stroke="#333"/>'
                      f'<text x="{px:.1f}" y="{my + ch + 19}" text-anchor="middle">{label}</text>')
        xticks.append(f'<line x1="{px:.1f}" y1="{my}" x2="{px:.1f}" y2="{my + ch}" stroke="#eee"/>')
    yticks = []
    for tick in nice_ticks(ylo, yhi):
        py = sy(tick)
        label = f"{tick:.4g}"
        yticks.append(f'<line x1="{mx - 5}" y1="{py:.1f}" x2="{mx}" y2="{py:.1f}" stroke="#333"/>'
                      f'<text x="{mx - 9}" y="{py + 4:.1f}" text-anchor="end">{label}</text>')
        yticks.append(f'<line x1="{mx}" y1="{py:.1f}" x2="{mx + cw}" y2="{py:.1f}" stroke="#eee"/>')

    svg_parts = []
    legend = []
    for index, (name, ser) in enumerate(sorted(series.items())):
        colour = PALETTE[index % len(PALETTE)]
        path_d = []
        for x, y in ser:
            if y is None:
                continue
            cmd = "M" if not path_d else "L"
            path_d.append(f"{cmd}{sx(x):.1f},{sy(y):.1f}")
        if path_d:
            svg_parts.append(f'<path d="{" ".join(path_d)}" fill="none" '
                             f'stroke="{colour}" stroke-width="2"/>')
        for x, y in ser:
            if y is None:
                continue
            svg_parts.append(f'<circle cx="{sx(x):.1f}" cy="{sy(y):.1f}" r="3.5" fill="{colour}"/>')
        legend.append(f'<rect x="{mx + cw + 16}" y="{my + 8 + index * 22}" width="12" height="12" '
                      f'fill="{colour}"/>'
                      f'<text x="{mx + cw + 34}" y="{my + 18 + index * 22}">{name}</text>')

    svg = SVG_TEMPLATE.format(
        w=w, h=h, cx=w / 2, mx=mx, my=my, right=mx + cw, bottom=my + ch,
        xlabel_x=mx + cw / 2, ylabel_rot_y=my + ch / 2,
        xlabel_y=h - 12,
        title=title, xlabel=xlabel, ylabel=ylabel,
        xticks="\n".join(xticks), yticks="\n".join(yticks),
        series="\n".join(svg_parts), legend="\n".join(legend))

    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as handle:
        handle.write(svg)


# --- Reporting ---------------------------------------------------------------

def median(values: list) -> Optional[float]:
    values = [v for v in values if v is not None]
    if not values:
        return None
    ordered = sorted(values)
    middle = len(ordered) // 2
    if len(ordered) % 2:
        return ordered[middle]
    return (ordered[middle - 1] + ordered[middle]) / 2


def build_report(all_results: list[WorkloadResult], extent: int,
                 dynamic_space_mb: int) -> dict:
    # Group repeated runs of the same (collector, workload); report the median so
    # a single scheduling hiccup does not dominate.
    grouped: dict[str, dict[str, list[WorkloadResult]]] = {}
    for result in all_results:
        grouped.setdefault(result.collector, {}).setdefault(result.workload, []).append(result)

    collectors = sorted(grouped)
    workloads = sorted({r.workload for r in all_results})
    report = {
        "extent_bytes": extent,
        "extent_mib": extent / (1024 * 1024),
        "dynamic_space_mib": dynamic_space_mb,
        "collectors": collectors,
        "workloads": workloads,
        "results": {},
        "aggregate": {},
    }
    for collector in collectors:
        report["results"][collector] = {}
        for workload in workloads:
            runs = grouped[collector].get(workload)
            if not runs:
                continue
            ok = [r for r in runs if r.status == "ok"]
            report["results"][collector][workload] = {
                "status": runs[0].status,
                "value": runs[0].value,
                "runs": len(runs),
                "load": median([r.load for r in runs]),
                "elapsed": median([r.elapsed for r in ok]) if ok else None,
                "host_bytes": median([r.host_bytes for r in ok]) if ok else None,
                "gc": {
                    "count": median([(r.gc or {}).get("count", 0) for r in ok]) if ok else None,
                    "time": median([(r.gc or {}).get("time", 0) for r in ok]) if ok else None,
                    "pause-max": median([(r.gc or {}).get("pause-max", 0) for r in ok]) if ok else None,
                },
            }

    def entries(collector):
        return [e for e in report["results"][collector].values() if e["status"] == "ok"]

    def elapsed_list(collector):
        return [e["elapsed"] for e in entries(collector) if e["elapsed"]]

    def host_list(collector):
        return [e["host_bytes"] for e in entries(collector) if e["host_bytes"] is not None]

    def gc_count(collector):
        return sum(int(e["gc"].get("count") or 0) for e in entries(collector))

    report["aggregate"] = {
        collector: {
            "ok": sum(1 for e in report["results"][collector].values()
                      if e["status"] == "ok"),
            "total": len(report["results"][collector]),
            "runs": max((e["runs"] for e in report["results"][collector].values()),
                        default=0),
            "elapsed_total": sum(elapsed_list(collector)) or None,
            "elapsed_max": max(elapsed_list(collector)) if elapsed_list(collector) else None,
            "host_bytes_total": sum(host_list(collector)) or None,
            "host_bytes_p50": percentile(host_list(collector), 0.5),
            "host_bytes_p95": percentile(host_list(collector), 0.95),
            "gc_cycles": gc_count(collector),
        }
        for collector in collectors
    }
    return report


def render_all(report: dict, out_dir: str) -> list[str]:
    os.makedirs(out_dir, exist_ok=True)
    written = []
    collectors = report["collectors"]
    workloads = report["workloads"]
    results = report["results"]
    extent_mib = report["extent_mib"]

    def xpos(workload):
        return workloads.index(workload)

    for metric, label, key in [
        ("elapsed", "entrypoint seconds (lower is better)", lambda r: r.get("elapsed")),
        ("load", "load+compile seconds (setup, lower is better)",
         lambda r: r.get("load")),
        ("host_bytes", "host bytes consed over the run (lower is better)",
         lambda r: r.get("host_bytes")),
        ("gc_pause", "longest GC pause (s)", lambda r: (r.get("gc") or {}).get("pause-max")),
        ("gc_count", "GC cycles", lambda r: (r.get("gc") or {}).get("count")),
    ]:
        series = {}
        for collector in collectors:
            points = []
            for workload in workloads:
                entry = results.get(collector, {}).get(workload)
                points.append((xpos(workload),
                               key(entry) if entry and entry.get("status") == "ok" else None))
            series[collector] = points
        path = os.path.join(out_dir, f"curve-{metric}.svg")
        render_curve(path, f"{metric.replace('_', ' ')} vs Gabriel workload "
                            f"({extent_mib:g} MiB managed extent)",
                     "Gabriel workload (benchmark order)", label, series)
        written.append(path)

    # Aggregated host bytes per collector (bar-like line at one x).
    series = {}
    for collector in collectors:
        total = report["aggregate"][collector]["host_bytes_total"]
        if total:
            series[collector] = [(0, total)]
    if len(series) > 1:
        path = os.path.join(out_dir, "curve-host-bytes-total.svg")
        render_curve(path, f"total host bytes consed ({extent_mib:g} MiB extent)",
                     "collector", "bytes", series)
        written.append(path)
    return written


def write_markdown(report: dict, out_dir: str, written_svgs: list[str]) -> str:
    lines = ["# Gabriel benchmark — Clamsara reference collectors", ""]
    runs = report["aggregate"][report["collectors"][0]]["runs"] if report["collectors"] else 0
    lines.append(f"Managed extent: {report['extent_mib']:g} MiB; "
                 f"SBCL dynamic space: {report['dynamic_space_mib']} MiB; "
                 f"{runs} run(s) per workload (median reported). "
                 "Each collector runs in a fresh process.")
    lines.append("")
    lines.append("A development harness, not a conformance or acceptance gate. "
                 "Host-byte columns measure allocation on the whole run path "
                 "(workload + collector), so host-GC noise is included.")
    lines.append("")
    lines.append("## Aggregate")
    lines.append("")
    lines.append("| collector | ok/total | elapsed total (s) | host bytes total | host bytes p95 | GC cycles |")
    lines.append("|---|---|---|---|---|---|")
    for collector in report["collectors"]:
        agg = report["aggregate"][collector]
        lines.append("| {c} | {ok}/{total} | {el} | {hb} | {p95} | {gc} |".format(
            c=collector, ok=agg["ok"], total=agg["total"],
            el=fmt(agg["elapsed_total"]), hb=fmt(agg["host_bytes_total"]),
            p95=fmt(agg["host_bytes_p95"]), gc=agg["gc_cycles"]))
    lines.append("")
    lines.append("## Per workload")
    lines.append("")
    lines.append("### Entrypoint seconds (excludes read/compile)")
    lines.append("")
    header = "| workload | " + " | ".join(report["collectors"]) + " |"
    lines.append(header)
    lines.append("|" + "---|" * (len(report["collectors"]) + 1))
    for workload in report["workloads"]:
        cells = []
        for collector in report["collectors"]:
            entry = report["results"].get(collector, {}).get(workload)
            if entry is None:
                cells.append("—")
            elif entry["status"] != "ok":
                cells.append("error")
            else:
                cells.append(fmt(entry["elapsed"]))
        lines.append(f"| {workload} | " + " | ".join(cells) + " |")
    lines.append("")
    lines.append("### GC cycles (collections entered during the entrypoint)")
    lines.append("")
    lines.append(header)
    lines.append("|" + "---|" * (len(report["collectors"]) + 1))
    for workload in report["workloads"]:
        cells = []
        for collector in report["collectors"]:
            entry = report["results"].get(collector, {}).get(workload)
            if entry is None:
                cells.append("—")
            elif entry["status"] != "ok":
                cells.append("error")
            else:
                cells.append(str((entry["gc"] or {}).get("count", "—")))
        lines.append(f"| {workload} | " + " | ".join(cells) + " |")
    lines.append("")
    lines.append("### Host bytes consed (whole run; dominated by the guest interpreter)")
    lines.append("")
    lines.append(header)
    lines.append("|" + "---|" * (len(report["collectors"]) + 1))
    for workload in report["workloads"]:
        cells = []
        for collector in report["collectors"]:
            entry = report["results"].get(collector, {}).get(workload)
            if entry is None:
                cells.append("—")
            elif entry["status"] != "ok":
                cells.append("error")
            else:
                cells.append(fmt(entry["host_bytes"]))
        lines.append(f"| {workload} | " + " | ".join(cells) + " |")
    lines.append("")
    lines.append("## Curves")
    lines.append("")
    for svg in written_svgs:
        lines.append(f"- `{os.path.relpath(svg, REPO)}`")
    lines.append("")
    path = os.path.join(out_dir, "REPORT.md")
    with open(path, "w") as handle:
        handle.write("\n".join(lines))
    return path


def fmt(value) -> str:
    if value is None:
        return "—"
    if isinstance(value, float):
        return f"{value:,.6g}" if value < 1e6 else f"{value:,.0f}"
    return f"{value:,}"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--collectors", default=",".join(COLLECTORS),
                        help="comma-separated collector keys")
    parser.add_argument("--workloads", default=",".join(DEFAULT_GC_WORKLOADS),
                        help="comma-separated Gabriel workload keys")
    parser.add_argument("--extent-mib", type=int, default=16,
                        help="managed extent in MiB (default 16)")
    parser.add_argument("--dynamic-space-mib", type=int, default=8192)
    parser.add_argument("--repeats", type=int, default=3,
                        help="runs per workload; the median is reported")
    parser.add_argument("--out", default=RESULTS)
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()

    extent = args.extent_mib * 1024 * 1024
    collectors = [c.strip() for c in args.collectors.split(",") if c.strip()]
    workloads = [w.strip() for w in args.workloads.split(",") if w.strip()]

    all_results: list[WorkloadResult] = []
    for collector in collectors:
        if not args.quiet:
            print(f"[driver] {collector} @ {args.extent_mib} MiB ...", file=sys.stderr)
        results, _ = run_collector(collector, extent, workloads,
                                   args.dynamic_space_mib, args.quiet,
                                   repeats=max(1, args.repeats))
        all_results.extend(results)
        if not args.quiet:
            ok = sum(1 for r in results if r.status == "ok")
            print(f"[driver] {collector}: {ok}/{len(results)} ok", file=sys.stderr)

    if not all_results:
        print("no results", file=sys.stderr)
        return 1

    report = build_report(all_results, extent, args.dynamic_space_mib)
    written = render_all(report, args.out)
    markdown = write_markdown(report, args.out, written)
    with open(os.path.join(args.out, "report.json"), "w") as handle:
        json.dump(report, handle, indent=2)
    if not args.quiet:
        print(f"[driver] wrote {markdown}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
