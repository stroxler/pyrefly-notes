# Audit context

These specifications are planning, documentation, and auditing tools, not a
proof that the implementation follows the model.

## Model review and repair

The second pass reviewed the [merged starting point](https://github.com/stroxler/pyrefly-notes/tree/e5e7ce781bdc458cbfa6b8cf294a9218bccd1b6b/formal-specs/pyrefly-scc)
and found concrete progress, ownership, and audit-coverage defects. The repair
replaces fragile positional re-entry with live control-frame ownership,
preserves answers while an invalidated pass unwinds, and records actual commits
rather than checking a state that disappears at publication.

The [regressions](model_tests/run_regressions.py) include completed executions,
late/warm merges, retained reads, independent nested components, complementary
visibility steps, and exact final partitions. A hidden initial dependency of a
noncyclic node is rejected as an explicit input-contract violation. Safety,
liveness, and reachability witnesses are separate checks.

Read-membership checking is a guard tripwire, not a complete type-value or
answer-lifetime analysis. Depth limits, member pruning, side caches, concurrent
publication, and module-owned diagnostics remain outside this model. The
[design sketch](DESIGN.md) states the admitted graph conditions and budget.

## Attribution

The [retrospective](RETROSPECTIVE.md) separates contemporaneous audit findings
from later reconstructed fix links. The April missing-merge commit explicitly
references a specification violation; later fixes are not automatically
credited to the original formal-model-assisted episode. Commit timing does not
resolve whether earlier uncommitted work existed.

## Current-code review

An optimized binary built from the reviewed source reproduced deterministic
problems in speculative lambda typing, opt-in depth-overflow handling, and
cross-module non-convergence warning routing. Artificial lambda-owner SCC
creation was also observed. These code issues were not repaired by the model
change and should not be described as historical fixes or as TLC discoveries.
A proposed cross-thread lambda-publication race remains unconfirmed.
