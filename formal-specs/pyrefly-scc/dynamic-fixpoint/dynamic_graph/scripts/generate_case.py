#!/usr/bin/env python3
"""Generate a placeholder dynamic-graph case from config.

This is a scaffold entrypoint; replace with Alloy-backed generation.
"""

import json
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 3:
        print("Usage: generate_case.py <config.json> <out_case.json>")
        return 2

    cfg_path = Path(sys.argv[1])
    out_path = Path(sys.argv[2])

    cfg = json.loads(cfg_path.read_text())
    nodes = cfg["nodes"]
    steps = int(cfg["steps"])

    # Scaffold behavior: emit an empty-edge case with full visibility.
    full_graph = {n: [] for n in nodes}
    dynamic_steps = {
        str(k): {n: [] for n in nodes} for k in range(steps)
    }

    case = {
        "nodes": nodes,
        "steps": steps,
        "full_graph": full_graph,
        "dynamic_steps": dynamic_steps,
        "meta": {
            "generator": "scaffold",
            "note": "Replace scripts/generate_case.py with Alloy-backed generation",
            "simulation_assumptions": {
                "initial_cycle_coverage": bool(
                    cfg.get("require_initial_cycle_coverage", True)
                ),
                "edge_coverage_within_steps": bool(
                    cfg.get("require_edge_coverage_within_steps", True)
                ),
            },
        },
    }

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(case, indent=2, sort_keys=True) + "\n")
    print(f"wrote {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
