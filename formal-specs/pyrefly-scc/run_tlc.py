#!/usr/bin/env python3
"""Reproduce the baseline checks and the audit's intentionally failing witness."""

import argparse
import subprocess
import tempfile
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--jar", required=True, type=Path, help="Path to tla2tools.jar")
    parser.add_argument("--workers", type=int, default=2)
    parser.add_argument("--timeout", type=int, default=180, help="Seconds per case")
    parser.add_argument("--heap", default="2g", help="Java maximum heap")
    parser.add_argument("--full-stack", action="store_true", help="Also run the original four-node stack configuration")
    args = parser.parse_args()
    jar = args.jar.expanduser().resolve(strict=True)
    root = Path(__file__).resolve().parent
    logs = Path(tempfile.mkdtemp(prefix="pyrefly-scc-tlc-"))
    cases = [
        ("stack-small", "stack", "pyrefly_stack", "StackSmall.cfg", False),
        ("fixpoint", "fixpoint", "PyreflyFixpoint", "PyreflyFixpoint.cfg", False),
        ("reachability-probes", "checks", "ModelProbes", "ModelProbes.cfg", False),
        ("merge-mutation", "checks", "MergeMutation", "MergeMutation.cfg", False),
        ("unfinished-deadlock", "checks", "DeadlockProbe", "DeadlockProbe.cfg", True),
    ]
    if args.full_stack:
        cases.append(("stack-full", "stack", "pyrefly_stack", "pyrefly_stack.cfg", False))
    failures = []
    for name, directory, module, config, expect_deadlock in cases:
        command = [
            "java", "-XX:+UseParallelGC", "-Xmx" + args.heap,
            "-DTLA-Library=" + str(root / "fixpoint"),
            "-cp", str(jar), "tlc2.TLC", "-workers", str(args.workers),
            "-metadir", str(logs / (name + "-states")),
            "-config", str(root / directory / config),
            str(root / directory / (module + ".tla")),
        ]
        logfile = logs / (name + ".log")
        try:
            with logfile.open("w") as output:
                result = subprocess.run(command, cwd=logs, stdout=output, stderr=subprocess.STDOUT, timeout=args.timeout, check=False)
        except subprocess.TimeoutExpired:
            failures.append(name)
            print(f"INCOMPLETE {name}: timeout; {logfile}")
            continue
        text = logfile.read_text()
        matched = (
            result.returncode == 11 and "Deadlock reached." in text
            if expect_deadlock else
            result.returncode == 0 and "No error has been found." in text
        )
        label = "EXPECTED MODEL DEADLOCK" if expect_deadlock else "NO VIOLATION IN SCOPE"
        print(f"{label if matched else 'UNEXPECTED RESULT'} {name}: {logfile}")
        if not matched:
            failures.append(name)
    print(f"Logs: {logs}")
    if failures:
        raise SystemExit("Unexpected/incomplete cases: " + ", ".join(failures))
    print("All expected audit outcomes reproduced. This is not proof of production correctness.")


if __name__ == "__main__":
    main()
