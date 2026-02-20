# Iterative Fixpoint SCC Solving (v3 Plan — Consolidated)

This plan merges and tightens the best elements of `v3-claude-d.md` and
`v3-codex-d.md`, cross-referenced against current `master` and the v2 stack
(`97cf266a62` → `4557b87914`). It corrects known errors, preserves the
successful mechanics from v2, and avoids the architectural pitfalls
(`active_iteration`, single-DFS iteration driving, min-idx breaking in
iterative mode).

The goal is to land iterative SCC solving on master cleanly and deterministically,
without reintroducing the v2 regressions.

---

## Cross-Reference Notes (Master + v2 Stack)

**Verified on master (baseline assumptions):**
- `CalcStack` contains `stack`, `scc_stack`, `position_of`, and
  `pending_completed_sccs`, but no iteration state.
- `Scc` stores `break_at`, `node_state`, `detected_at`, `anchor_pos`, and
  `segment_size`.
- `NodeState` variants are `Fresh`, `InProgress`, `HasPlaceholder(Var)`,
  `Done { answer, errors }`. **No `BreakAt` variant.**
- `SccSolvingMode` contains `CyclesDualWrite` and `CyclesThreadLocal` only.
- `ThreadState` holds `scc_solving_mode` but does **not** propagate it into
  `CalcStack`.
- `BindingAction` does **not** include `NeedsColdPlaceholder` yet.
- `commit_single_result` already asserts cross-module commit success via
  `commit_to_module`.

**v2 stack artifacts to reuse (carefully):**
- Iterative driver scaffolding and cross-module solving in `090277a54e0c`.
- `answers_equal` helpers in `a2e918c59b7b`.
- LoopPhi bypass idea in `a7c19d601a23`.
- Drive-all-members fix in `4557b879145f`.

---

## Goals

1. **Determinism:** SCC solving is independent of DFS entry order.
2. **Convergence:** Iterative fixpoint with warm-start answers until stabilized.
3. **Correctness:** Disjoint SCCs, late merges (demotions), LoopPhi, and
   cross-module cycles handled correctly.
4. **Stack safety:** In iterative mode, **never** use min-idx breaking.
5. **Isolation:** Iteration state is SCC-scoped so multiple SCCs can iterate
   independently.

Non-goals: redesigning the solver or changing the type system or diagnostics
format.

---

## Architectural Fixes (Required)

### 1) Iteration State Lives on `Scc`
Iteration state must be stored per-SCC to allow independent concurrent
iteration of disjoint SCCs.

```rust
pub struct Scc {
    // existing
    break_at: BTreeSet<CalcId>,
    node_state: BTreeMap<CalcId, NodeState>,
    detected_at: CalcId,
    anchor_pos: usize,
    segment_size: usize,

    // new
    iterative: Option<SccIterationState>,
}
```

`SccIterationState`:
- `iteration: u32`
- `node_states: BTreeMap<CalcId, IterationNodeState>`
- `previous_answers: BTreeMap<CalcId, Arc<dyn Any + Send + Sync>>`
- `demoted: bool`
- `has_changed: bool`

No separate `members` field; membership is `node_state.keys()`.

**Merge rule:** if any merged SCC is iterating, the merged SCC restarts at
iteration 1 with fresh node states, `previous_answers` cleared, and
`demoted = true`.

### 2) Membership-Based Back-Edge Detection
A request for a CalcId that is a member of a **non-top** iterating SCC is a
back-edge that must **merge + demote**. This is required because in iterative
mode a member can be off the call stack but still belongs to an active SCC.

Add:
```rust
fn find_iterating_scc_containing(&self, target: &CalcId) -> Option<usize>
```

In `CalcStack::push` (iterative mode):
- If `target` is in a non-top iterating SCC, merge all SCCs from that index to
  top, set `demoted = true`, and return an appropriate `BindingAction` based on
  iteration state (previous answer / placeholder / cold placeholder).
