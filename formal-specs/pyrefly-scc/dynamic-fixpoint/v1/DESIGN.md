# Dynamic fixpoint v1: historical sketch

This variant makes SCC stack-segment bounds and their lifetime checks more
explicit while retaining the dynamic graph input. It belongs to the earlier
positional-tracking experiment; the current implementation subsequently
replaced mutable upper-bound tracking, as the [retrospective](../../fixpoint/spec-issues.md)
records. The actual rules and checks live in `PyreflyFixpoint.tla`.

`RawDynamicGraph.tla` retains a generated example case. Use a disposable copy
to install another case through the [export tooling](../dynamic_graph/).
This preserved variant has not received a new behavioral audit.
