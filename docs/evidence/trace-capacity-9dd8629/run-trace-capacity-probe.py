#!/usr/bin/env python3
"""Runner for trace-capacity-probe.lisp (prepared, NOT run by the reviewer).

What it does
  1. Verifies the frozen snapshot against review-snapshot.json (41 sources)
     plus test/quality/support.lisp and the probe file itself (sha256, stdlib).
  2. Records a full-tree hash snapshot of the frozen tree, excluding this
     probe's own artifact directory, so the run cannot silently modify it.
  3. Runs SBCL against the private snapshot source registry only.
  4. Writes the complete process output to trace-capacity-probe.log.
  5. Re-verifies the pinned hashes and the tree, and fails loudly on any
     change or on a non-zero SBCL exit.

Usage
  python3 run-trace-capacity-probe.py                 # full diagnostic
  python3 run-trace-capacity-probe.py --check-only    # hashes only, no SBCL
  python3 run-trace-capacity-probe.py --root <dir>    # alternate snapshot copy

Scope
  Diagnostic for one 4096-scale question on the frozen 9dd8629 tree.
  Not Gabriel, not GCBench, not target acceptance, not a benchmark.
"""

import argparse
import hashlib
import json
import os
import shlex
import subprocess
import sys
import time

DEFAULT_ROOT = "/tmp/clamsara-description-review-7p14doks/"
ARTIFACT_SUBDIR = "independent-review/deepseek-performance/"
PROBE_NAME = "trace-capacity-probe.lisp"
LOG_NAME = "trace-capacity-probe.log"


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def pinned_expectations(root):
    """(relative-path, expected-sha256, source-of-expectation) triples."""
    expectations = []
    snapshot_path = os.path.join(root, "review-snapshot.json")
    with open(snapshot_path) as handle:
        snapshot = json.load(handle)
    for relative, digest in sorted(snapshot["sources"].items()):
        expectations.append((relative, digest, "review-snapshot.json"))
    expectations.append(
        ("test/quality/support.lisp",
         "f370778fbf508c2543400efea3de841448611d5594a1cdba5661db4ad1c1f582",
         "probe pin (frozen tree; not in review-snapshot.json)"))
    return snapshot.get("commit"), expectations


def verify_pins(root, label):
    commit, expectations = pinned_expectations(root)
    rows = []
    ok = True
    for relative, expected, origin in expectations:
        path = os.path.join(root, relative)
        if not os.path.exists(path):
            rows.append((relative, None, expected, False, "missing"))
            ok = False
            continue
        actual = sha256_file(path)
        match = actual == expected
        ok = ok and match
        rows.append((relative, actual, expected, match, origin))
    print("[%s] snapshot commit %s; %d pinned files; all-match=%s"
          % (label, commit, len(rows), ok))
    for relative, actual, _expected, match, _origin in rows:
        if not match:
            print("  MISMATCH %s actual=%s" % (relative, actual))
    return ok, commit, rows


def tree_hashes(root):
    """Hash every file under the frozen tree except this probe's own artifacts."""
    skip_prefix = os.path.join(root, ARTIFACT_SUBDIR)
    result = {}
    for directory, _dirs, files in os.walk(root):
        for name in files:
            path = os.path.join(directory, name)
            if path.startswith(skip_prefix):
                continue
            result[os.path.relpath(path, root)] = sha256_file(path)
    return result


