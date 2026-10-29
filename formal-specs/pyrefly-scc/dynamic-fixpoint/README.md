# Dynamic-graph fixpoint experiment

This is the historical Alloy-to-TLC experiment, preserved alongside—not as a
replacement for—the simpler [static model](../fixpoint/PyreflyFixpoint.tla).
The models, generated example graphs, and Python tools are copied verbatim
from [learn-specification at 345a774](https://github.com/stroxler/learn-specification/tree/345a7744598e1e8ab9e6d8ef161dc876c2d8c8b2/pyrefly_fixpoint).

- `dynamic_graph/`: Alloy schedule generator, JSON exporter, and supporting
  Python tools. Its README distinguishes working export from scaffolds.
- `v0/`: dynamic TLA consumer with explicit membership-based merging.
- `v1/`: a historical variant adding stack-segment bounds and related checks.
  Those bounds do not describe today's implementation.
- Each version retains `RawDynamicGraph.tla`, a generated example, plus the
  stable `DynamicGraph.tla` wrapper that supplies dependencies to its solver.

The intended workflow is Alloy generation, conversion to a raw graph module,
and TLC exploration with a chosen consumer. Keep runs in disposable copies:
installing another case replaces that copy's raw graph module.

These versions retain their original assumptions and limitations. Preserving
an executable experiment is not a fresh audit of its solver behavior, nor an
assertion that all its configured properties pass. The main audit's static
scope findings should not be attributed to these separate dynamic versions.
