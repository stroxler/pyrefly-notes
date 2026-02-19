# Iterative Fixpoint SCC Solving (v1 Plan)

This document is the implementation-ready plan for reimplementing Pyrefly's SCC
solver using an **iterative fixpoint** strategy. It replaces the prototype
(6 commits at HEAD, to be discarded) and incorporates all lessons learned from
that prototype. It assumes **ref-native type aliases are landed** (9 commits
ending at be2e6f0d94): `Variable::AliasRecursive` is gone, recursive aliases
no longer participate in SCC cycle-breaking, and the 13 recursive alias test
failures that blocked the prototype are eliminated.

---

## Goals

1. **Determinism:** SCC solving must produce the same types regardless of DFS
   entry order. The current legacy behavior is nondeterministic because
   detection-order changes `break_at` sets, placeholder placement, and final
   types.
2. **Convergence:** Iterative fixpoint with warm-start answers, converging when
   types stabilize. This is a core feature, not deferred.
3. **Correctness:** Handle all edge cases (LoopPhi, cross-module, demotion).
   Incorporate all prototype bug fixes (1--7) and their root causes.
4. **Compatibility:** Integrate with existing `Calculation` / `CalcStack`
   infrastructure without rewriting the DFS-driven solver.
5. **Parity:** Match or exceed Legacy mode correctness for recursive structures.

## Out of Scope

- Reintroducing `Variable::AliasRecursive` or recursive type alias SCC breaking
  (already removed by ref-native aliases).
- Redesigning the solver outside SCC handling.
- Changing the external type system or error message formats.

---

## What Changed with AliasRecursive Gone

The ref-native alias work significantly simplifies the SCC solver:

- `Binding::TypeAliasRef` now produces `TypeAliasData::Ref` at binding time,
  so recursive aliases are structurally resolved before SCC detection.
- `create_recursive` no longer needs a `Binding::TypeAlias` arm. The only
  `Variable` types that `create_recursive` now produces are `Recursive` and
  `LoopRecursive`.
- The 13 recursive alias test failures that blocked the prototype are gone.
- `wrap_type_alias` has an expand step for non-recursive Refs, but this is
  orthogonal to SCC iteration.
- Legacy-only code that special-cased `AliasRecursive` in SCC break-at logic
  can be removed after the iterative solver is stable.

---

## Architecture Overview

The algorithm has three phases:

### Phase 0: Iteration Zero (Discovery)

Phase 0 is **not** a new phase introduced by the iterative solver. It IS the
existing SCC discovery mechanism: the normal demand-driven DFS that creates
`Scc` structs via `CalcStack` and `Calculation`. The only difference is that
in IterativeFixpoint mode, the completed `Scc` is handed to
`iterative_resolve_scc` instead of being committed directly.

- Run demand-driven DFS as usual via existing `CalcStack` and `Calculation`.
- **Break immediately** at every back-edge (all back-edges return `BreakHere`).
- **Discard** all answers and errors. The sole purpose is to discover SCC
  membership.
- Output: An `Scc` struct whose `node_state` keys form the member set.
- Transition: `iterative_resolve_scc` is called with the discovered `Scc`,
  after the existing SCC lifecycle completes.

**Note on solver state during discovery:** Phase 0 reuses the existing
demand-driven DFS, which executes `K::solve` and `finalize_recursive_answer`
as part of normal computation — it is not a "pure" discovery pass. The
answers and errors are discarded, but side effects on solver state (Var
allocations, placeholder unifications) do occur. This is acceptable because
Iteration 1+ allocates fresh placeholders and does not depend on Phase 0's
solver state, but it does mean Phase 0 has higher Var churn than a
hypothetical pure-discovery pass would. Redesigning Phase 0 to avoid
computation is out of scope for v1.

### Phase 1+: Deterministic Fixpoint Iterations

**Note on single-member SCCs:** A single-member SCC with a self-loop (back-edge
to itself) still goes through `iterative_resolve_scc` and full fixpoint
iteration. A node that appears as a singleton "SCC" but has no self-loop is not
a true SCC; it does not enter `iterative_resolve_scc` at all and is committed
through the normal non-SCC path.

- Restart solving from the minimum `CalcId` (deterministic entry point).
- **Iteration 1 (Cold Start):** Every back-edge allocates a placeholder via
  `K::create_recursive` and returns the promoted recursive type.
- **Iteration 2+ (Warm Start):** Every back-edge returns the previous
  iteration's answer.
- After each iteration >= 2, compare answers for convergence.
- Stop when answers stabilize (fixpoint) or a hard limit is reached.

### Demotion (Dynamic Expansion)

- If new SCC members are discovered during Iteration 1+ (via
  `on_scc_detected`), **demote**: discard the current iteration's answers and
  restart from **Iteration 1 (cold start)** with the expanded member set.
- We do NOT restart from Iteration Zero because the expanded SCC membership
  is already known from the merge that triggered demotion. We only need to
  restart cold solving with the larger set.

