#!/usr/bin/env python3
"""Render generated case JSON to a TLC constants include fragment.

This is intentionally minimal and may need adaptation based on chosen
cfg templating strategy.
"""

import json
import sys
from pathlib import Path


def tla_set(items):
    if not items:
        return "{}"
    return "{" + ", ".join(f'"{x}"' for x in items) + "}"


def main() -> int:
    if len(sys.argv) != 3:
        print("Usage: render_tla_constants.py <case.json> <out.cfg.inc>")
        return 2

    case = json.loads(Path(sys.argv[1]).read_text())
    out = Path(sys.argv[2])

    nodes = case["nodes"]
    steps = int(case["steps"])

    lines = []
    lines.append(f"CONSTANT Nodes = {tla_set(nodes)}")
    lines.append(f"CONSTANT Steps = {steps}")
    lines.append("\\* TODO: render full_graph and dynamic_steps with final encoding")

    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("\n".join(lines) + "\n")
    print(f"wrote {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
