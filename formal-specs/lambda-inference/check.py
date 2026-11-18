#!/usr/bin/env python3
"""Check native Alloy 6 traces, expected outcomes, state bounds, and lasso evidence."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent
JAR_SHA256 = "6037cbeee0e8423c1c468447ed10f5fcf2f2743a2ffc39cb1c81f2905c0fdb9d"
TERMINAL = re.compile(r"^\d+\.\s+(run|check)\s+(\w+)\s+.*\b(SAT|UNSAT)\s*$")
FIELDS = {"phase", "thread", "parent", "top", "installed", "published", "selected", "event", "actor", "policy"}


def terminal_results(log):
    """Require completed-command lines; no output file is not proof of UNSAT."""
    results = {}
    for line in log.replace("\b", "").splitlines():
        match = TERMINAL.fullmatch(line)
        if match:
            kind, name, status = match.groups()
            if name in results:
                raise ValueError(f"duplicate terminal result: {name}")
            results[name] = (kind, status == "SAT")
    return results


def read_lasso(path):
    """Alloy 6.2's XML carries the actual loop; its JSON loopstate can be -1."""
    instances = ET.parse(path).getroot().findall("instance")
    if not instances:
        raise ValueError("XML has no temporal instances")
    attributes = instances[0].attrib
    length = int(attributes["tracelength"])
    loop_length = int(attributes["looplength"])
    if len(instances) != length or not 1 <= loop_length <= length:
        raise ValueError("incomplete or invalid XML lasso")
    return {
        "states": length, "loop_start": length - loop_length,
        "min_states": int(attributes["mintrace"]),
        "max_states": int(attributes["maxtrace"]),
    }


def execution_values(instance):
    return {k: v for k, v in instance["values"].items() if "phase" in v}


def validate(receipt, expectations, log, lassos):
    commands = receipt["commands"]
    terminal = terminal_results(log)
    if set(commands) != set(expectations) or set(terminal) != set(expectations):
        raise ValueError("missing, extra, or incomplete checker commands")
    if set(lassos) != {name for name, (_, sat) in terminal.items() if sat}:
        raise ValueError("missing or extra SAT lasso evidence")
    report = {}
    for name, expected in expectations.items():
        command = commands[name]
        kind, sat = terminal[name]
        solutions = command.get("solution", [])
        scopes = {
            f"exactly {expected['executions']} Execution",
            f"exactly {expected['threads']} ThreadState",
        }
        if (
            not isinstance(solutions, list)
            or kind != expected["kind"] or command["type"] != kind
            or sat != expected["sat"] or bool(solutions) != sat
            or command.get("expects", 0) != int(sat)
            or set(command["scopes"]) != scopes
            or command["minprefix"] != expected["min_states"]
            or command["maxprefix"] != expected["max_states"]
        ):
            raise ValueError(f"unexpected outcome, kind, or temporal scope: {name}")
        report[name] = {**expected, "status": "SAT" if sat else "UNSAT"}
        if sat:
            lasso = lassos[name]
            instances = solutions[0]["instances"]
            if (
                not expected["min_states"] <= lasso["states"] <= expected["max_states"]
                or lasso["min_states"] != expected["min_states"]
                or lasso["max_states"] != expected["max_states"]
                or len(instances) != lasso["states"]
                or not 0 <= lasso["loop_start"] < len(instances)
            ):
                raise ValueError(f"incomplete or out-of-bound lasso: {name}")
            identities = None
            for index, instance in enumerate(instances):
                values = execution_values(instance)
                if (
                    instance.get("state", 0) != index
                    or len(values) != expected["executions"]
                    or any(not FIELDS <= set(v) for v in values.values())
                    or (identities is not None and set(values) != identities)
                ):
                    raise ValueError(f"incomplete native state: {name}, state {index}")
                identities = set(values)
            report[name].update(lasso)
    return report


def atom(name):
    short = name.split("/")[-1]
    return short.replace("$", "") if short.startswith("ThreadState$") else short.split("$")[0]


