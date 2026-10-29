#!/usr/bin/env python3
"""Convert an Alloy solution JSON trace into a raw TLA graph module.

Usage:
  python3 scripts/alloy_trace_to_tla_constants.py <solution.json> <out.tla> [--module-name NAME]

The emitted module defines raw graph operators:
  Nodes
  StepCount
  FullGraph
  DynamicSteps

DynamicSteps is emitted as a sequence (1-based), where entry i corresponds to
Alloy step index (i-1).
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path


NODE_RE = re.compile(r"Node\$(\d+)$")


def parse_int(atom: str) -> int:
    return int(atom)


def node_sort_key(atom: str):
    m = NODE_RE.match(atom)
    if m:
        return (0, int(m.group(1)))
    return (1, atom)


def tla_set(items: list[str]) -> str:
    if not items:
        return "{}"
    return "{" + ", ".join(f'"{x}"' for x in items) + "}"


def tla_graph_func(mapping: dict[str, set[str]], indent: str = "") -> str:
    keys = sorted(mapping.keys())
    lines = [f"{indent}[n \\in Nodes |->"]
    for i, k in enumerate(keys):
        dst = tla_set(sorted(mapping[k]))
        if i == 0:
            lines.append(f"{indent}    IF n = \"{k}\" THEN {dst}")
        elif i < len(keys) - 1:
            lines.append(f"{indent}    ELSE IF n = \"{k}\" THEN {dst}")
        else:
            lines.append(f"{indent}    ELSE {dst}")
    lines.append(f"{indent}]")
    return "\n".join(lines)


def usage() -> int:
    print(
        "Usage: alloy_trace_to_tla_constants.py <solution.json> <out.tla> [--module-name NAME]",
        file=sys.stderr,
    )
    return 2


def parse_args(argv: list[str]):
    if len(argv) not in (3, 5):
        raise ValueError("bad_arity")

    inp = Path(argv[1])
    out = Path(argv[2])
    module_name = "RawDynamicGraph"

    if len(argv) == 5:
        if argv[3] != "--module-name":
            raise ValueError("bad_flag")
        module_name = argv[4]
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", module_name):
            raise ValueError("bad_module_name")

    return inp, out, module_name


def main() -> int:
    try:
        inp, out, module_name = parse_args(sys.argv)
    except ValueError:
        return usage()

    data = json.loads(inp.read_text())
    if not data.get("instances"):
        print("ERROR: no instances in Alloy solution JSON", file=sys.stderr)
        return 1

    values = data["instances"][0]["values"]

    node_atom_set = {k for k in values if k.startswith("Node$")}

    for src, dst in values.get("FullGraph$0", {}).get("edges", []):
        if isinstance(src, str) and src.startswith("Node$"):
            node_atom_set.add(src)
        if isinstance(dst, str) and dst.startswith("Node$"):
            node_atom_set.add(dst)

    for step_atom in [k for k in values if k.startswith("Step$")]:
        for src, dst in values[step_atom].get("edges", []):
            if isinstance(src, str) and src.startswith("Node$"):
                node_atom_set.add(src)
            if isinstance(dst, str) and dst.startswith("Node$"):
                node_atom_set.add(dst)

    node_atoms = sorted(node_atom_set, key=node_sort_key)
    if not node_atoms:
        print("ERROR: no Node atoms found", file=sys.stderr)
        return 1

    aliases = {atom: f"n{i}" for i, atom in enumerate(node_atoms)}
    nodes = [aliases[a] for a in node_atoms]

    full_graph = {n: set() for n in nodes}
    for src, dst in values.get("FullGraph$0", {}).get("edges", []):
        full_graph[aliases[src]].add(aliases[dst])

    params = values.get("Params$0", {})
    step_count = None
    if "step_count" in params and params["step_count"]:
        step_count = parse_int(params["step_count"][0][0])

    step_map: dict[int, dict[str, set[str]]] = {}
    step_atoms = sorted([k for k in values if k.startswith("Step$")], key=node_sort_key)
    for step_atom in step_atoms:
        val = values[step_atom]
        if not val.get("idx"):
            print(f"ERROR: step atom {step_atom} has no idx", file=sys.stderr)
            return 1
        idx = parse_int(val["idx"][0][0])
        if idx in step_map:
            print(f"ERROR: duplicate step index {idx}", file=sys.stderr)
            return 1

        g = {n: set() for n in nodes}
        for src, dst in val.get("edges", []):
            g[aliases[src]].add(aliases[dst])
        step_map[idx] = g

    if step_count is None:
        step_count = len(step_map)

    expected_idxs = set(range(step_count))
    actual_idxs = set(step_map.keys())
    if actual_idxs != expected_idxs:
        missing = sorted(expected_idxs - actual_idxs)
        extra = sorted(actual_idxs - expected_idxs)
        print(
            f"ERROR: step indices mismatch; missing={missing} extra={extra}",
            file=sys.stderr,
        )
        return 1

    mapping_lines = ["\\* Node mapping (alias -> Alloy atom):"]
    mapping_lines.extend(f"\\* {aliases[a]} = {a}" for a in node_atoms)

    step_defs = []
    for idx in range(step_count):
        step_defs.append(f"Step{idx} ==")
        step_defs.append(tla_graph_func(step_map[idx]))
        step_defs.append("")

    dynamic_steps_expr = "<<" + ", ".join(f"Step{i}" for i in range(step_count)) + ">>"

    out_lines = [f"---- MODULE {module_name} ----", ""]
    out_lines.extend(mapping_lines)
    out_lines.extend(["", "Nodes == " + tla_set(nodes), "", f"StepCount == {step_count}", ""])
    out_lines.extend(["FullGraph ==", tla_graph_func(full_graph), ""])
    out_lines.extend(step_defs)
    out_lines.extend(["DynamicSteps ==", f"    {dynamic_steps_expr}", "", "====", ""])

    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("\n".join(out_lines))
    print(f"wrote {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