def compare_trees(before, after):
    added = sorted(set(after) - set(before))
    removed = sorted(set(before) - set(after))
    changed = sorted(name for name in set(before) & set(after)
                     if before[name] != after[name])
    return added, removed, changed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=DEFAULT_ROOT,
                        help="frozen snapshot root (default %s)" % DEFAULT_ROOT)
    parser.add_argument("--dynamic-space-mb", type=int, default=1024)
    parser.add_argument("--timeout", type=int, default=3600)
    parser.add_argument("--check-only", action="store_true",
                        help="verify hashes only; do not start SBCL")
    parser.add_argument("--sbcl", default="sbcl")
    arguments = parser.parse_args()

    root = arguments.root
    if not root.endswith("/"):
        root += "/"
    if not os.path.isdir(root):
        print("FAIL: root %s is not a directory" % root)
        return 2
    artifact_dir = os.path.join(root, ARTIFACT_SUBDIR)
    if not os.path.isdir(artifact_dir):
        print("FAIL: artifact directory %s is missing" % artifact_dir)
        return 2
    probe_path = os.path.join(artifact_dir, PROBE_NAME)
    if not os.path.exists(probe_path):
        print("FAIL: probe %s is missing" % probe_path)
        return 2

    pins_ok, commit, _rows = verify_pins(root, "before")
    if not pins_ok:
        print("FAIL: frozen source pins do not match before the run")
        return 1
    probe_digest_before = sha256_file(probe_path)
    before = tree_hashes(root)
    print("[before] tree files (excluding %s): %d" % (ARTIFACT_SUBDIR, len(before)))
    if arguments.check_only:
        print("[check-only] PASS")
        return 0

    command = [
        arguments.sbcl, "--noinform",
        # Runtime options must precede any Lisp option; --end-runtime-options
        # makes the boundary explicit.
        "--dynamic-space-size", str(arguments.dynamic_space_mb),
        "--end-runtime-options",
        "--non-interactive", "--disable-debugger", "--no-sysinit", "--no-userinit",
        "--eval", "(require :asdf)",
        "--eval",
        "(asdf:initialize-source-registry '(:source-registry "
        "(:directory #p\"%s\") :inherit-configuration))" % root,
        "--eval", "(asdf:load-system :clamsara)",
        "--eval", "(load \"%stest/quality/support.lisp\")" % root,
        "--eval", "(load \"%s\")" % probe_path,
        "--eval", "(clamsara.review.trace-capacity-probe:run-trace-capacity-probe)",
    ]
    environment = dict(os.environ)
    environment["CL_SOURCE_REGISTRY"] = root + "//"
    environment["CLAMSARA_PROBE_ROOT"] = root

    started = time.time()
    completed = subprocess.run(command, env=environment, capture_output=True,
                               text=True, timeout=arguments.timeout)
    elapsed = time.time() - started

    pins_ok_after, _commit2, _rows2 = verify_pins(root, "after")
    probe_digest_after = sha256_file(probe_path)
    after = tree_hashes(root)
    added, removed, changed = compare_trees(before, after)

    log_path = os.path.join(artifact_dir, LOG_NAME)
    with open(log_path, "w") as log:
        log.write("# trace-capacity-probe run\n")
        log.write("# frozen root: %s\n" % root)
        log.write("# snapshot commit: %s\n" % commit)
        log.write("# probe sha256: %s\n" % probe_digest_before)
        log.write("# command: %s\n" % " ".join(shlex.quote(part) for part in command))
        log.write("# env CL_SOURCE_REGISTRY: %s\n" % environment["CL_SOURCE_REGISTRY"])
        log.write("# env CLAMSARA_PROBE_ROOT: %s\n" % environment["CLAMSARA_PROBE_ROOT"])
        log.write("# exit code: %s\n" % completed.returncode)
        log.write("# duration seconds: %.3f\n" % elapsed)
        log.write("# tree files before/after: %d/%d; added=%s removed=%s changed=%s\n"
                  % (len(before), len(after), added or "[]", removed or "[]",
                     changed or "[]"))
        log.write("# pins match before/after: %s/%s; probe unchanged: %s\n"
                  % (pins_ok, pins_ok_after,
                     probe_digest_before == probe_digest_after))
        log.write("# ---- stdout ----\n")
        log.write(completed.stdout)
        log.write("# ---- stderr ----\n")
        log.write(completed.stderr)
        log.write("# ---- end ----\n")
    print("[run] sbcl exit=%s duration=%.3fs log=%s"
          % (completed.returncode, elapsed, log_path))
    print("[after] pins all-match=%s; probe unchanged=%s; tree added=%s removed=%s changed=%s"
          % (pins_ok_after, probe_digest_before == probe_digest_after,
             added or "[]", removed or "[]", changed or "[]"))

    failures = []
    if completed.returncode != 0:
        failures.append("sbcl exit code %s" % completed.returncode)
    if not pins_ok_after:
        failures.append("pinned source hashes changed during the run")
    if probe_digest_before != probe_digest_after:
        failures.append("probe file changed during the run")
    if added or removed or changed:
        failures.append("frozen tree changed (added=%s removed=%s changed=%s)"
                        % (added, removed, changed))
    for marker in ("TRACE-CAPACITY-PROBE :DONE",
                   "TRACE-CAPACITY-PROBE :SOURCE-HASHES-AFTER",
                   "TRACE-CAPACITY-PROBE :COMPARISON"):
        if marker not in completed.stdout:
            failures.append("probe output is missing %r" % marker)
    if failures:
        print("FAIL: " + "; ".join(failures))
        return 1
    print("PASS: probe completed; frozen tree unchanged")
    return 0


if __name__ == "__main__":
    sys.exit(main())