def one(relation):
    return atom(relation[0][0]) if relation else "-"


def pairs(relation):
    return ",".join(f"{atom(a)}:{atom(b)}" for a, b in relation) or "-"


def render(solution, lasso):
    """Normalize real native states, preserving identities and removing stutters."""
    instances = solution["instances"]
    executions = sorted(execution_values(instances[0]))
    lines = [f"Native lasso: {lasso['states']} states; loop starts at state {lasso['loop_start']}."]
    for index, execution in enumerate(executions, 1):
        first = execution_values(instances[0])[execution]
        lines.append(f"Execution {index}: {one(first['policy'])}")
        previous = None
        meaningful = 0
        for state_index, instance in enumerate(instances):
            state = execution_values(instance)[execution]
            fingerprint = json.dumps(state, sort_keys=True)
            if fingerprint == previous:
                continue
            previous = fingerprint
            lines.append(
                f"{meaningful:02} [state {state_index:02}] {one(state['event']):14} "
                f"{one(state['actor']):8} working={pairs(state['installed'])} "
                f"published={one(state['published'])} selected={pairs(state['selected'])} "
                f"top={pairs(state['top'])} parent={pairs(state['parent'])}"
            )
            meaningful += 1
        lines.append("")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--java", default=os.environ.get("JAVA", "java"))
    parser.add_argument("--jar", type=Path, default=Path(os.environ.get("ALLOY_JAR", ROOT / ".tools/alloy-6.2.0.jar")))
    parser.add_argument("--solver", default="glucose")
    parser.add_argument("--timeout", type=int, default=1200, help="seconds per model")
    parser.add_argument("--output", type=Path, default=ROOT / "out")
    args = parser.parse_args()
    if hashlib.sha256(args.jar.read_bytes()).hexdigest() != JAR_SHA256:
        raise ValueError("checker jar is not the pinned Alloy 6.2.0 distribution")
    args.output.mkdir(parents=True, exist_ok=True)
    run_dir = Path(tempfile.mkdtemp(prefix="check-", dir=args.output))
    expectations = json.loads((ROOT / "expectations.json").read_text())
    report = {
        "solver": args.solver, "jar_sha256": JAR_SHA256, "models": {},
        "source_sha256": {model: hashlib.sha256((ROOT / model).read_bytes()).hexdigest() for model in expectations},
    }
    for model, expected in expectations.items():
        destination = run_dir / Path(model).stem
        command = [
            args.java, "-Xmx4g", "-jar", str(args.jar.resolve()), "exec",
            "-s", args.solver, "-c", "*", "-t", "xml", "-o", str(destination.resolve()),
            str(ROOT / model),
        ]
        completed = subprocess.run(command, capture_output=True, text=True, timeout=args.timeout, cwd=ROOT)
        log = completed.stdout + "\n" + completed.stderr
        (run_dir / f"{Path(model).stem}.log").write_text(log)
        if completed.returncode:
            raise RuntimeError(f"checker failed ({completed.returncode}): {model}\n{log}")
        receipt = json.loads((destination / "receipt.json").read_text())
        lassos = {
            name: read_lasso(destination / f"{name}-solution-0.xml")
            for name, (_, sat) in terminal_results(log).items() if sat
        }
        report["models"][model] = validate(receipt, expected, log, lassos)
        for name, result in report["models"][model].items():
            print(f"{result['status']:5} {result['kind']:5} {name}", flush=True)
            if result["sat"]:
                text = render(receipt["commands"][name]["solution"][0], lassos[name])
                (run_dir / f"{name}.txt").write_text(text)
    report["all_expected"] = True
    (run_dir / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"All {sum(map(len, expectations.values()))} outcomes matched. Evidence: {run_dir}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, RuntimeError, ET.ParseError, subprocess.TimeoutExpired) as error:
        print(f"CHECKING FAILED: {error}", file=sys.stderr)
        sys.exit(1)
