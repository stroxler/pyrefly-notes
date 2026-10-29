# Alloy stack experiment

This Alloy 6 temporal model records the stack traversal and cycle-breaking
experiment. It is a port of the original TLA+ stack model, not a simulation
of the full iterative fixpoint solver. The model and trace helper are copied
from
[learn-specification at 345a774](https://github.com/stroxler/learn-specification/tree/345a7744598e1e8ab9e6d8ef161dc876c2d8c8b2/alloy/pyrefly_stack).
Only the model's trailing blank line was removed; its definitions are unchanged.

The exploration commands and bounded checks are documented in
`pyrefly_stack.als`. With an Alloy 6 CLI named `alloy`:

```sh
alloy commands pyrefly_stack.als
alloy exec -c 1 -o /tmp/pyrefly-alloy-stack -t json -r 1 pyrefly_stack.als
python3 trace_summary.py /tmp/pyrefly-alloy-stack/showCycle-solution-0.json
```

Use a fresh output directory. Command 1 asks for a resolving multi-node cycle;
it is an example search, not a check of all the assertions. Small temporal
scopes were useful for exploring the protocol, but larger searches motivated
separating graph generation from solver exploration.

The companion [graph-generation experiment](../dynamic-fixpoint/) preserves
that Alloy-to-TLC division of labor.

Import validation on 2026-10-29 parsed the exploration commands. A fresh
resolving-cycle search did not complete within a two-minute bound; the
bounded assertion checks were not rerun.
