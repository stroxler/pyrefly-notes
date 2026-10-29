#!/usr/bin/env python3
"""Bounded canonical-model regressions, including expected baseline failures.

Run the repaired tree with --root PATH. --baseline records known failures in
an unchanged old tree, so regression tests can precede the repair commit.
A successful safety/liveness run is followed by reachability probes: their
expected invariant violations witness completion and the requested events.
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent


def graph(nodes, edges):
    branches = " ".join(
        ("IF" if i == 0 else "ELSE IF")
        + f' n = "{n}" THEN '
        + "{"
        + ", ".join(f'"{d}"' for d in sorted(edges.get(n, [])))
        + "}"
        for i, n in enumerate(nodes)
    )
    return "[n \\in Nodes |-> " + branches + " ELSE {}]"


def raw(nodes, full, steps):
    text = (
        "---- MODULE RawDynamicGraph ----\nNodes == {"
        + ", ".join(f'"{n}"' for n in nodes)
        + "}\n"
    )
    text += f"StepCount == {len(steps)}\nFullGraph == " + graph(nodes, full) + "\n"
    text += "\n".join(f"Step{i} == " + graph(nodes, g) for i, g in enumerate(steps))
    return (
        text
        + "\nDynamicSteps == <<"
        + ", ".join(f"Step{i}" for i in range(len(steps)))
        + ">>\n====\n"
    )


def cases():
    full = {"a": {"a", "b"}, "b": {"a", "b"}}
    split = {"a": {"a"}, "b": {"b"}}
    warm_full = {"a": {"b"}, "b": {"a", "c"}, "c": {"a", "c"}}
    warm_initial = {"a": {"b"}, "b": {"a"}, "c": {"a", "c"}}
    caller_full = {"a": {"b", "c"}, "b": {"a", "b"}, "c": {"a"}}
    caller_initial = {"a": {"b", "c"}, "b": {"b"}, "c": {"a"}}
    pairs_full = {"a": {"b"}, "b": {"a", "c"}, "c": {"d"}, "d": {"a", "c"}}
    pairs_initial = {"a": {"b"}, "b": {"a"}, "c": {"d"}, "d": {"c"}}
    pairs_bridge = {"a": {"b"}, "b": {"a", "c"}, "c": {"d"}, "d": {"c"}}
    return {
        "example": {
            "source": True,
            "baseline": 13,
            "witness": (
                'Finished /\\ {e.members : e \\in committed_sccs} = {{"n0","n1","n2"}}'
            ),
        },
        "static-dag": {
            "nodes": ["a", "b", "c"],
            "full": {"a": {"b"}, "b": {"c"}, "c": set()},
            "period": 1,
            "baseline": 0,
            "witness": "Finished /\\ committed_sccs = {}",
        },
        "static-self": {
            "nodes": ["a"],
            "full": {"a": {"a"}},
            "period": 1,
            "baseline": 0,
            "witness": 'Finished /\\ {e.members : e \\in committed_sccs} = {{"a"}}',
        },
        "nested-independent": {
            "nodes": ["a", "b", "c"],
            "full": {"a": {"b", "c"}, "b": {"b"}, "c": {"a"}},
            "period": 4,
            "baseline": 12,
            "witness": (
                'Finished /\\ {e.members : e \\in committed_sccs} = {{"a","c"},{"b"}}'
            ),
        },
        "late-split-full": {
            "nodes": ["a", "b"],
            "full": full,
            "steps": [split] * 3 + [full],
            "baseline": 12,
            "witness": (
                "Finished /\\ late_merge_seen /\\ "
                '{e.members : e \\in committed_sccs} = {{"a","b"}}'
            ),
        },
        "warm-merge-availability": {
            "nodes": ["a", "b", "c"],
            "full": warm_full,
            "steps": [warm_initial] * 3 + [warm_full],
            "baseline": 12,
            "witness": (
                "Finished /\\ warm_merge_seen /\\ retained_read_seen /\\ "
                '{e.members : e \\in committed_sccs} = {{"a","b","c"}}'
            ),
        },
        "caller-handoff": {
            "nodes": ["a", "b", "c"],
            "full": caller_full,
            "steps": [caller_initial] * 3 + [caller_full],
            "baseline": 12,
            "witness": (
                "Finished /\\ warm_merge_seen /\\ "
                '{e.members : e \\in committed_sccs} = {{"a","b","c"}}'
            ),
            "extra_witness": (
                "\\E i \\in 1..Len(scc_stack) : "
                'scc_stack[i].owner.kind = "Calc" /\\ '
                "scc_stack[i].phase >= 2 /\\ scc_stack[i].needs_restart"
            ),
        },
        "two-pairs-late-merge": {
            "nodes": ["a", "b", "c", "d"],
            "full": pairs_full,
            "steps": [pairs_initial, pairs_bridge, pairs_full, pairs_initial],
            "baseline": 12,
            "baseline_invariant": "SccSegmentsMonotonicDisjoint",
            "witness": (
                "Finished /\\ late_merge_seen /\\ "
                '{e.members : e \\in committed_sccs} = {{"a","b","c","d"}}'
            ),
        },
        "period-union-ring": {
            # No row equals FullGraph; coverage requires combining the period.
            "nodes": ["a", "b", "c"],
            "full": {"a": {"a", "b"}, "b": {"b", "c"}, "c": {"c", "a"}},
            "steps": [
                {"a": {"a"}, "b": {"b"}, "c": {"c"}},
                {"a": {"b"}, "b": set(), "c": set()},
                {"a": set(), "b": {"c"}, "c": set()},
                {"a": set(), "b": set(), "c": {"a"}},
            ],
            "baseline": 12,
            "witness": (
                "Finished /\\ late_merge_seen /\\ "
                '{e.members : e \\in committed_sccs} = {{"a","b","c"}}'
            ),
        },
        "hidden-acyclic-rejected": {
            "nodes": ["a", "b"],
            "full": {"a": {"b"}, "b": {"b"}},
            "steps": [
                {"a": set(), "b": {"b"}},
                {"a": {"b"}, "b": {"b"}},
                {"a": {"b"}, "b": {"b"}},
                {"a": {"b"}, "b": {"b"}},
            ],
            "baseline": 12,
            "reject": True,
        },
        "acyclic-full-initial": {
            "nodes": ["a", "b"],
            "full": {"a": {"b"}, "b": {"b"}},
            "period": 4,
            "baseline": 0,
            "witness": 'Finished /\\ {e.members : e \\in committed_sccs} = {{"b"}}',
        },
    }


def tlc(run, args, module="PyreflyFixpoint", suffix="main"):
    tmp = run / "tmp"
    tmp.mkdir(exist_ok=True)
    log = run / (suffix + ".log")
    cmd = [
        "java",
        "-Djava.io.tmpdir=" + str(tmp),
        "-Xmx2g",
        "-XX:+UseParallelGC",
        "-cp",
        str(args.jar),
        "tlc2.TLC",
        "-workers",
        "2",
        "-metadir",
        str(run / ("states-" + suffix)),
        "-config",
        "PyreflyFixpoint.cfg",
        module + ".tla",
    ]
    with log.open("w") as out:
        try:
            result = subprocess.run(
                cmd, cwd=run, stdout=out, stderr=subprocess.STDOUT, timeout=args.timeout
            )
            return result.returncode, log.read_text()
        except subprocess.TimeoutExpired:
            return 124, log.read_text()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--root", type=Path, default=HERE.parent)
    p.add_argument("--jar", type=Path, required=True)
    p.add_argument("--timeout", type=int, default=90)
    p.add_argument("--baseline", action="store_true")
    p.add_argument("--case", action="append")
    args = p.parse_args()
    runs = Path(tempfile.mkdtemp(prefix="scc-model-regressions-"))
    selected = args.case or list(cases())
    results = []
    for name in selected:
        case = cases()[name]
        run = Path(tempfile.mkdtemp(prefix=name + "-", dir=runs))
        for file in ("PyreflyFixpoint.tla", "DynamicGraph.tla", "RawDynamicGraph.tla"):
            shutil.copy2(args.root / "behavior" / file, run / file)
        if not case.get("source"):
            steps = case.get("steps", [case["full"]] * case.get("period", 4))
            (run / "RawDynamicGraph.tla").write_text(
                raw(case["nodes"], case["full"], steps)
            )
        config = (args.root / "behavior/PyreflyFixpoint.cfg").read_text()
        if args.baseline:
            config += "\nPROPERTY Liveness\n"
        (run / "PyreflyFixpoint.cfg").write_text(config)
        code, text = tlc(run, args)
        if args.baseline:
            expected = case["baseline"]
            if expected == 13:
                diagnostic = "Temporal properties were violated"
            elif expected == 12:
                invariant = case.get(
                    "baseline_invariant",
                    "DepsBeforeDone"
                    if case.get("reject")
                    else "CommittedSccMatchesTruth",
                )
                diagnostic = f"Invariant {invariant} is violated"
            else:
                diagnostic = "Model checking completed. No error has been found."
            ok = code == expected and diagnostic in text
        elif case.get("reject"):
            ok = (
                code == 10
                and re.search(r"(?s)Error: Assumption .*? is false\.", text) is not None
            )
        else:
            ok = code == 0
        row = {"case": name, "exit": code, "passed": ok, "directory": str(run)}
        print(json.dumps(row), flush=True)
        if ok and not args.baseline and not case.get("reject"):
            # This deliberately failing invariant must be reached. A dead or
            # noncommitting protocol cannot satisfy the positive regression.
            probes = [
                ("completion", "Finished"),
                ("event", case.get("witness", "Finished")),
            ]
            if "extra_witness" in case:
                probes.append(("ownership", case["extra_witness"]))
            for suffix, witness in probes:
                (run / "RegressionProbe.tla").write_text(
                    "---- MODULE RegressionProbe ----\n"
                    "EXTENDS PyreflyFixpoint\nProbeNever == ~(" + witness + ")\n====\n"
                )
                (run / "PyreflyFixpoint.cfg").write_text(
                    config + "\nINVARIANT ProbeNever\n"
                )
                probe_code, probe_text = tlc(run, args, "RegressionProbe", suffix)
                found = (
                    probe_code == 12
                    and "Invariant ProbeNever is violated" in probe_text
                )
                row[suffix] = found
                ok = ok and found
                print(
                    json.dumps(
                        {
                            "case": name,
                            "probe": suffix,
                            "witnessed": found,
                            "exit": probe_code,
                        }
                    ),
                    flush=True,
                )
        row["passed"] = ok
        results.append(row)
    (runs / "latest-results.json").write_text(json.dumps(results, indent=2))
    return 0 if all(r["passed"] for r in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