- This check runs **before** the top-SCC iterative bypass.
- The scan intentionally considers only SCCs with `iterative: Some(...)`; SCCs
  still in Phase 0 discovery are merged via the existing `on_scc_detected` path.

---

## Algorithm Overview

### Solving Modes
- `CyclesDualWrite` (legacy)
- `CyclesThreadLocal` (legacy)
- `Iterative` (new)

Config enum `SccMode` maps to `SccSolvingMode::resolve`, with env var override.

**Invariant:** Iterative mode never uses min-idx breaking. Every back-edge is
`BreakHere`.

### Two Loops
- **Outer loop (demotion):** if membership expands, restart at iteration 1.
  Max demotions = 10 (panic if exceeded).
- **Inner loop (fixpoint):**
  - Iteration 1 (cold): back-edges allocate placeholders.
  - Iteration 2+ (warm): back-edges reuse previous answers.
  - Converge when `has_changed == false` after iteration >= 2.
  - Max iterations = 5 (warn and commit last answers).

### Phase 0 Discovery
Phase 0 remains the current DFS. In iterative mode, back-edges always break
immediately; Phase 0 is **membership discovery only**. Iteration restarts with
fresh error contexts and answers, so Phase 0 outputs do not contaminate
iterative results.

### Single-Member SCCs
A singleton SCC with a self-loop runs through `iterative_resolve_scc`. A
singleton without a self-loop is not a true SCC and should follow the normal
non-SCC commit path.

---

## Core Mechanics

### Two Node-State Maps
- `Scc::node_state`: legacy SCC tracking and membership set.
- `Scc::iterative.node_states`: per-iteration state (fresh/in-progress/done).

Phase 0 uses `node_state`. Iteration uses `iterative.node_states` and bypasses
legacy state.

### Iterative Bypass in `CalcStack::push`
When top SCC is iterating and target is a member:
- `Fresh` → mark `InProgress`, return `Calculate`
- `InProgress + previous answer` → `SccLocalAnswer(prev)`
- `InProgress + placeholder` → `CycleBroken(var)`
- `InProgress + neither` → `NeedsColdPlaceholder`
- `Done` → `SccLocalAnswer(answer)`

To support read-then-act borrowing, use a lightweight summary enum:
`IterationNodeStateKind = Fresh | InProgressWithPreviousAnswer |
InProgressWithPlaceholder | InProgressCold | Done`.

### `BindingAction::NeedsColdPlaceholder`
Two-step protocol (because `push` lacks `K: Solve`):
1. `push` returns `NeedsColdPlaceholder`.
2. `get_idx` allocates via `K::create_recursive`, stores placeholder in
   iteration state, returns `K::promote_recursive`.

### `CycleDetected` Without Active Cycle
In iterative mode, if `propose_calculation` yields `CycleDetected` but
`current_cycle()` is `None`, treat as `NeedsColdPlaceholder` **before** any
`unwrap()`. This handles stale `Calculating` state from Phase 0.

### `calculate_and_record_answer` (Iterative Path)
For iterating SCC members:
- Store `IterationNodeState::Done`.
- If a placeholder was created, call `finalize_recursive_answer`.
- Deep-force the answer before storage (avoid Var-ID inequality).
- Compare to `previous_answers` via `answers_equal` (assumes deep-forced
  inputs) to set `has_changed`.
- Do **not** write into `Calculation` until commit.

**Errors:**
- Iteration 1: `error_swallower()`
- Iteration ≥ 2: `error_collector()`
- Only final iteration’s errors are committed.

---

## Iteration Driver (`iterative_resolve_scc`)

Pseudo-logic:
```
fn iterative_resolve_scc(mut scc: Scc):
    let scc_identity = scc.detected_at
    iteration = 1
    demotions = 0

    loop:
        if iteration > MAX_ITERS:
            warn; break

        previous_answers = if iteration > 1 { extract_done_answers(&scc) } else { empty }
        scc.iterative = Some(fresh_state(iteration, previous_answers))
        push scc

        drive_all_iteration_members() // until next_fresh_member() == None

        if scc_stack
            .last()
            .expect("just pushed")
            .detected_at != scc_identity:
            return // absorbed into ancestor
        scc = pop()

        if scc.iterative.demoted:
            demotions += 1
            if demotions > MAX_DEMOTIONS: panic!
            iteration = 1
            continue

        if iteration >= 2 && !scc.iterative.has_changed:
            break

        iteration += 1

    commit_final_answers(scc)
```

