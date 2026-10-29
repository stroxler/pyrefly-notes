# Generate graph inputs

Alloy chooses a full graph and a bounded schedule of visible edges. Its input
assumptions live in `dynamic_graph_gen.als`; the JSON exporter documents the
TLA encoding beside its implementation.

From this directory, with an Alloy 6 CLI named `alloy`:

```sh
alloy exec -c 0 -o /tmp/pyrefly-alloy-graphs -t json -r 1 dynamic_graph_gen.als
python3 ../run_tlc.py --jar /path/to/tla2tools.jar --alloy-json '/tmp/pyrefly-alloy-graphs/run$1-solution-0.json'
```

Use a fresh Alloy output directory. The runner exports the chosen solution
and explores it using the TLA behavior model in a disposable directory.
Neither operation overwrites the checked-in example graph.

The generator's coverage assumptions are simulation inputs, not conclusions
about Python dependency discovery or publication timing. The old temporal
Alloy stack experiment and unused scaffold tools are retained in history,
not in this pipeline.
