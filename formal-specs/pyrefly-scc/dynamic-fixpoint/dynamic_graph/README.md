# Generate a graph schedule for TLC

Alloy chooses a full graph and a bounded schedule of visible edges. The
assumptions are in `dynamic_graph_gen.als`: visible edges belong to the full
graph, initial cycle participants match, and every full edge appears somewhere
in the schedule. These are simulation assumptions, not conclusions about
Python dependency discovery or publication timing.

With an Alloy 6 CLI named `alloy`, from this directory:

```sh
alloy exec -c 0 -o /tmp/pyrefly-alloy-graphs -t json -r 1 dynamic_graph_gen.als
python3 scripts/alloy_trace_to_tla_constants.py '/tmp/pyrefly-alloy-graphs/run$1-solution-0.json' /tmp/RawDynamicGraph.tla
```

Use fresh output paths. The exporter writes the raw module consumed by the
`DynamicGraph.tla` wrapper in `../v0/` or `../v1/`. To explore that generated
case, copy a consumer into a disposable run directory, replace its raw graph
module, and invoke TLC with its included configuration.

`validate_case.py` checks the normalized case-JSON contract documented in its
source. It does not directly read Alloy solution JSON. `generate_case.py`
produces an empty-edge placeholder, and `render_tla_constants.py` emits only
partial constants; both are retained as clearly labeled scaffolds, not the
working Alloy-export path.

The source and tools are preserved verbatim from the original experiment.
Schemas, encodings, and validation rules belong beside the implementation,
not as duplicate Markdown definitions.