### Drive All Members
Because every back-edge breaks, a single DFS from `min(CalcId)` can miss
reachable components. Use:
```
while let Some(id) = next_fresh_member() { drive_member(id) }
```

### Absorption Detection
If the top SCC is merged into an ancestor during iteration, the merged SCC’s
`detected_at` becomes the ancestor’s. The driver detects this and returns
without committing.

### Max-Iteration Warning
If `MAX_ITERS` is exceeded, emit a logging warning (e.g., `tracing::warn!`) and
commit the last iteration’s answers; do not emit a diagnostic error.

---

## LoopPhi Handling

During iteration 1, eager breaking prevents `LoopPhi` from creating its own
`LoopRecursive` placeholder. Add a cold-start bypass:

1. Detect `Binding::LoopPhi` in `get_idx` for iterating SCC members.
2. Resolve its prior/default index.
3. Deep-force the result.
4. Store as `IterationNodeState::Done` and return it directly.

If tests are added before this lands, mark with
`bug = "LoopPhi bypass not yet implemented"`.

---

## Cross-Module Solving

SCC members can span modules. Add:
- `LookupAnswer::solve_idx_erased` (default no-op)
- `Answers::solve_idx_erased` to construct an `AnswersSolver` with shared
  `ThreadState`
- `TransactionHandle::resolve_cross_module_target` helper (reuse factoring
  from v2)

Iteration driver uses `solve_idx_erased` to keep a single `scc_stack` across
modules.

---

## Disjoint SCCs During Iteration
If iterating SCC A discovers a disjoint SCC B, B is pushed with its own
iteration state, solves to completion, commits, and returns. A’s iteration
state remains intact and observes B’s answers as stable inputs.

---

## Borrow-Safe Patterns

- **Read-then-act:** use a lightweight `IterationNodeStateKind` to read state
  under `borrow()`, then drop it before `borrow_mut()`.
- **Pop-mutate-push:** mutate the SCC between iterations while it is off the
  stack.
- **Membership scan:** return an index with a shared borrow, then drop before
  merging.

---

## Accessor Methods (CalcStack)

Add iteration helpers that scan `scc_stack`:
- `find_iterating_scc_containing`
- `is_iterating_member`
- `is_final_iteration` / `is_cold_iteration`
- `get_iteration_node_state`
- `set_iteration_placeholder` / `get_iteration_placeholder`
- `set_iteration_node_done`
- `mark_iteration_changed`
- `get_previous_answer`
- `check_active_iteration_member`
- `next_fresh_member`
- `extract_previous_answers`
- `read_iteration_outcome` (demoted, has_changed)

---

## Commit Plan (each commit should keep legacy mode green)

Every commit should have a commit summary explaining what it does at
a high level (no need to list off every code change in the summary, that's in
the diff of the code).

Every commit title should begin with "[pyrefly][scc-solving][v3]" so that
the stack is easy to identify and distinguish from some previous attempts
to implement this.

### Phase A — Infrastructure (dead code)
1. **Mode + config plumbing:** add `SccSolvingMode::Iterative`, config enum
   `SccMode`, and `SccSolvingMode::resolve(SccMode)` with env override.
2. **Propagate mode:** add `scc_solving_mode` field in `CalcStack`, pass through
   `ThreadState::new`.
3. **Convergence helpers:** add `answers_equal` / `answers_equal_typed` via
   `dispatch_anyidx!`.
4. **Iteration structs:** add `SccIterationState`, `IterationNodeState`,
   `IterationNodeStateKind`, and `Scc::iterative` with merge handling.
5. **CalcStack accessors:** add iteration scanning helpers listed above.

