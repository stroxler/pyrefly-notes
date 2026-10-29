# Pyrefly SCC specifications

A compact planning, documentation, and auditing pipeline:

```text
Alloy graph generator -> graph input -> TLA+ behavior model
```

- `graphs/`: the Alloy generator and its JSON-to-TLA export bridge.
- `behavior/`: one dynamic SCC-solving model, its configuration, and an
  interchangeable example graph. Graph assumptions and transition rules are
  documented in the source.
- [Design sketch](DESIGN.md), [retrospective](RETROSPECTIVE.md), and
  [audit context](AUDIT.md): short orientation and history, not parallel
  code-level specifications.

## Use a given graph

With Python 3, Java, and a local `tla2tools.jar`:

```sh
python3 run_tlc.py --jar /path/to/tla2tools.jar --graph /path/to/RawDynamicGraph.tla
python3 run_tlc.py --jar /path/to/tla2tools.jar --alloy-json /path/to/solution.json
```

With neither input flag, the runner uses the checked-in example. It copies
all inputs into a fresh temporary directory rather than overwriting the
example. `--timeout`, `--workers`, and `--heap` bound resource use. Model-checker
failures are returned as failures; a timeout returns 124, not success.

Static graphs can be represented by an unchanging visibility schedule. See
[graph generation](graphs/README.md) for producing an input with Alloy.

## Provenance

The generator and retained behavior model originate in
[learn-specification at 345a774](https://github.com/stroxler/learn-specification/tree/345a7744598e1e8ab9e6d8ef161dc876c2d8c8b2/pyrefly_fixpoint).
The behavior model is the latest saved dynamic snapshot, previously called
`v1`; its rules are unchanged by this reorganization and are not a claim to
match every detail of today's implementation.

The Alloy stack model, static TLA models, older variant, and audit probes remain
in [commit history](https://github.com/stroxler/pyrefly-notes/tree/8ef354e5238459dba374ed146df07f9b6793b290/formal-specs/pyrefly-scc),
not as competing models in the current tree. The source repository is untouched.
