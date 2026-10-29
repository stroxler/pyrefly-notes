# Dynamic fixpoint v0: historical sketch

This version explores SCC solving against an externally supplied dependency
schedule. It merges components by explicit membership and uses per-node
counters to select visible dependencies. The transition details are documented
in `PyreflyFixpoint.tla` and `DynamicGraph.tla`.

`RawDynamicGraph.tla` retains a generated example case. New Alloy cases can be
installed in a disposable copy through the [export tooling](../dynamic_graph/).
This is an experimental snapshot, not a description of the current Rust
implementation or a fresh set of audited solver guarantees.
