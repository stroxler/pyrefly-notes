#!/usr/bin/env python3
"""Validate dynamic-graph case constraints.

This validator checks:
1. baseline shape/soundness constraints
2. optional simulation-only assumptions used for SCC-discovery-complete cases
"""

import json
import sys
from pathlib import Path


def fail(msg: str) -> int:
    print(f"ERROR: {msg}")
    return 1


def cycle_nodes(graph: dict[str, set[str]], nodes: list[str]) -> set[str]:
    """Return nodes that are part of at least one directed cycle."""
    index = 0
    stack = []
    onstack = set()
    idx = {}
    low = {}
    sccs = []

    def strongconnect(v: str) -> None:
        nonlocal index
        idx[v] = index
        low[v] = index
        index += 1
        stack.append(v)
        onstack.add(v)

        for w in graph[v]:
            if w not in idx:
                strongconnect(w)
                low[v] = min(low[v], low[w])
            elif w in onstack:
                low[v] = min(low[v], idx[w])

        if low[v] == idx[v]:
            comp = []
            while True:
                w = stack.pop()
                onstack.remove(w)
                comp.append(w)
                if w == v:
                    break
            sccs.append(comp)

    for n in nodes:
        if n not in idx:
            strongconnect(n)

    cyc = set()
    for comp in sccs:
        if len(comp) > 1:
            cyc.update(comp)
        elif comp:
            n = comp[0]
            if n in graph[n]:
                cyc.add(n)
    return cyc


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: validate_case.py <case.json>")
        return 2

    case_path = Path(sys.argv[1])
    case = json.loads(case_path.read_text())

    nodes = case.get("nodes", [])
    steps = int(case.get("steps", 0))
    full_graph = case.get("full_graph", {})
    dynamic_steps = case.get("dynamic_steps", {})
    assumptions = case.get("meta", {}).get("simulation_assumptions", {})
    require_initial_cycle_coverage = assumptions.get("initial_cycle_coverage", True)
    require_edge_coverage_within_steps = assumptions.get(
        "edge_coverage_within_steps", True
    )

    node_set = set(nodes)

    if steps <= 0:
        return fail("steps must be >= 1")
    for n in nodes:
        if n not in full_graph:
            return fail(f"missing full_graph entry for node {n}")
        full = set(full_graph[n])
        if not full <= node_set:
            return fail(f"full_graph[{n}] contains unknown nodes")

    for k in range(steps):
        ks = str(k)
        if ks not in dynamic_steps:
            return fail(f"missing dynamic_steps[{ks}]")
        step_graph = dynamic_steps[ks]
        for n in nodes:
            if n not in step_graph:
                return fail(f"missing dynamic_steps[{ks}][{n}]")
            vis = set(step_graph[n])
            full = set(full_graph[n])
            if not vis <= full:
                return fail(
                    f"dynamic_steps[{ks}][{n}] not subset of full_graph[{n}]"
                )

    if require_initial_cycle_coverage:
        full_g = {n: set(full_graph[n]) for n in nodes}
        step0 = dynamic_steps.get("0", {})
        step0_g = {n: set(step0.get(n, [])) for n in nodes}
        full_cycle_nodes = cycle_nodes(full_g, nodes)
        if not full_cycle_nodes:
            return fail(
                "full_graph has no cycle participants; this simulation case is not useful "
                "for SCC-discovery invariants"
            )
        step0_cycle_nodes = cycle_nodes(step0_g, nodes)
        missing_in_step0 = sorted(full_cycle_nodes - step0_cycle_nodes)
        if missing_in_step0:
            return fail(
                "initial-cycle-coverage failed; nodes in full-graph cycles not in "
                f"step-0 cycles: {missing_in_step0}"
            )
        extra_in_step0 = sorted(step0_cycle_nodes - full_cycle_nodes)
        if extra_in_step0:
            return fail(
                "initial-cycle-coverage failed; nodes in step-0 cycles not in "
                f"full-graph cycles: {extra_in_step0}"
            )

    if require_edge_coverage_within_steps:
        observed = {n: set() for n in nodes}
        for k in range(steps):
            ks = str(k)
            step_graph = dynamic_steps[ks]
            for n in nodes:
                observed[n].update(step_graph[n])
        for n in nodes:
            full = set(full_graph[n])
            if not full <= observed[n]:
                missing = sorted(full - observed[n])
                return fail(
                    "edge-coverage-within-steps failed; "
                    f"missing edges for {n} within first {steps} steps: {missing}"
                )

    print(f"OK: {case_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