### Upstream SCCs During Iteration

During iteration, solving a member's dependencies may trigger discovery of a
**disjoint SCC** (a separate cycle with no overlap with the current SCC's
members). This is not "nesting" — it's a separate upstream component in the
DAG of SCCs. When this happens:

- The upstream SCC is committed via `batch_commit_scc` (the legacy path),
  NOT via a nested `iterative_resolve_scc`. This is intentional:
  `active_iteration` is already set for the current SCC, and nesting
  iterative resolution would clobber it. More importantly, independent
  SCCs should resolve independently — coupling them would cause compute
  costs to explode in loosely coupled codebases.
- The upstream SCC's `CalcId`s are NOT in the current `members` set, so the
  current `active_iteration` bypass logic does not apply to them. They follow
  the normal `Calculation` / `CalcStack` path.
- The upstream SCC's final answers are committed to `Calculation` cells
  normally. The current iteration sees them as stable, already-computed
  answers.

If the discovered cycle **overlaps** with the current SCC, the SCC merge
logic unions them — this is **demotion**, not nesting. True nested SCCs
(disjoint cycles where one must iterate inside another's iteration) are
impossible when merging works correctly: any overlap triggers a merge into
a single, larger SCC.

---

## Core Data Structures

### `SccIterationState`

Stored in `CalcStack::active_iteration` (`RefCell<Option<SccIterationState>>`).
Tracks the entire iterative phase.

```rust
struct SccIterationState {
    /// The full set of SCC members for the current iteration.
    members: BTreeSet<CalcId>,

    /// Current iteration number (1 = cold start, 2+ = warm).
    /// The iteration number fully determines the mode:
    ///   1     -> cold (use placeholders at back-edges)
    ///   2+    -> warm (use previous_answers at back-edges)
    /// No separate "mode" field is needed.
    iteration: u32,

    /// Per-node state during the current iteration pass.
    node_states: BTreeMap<CalcId, IterationNodeState>,

    /// Previous iteration's answers, used for warm-start at back-edges.
    /// Empty during iteration 1 (cold start).
    previous_answers: BTreeMap<CalcId, Arc<dyn Any + Send + Sync>>,

    /// Whether new SCC members were discovered during this iteration,
    /// requiring a demotion to iteration 1 with expanded membership.
    demoted: bool,

    /// Whether any answer has changed in this iteration compared to the
    /// previous iteration. Used for convergence detection. Only meaningful
    /// when iteration >= 2.
    has_changed: bool,

    // NOTE: LoopPhi handling is deferred (see "LoopPhi Handling" section).
    // The final approach may add fields here or may use a different mechanism
    // entirely (e.g., unconditional LoopPhi break in iteration 1).
}
```

### `IterationNodeState`

Tracks the progress of each member within a single iteration pass.

```rust
enum IterationNodeState {
    /// Node hasn't been visited yet in this iteration.
    Fresh,

    /// Node is currently being computed (on the Rust call stack).
    /// The placeholder_var stores the recursive Var created for this node
    /// (if a cold-start back-edge allocated one). Required for:
    ///   - Idempotency (Bug 6): multiple back-edges reuse the same Var
    ///   - Finalization: calculate_and_record_answer can call
    ///     finalize_recursive_answer to unify the Var with the computed type
    InProgress {
        placeholder_var: Option<Var>,
    },

    /// Node's computation has completed for this iteration.
    Done {
        answer: Arc<dyn Any + Send + Sync>,
        errors: Option<Arc<ErrorCollector>>,
    },
}
```

**Design note on `NeedsColdPlaceholder`:** This is a `BindingAction` variant
returned by `CalcStack::push`, NOT a field on `IterationNodeState`. The
`push` method is generic over `T: Dupe` and cannot call `K::create_recursive`.
Instead, it signals `get_idx` (which has the `K: Solve` context) to allocate
the placeholder. The placeholder is then stored back into
`IterationNodeState::InProgress` via `set_active_iteration_placeholder`.

---

## CalcStack / Calculation Interaction

The iterative solver sits alongside the legacy `Calculation` machinery. The
key invariant is: **when `active_iteration` is set and `calc_id` is in
`members`, we never write to `Calculation` cells**. All answers and errors
stay in `SccIterationState` until the final iteration completes.

### `CalcStack::push` Behavior

When `active_iteration` is present and `current` is in `members`, bypass
normal SCC/Calculation logic entirely:

| Current `IterationNodeState` | Condition | Action |
| --- | --- | --- |
| `Fresh` | -- | Set to `InProgress { placeholder_var: None }`, return `Calculate` |
| `InProgress` | `previous_answers` has entry | Return `SccLocalAnswer(prev)` (warm back-edge) |
| `InProgress` | `placeholder_var` is `Some(var)` | Return `CycleBroken(var)` (Bug 6: reuse placeholder) |
| `InProgress` | no prev, no placeholder | Return `NeedsColdPlaceholder` (cold back-edge) |
| `Done` | -- | Return `SccLocalAnswer(answer)` |

All non-member nodes follow the existing SCC/Calculation path unchanged.

### `CycleDetected` Without Active Cycle (Bug 5 / Bug 2)

When `propose_calculation()` returns `CycleDetected` but `current_cycle()` is
`None` while in iterative mode, treat it as `NeedsColdPlaceholder`. This
mirrors legacy behavior and avoids panics when multiple DFS paths revisit a
node still in `Calculating` state from Discovery.

**Important:** The current `push()` implementation calls
`self.current_cycle().unwrap()` when `CycleDetected` fires, which will panic
if there is no active cycle. The iterative mode fix must guard this unwrap
so that it does not fire when `active_iteration` is set and the node is a
member. Specifically, the `active_iteration` member check must happen
**before** the `current_cycle().unwrap()` call.

**Calculation cell state during iteration:** During Phase 0 (discovery), the
`Calculation` cells for SCC members are set to `Calculating` and never
completed -- Phase 0 discards answers rather than storing them. During
Iteration 1+, these cells remain frozen in the `Calculating` state. The
iterative solver does not read or write `Calculation` cells for members;
`IterationNodeState` is the **sole source of truth** for member progress
during iteration. `Calculation` cells are only updated at the end, during
batch commit of final answers. This is why `propose_calculation` returns
`CycleDetected` for SCC members during iteration -- it sees the stale
`Calculating` state -- and why we must bypass that result.

### `BindingAction::NeedsColdPlaceholder` Protocol (Bug 1)

Because `push()` is generic over `T: Dupe` and lacks `K: Solve` context:

1. `push` returns `BindingAction::NeedsColdPlaceholder`.
2. `get_idx` handles this action:
   - Calls `K::create_recursive(self, binding)` to allocate a `Recursive` var.
   - Stores the var via `set_active_iteration_placeholder(current, var)`.
   - Returns `K::promote_recursive(heap, var)`.
   - Note: LoopPhi-aware placeholder types are deferred (see "LoopPhi
     Handling" section). Initially all cold-start placeholders are plain
     `Recursive`.

### `calculate_and_record_answer`

There are exactly three paths:

1. **Legacy SCC participant:** Store in `NodeState::Done`, finalize placeholder
   if needed, defer commit until `batch_commit_scc`.
2. **Active iteration member:** Store in `IterationNodeState::Done`, finalize
   placeholder if present (Bug 3), do **not** write to `Calculation`.
3. **Non-SCC path:** Write directly to `Calculation` (unchanged).

### Placeholder Finalization (Bug 3)

When `calculate_and_record_answer` finishes for an `active_iteration` member:
- Check if `IterationNodeState::InProgress` had a `placeholder_var`.
- If yes, call `finalize_recursive_answer` (unifies the Var with the result).
- This is critical for `LoopRecursive` types to resolve correctly.

---

## Error Handling

Error handling is tightly coupled to the iteration number:

| Iteration | Error Behavior | Rationale |
| --- | --- | --- |
| 0 (Discovery) | All errors discarded | Answers are also discarded; this pass is discovery-only |
| 1 (Cold Start) | Errors suppressed via `error_swallower()` | Placeholder types at back-edges produce misleading diagnostics (e.g. "Cannot call method on type `Unknown`") |
| 2+ (Warm) | Errors collected via `error_collector()` | Answers from previous iterations are real types; errors are meaningful |

**Which errors are committed?** Only the **final** iteration's errors are
committed. "Final" means whichever iteration is last: either the one where
convergence is detected, or the last iteration before `max_iterations` is hit.

**Implementation:** The `is_final_iteration` method returns `iteration >= 2`
(Bug 4 fix: the prototype originally used `== 2`, which broke when convergence
required more than 2 iterations). Since every iteration >= 2 *might* be the
final one, we collect errors on all of them. This means we may collect errors
on an intermediate warm iteration that is not actually the last, but since we
replace error state on each iteration, only the last iteration's errors survive
to be committed.

---

## Iteration Driver (`iterative_resolve_scc`)

Pseudo-logic:

```
fn iterative_resolve_scc(completed_scc: Scc):
    members = completed_scc.node_state.keys()
    max_iterations = 5
    max_demotions = 10
    iteration = 1
    demotion_count = 0

    loop:
        if iteration > max_iterations:
            log warning "SCC did not converge after {max_iterations} iterations"
            break

        // Build previous_answers from prior iteration's Done states
        previous_answers = if iteration > 1:
            extract Done answers from active_iteration
        else:
            empty map

        // Initialize all nodes as Fresh
        node_states = { id -> Fresh for id in members }

        // Install the iteration state
        active_iteration = Some(SccIterationState {
            members, iteration, node_states, previous_answers,
            demoted: false, has_changed: false,
        })

        // Solve all members (not just min_calc_id)
        for member in members (sorted by CalcId):
            if node_states[member] == Fresh:
                solve_idx_erased(member)

        // Check demotion
        if active_iteration.demoted:
            demotion_count += 1
            if demotion_count > max_demotions:
                panic!("SCC demotion limit exceeded ({max_demotions}). \
                    This indicates nondeterministic SCC membership.")
            members = active_iteration.members  // expanded set
            iteration = 1  // restart cold (NOT iteration zero)
            continue

        // Convergence check (only on warm iterations)
        if iteration > 1 && !active_iteration.has_changed:
            break  // fixpoint reached

        iteration += 1

    // Commit final answers
    for (calc_id, node_state) in active_iteration.take().node_states:
        if let Done { answer, errors } = node_state:
            commit_single_result(calc_id, answer, errors)
```

### Ensure All Members Solved (Explicit Requirement)

A single DFS from `min(CalcId)` is insufficient because **every back-edge
breaks** in iterative mode, which can leave parts of the SCC graph
unreachable from the min node. After the initial DFS from `min_calc_id`, we
iterate through ALL members in deterministic (sorted) order and solve any
that remain `Fresh`. The idempotency logic in `push` ensures we do not
re-calculate `Done` nodes.

### Max-Iteration Guardrail

Use a small `max_iterations` value (5, not 20). Most real cycles converge in
2--3 iterations. A high max wastes CPU on genuinely divergent cases.

**Behavior when the limit is hit:**

1. Commit the **last completed iteration's** answers and errors. These types
   may not be a fixpoint (i.e., running another iteration might produce
   different answers), but they are the best approximation available.
2. Emit a **diagnostic warning** indicating that the SCC did not converge.
   This warning should include the SCC member count and the iteration limit
   to aid debugging.
3. The committed types are used downstream as-is. Consumers of these types
   should not assume they are a fixpoint.

Note: `max_iterations` limits the number of **non-demoted** iterations. It is
independent of the demotion limit (see below).

### Demotion

If `on_scc_detected` fires during Iteration 1+ and discovers a new member:
- Add the new member to `members` and mark it `Fresh` in `node_states`.
- Set `demoted = true`.
- The loop checks `demoted` and restarts from iteration 1 (cold start) with
  the expanded membership. We do NOT return to iteration zero because the
  expanded SCC membership is already known from the merge.

**Demotion limit:** Demotion indicates that the SCC membership discovered
during Phase 0 was incomplete — a deterministic iteration revealed a cycle
member that the nondeterministic discovery phase missed. This is expected to
be rare (at most 1--2 demotions). If demotion occurs repeatedly, it signals
a fundamental problem with SCC membership stability, which would cause
**nondeterminism** — the very thing this algorithm exists to eliminate.

Therefore: set a **high demotion limit** (e.g., `max_demotions = 10`) and
**panic** if it is exceeded. This must not be silent. A panic ensures we
catch any pathological graph structure during development rather than
silently producing nondeterministic results. In the future, a feature flag
could downgrade this from a panic to a type error diagnostic if needed for
production resilience, but the default must be loud failure.

---

## LoopPhi Handling (Open Problem)

**Problem:** In IterativeFixpoint mode, every back-edge immediately breaks,
so `LoopPhi` never creates its own `LoopRecursive` placeholder the way it
does in Legacy mode (where the cycle unwind propagates past non-LoopPhi
nodes via `Continue` until reaching the LoopPhi). This causes incorrect
generic inference when `Recursive` (which absorbs any type) is used instead
of `LoopRecursive` (which pins to the prior type).

**Status:** LoopPhi handling is an **open problem** and should be addressed
**late** in the implementation, as a separate commit after the core iteration
machinery is working. It is acceptable to regress loop behavior initially
and recover it afterward.

**Why this is hard:** An SCC can contain **multiple `LoopPhi` bindings** —
one per variable reassigned in a loop. Multiple variables' cycles can overlap
and merge into a single SCC (see `test_while_two_vars`), and nested loops
produce further overlap. Any solution must handle multiple LoopPhis with
different prior types correctly.

### Candidate approaches

**Approach A (prototype): Pre-scan SCC for a single LoopPhi prior.** Scan
members for any `LoopPhi` binding, extract its prior type, and use it for
ALL cold-start placeholders in the SCC. This worked in the prototype's test
suite but relies on a single-LoopPhi-per-SCC assumption that is not true in
general. It is likely overfitted to unit tests.

**Approach B (preferred): Unconditional LoopPhi break on iteration 1.**
During iteration 1 (cold start), when the DFS encounters a `LoopPhi` member,
**always** return the LoopPhi's promoted prior type as the answer,
unconditionally — even if the node is `Fresh` and not yet at a back-edge.
This is an exception to the normal `Fresh → InProgress → Calculate` flow:
for LoopPhi nodes specifically, iteration 1 treats them as pre-solved with
their prior type.

This approach:
- Is deterministic as long as it is applied unconditionally in iteration 1.
- Naturally handles multiple LoopPhis: each LoopPhi uses its own prior.
- Removes the need for `loop_phi_prior` on `SccIterationState` entirely.
- May cause slower SCC discovery (more restarts / demotions) because
  LoopPhi nodes don't participate in the DFS during iteration 1, potentially
  leaving some cycle edges undiscovered until iteration 2.
- Makes conceptual sense: iteration 1 is a cold start from "bottom," and
  the LoopPhi prior IS the bottom for loop variables.

**Approach C: Per-CalcId LoopPhi prior map.** Make `loop_phi_prior` a
`BTreeMap<CalcId, Type>` mapping each LoopPhi member to its own prior type.
Only use the prior when creating a placeholder for that specific member.
This is more precise than Approach A but adds complexity.

**Recommendation:** Start without any LoopPhi handling (accept regressions
in loop tests). Then implement Approach B as a separate commit. If Approach B
causes problems (e.g., too many demotions), fall back to Approach C.

**Is this still necessary post ref-aliases?** Yes. The ref-alias changes only
removed `AliasRecursive`. LoopPhi-based recursion still exists and still
needs `LoopRecursive` placeholder semantics.

---

## Convergence Detection

### Mechanism

Convergence is checked at the end of each iteration where `iteration >= 2`.
The `has_changed` flag is set **eagerly** during `calculate_and_record_answer`,
not in the iteration driver loop. Each time a member's answer is stored into
`IterationNodeState::Done`, the comparison happens immediately:

1. When storing a `Done` answer, check if `previous_answers` has an entry
   for this `CalcId`.
2. If yes, compare the two answers using type-erased equality.
3. If they differ, set `has_changed = true`.
4. If no previous answer exists for a member in a warm iteration, treat it
   as changed.

The driver loop simply checks the `has_changed` flag after all members have
been solved. It does not perform any comparisons itself.

### Type-Erased Answer Comparison (`answers_equal`)

The comparison uses `dispatch_anyidx!` to recover the concrete key type from
a `CalcId`'s `AnyIdx`, then downcasts `Arc<dyn Any + Send + Sync>` to the
concrete `Arc<K::Answer>` type and compares with `PartialEq`:

```rust
fn answers_equal(&self, calc_id: &CalcId, a: &Arc<dyn Any>, b: &Arc<dyn Any>) -> bool {
    let CalcId(_, ref any_idx) = *calc_id;
    dispatch_anyidx!(any_idx, self, answers_equal_typed, a, b)
}

fn answers_equal_typed<K: Solve<Ans>>(&self, _idx: Idx<K>, a: &Arc<dyn Any>, b: &Arc<dyn Any>) -> bool
where
    K::Answer: PartialEq,
{
    let a_typed = a.downcast_ref::<Arc<K::Answer>>().expect("type mismatch a");
    let b_typed = b.downcast_ref::<Arc<K::Answer>>().expect("type mismatch b");
    a_typed == b_typed
}
```

### What Drives Convergence

- **Only answers drive convergence.** Errors are NOT part of the fixpoint
  check. This is because errors can differ between iterations due to error
  suppression strategy without indicating a real type-level change.
- Structural equality via `PartialEq` is preferred over hashing to avoid
  hash collisions.

### Var Identity and Convergence Soundness

The `PartialEq` comparison on answers is sound only if the compared answers
are **semantically comparable** — i.e., they don't contain `Var` references
that would differ in identity between iterations despite representing the
same resolved type.

During cold start (iteration 1), placeholder `Var`s are created at back-edges.
After `finalize_recursive_answer` unifies each placeholder with the computed
type, the `Var`'s solution is recorded in the solver's `Variables` map. However,
it is possible that the finalized answer type still contains `Type::Var(v)`
nodes where `v` has been **solved but not expanded** — i.e., the Var has a
solution in the Variables map, but the type tree still holds a lazy `Var`
reference rather than the inlined concrete type. If `PartialEq` on `Type`
compares `Var` IDs without forcing through to solutions, two semantically
identical types could compare as unequal.

**Implementation requirement:** Before storing an answer for convergence
comparison, the implementation **must expand all solved Vars** in the
answer type (deep-force / simplify). This ensures the stored answer is a
fully concrete type where `PartialEq` reflects semantic equality.
`Type` derives `PartialEq`, and `Var` compares by identity (unique ID).
Two types with different solved Var IDs that point to the same resolved
type will compare as unequal under the derived `PartialEq`. Therefore,
deep-force/expand is **mandatory** before convergence comparison — it is
not optional. The existing `deep_force` pattern used by
`calculate_and_record_answer` for exported keys can be reused for
iteration answers.

**Structural invariant:** Deep-force correctness relies on `VisitMut<Type>`
covering all `Var`-containing fields in all `Answer` types. The `Keyed`
trait already requires `VisitMut<Type>` on `Answer` (alongside `TypeEq`,
which transitively requires `PartialEq`), so this invariant is
structurally enforced by the type system. Any new `Answer` type that fails
to implement `VisitMut<Type>` will produce a compile error at the `Keyed`
trait bound, not a silent convergence bug.

Iteration 2+ uses `previous_answers` (from the prior iteration) at
back-edges, so no new placeholder `Var`s are allocated in warm iterations.
But the answers from iteration 1 that are used as `previous_answers` must
themselves be Var-expanded for the comparison to work correctly.

Additionally, union types (`A | B` vs `B | A`) do not pose a convergence
problem because Pyrefly canonicalizes union types (they are sorted), so
structural equality is stable across iterations.

### Monotonicity

The iteration is **expected** to be monotone in most practical cases: types
grow from a bottom value (placeholder on cold start) toward a fixpoint as
information accumulates at each iteration. However, it is **known in advance**
that non-monotone examples exist (e.g., types that oscillate or expand
unboundedly across iterations). The algorithm makes **no assumption** of
monotonicity. For cases that do not converge — whether due to oscillation,
divergent type growth, or any other reason — the `max_iterations` guardrail
stops iteration at a deterministic point and commits the last iteration's
answers along with a non-convergence diagnostic. This is the same handling
used for genuinely divergent cases like a type that wraps one layer deeper
each iteration (`list[int | list[int | ...]]`).

---

## Cross-Module `solve_idx_erased`

### Problem

SCCs can span module boundaries. Iterative re-solving may start at a
`CalcId` from another module. The prototype panics on cross-module calls
(`solve_idx_erased not implemented`).

### Solution

The `solve_idx_erased` method in `AnswersSolver` already dispatches:

```rust
fn solve_idx_erased(&self, calc_id: &CalcId) {
    let CalcId(ref bindings, ref any_idx) = *calc_id;
    if bindings.module().name() != self.bindings().module().name() {
        // Cross-module: delegate to LookupAnswer
        self.answers.get_erased(calc_id.dupe(), self.thread_state);
        return;
    }
    dispatch_anyidx!(any_idx, self, solve_erased_helper)
}
```

This function should also make sure we don't unexpectedly fail to write the answer;
details of that may be missing in the snippet above; that check has to handle
the possibility that another thread might have already finished the SCC and evicted
another module's Answers by allowing failure-to-write if a module already has
finished Solutions.

### Required Plumbing

1. **`LookupAnswer::get_erased`**: This method does not currently exist on
   the `LookupAnswer` trait (the trait only has `get` and `commit_to_module`).
   It must be added as a new trait method and implemented in
   `TransactionHandle` (located in `pyrefly/lib/state/state.rs`). The
   implementation must:
   - Look up the target module's `Answers` via `TransactionHandle`.
   - Call `Answers::solve_idx_erased` on it, which creates an `AnswersSolver`
     for the target module and dispatches via `dispatch_anyidx!`.
2. **Thread-local iteration state:** Since `CalcStack` is thread-local and
   `active_iteration` is on `CalcStack`, cross-module calls within the same
   thread share the iteration state naturally. No additional threading work
   is needed.
3. **Key challenge:** Getting a reference to the other module's `Answers`
   goes through `LookupAnswer` / `TransactionHandle`. The `TransactionHandle`
   implementation must resolve the target module and invoke
   `solve_idx_erased` on it.
4. **Return value:** No return value is needed from `get_erased`. We rely on
   the side effect of populating `IterationNodeState::Done` in the shared
   `active_iteration` state.

---

## Iteration Nesting

At one point, a reader of this doc incorrectly inferred that if we discover
a disjoint Scc in the dependencies of an Scc, we should include the solve of
the "inner" Scc discovered in the dependencies as part of iteration on the
original Scc.

This is not the case: disjoint Sccs (and isolated bindings not in an Scc,
which are in effect their own single-node Sccs) should always solve independently.

So if we branch out from an Scc during iterative solving and encounter a new
Scc, that new Scc should go on the Scc stack and be fully solved independent
of the first one, assuming it remains disjoint. By fully solved, I mean the
iteration will run to completion and the answers will all be stored globally
in the Answers table, cached for all threads to use. If we discover a back-edge
while solving the new Scc, then we would merge them and demote (restarting
iteration), which has already been discussed.

It is very important that disjoint Sccs solve independently, since (a) we could
enter them in different orders anyway in successive runs, and (b) if they
*didn't* solve independently, then the costs would quickly become exponential
in the number of components even for a mostly acyclic graph - Pyrefly would be
unable to type check medium-sized codebases in a reasonable amount of time.

## Residual Nondeterminism

Even with iterative fixpoint solving, **path-dependent edges** can cause
different SCC memberships across runs. A path-dependent edge is one where the
DFS traversal order depends on previously-computed types. For example:

- If type `A` resolves to `int`, the solver follows branch X.
- If type `A` resolves to `str`, the solver follows branch Y.
- Branch X and Y may have different back-edges, producing different SCC
  memberships.

This means two runs starting from different DFS entry points could discover
different SCC member sets, leading to different fixpoint results. This is a
**known limitation** accepted by the design. The iterative solver guarantees
determinism *within* a given SCC membership set, but does not guarantee that
the membership set itself is stable across entry points. In practice, most
real-world cycles do not have path-dependent edges, and where they exist, the
types typically converge to the same result regardless of membership
differences.

---

## Cleanup / Legacy Code Removal

After IterativeFixpoint is live and stable:

- Remove any remaining `AliasRecursive` handling and special-casing in SCC
  code.
- Remove legacy assumptions that `break_at` is a singleton min-id.
- Leave legacy SCC mode intact (config gated) as a safety valve during
  rollout, but strip dead logic paths that only existed to support recursive
  aliases.
- Ensure `LoopPhi`-specific handling remains (it is still required).
- Keep `SccMode::Legacy` and `SccMode::IterativeFixpoint` as explicit modes
  in `crates/pyrefly_config/src/base.rs` while the rollout is staged.

---

## Commit Stack

Each commit should be independently testable: all tests pass in Legacy mode
after each commit. The prototype showed that some diffs (like the original
4a+4b) are too tightly coupled to split. This stack reflects that lesson.

### Commit 1: Infrastructure -- `SccMode`, `SccIterationState`, `IterationNodeState`, CalcStack Helpers

- Add `SccMode` enum (`Legacy`, `IterativeFixpoint`) to
  `crates/pyrefly_config/src/base.rs`. This enum does not currently exist
  and must be created.
- Add `SccMode` field to `ThreadState` so the iteration driver can check
  which mode is active.
- Add `SccIterationState` and `IterationNodeState` to `answers_solver.rs`.
- Add `active_iteration: RefCell<Option<SccIterationState>>` to `CalcStack`.
- Add CalcStack accessor methods: `is_active_iteration_member`,
  `is_final_iteration`, `set_active_iteration_placeholder`,
  `get_active_iteration_placeholder`.
- Add `answers_equal` and `answers_equal_typed` dispatch helpers.
- All new code is dead at this point (no callers). Tests pass in Legacy mode.

### Commit 2: CalcStack `push` / `get_idx` Integration

- Update `push` to check `active_iteration` and bypass `Calculation` for
  members.
- Add `BindingAction::NeedsColdPlaceholder` and `BindingAction::SccLocalAnswer`.
- Update `get_idx` to handle `NeedsColdPlaceholder` (calls `create_recursive`,
  stores placeholder via `set_active_iteration_placeholder`).
- Handle `CycleDetected` without active cycle (fallback to
  `NeedsColdPlaceholder` in iterative mode).

### Commit 3: `calculate_and_record_answer` + Error Suppression

- Add active iteration path in `calculate_and_record_answer`:
  store in `IterationNodeState::Done`, finalize placeholder if present.
- Implement error suppression: `error_swallower()` for non-final iterations,
  `error_collector()` for final iterations.
- Add convergence comparison logic (set `has_changed` during answer storage).

### Commit 4: `iterative_resolve_scc` Core Loop + Demotion

- Implement `iterative_resolve_scc` with the full iteration loop.
- Implement demotion logic in `on_scc_detected`.
- Implement `commit_single_result` for final answer commit.
- Wire `iterative_resolve_scc` into the SCC completion path (gated on
  `SccMode::IterativeFixpoint`).
- This is the commit where IterativeFixpoint mode becomes functional.
- **Note:** Loop tests involving LoopPhi may regress at this point. That is
  expected — LoopPhi handling is deferred to Commit 6.

### Commit 5: Cross-Module `solve_idx_erased` Plumbing

- Add `LookupAnswer::get_erased` as a new trait method (this method does not
  currently exist on the trait).
- Implement `get_erased` in `TransactionHandle` (`pyrefly/lib/state/state.rs`).
- Implement `Answers::solve_idx_erased`.
- Add `solve_idx_erased` method to `AnswersSolver`.
- This is deferred until after the core iteration loop works for
  single-module SCCs because cross-module SCCs are rare, and getting the
  single-module case working first is more practical.

### Commit 6: LoopPhi Handling

- Address the LoopPhi open problem (see "LoopPhi Handling" section).
- The specific approach should be determined during implementation based on
  what works. Start with the simplest viable approach.
- Update or add loop-related tests.

### Commit 7: Tests + Cleanup

- Add targeted tests (see Testing Plan below).
- Remove obsolete `AliasRecursive` paths from SCC code.
- Trim legacy-only placeholder handling no longer needed.
- Verify conformance suite passes in both modes.

---

## Testing Plan

### Required Before Handoff

- Run `./test.py --no-test --no-conformance` (formatting and linting).
- Run full test suite in Legacy mode to ensure no regressions.

### Targeted Tests to Add

1. **Cycle Determinism:** A cycle with multiple DFS entry points yields
   identical types regardless of which entry point is used. Verify by running
   the same cycle with different `min_calc_id` values and comparing results.

2. **Warm-Start Convergence:** A non-trivial SCC that requires > 1 warm
   iteration to stabilize. Verify the iteration count and final types.

3. **LoopPhi Cycle:** Ensure LoopPhi-driven recursive inference uses
   `LoopRecursive` placeholder behavior. Verify via type inspection that the
   promoted prior type is correctly applied.

4. **Cross-Module SCC:** A cycle spanning two modules converges correctly in
   IterativeFixpoint mode.

5. **Demotion:** A cycle that reveals a new branch only after a specific type
   flows through, triggering demotion. Verify the iteration restarts from
   cold start with expanded membership.

6. **Error Suppression:** Verify that placeholder-driven errors from cold-start
   iterations do not appear in the final output.

7. **Max-Iteration Guardrail:** A pathological cycle that does not converge.
   Verify it stops at `max_iterations` and emits a warning.

### Test Infrastructure

- Use existing integration test harnesses (`pyrefly/lib/test`,
  `test/` markdown).
- Only use `bug = "..."` markers if a test captures known, **still-unfixed**
  behavior. Those tests must still pass.

---

## Prototype Bug Fixes Reference

| Bug | Description | Root Cause | Fix |
| --- | --- | --- | --- |
| **1** | `NeedsColdPlaceholder` | `push()` is generic `T: Dupe`, lacks `K: Solve` to call `create_recursive` | Two-step protocol: `push` returns `NeedsColdPlaceholder`, `get_idx` allocates the Var |
| **2** | `CycleDetected` without active cycle | Multiple DFS paths revisit a node in `Calculating` from Discovery | Fallback to `NeedsColdPlaceholder` when `current_cycle()` is `None` in iterative mode |
| **3** | Placeholder finalization | `IterationNodeState::InProgress` stores placeholders but completion must finalize them | `calculate_and_record_answer` calls `finalize_recursive_answer` for iteration members with a `placeholder_var` |
| **4** | Error suppression threshold | `is_final_iteration` was `== 2` but convergence can take > 2 iterations | Changed to `>= 2`: every warm iteration collects errors, only the last iteration's errors survive |
| **5** | CycleDetected + None panic | In iterative mode, `propose_calculation` returns `CycleDetected` but no cycle is active on the stack | Same fix as Bug 2: treat as `NeedsColdPlaceholder` |
| **6** | Placeholder idempotency | Multiple back-edges to the same `InProgress` node each created a new Var, leaking orphaned promoted types | Check `placeholder_var` in `InProgress` state; if already `Some`, return `CycleBroken(var)` instead of creating a new one |
| **7** | LoopPhi prior types | In iterative mode, every back-edge breaks immediately, so `LoopPhi` never creates its own `LoopRecursive` placeholder | Pre-scan SCC members for `Binding::LoopPhi`, extract prior type, use it in `create_recursive` for all cold-start placeholders |

---

## Key Files

| File | Role |
| --- | --- |
| `pyrefly/lib/alt/answers_solver.rs` | Main SCC solving logic, CalcStack, iteration driver (~2200 lines) |
| `pyrefly/lib/alt/answers.rs` | `LookupAnswer` trait, `Answers` struct, `solve_idx_erased` |
| `pyrefly/lib/state/state.rs` | `TransactionHandle` (implements `LookupAnswer`, cross-module dispatch) |
| `pyrefly/lib/alt/solve.rs` | Type solving, `Solve` trait |
| `pyrefly/lib/binding/binding.rs` | `AnyIdx`, `dispatch_anyidx!` macro, binding types |
| `crates/pyrefly_config/src/base.rs` | `SccMode` enum (`Legacy`, `IterativeFixpoint`) |

---

## Implementation Checklist

- [ ] `SccMode` enum created in `crates/pyrefly_config/src/base.rs`
- [ ] `SccIterationState` / `IterationNodeState` added
- [ ] `CalcStack` active iteration bypass in `push`
- [ ] `NeedsColdPlaceholder` flow and placeholder idempotency
- [ ] `answers_equal` / `answers_equal_typed` dispatch helpers
- [ ] `iterative_resolve_scc` with demotion + convergence
- [ ] `find_loop_phi_prior_in_members` or alternative LoopPhi approach (deferred, separate commit)
- [ ] Cross-module `solve_idx_erased` (add `get_erased` to `LookupAnswer` trait)
- [ ] Ensure all members solved (no `Fresh` left after iteration)
- [ ] Error suppression: swallow on iteration 1, collect on iteration 2+
- [ ] Convergence: compare answers with `PartialEq` via `dispatch_anyidx!`
- [ ] Max iterations guardrail (5)
- [ ] Cleanup of obsolete `AliasRecursive` paths
- [ ] Targeted tests for determinism, LoopPhi, demotion, cross-module, convergence
