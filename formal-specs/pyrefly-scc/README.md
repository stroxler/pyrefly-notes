# Pyrefly SCC specifications

A compact planning, documentation, and auditing pipeline:

```text
Alloy graph generator -> graph input -> TLA+ behavior model
```

- `graphs/`: Alloy generation and the JSON-to-TLA export bridge.
- `behavior/`: SCC behavior, configuration, and an interchangeable example graph.
- [Design sketch](DESIGN.md), [retrospective](RETROSPECTIVE.md), and
  [audit context](AUDIT.md): short orientation, scope, and history.
- `model_tests/`: bounded regressions with separate completion/event witnesses.

## Use a given graph

With Python 3, Java, and a local `tla2tools.jar`:

```sh
python3 run_tlc.py --jar /path/to/tla2tools.jar --graph /path/to/RawDynamicGraph.tla
python3 run_tlc.py --jar /path/to/tla2tools.jar --alloy-json /path/to/solution.json
```

With neither input flag, the runner uses the checked-in example. It copies all
inputs into a temporary directory. `--timeout`, `--workers`, and `--heap` bound
resources; failures remain failures and a timeout returns 124.

## Run regressions

```sh
python3 model_tests/run_regressions.py --jar /path/to/tla2tools.jar
TLA2TOOLS_JAR=/path/to/tla2tools.jar python3 -m unittest discover -p 'test_*.py'
```

The model suite checks safety and liveness, then uses deliberately failing
probe invariants to witness completion and selected events. Probe exit 12 is
expected only after the corresponding main model check succeeds. The rejected
input case must produce TLC's false-assumption diagnostic. Logs and generated
cases are kept outside the repository.

`--baseline --root /path/to/starting-point` records known failures in the
original merged model for regression-first history; it is not the repaired
model's pass criterion. Graph assumptions and transitions are documented in
the code. Static visibility is an unchanging schedule; changing schedules must
satisfy the explicit input contract.

## Provenance

The generator and initial dynamic model originate in
[learn-specification at 345a774](https://github.com/stroxler/learn-specification/tree/345a7744598e1e8ab9e6d8ef161dc876c2d8c8b2/pyrefly_fixpoint).
The behavior model is now repaired rather than preserved as an exact snapshot.
The Alloy stack model, static models, older variants, and initial audit probes
remain in [history](https://github.com/stroxler/pyrefly-notes/tree/8ef354e5238459dba374ed146df07f9b6793b290/formal-specs/pyrefly-scc).
The source repository is untouched; no formal model-to-code relation is supplied.
