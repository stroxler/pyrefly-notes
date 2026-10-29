# Pyrefly SCC specifications

Post-hoc models used for planning, documentation, and auditing Pyrefly's SCC
solver. They make the intended protocol explicit without supplying a formal
relation between the model and the implementation.

- [Design sketch](fixpoint/DESIGN.md): the high-level idea and assumptions.
- [Retrospective](fixpoint/spec-issues.md): concise problems and fixing commits.
- [Audit summary](AUDIT.md): model limitations and outstanding follow-ups.
- `stack/` and `fixpoint/`: executable models; detailed explanations live in
  their comments rather than parallel Markdown definitions.
- `checks/`: coverage probes, an undetected mutation, and a model-only deadlock.

## Provenance

The original models and notes were imported from
[`learn-specification` at `345a7744598e1e8ab9e6d8ef161dc876c2d8c8b2`](https://github.com/stroxler/learn-specification/tree/345a7744598e1e8ab9e6d8ef161dc876c2d8c8b2/tla%2B).
The import preserved the files verbatim; subsequent documentation cleanup
rewrites the notes and updates spec comments without changing transition or
configuration semantics. The source repository remains untouched.

## Reproduce

With Python 3, Java, and a local `tla2tools.jar`, run:

```sh
python3 run_tlc.py --jar /path/to/tla2tools.jar
```

The audit used TLC `2026.03.12.220102` (`0a0bffb`). Logs, traces, and state
directories go to a fresh temporary directory. `--workers`, `--heap`, and
`--timeout` bound resource use. `--full-stack` also runs the more expensive
original four-node configuration.

Success means the expected **audit observations** reproduced, including the
known model deadlock and undetected mutation—not that those behaviors are
correct. The probe comments explain each outcome. Fixing the model's behavior
is a separate change from documenting it accurately.
