# Iterative Fixpoint SCC Solving (v1)

This document describes the plan for reimplementing Pyrefly's SCC solving mechanism using an **iterative fixpoint** algorithm. This approach replaces the "Legacy" single-pass cycle breaking with a multi-pass approach that converges on stable types, eliminating nondeterminism and reducing the reliance on `Any`.

This plan incorporates lessons learned from a previous 6-commit prototype, specifically addressing placeholder idempotency, loop priors, and error suppression.

## Context & Motivation

Pyrefly uses a demand-driven DFS to solve bindings. When cycles (SCCs) are detected:
- **Legacy Mode**: Breaks the cycle immediately at the detection point (or min CalcId) using a `Recursive` placeholder. This often results in `Any` or degraded types, and the break point depends on thread scheduling (nondeterministic).
- **Iterative Mode (Goal)**: Re-solves the SCC multiple times. Information flows around the cycle until types converge (fixpoint). This is deterministic and produces higher quality types.

## Prerequisite: Ref-Native Type Aliases

This plan assumes the **Ref-Native Type Aliases** work is completed.
- `Variable::AliasRecursive` is removed/deprecated.
- Recursive type aliases are handled via `TypeAliasData::Ref` and `expand`, meaning they **do not** participate in the general SCC cycle-breaking mechanism described here.
- This simplifies the solver, as we only need to handle value-level recursion (functions, loops) and `LoopPhi`.

## Architecture Phases

The solving process for an SCC follows these phases:

### Phase 1: Iteration Zero (Discovery)
The initial DFS pass that discovers the SCC.
- Behavior mimics Legacy mode: every back-edge triggers an immediate break.
- **Goal**: Solely to identify SCC members.
- **Result**: The computed answers are discarded (they contain arbitrary `Any`/placeholders from the break points).
- **Transition**: Once the SCC is fully popped and identified, we enter the Iteration Loop.

### Phase 2: The Iteration Loop
We re-solve the SCC members repeatedly until convergence.
- **Anchor**: The loop is driven by `iterative_resolve_scc`, usually starting from the member with the minimum `CalcId` to ensure deterministic graph traversal order.
- **State**: `SccIterationState` tracks `members`, `iteration` count, `previous_answers`, and `node_states`.

#### Iteration 1: Cold Start
- **Input**: No previous answers.
- **Back-edges**: When a member is encountered as a back-edge (via `push`):
  - Return `BindingAction::NeedsColdPlaceholder`.
  - `get_idx` handles this by creating a **fresh recursive placeholder**.
- **LoopPhi Handling (Lesson Learned)**:
  - In Legacy mode, `LoopPhi` determines the placeholder type (using the "prior" type from before the loop).
  - In Iterative mode, a back-edge might hit *any* node, not just `LoopPhi`.
  - **Fix**: Before Iteration 1, scan all SCC members for `Binding::LoopPhi`. If found, extract the `prior` type. Use this type to create `LoopRecursive` placeholders for *all* back-edges in this SCC. This ensures the back-edge "pins" to the loop prior, matching Legacy behavior.

#### Iteration 2+: Warm Start
- **Input**: `previous_answers` populated from the previous iteration.
- **Back-edges**: When a member is encountered as a back-edge:
  - Return `BindingAction::SccLocalAnswer(prev)` using the answer from the previous iteration.
  - This allows the type information to flow "around" the cycle.

#### Convergence Detection
- After each Warm iteration (2+), compare the computed answers with `previous_answers`.
- Comparison uses `answers_equal_typed` (checking `PartialEq` of the inner `Arc<K::Answer>`).
- If **no answers changed**, the fixpoint is reached. Break the loop.

#### Demotion (Dynamic SCC Growth)
- During any iteration, the solver might discover *new* dependencies that form a larger cycle (e.g., because a type narrowed and revealed a new path).
- If `on_scc_detected` finds a cycle involving current members + new nodes:
  - Add new nodes to `members`.
  - Set `demoted = true`.
  - **Action**: Abort current iteration, reset to **Iteration 1 (Cold)** with the expanded member set.

### Phase 3: Finalization
- Once converged (or max iterations reached):
  - **Commit**: Batch-commit the final answers to the global `Calculation` table.
  - **Errors**: Errors are collected **only** during the final iteration. Intermediate iterations use a `swallowing_error_collector` to prevent spurious errors from temporary placeholders.

