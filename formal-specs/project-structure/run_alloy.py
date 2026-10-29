#!/usr/bin/env python3
"""Run this project's named, single-line Alloy commands and verify their expectations.

Alloy 6.2.0 can exit zero on some errors. A successful process is insufficient:
require a receipt for every declared command and the expected SAT/UNSAT outcome.
An UNSAT check has no counterexample; a SAT run witnesses admitted behavior;
a SAT check witnesses a deliberately false assertion. Bounds remain in the model.
"""

import argparse
import json
import math
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile


COMMAND = re.compile(r"^(check|run)\s+(\w+)\b.*\bexpect\s+([01])\s*$")


def expectations(model):
    result = {}
    for line in model.read_text().splitlines():
        stripped = line.strip()
        if not re.match(r"^(check|run)\b", stripped):
            continue
        match = COMMAND.fullmatch(stripped)
        if not match:
            raise ValueError("Commands must be named, single-line, and end in expect 0 or 1")
        kind, name, expected = match.groups()
        if name in result:
            raise ValueError(f"Duplicate command: {name}")
        result[name] = (kind, int(expected))
    if not result:
        raise ValueError("No commands with explicit expectations")
    return result


def verify_completions(stderr, expected):
    # A receipt includes command metadata before solving and has no explicit
    # UNSAT bit. Alloy 6.2.0's terminal result line is required for every command,
    # so an exception followed by a later receipt write cannot masquerade as UNSAT.
    if re.search(r"(?mi)^errors?\s*$|^\[.*?\]\s+ERROR\b|could not be solved", stderr):
        raise ValueError("Alloy reported a command error")
    progress = stderr.replace("\b", "").replace("\r", "")
    rows = re.findall(r"(?m)^\d+\.\s+(check|run)\s+(\w+)\s+[^\n]*?\b(UNSAT|SAT)\b[^\n]*$", progress)
    completed = {}
    for kind, name, result in rows:
        if name in completed:
            raise ValueError(f"Duplicate command completion: {name}")
        completed[name] = (kind, int(result == "SAT"))
    if completed != expected:
        raise ValueError("Missing or unexpected command completion results")


def verify_receipt(receipt, expected):
    if not isinstance(receipt, dict):
        raise ValueError("Receipt is not a JSON object")
    commands = receipt.get("commands")
    if not isinstance(commands, dict) or set(commands) != set(expected):
        raise ValueError("Receipt does not contain exactly the requested commands")
    for name, (kind, outcome) in expected.items():
        command = commands[name]
        if not isinstance(command, dict) or command.get("type") != kind:
            raise ValueError(f"Wrong command type: {name}")
        # Alloy omits default-valued fields, including expects=0 and empty solutions.
        if command.get("expects", 0) != outcome:
            raise ValueError(f"Wrong receipt expectation: {name}")
        solutions = command.get("solution", [])
        if not isinstance(solutions, list):
            raise ValueError(f"Malformed solutions: {name}")
        if bool(solutions) != bool(outcome):
            raise ValueError(f"Unexpected {'SAT' if solutions else 'UNSAT'}: {name}")
        print(f"PASS {kind} {name}: {'SAT' if solutions else 'UNSAT'}")


def run_checker(command, env, timeout):
    # Defer signals during launch until the child handle exists, and during
    # cleanup so a second Ctrl-C cannot interrupt group termination and reaping.
    deferred = True
    pending = None

    def raise_interrupt(signum):
        if signum == signal.SIGINT:
            raise KeyboardInterrupt
        raise SystemExit(128 + signum)

    def interrupt(signum, frame):
        nonlocal pending
        if deferred:
            pending = signum
        else:
            raise_interrupt(signum)

    previous = {s: signal.signal(s, interrupt) for s in (signal.SIGINT, signal.SIGTERM)}
    process = None
    try:
        process = subprocess.Popen(command, env=env, start_new_session=True,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        deferred = False
        if pending is not None:
            raise_interrupt(pending)
        stdout, stderr = process.communicate(timeout=timeout)
        return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)
    except BaseException:
        deferred = True
        if process is not None:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            try:
                process.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                process.stdout.close()
                process.stderr.close()
                process.kill()
                process.wait(timeout=5)
        raise
    finally:
        for signum, handler in previous.items():
            signal.signal(signum, handler)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--alloy", default="alloy", help="Alloy 6.2.0 CLI executable")
    parser.add_argument("--solver", default="minisat", help="Alloy solver ID; use sat4j for Java-only checking")
    parser.add_argument("--model", type=Path,
                        default=Path(__file__).with_name("flat_files_checks.als"))
    parser.add_argument("--timeout", type=float, default=180, help="Total checker timeout in seconds")
    parser.add_argument("--output", type=Path, help="Keep results in a new directory; never overwrite one")
    args = parser.parse_args(argv)
    if os.name != "posix":
        parser.error("This runner requires POSIX process groups; use Alloy directly on other hosts")
    if not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("--timeout must be finite and positive")
    if args.output is not None and args.output.exists():
        parser.error("--output must not already exist")
    try:
        expected = expectations(args.model)
        with tempfile.TemporaryDirectory(prefix="flat-files-alloy-") as temporary:
            output = args.output.resolve() if args.output else Path(temporary) / "results"
            env = os.environ.copy()
            # One small checker process. This sets a memory bound, not a perf claim.
            env["JAVA_TOOL_OPTIONS"] = (env.get("JAVA_TOOL_OPTIONS", "") + " -Xmx512m").strip()
            command = [args.alloy, "exec", "-c", "*", "-s", args.solver, "-t", "json",
                       "-o", str(output), str(args.model.resolve())]
            completed = run_checker(command, env, args.timeout)
            print(completed.stdout or "", end="")
            print(completed.stderr or "", end="", file=sys.stderr)
            if completed.returncode:
                return completed.returncode if completed.returncode > 0 else 1
            verify_completions(completed.stderr or "", expected)
            receipt = json.loads((output / "receipt.json").read_text())
            verify_receipt(receipt, expected)
            if receipt.get("solver") != args.solver:
                raise ValueError("Receipt solver does not match the requested solver")
            print(f"Verified {len(expected)} command expectations (bounded model checking).")
            if args.output:
                print(f"Results: {output}")
        return 0
    except subprocess.TimeoutExpired:
        print("Alloy timed out; no successful validation is claimed.")
        return 124
    except (OSError, ValueError) as error:
        print(f"Alloy validation failed: {error}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
