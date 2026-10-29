# Pyrefly SCC models

These are post-hoc models of Pyrefly's intended SCC traversal and fixpoint
protocol, not a verified refinement of the Rust implementation.

Read [AUDIT.md](AUDIT.md) for the current-source comparison, the discovery
assumption, confirmed model gaps, and executed checks.

## Layout

- `stack/`: original traversal model/config, plus the audit's smaller config.
- `fixpoint/`: original fixpoint model/config and historical design/gap notes.
- `checks/`: separate audit probes, including an intentionally failing deadlock
  witness and a mutation the original static scope does not detect.
- `run_tlc.py`: reproduces the small baseline and the expected audit outcomes.

The seven original files were copied verbatim from
[`stroxler/learn-specification` at `345a7744598e1e8ab9e6d8ef161dc876c2d8c8b2`](https://github.com/stroxler/learn-specification/tree/345a7744598e1e8ab9e6d8ef161dc876c2d8c8b2/tla%2B).
The source repository has not been modified or deleted.

**Historical-document status:** `fixpoint/DESIGN.md` describes a planned dynamic
model, while the executable module uses a frozen graph. `DYNAMIC_GRAPH.md`
sketches the Alloy-to-TLC pipeline; generator code and a generated-case corpus
are not included here. `spec-issues.md` describes an older implementation and
must not be treated as a current bug list.

## Reproduce

With Python 3, Java, and a local `tla2tools.jar`:

```sh
python3 run_tlc.py --jar /path/to/tla2tools.jar
```

The audit used TLC `2026.03.12.220102` (`0a0bffb`). Logs and state directories
are written outside the repository to a fresh temporary directory.
`--workers`, `--heap`, and `--timeout` control resource bounds.
`--full-stack` additionally runs the original four-node configuration; it can
be much more expensive than the default three-node sanity check.

Expected outcomes are deliberately mixed:

- Small stack and original fixpoint safety checks find no violation in scope.
- Absence probes confirm that final-all-Done states and positive-phase SCC
  expansion are not reached in the original fixpoint scope.
- The phase-preserving merge mutation is not detected by that static scope.
- `DeadlockProbe` produces an unfinished model deadlock (TLC exit 11). Normal
  Finished states are explicitly allowed to stutter, avoiding false reports of
  intended termination as deadlock.

A successful runner means these **audit observations** reproduced. It does not
mean the model is correct: the deadlock and coverage gaps are known issues to
repair in a separate revision. Original model semantics are preserved so the
historical experiment and the current audit are not conflated.