### Phase B — Core Integration
6. **Eager breaking:** in iterative mode, `on_scc_detected` always returns
   `BreakHere` (no min-idx breaking).
7. **Iterative bypass in `push`:** add `BindingAction::NeedsColdPlaceholder`
   and use SCC-scoped iteration state.
8. **Membership back-edge detection:** scan `scc_stack`, merge + demote when
   target is in a non-top iterating SCC.
9. **`get_idx` plumbing:** handle `NeedsColdPlaceholder`, `SccLocalAnswer`, and
   `CycleDetected` without active cycle.
10. **`calculate_and_record_answer`:** iterative path with deep-force,
    placeholder finalization, convergence tracking, and error suppression.
11. **Iteration driver:** implement `iterative_resolve_scc` +
    `drive_all_iteration_members`, including absorption detection.

### Phase C — Features
12. **Cross-module iteration:** add `solve_idx_erased` plumbing and update the
    iteration driver to use it.
13. **LoopPhi bypass:** add iteration-1 shortcut for `Binding::LoopPhi`.

### Phase D — Config + Tests
14. **Config exposure + helpers:** add `SccMode::IterativeFixpoint` defaults and
    test helpers to set mode.
15. **Targeted tests:**
    - LoopPhi simple / multi-var / increment
    - Cross-module SCC cycle
    - Warm-start convergence
    - Error suppression across iterations
    - Membership back-edge merge + demotion
    - Disjoint SCC independence
    - Absorption detection (nested SCC merged into ancestor)
    - Demotion limit panic

---

## Invariants (Must Hold)

1. Iteration state is owned by `Scc`, not `CalcStack`.
2. Any access to a member of an active SCC from outside that SCC is a back-edge.
3. Iterative mode never uses min-idx breaking.
4. Merges during iteration always demote to cold start.
5. Answers stored in `IterationNodeState::Done` are deep-forced.
6. All merge paths use `Scc::merge` / `Scc::merge_many`.
7. Unreachable states must panic (`unreachable!` / `expect`).

---

## V2 Pitfalls (Do Not Regress)
1. `NeedsColdPlaceholder` is required because `push` lacks `K: Solve`.
2. `CycleDetected` without active cycle must fall back to `NeedsColdPlaceholder`.
3. Placeholder finalization must happen on iteration member completion.
4. Error suppression threshold must be `>= 2` iterations.
5. Placeholder idempotency: reuse existing placeholder on repeated back-edges.
6. LoopPhi bypass is required in cold-start iteration.
7. Must drive all members each iteration (no single-DFS shortcut).

---

## V2 Commit Map (for Reference)
- Mode plumbing: `97cf266a62db`
- Mode → CalcStack: `9a4a8e127cde`
- `answers_equal`: `a2e918c59b7b`
- Iteration structs: `96bf21889046`
- Iteration accessors: `a16fec5f8ae2`
- Iterative driver: `f250fe186148`
- Drive-all-members fix: `4557b879145f`
- Cross-module solve: `090277a54e0c`
- LoopPhi bypass: `a7c19d601a23`

---

## Key Files (Orientation)
| File | Role |
| --- | --- |
| `pyrefly/lib/alt/answers_solver.rs` | `CalcStack`, `Scc`, iterative driver, `BindingAction` |
| `pyrefly/lib/alt/answers.rs` | `Answers`, `LookupAnswer`, cross-module dispatch |
| `pyrefly/lib/state/state.rs` | `TransactionHandle` and module lookup wiring |
| `pyrefly/lib/alt/solve.rs` / `pyrefly/lib/alt/traits.rs` | `Solve` trait + solver helpers |
| `pyrefly/lib/binding/binding.rs` | `AnyIdx`, `dispatch_anyidx!`, binding definitions |
| `crates/pyrefly_config/src/base.rs` | `SccMode` config enum |

---

## Validation

- **Required before handoff:** `./test.py --no-test --no-conformance`.
- Full tests as time allows; CI will cover the rest.
