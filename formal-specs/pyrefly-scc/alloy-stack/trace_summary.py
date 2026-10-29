#!/usr/bin/env python3
"""Summarize an Alloy solution JSON into a compact trace."""

import json
import sys


MULTI_ATOM_SIGS = {"Node", "Scc"}

def atom_name(s):
    """Shorten atom names: 'Node$2' -> 'N2', 'Scc$1' -> 'S1', 'Fresh$0' -> 'Fresh'."""
    if "$" not in s:
        return s
    base, idx = s.rsplit("$", 1)
    # Multi-atom sigs: shorten to N0, S0, etc.
    if base in MULTI_ATOM_SIGS:
        prefix = base[0].upper()
        return f"{prefix}{idx}"
    # Singletons (enums, CalcStack, Trace) always have $0 — just use base name
    return base


def summarize_state(state_obj):
    values = state_obj["values"]
    state_idx = state_obj["state"]

    # Event and acted_on from Trace
    trace = values.get("Trace$0", {})
    event = atom_name(trace.get("event", [[""]])[0][0])
    acted_on = atom_name(trace.get("acted_on", [[""]])[0][0])

    # Stack from CalcStack
    cs = values.get("CalcStack$0", {})
    depth = cs.get("depth", [[0]])[0][0]
    elems = cs.get("elems", [])
    # elems is list of [pos_str, node_str] pairs
    stack_entries = sorted(
        [(int(e[0]), atom_name(e[1])) for e in elems],
        key=lambda x: x[0],
    )
    stack_str = "[" + ", ".join(f"{n}" for _, n in stack_entries) + "]"

    # Node gstates
    node_states = {}
    for key, val in sorted(values.items()):
        if key.startswith("Node$"):
            name = atom_name(key)
            gs = atom_name(val.get("gstate", [[""]])[0][0])
            node_states[name] = gs

    nodes_str = " ".join(f"{n}={s}" for n, s in sorted(node_states.items()))

    # SCCs
    sccs = []
    for key, val in sorted(values.items()):
        if key.startswith("Scc$"):
            name = atom_name(key)
            members = [atom_name(m[0]) for m in val.get("members", [])]
            if members:
                anchor = val.get("anchor", [[""]])[0][0] if val.get("anchor") else "?"
                nst = {atom_name(e[0]): atom_name(e[1]) for e in val.get("nstate", [])}
                member_str = ",".join(sorted(members))
                nst_str = ",".join(f"{k}={v}" for k, v in sorted(nst.items()))
                sccs.append(f"{name}({member_str} @{anchor} [{nst_str}])")
    scc_str = " ".join(sccs) if sccs else "-"

    return f"State {state_idx}: {event:15s} {acted_on:6s} | stack={stack_str:20s} | {nodes_str} | scc={scc_str}"


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else None
    if not path:
        print("Usage: trace_summary.py <solution.json>")
        sys.exit(1)

    with open(path) as f:
        data = json.load(f)

    # Print graph (from state 0)
    if data["instances"]:
        values = data["instances"][0]["values"]
        print("Graph:")
        for key, val in sorted(values.items()):
            if key.startswith("Node$"):
                name = atom_name(key)
                deps_list = [atom_name(d[0]) for d in val.get("deps", [])]
                print(f"  {name} -> {deps_list}")
        print()

    loop = data.get("loopstate", -1)
    print("Trace:")
    for inst in data["instances"]:
        line = summarize_state(inst)
        if inst["state"] == loop:
            line += "  <-- loop"
        print(f"  {line}")


if __name__ == "__main__":
    main()