## Detailed Design & Implementation Notes

### 1. `SccIterationState`
Extends the current tracking to include:
```rust
struct SccIterationState {
    members: BTreeSet<CalcId>,
    iteration: u32,
    node_states: BTreeMap<CalcId, IterationNodeState>,
    previous_answers: BTreeMap<CalcId, Arc<dyn Any>>,
    demoted: bool,
    loop_phi_prior: Option<Type>, // Key for LoopRecursive creation
    has_changed: bool,
}
```

### 2. `IterationNodeState`
```rust
enum IterationNodeState {
    Fresh,
    InProgress { placeholder_var: Option<Var> },
    Done { answer: Arc<dyn Any>, errors: Option<Arc<ErrorCollector>> },
}
```
*Lesson Learned (Bug 6)*: `InProgress` must track `placeholder_var`. If the same back-edge is hit multiple times in one iteration (e.g. diamond pattern), we must reuse the *same* placeholder Var to ensure it gets finalized correctly.

### 3. The `NeedsColdPlaceholder` Protocol
- **Problem**: `CalcStack::push` cannot call `K::create_recursive` because it is generic over `T: Dupe` and lacks `K: Solve` context.
- **Solution**:
  - `push` detects a cold-start back-edge and returns `BindingAction::NeedsColdPlaceholder`.
  - `get_idx` (which has `K: Solve`) matches this action.
  - `get_idx` calls `K::create_recursive` (using `loop_phi_prior` if available) and registers the var in `IterationNodeState`.

### 4. Cross-Module Support
- The SCC solver must handle cycles spanning modules.
- **Requirement**: Implement `LookupAnswer::solve_idx_erased`.
  - This method allows the solver to trigger `get_idx` on a `CalcId` from another module (for side-effects/population of `NodeState`).
  - Currently `unimplemented!`, this must be wired up to dispatch to the appropriate module's `AnswersSolver`.

### 5. Ensure All Members Solved
- **Problem**: Starting DFS from `min_calc_id` might not reach all members if the graph structure changes (e.g. edges disappear due to type narrowing).
- **Solution**: The iteration loop must iterate through **all** `members`.
  - For each `member`, check if `node_state` is `Fresh`.
  - If `Fresh`, call `solve_idx_erased(member)`.
  - This ensures full coverage even if the graph is disconnected relative to the anchor.

## Implementation Steps

1.  **Cleanup**: Remove/Refactor existing prototype code in `answers_solver.rs` to match this design.
2.  **Core Iteration Logic**: Implement `iterative_resolve_scc` with the Cold/Warm loop and Demotion handling.
3.  **LoopPhi Scanning**: Implement `find_loop_phi_prior_in_members` to pre-scan for `LoopPhi` and support `LoopRecursive` placeholders.
4.  **Action Handling**: Implement `NeedsColdPlaceholder` in `get_idx` and `push`.
5.  **Convergence**: Implement `answers_equal` check.
6.  **Cross-Module**: Implement `solve_idx_erased` in `LookupAnswer`.
7.  **Tests**:
    - Port existing `bug = "..."` tests.
    - Add specific tests for:
        - Convergence (cycle requiring 2+ iterations).
        - Demotion (cycle growing during solve).
        - Loop priors (ensuring `LoopPhi` types are preserved).

## Lessons Learned (From Prototype)

- **Placeholder Idempotency**: Always reuse the placeholder Var for a given node within an iteration. Creating multiple vars for the same node leads to "leaked" vars that never get unified.
- **LoopPhi is Critical**: Without scanning for `LoopPhi` and using `LoopRecursive`, loops degrade to `Any` because the random break point doesn't know it's part of a loop structure.
- **Error Swallowing**: Never report errors from Iteration 1 (or any non-final iteration). The placeholders are temporary and cause confusing "type mismatch" errors.
- **CycleDetected Fallback**: In Iterative mode, `CycleDetected` can occur where `current_cycle()` returns `None` (because the node is `Calculated` in the global scope but `Calculating` in the iteration scope). Handle this by falling back to `NeedsColdPlaceholder`.