# SCC solving: design sketch

These models make the intended SCC-solving protocol explicit for planning,
documentation, and auditing. They are simplified descriptions, not proofs
that the implementation follows the protocol. The transition rules and their
assumptions belong in [PyreflyFixpoint.tla](PyreflyFixpoint.tla).

## The idea

A strongly connected component groups calculations whose answers depend on
one another. Instead of treating the first cycle break as a final answer,
solve the component together:

- **Discover:** follow dependencies and collect calculations that must be
  solved together.
- **Start cold:** break recursion with temporary answers, without publishing
  those answers outside the component.
- **Refine:** reuse the previous pass to resolve recursion and revisit every
  known member.
- **Restart when membership grows:** discard the old pass as a basis for the
  enlarged component. Active work must unwind safely before restarting.
- **Publish:** expose the final pass only after the component's active work
  has finished.

The implementation bounds refinement and may stop when answers stabilize.
The executable model uses a fixed number of passes and tracks answer
availability rather than type values. It describes the protocol, not whether
a particular inferred type is correct.

## The important boundary

Dependency discovery can depend on provisional answers. The design assumes
that every entrypoint discovers the full component before it can publish a
proper subcomponent. Establishing this for Python bindings is a separate
language-semantics question, not a graph-algorithm result.

The checked-in model freezes its graph. It also simplifies continuation
ownership, memory lifetime, and concurrent publication. These omissions are
explicit boundaries for an audit, not implementation guarantees. See the
[retrospective](spec-issues.md) for changes informed by the intended contract,
and [the audit summary](../AUDIT.md) for the remaining model limitations.
