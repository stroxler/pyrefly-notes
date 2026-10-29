#!/usr/bin/env python3
"""Explore Pyrefly SCC behavior for a supplied graph in a disposable directory."""

import argparse
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


def positive_int(value):
    number = int(value)
    if number <= 0:
        raise argparse.ArgumentTypeError("must be positive")
    return number


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--jar", required=True, type=Path, help="Path to tla2tools.jar")
    inputs = parser.add_mutually_exclusive_group()
    inputs.add_argument("--graph", type=Path, help="A RawDynamicGraph.tla input module")
    inputs.add_argument(
        "--alloy-json", type=Path, help="An Alloy generator solution JSON"
    )
    parser.add_argument("--workers", type=positive_int, default=2)
    parser.add_argument("--timeout", type=positive_int, default=180, help="Seconds")
    parser.add_argument("--heap", default="2g", help="Java maximum heap")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent
    jar = args.jar.expanduser().resolve(strict=True)
    run = Path(tempfile.mkdtemp(prefix="pyrefly-scc-tlc-"))
    for name in (
        "PyreflyFixpoint.tla",
        "PyreflyFixpoint.cfg",
        "DynamicGraph.tla",
        "RawDynamicGraph.tla",
    ):
        shutil.copy2(root / "behavior" / name, run / name)
    if args.graph:
        shutil.copy2(
            args.graph.expanduser().resolve(strict=True), run / "RawDynamicGraph.tla"
        )
    elif args.alloy_json:
        subprocess.run(
            [
                sys.executable,
                str(root / "graphs" / "alloy_trace_to_tla_constants.py"),
                str(args.alloy_json.expanduser().resolve(strict=True)),
                str(run / "RawDynamicGraph.tla"),
            ],
            check=True,
        )
    print(f"Run directory: {run}", flush=True)
    command = [
        "java",
        "-XX:+UseParallelGC",
        "-Xmx" + args.heap,
        "-cp",
        str(jar),
        "tlc2.TLC",
        "-workers",
        str(args.workers),
        "-metadir",
        str(run / "states"),
        "-config",
        "PyreflyFixpoint.cfg",
        "PyreflyFixpoint.tla",
    ]
    try:
        result = subprocess.run(command, cwd=run, timeout=args.timeout, check=False)
    except subprocess.TimeoutExpired:
        print("INCOMPLETE: TLC exceeded the time bound.", file=sys.stderr)
        return 124
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
