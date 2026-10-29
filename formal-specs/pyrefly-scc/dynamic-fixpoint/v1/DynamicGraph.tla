---- MODULE DynamicGraph ----

\* Stable wrapper over generated RawDynamicGraph.
\* PyreflyFixpoint should depend on this module, not on generated output.

EXTENDS Naturals, RawDynamicGraph

PushCountInit ==
    [n \in Nodes |-> 0]

RecordPush(push_count, n) ==
    [push_count EXCEPT ![n] = @ + 1]

StepFor(push_count, n) ==
    ((push_count[n] - 1) % StepCount) + 1

Deps(push_count, n) ==
    DynamicSteps[StepFor(push_count, n)][n]

DynamicDeps(push_count, n) ==
    Deps(push_count, n)

====
