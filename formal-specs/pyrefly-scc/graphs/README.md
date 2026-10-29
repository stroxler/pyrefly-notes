# Generate graph inputs

Alloy chooses a full graph and a cyclic schedule of visible dependencies.
Input assumptions live in `dynamic_graph_gen.als`; the JSON exporter documents
the TLA encoding beside its implementation.

From this directory, with an Alloy 6 CLI named `alloy`:

```sh
alloy exec -c 0 -o /tmp/pyrefly-alloy-graphs -t json -r 1 dynamic_graph_gen.als
python3 ../run_tlc.py --jar /path/to/tla2tools.jar --alloy-json '/tmp/pyrefly-alloy-graphs/run$1-solution-0.json'
```

Use a fresh Alloy output directory. The runner exports the chosen solution
and explores it using the behavior model in a disposable directory. It does
not overwrite the checked-in example graph.

The generator admits changing visibility and initially separate cycles, but
requires full initial dependencies for noncyclic nodes and coverage of all
full edges across the period. The behavior model repeats that input contract
and gives every restarted component a complete period of solving. These
conditions do not establish Python's dependency-discovery behavior.

The temporal Alloy stack experiment and unused scaffolds remain in history,
not in this pipeline.
