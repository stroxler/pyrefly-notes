# SCC solving: design sketch

The specification makes the intended protocol explicit for planning,
documentation, and auditing. The graph is an input; the TLA+ model describes
how calculations are grouped and solved on top of it. Detailed rules belong
in [the model](behavior/PyreflyFixpoint.tla), not a second Markdown definition.

## The idea

Calculations whose answers depend cyclically on one another must be solved
as a component rather than treating the first cycle break as a final answer:

- **Discover** which calculations belong together.
- **Start cold** with temporary cycle-breaking answers kept inside the component.
- **Refine** using previous answers and revisiting known members.
- **Restart when membership grows**, after active work has unwound safely.
- **Publish** a final pass only when no component work remains active.

Alloy supplies graph cases independently of the solver's behavior. A case can
include changing dependency visibility; that does not imply the generator
models Python's language semantics.

## The boundary

The design assumes each entrypoint discovers the full component before it can
publish a proper subcomponent. An edge that would appear only after an early
exit does not satisfy that assumption. Establishing it for Python bindings is
outside the graph algorithm.

The behavior model tracks answer availability, not inferred types, and
simplifies convergence, concurrent publication, and memory lifetime. It retains
the latest saved dynamic experiment's positional bookkeeping, which is not a
literal description of the current implementation. The [retrospective](RETROSPECTIVE.md)
records how that implementation evolved; this cleanup does not change model
semantics or supply a formal relation between the specification and the code.
