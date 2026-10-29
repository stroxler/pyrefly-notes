# Fixpoint Extraction Plan (v0 Codex)

## Goal

Extract SCC/fixpoint traversal logic from `answers_solver.rs` into a reusable engine that:

- does not depend on Pyrefly binding/answer internals,
- preserves current semantics required by Pyrefly,
- supports cross-module batch commit,
- can be tested with arbitrary mocked graphs and dynamic dependency schedules.

This is an incremental migration plan, not a one-shot rewrite.

## Non-goals (v0)

- No immediate redesign of `Calculation` semantics (exports uses them too).
- No full multithreading model in first extraction pass.
- No attempt to preserve known-buggy behavior if it conflicts with spec-level invariants.

## Target Architecture

### 1) `fixpoint_engine` (new module/crate boundary)

Owns:

- traversal stack,
- SCC stack,
- SCC merge/demotion/iteration transitions,
- SCC node states and iteration bookkeeping,
- transition/event emission for diagnostics and parity testing.

Does not own:

- typed answer computation,
- module routing,
- `Calculation` storage and locking,
- error collector merge,
- trace side-effect publication.

### 2) `EngineHost` adapter trait (implemented by `AnswersSolver` adapter)

Minimal host operations:

- `read_committed(node) -> Option<Value>`
- `propose(node) -> Proposal` (only for coordination/fast-paths)
- `solve(node, engine_ctx) -> Value` (host computes node; recursive deps go through `engine_ctx.get(dep)`)
- `answers_equal(node, prev, next) -> bool`
- `begin_batch(members)` / `write_member(...)` / `finish_batch(...)` / `abort_batch(...)`
- hooks for diagnostics (`report_non_convergent`, optional debug event sink)

### 3) `PyreflyAdapter`

Wraps existing `AnswersSolver` typed operations and cross-module writes behind `EngineHost`.

### 4) `MockGraphHost` test harness

Supports:

- arbitrary graph injection,
- dynamic visibility by push count (mirrors v1 spec model),
- scripted "other thread already committed" responses,
- deterministic event-log assertions.

## Mapping from Current Code

Primary extraction candidates from `pyrefly/lib/alt/answers_solver.rs`:

- `CalcStack` + SCC stack methods,
- `Scc`, `SccNodeState`, `SccIterationState`,
- `BindingAction`-style decision logic,
- `iterative_resolve_scc`, `drive_all_iteration_members`.

Leave in adapter layer initially:

- `dispatch_anyidx!` plumbing,
- type-erased downcast edges,
- `Calculation` propose/get/write lock/unlock,
- trace/error collector publication,
- module-local vs cross-module routing.

## Suggested Commit Stack

### Commit 1: Add transition/event model around existing solver

- Introduce `FixpointEvent` enums and emission points in current path.
- No behavior changes.
- Add tests that snapshot event streams for stable scenarios.

Acceptance:

- Existing tests pass.
- Event logs deterministic for fixed inputs.

### Commit 2: Introduce `EngineHost` trait and thin adapter interface

- Add trait + minimal context API.
- Implement trait with current code paths (still old control flow).

Acceptance:

- No behavior change.
- Adapter tests for same-module and cross-module calls.

### Commit 3: Move pure SCC data structures into engine module

- Move `Scc`, node/iteration state types, pure transition helpers.
- Keep traversal orchestration in `answers_solver` for now.

Acceptance:

- Zero semantic changes; compile-time move only.
- Unit tests for reset/advance/merge helpers.

### Commit 4: Extract stack + SCC transition state machine

- Move `push/pop/current_cycle/on_scc_detected/merge` logic into engine.
- Adapter calls into engine for binding actions.

Acceptance:

- Event parity with pre-extraction logs on baseline suites.
- Invariant checks equivalent or stricter than baseline.

### Commit 5: Extract iterative driver into engine

- Move `drive_all_iteration_members` + `iterative_resolve_scc` protocol to engine.
- Host controls how to drive a member and how to commit batch writes.

Acceptance:

- Same commit ordering guarantees.
- No new invariant failures on existing stress tests.

### Commit 6: Add mock-graph fidelity tests

- Build `MockGraphHost` with scripted dynamic deps and commit races.
- Add tests for:
  - merge during iteration => demotion/restart,
  - truncated DFS requiring multi-entry driving,
  - no cross-SCC preliminary leakage,
  - commit/transition requires all members done,
  - inactive-segment back-edge expansion behavior.

Acceptance:

- Tests mirror key v1 properties at unit-test level.

### Commit 7: Shadow-mode dual run (optional but recommended)

- Run old and new engines in parallel in debug/test mode.
- Compare event streams + final committed sets; classify divergences:
  - known-bug-compatible,
  - spec-violating,
  - unknown.

Acceptance:

- Divergence report format includes minimal repro payload.

### Commit 8: Cutover

- Make extracted engine authoritative.
- Keep old path behind temporary kill-switch for rollback.

Acceptance:

- No regressions on pyrefly suite.
- Invariant checks can be tightened vs current baseline.

## Invariants to Keep Explicit in Engine

- SCC segments are ordered, non-overlapping, and monotonic.
- `top_pos_exclusive` push/pop symmetry for SCC participants.
- At most one SCC completion per completion point.
- Commit/phase transition only when all SCC members are done.
- Merge expansion resets to phase 0 and clears prev/current answers.
- Warm back-edge never allocates placeholder.
- No cross-SCC preliminary answer reads.

## API Notes for Cross-Module Batch Writing

Engine should treat commit as two-phase host operation:

1. acquire all member write locks in deterministic node order,
2. write/unlock each locked member,
3. publish side effects only for writes that actually won,
4. ensure panic-safe unlock for partially locked sets.

This keeps existing semantics while isolating policy in host adapter.

## Risks and Mitigations

Risk: extraction accidentally changes ordering-sensitive behavior.
Mitigation: event parity tests + shadow mode before cutover.

Risk: host API too Pyrefly-specific or too abstract to use.
Mitigation: introduce minimal trait first, evolve only with real callsites.

Risk: multithread interaction remains under-modeled.
Mitigation: add scripted host events for "concurrent commit observed" and keep explicit contamination/restart hooks in engine API.

## Suggested First Milestone

Before large moves, reach this checkpoint:

- new engine module exists,
- old solver emits stable transition events,
- mock host can execute extracted transition helpers on arbitrary graphs,
- at least one dynamic-graph test reproduces a current hard-to-reason scenario.

This gives a concrete harness for Claude workers and makes later refactors reviewable.
