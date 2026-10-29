# SCC models: audit summary

These specifications support planning, documentation, and auditing. Their
value is a precise reference for intended behavior, not a proof about the
implementation. The [design sketch](fixpoint/DESIGN.md) gives the idea;
transition-level explanations belong in the spec comments.

## Scope

The 2026-10-29 source audit concerned the static models in `stack/` and
`fixpoint/` and used
[Pyrefly at 8003f9b](https://github.com/meta/pyrefly/blob/8003f9b3d96b207c916c4a5c5ba039fb568cb857/pyrefly/lib/alt/answers_solver.rs).
The models originated in
[learn-specification at 345a774](https://github.com/stroxler/learn-specification/tree/345a7744598e1e8ab9e6d8ef161dc876c2d8c8b2/tla%2B).
The [retrospective](fixpoint/spec-issues.md) links historical fixes and later
refinements; it is not a list of bugs asserted to exist today.

## Design boundary

The current implementation explicitly separates local progress, ownership of
active work, retention of provisional answers, and final publication. The
models simplify those mechanisms and track answer availability, not type
values or diagnostics. The static models freeze the graph and omit concurrent
workers, module eviction, and depth overflow. The separate
[dynamic experiment](dynamic-fixpoint/) is preserved with its Alloy inputs and
historical consumers; it is not covered by the static audit findings below.

The intended discovery assumption is that every entrypoint finds the full
component before it can publish a proper subcomponent. Whether Python bindings
satisfy that assumption is a separate language-semantics question. An edge that
would appear only after an early exit does not satisfy it.

## Model limitations found during this audit

- **Caller continuation:** the model can resume a caller before its child SCC
  finishes, unlike the implementation. The
  [deadlock witness](checks/DeadlockProbe.tla) reproduces the resulting stall.
- **Answer completeness:** the historical commit check observes a state that
  is never reached. The [reachability probes](checks/ModelProbes.tla) document
  this blind spot beside the formulas.
- **Late expansion:** the supplied static scope never exercises expansion of
  an already-iterating SCC. A
  [phase-preserving mutation](checks/MergeMutation.tla) therefore passes the
  configured checks. Dynamic cases need a positive witness of that event.

The ordinary SCC protocol and these simplified model transitions should not
be conflated. Their differences are useful audit questions, not automatically
implementation bugs.

## Implementation follow-ups

Three source-level candidates remain unconfirmed by new runtime reproducers:
[provisional lambda-type publication](https://github.com/meta/pyrefly/blob/8003f9b3d96b207c916c4a5c5ba039fb568cb857/pyrefly/lib/alt/answers_solver.rs#L2305-L2328),
[queued work encountering depth overflow](https://github.com/meta/pyrefly/blob/8003f9b3d96b207c916c4a5c5ba039fb568cb857/pyrefly/lib/alt/answers_solver.rs#L2543-L2547),
and [cross-module non-convergence diagnostic routing](https://github.com/meta/pyrefly/blob/8003f9b3d96b207c916c4a5c5ba039fb568cb857/pyrefly/lib/alt/answers_solver.rs#L3314-L3326).
They are separate from the historical fixes and the reproduced model gaps.

## Reproduction and further experiments

The [runner](run_tlc.py) reproduces the small baseline checks and expected audit
outcomes, including the model-only deadlock and undetected mutation. The
original four-node stack run did not complete within its four-minute audit
bound. No Pyrefly implementation was changed, built, or runtime-tested here.

[Graph generation](fixpoint/DYNAMIC_GRAPH.md) records the useful Alloy/TLC
split: generate cases separately, then explore solver behavior. A future Quint
comparison could pair small exhaustive scopes with larger seeded simulations;
its [simulator](https://quint.sh/docs/simulator) checks sampled invariants,
while [model-checker backends](https://quint.sh/docs/model-checkers) handle
stronger exploration. No Quint port or performance comparison has been run.
