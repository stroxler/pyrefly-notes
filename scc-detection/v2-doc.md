# SCC-Based Cycle Resolution: V2 Implementation Plan

This document describes the revised phased approach to implementing SCC (Strongly Connected
Component) based cycle resolution in Pyrefly. This plan incorporates lessons learned from
the v1 implementation attempt, which added infrastructure for Phases A and B but was blocked
on Phase C (SCC merging) by the existing stack winding/unwinding mechanism.

**Current status:** Phases 1-3.5 are complete. The old `recursion_stack` and `unwind_stack`
have been removed. The `Scc` struct now has a clean form:
```rust
pub struct Scc {
    node_state: HashMap<CalcId, NodeState>,
    detected_at: CalcId,
}
```
Cycles break at the detection point (InProgress nodes) rather than using a `break_at` anchor.
The remaining phases (4-8) implement SCC merging, determinism, and type quality improvements.

**Landing strategy:** Phase 3.5 introduced test regressions that will be fixed by later phases
(specifically, the fixpoint iteration in Phases 7-8). Tests have been updated with `bug` markers
to document these regressions. All diffs from Phase 3.5 onward are marked with the
`[pyrefly][scc][land-as-stack]` tag to indicate they must land atomically. This prevents
intermediate diffs from introducing visible regressions to users while the stack is in progress.

**Test regressions from Phase 3.5:**
- Loop variable widening now shows `Literal[x] | Unknown` instead of `int` after loops
- Some loop-related type inference errors appear or disappear compared to before
- These are expected and will be fixed by multi-iteration in later phases

**Key insight from v1:** The original `Cycle` architecture with `recursion_stack` and
`unwind_stack` was fundamentally cycle-centric. It assumed cycles are detected and resolved
one at a time with a clear winding/unwinding flow. SCC merging requires a different mental
model: we're not tracking phases of a cycle, we're tracking computation within a set of
mutually-recursive bindings. The refactoring phases below gradually transform the cycle
machinery into SCC machinery before attempting merging.

---

## Background: CalcStack vs SccStack

Understanding the relationship between these two stacks is essential:

**CalcStack** (shadow of Rust call stack):
- One entry per active `get_idx` call
- Tracks which bindings are currently being computed
- Used for cycle detection: if we try to compute X and X is already on the CalcStack, we've found a cycle

**SccStack** (active SCCs being resolved):
- One entry per SCC currently being resolved
- An SCC is pushed when a cycle is detected
- An SCC is popped when its computation completes
- Multiple SCCs can be nested (independent cycles discovered during resolution of outer cycles)

**Relationship:**
- CalcStack entries may or may not belong to an SCC
- "Free-floating" nodes are CalcStack entries not in any SCC (yet)
- When a cycle is detected, some CalcStack entries become participants in a new SCC

**Example:**
```
CalcStack: [A, B, C, D, E]
SccStack: [SCC1={A,B,C}]

Here: A, B, C are in SCC1; D and E are "free-floating" (computed as dependencies
of SCC1 but not yet known to be cyclic)
```

---

## Prerequisites

### CalcId Dispatch Mechanism

**Status:** Not yet implemented. Blocking for Phase 5.

Phase 5 (SCC Merging) requires restarting computation from a canonical entry point after
merge. This means calling `get_idx` from a type-erased `CalcId`. This requires a dispatch
mechanism to map `CalcId` → appropriate `Idx<K>` type.

**Design considerations:**
- Requires runtime dispatch based on TypeId
- Must handle all key types (Key, KeyClass, KeyExport, etc.)
- Must be updated when new key types are added
- **Cross-module restart:** The minimal idx may be in a different module than where
  the merge was detected. The dispatch mechanism must be able to switch to the appropriate
  `AnswersSolver` for the target module, not just dispatch to `get_idx` within the
  current solver.

**Note:** An earlier abandoned v1 prototype had to implement this dispatch. That code
may provide useful reference for the implementation.

**Recommendation:** Design and implement this mechanism before starting Phase 5. It's not
needed for Phases 1-4, but is blocking for restart-after-merge.

### Cross-Module SCC Handling

When an SCC spans modules:
- Different `AnswersSolver` instances compute different nodes
- `CalcStack` and `ThreadState` are shared across modules
- Preliminary answers must be accessible to all participating solvers

**Note:** `ThreadState` is already designed to be cross-module, so basing SCC visibility
on it should make cross-module preliminary answer access straightforward. This should
be a non-issue unless something unexpected comes up during implementation.

**Invariants to maintain:**
- SCC membership is determined by CalcId, which includes module info
- The merge operation works regardless of which solver detected the connection
- Commit writes to the appropriate module's Calculations

**Recommendation:** Add explicit test cases for cross-module cycle merging before Phase 5.

### Test Strategy for Determinism

**Current state:** Many cross-module cycle tests are commented out due to nondeterminism:
```
/*
Unlike the leaky loop tests, these have no variations that aren't potentially
subject to race conditions, so they are all commented out for CI stability.
*/
```

**Strategy:**
1. Keep these tests commented during Phases 4 and 5 (which introduce controlled nondeterminism)
2. After Phase 6 (atomic commit) is complete and we believe determinism is achieved:
   - Re-enable the commented tests
   - Add new determinism-focused tests that assert identical results regardless of entry order
   - Run stress tests with varying thread counts to validate consistency
3. These re-enabled tests serve as regression tests for the determinism guarantees

---

## Phase 1: Stack Frame Reuse (RestartFrom Elimination)

**Goal:** When a cycle is detected, reuse existing stack frames rather than
restarting computation from scratch. This is a performance optimization.

**Key insight:** When we detect a cycle at node X, that node already exists on the
Rust call stack (since we're currently computing it). We can break the cycle right
there by returning a placeholder, rather than restarting computation.

**Why this works:**
- The existing call chain already passes through the detection point
- We return `BreakHere` immediately and create the placeholder at the detection point
- This eliminates the need for `recursion_stack` - we track node state instead

**Implementation:**
- In `on_cycle_detected`: always return `BreakHere`
- The cycle is registered with the detected_at node marked as InProgress
- `pre_calculate_state` tracks Fresh/InProgress/Done for each node
- We create the placeholder immediately at the detection point and begin unwinding

**Verification gate:**
- All existing cycle tests pass
- Tracing confirms cycles break at the detection point

---

## Phase 2: Replace Stacks with "In Progress" Tracking

**Goal:** Remove `recursion_stack` and `unwind_stack`. Instead, track a per-binding
"is this binding in progress" flag within each cycle.

**The new model:**
- Each cycle tracks which bindings are currently "in progress" (on the Rust call stack
  within this cycle's computation)
- When `get_idx` is called for a binding in the cycle:
  - If marked "in progress" → return recursive placeholder (break here)
  - Otherwise → mark as "in progress", compute, mark as done
- When `get_idx` is called for something outside the cycle → normal computation

**Key behavior change:** Sub-cycles within a cycle no longer create new `Cycle` entries
on the cycle stack. If we're in cycle {A, B, C} and encounter recursion to B while B is
in progress, we just return a placeholder - no new Cycle needed.

**Why this is a stepping stone:**
- The mental model shifts from "which phase of which cycle?" to "is this binding in
  progress within the active computation group?"
- This is essentially the SCC model, just without merging yet

**Accepted tradeoffs:**
- Behavior changes for densely-connected graphs (sub-cycles handled differently)
- Possible nondeterminism from evaluation order
- Both are acceptable because this unblocks the architecture we need

**Verification gate:**
- All tests pass
- `recursion_stack`/`unwind_stack` are unused (can be removed)
- Tracing confirms sub-cycles don't create new Cycle entries

---

## Phase 3: Rename Cycle → Scc

**Goal:** Reflect that we're now tracking a set of mutually-recursive bindings, not a
cycle with winding/unwinding phases.

This is a straightforward rename, but conceptually important - it signals that the data
structure represents an SCC, preparing for merging in the next phase.

**Note:** At Phase 3 completion, "SCC" still means "single cycle, not yet merged." The
data structure semantics fully match the name only after Phase 4.

**Verification gate:** Compile-time only, no behavior change, all tests pass.

---

## Phase 3.5: Break at Detection Point Using Node State

**Goal:** Eliminate the use of `break_at` (anchor) for deciding when to break a cycle,
and instead use node state. This simplifies the model and aligns with how component-based
cycle handling will work.

**Key insight:** Instead of finding the minimal CalcId in the cycle and using that as a
fixed anchor point, we break at any InProgress node we encounter. This changes sub-cycle
behavior but simplifies the mental model and prepares for component merging.

**The new model:**
- When an SCC is created, `detected_at` is marked as InProgress; other participants start as Fresh
- When entering a participant: Fresh → InProgress (return `Participant`)
- When hitting an InProgress node: return `BreakAt` and create placeholder
- When hitting a Done node: return `NoDetectedCycle` (already computed)

**Behavioral change for sub-cycles:**
Previously, if we had a cycle A B C D E and during unwinding saw a direct read from D to B,
we would find the minimal idx and potentially pick a new anchor. Now we break at B (where
we detect the recursion) because B is already InProgress. This means sub-cycles break at
their detection point rather than finding a new minimal anchor.

**Why this is correct:**
- We're treating cycles more like components: when we see a back-edge to an InProgress
  node, we break there
- This is exactly what component merging will do - break at detection, not at a canonical
  anchor determined by CalcId ordering
- The anchor concept only matters for completion detection (which we handle via is_complete())

**Implementation changes:**
- Remove `break_at` field from `Scc` struct
- Mark `detected_at` as InProgress in `Scc::new()`, others as Fresh
- In `pre_calculate_state`, return `BreakAt` for InProgress nodes
- `on_cycle_detected` now always returns `BreakHere`
- Remove unused `Continue` variant from `CycleDetectedResult`

**Verification gate:**
- All tests pass
- Formatting and linting pass

---

## Phase 4: Preliminary Answer Storage

**Goal:** Introduce thread-local storage for answers computed during SCC resolution,
so that answers can be discarded on merge and committed atomically on completion.

**Why this comes before merging:**
- Restart after merge requires a place to store "preliminary" answers that can be discarded
- Without this, answers go directly to global `Calculation` objects (first-write-wins semantics)
- Stale answers from before a merge would block correct answers from after the merge
- This phase provides the infrastructure that makes restart correct

**Chosen approach: AnyAnswer in NodeState**

We extend `NodeState` to store preliminary answers using an enum-based type erasure pattern
that mirrors the existing `AnyIdx` pattern in the codebase. This approach was chosen over
a sparse answers table (see Appendix C) because:

1. **Consistency**: Follows the established `AnyIdx` pattern already used for 20 key types
2. **Type safety**: Compile-time type checking via enum variants, no runtime downcasting
3. **Less code**: ~195 lines vs ~500-600 for the sparse table approach
4. **Semantic clarity**: "An answer exists only while InProgress" is a natural coupling

**New data structures:**

```rust
/// Type-erased preliminary answer, mirroring AnyIdx structure.
/// Each variant holds Arc<K::Answer> for the corresponding Key type.
#[derive(Clone, Debug)]
pub enum AnyAnswer {
    Key(Arc<TypeInfo>),
    KeyExpect(Arc<EmptyAnswer>),
    KeyConsistentOverrideCheck(Arc<EmptyAnswer>),
    KeyClass(Arc<NoneIfRecursive<Class>>),
    KeyTParams(Arc<TParams>),
    KeyClassBaseType(Arc<ClassBases>),
    KeyClassField(Arc<ClassField>),
    KeyVariance(Arc<VarianceMap>),
    KeyClassSynthesizedFields(Arc<ClassSynthesizedFields>),
    KeyExport(Arc<Type>),
    KeyDecorator(Arc<Decorator>),
    KeyDecoratedFunction(Arc<Type>),
    KeyUndecoratedFunction(Arc<UndecoratedFunction>),
    KeyAnnotation(Arc<AnnotationWithTarget>),
    KeyClassMetadata(Arc<ClassMetadata>),
    KeyClassMro(Arc<ClassMro>),
    KeyAbstractClassCheck(Arc<AbstractClassMembers>),
    KeyLegacyTypeParam(Arc<LegacyTypeParameterLookup>),
    KeyYield(Arc<YieldResult>),
    KeyYieldFrom(Arc<YieldFromResult>),
}

/// Updated NodeState with optional preliminary answer in InProgress.
#[derive(Debug, Clone)]
enum NodeState {
    /// Node hasn't been processed yet as part of SCC handling.
    Fresh,
    /// Node is currently being processed. Optionally stores a preliminary
    /// answer if we've computed one while the node was InProgress.
    InProgress(Option<AnyAnswer>),
    /// Node's calculation has completed.
    Done,
}
```

**Helper trait for type recovery:**

```rust
/// Enables recovering typed answers from type-erased AnyAnswer.
pub trait RecoverAnswer: Keyed {
    fn recover_from_any(any: &AnyAnswer) -> Option<Arc<Self::Answer>>;
}

// One impl per Key type, e.g.:
impl RecoverAnswer for Key {
    fn recover_from_any(any: &AnyAnswer) -> Option<Arc<TypeInfo>> {
        match any {
            AnyAnswer::Key(ans) => Some(ans.clone()),
            _ => None,
        }
    }
}
```

**Implementation steps:**

1. Add `AnyAnswer` enum with all 20 variants
2. Update `NodeState::InProgress` to include `Option<AnyAnswer>`
3. Add `RecoverAnswer` trait + impls for all Key types
4. Add `Scc::record_preliminary_answer()` and `Scc::get_preliminary_answer()` methods
5. Modify answer lookup in `get_idx`:
   - First check: Active SCC's preliminary answers via `NodeState::InProgress(Some(...))`
   - Second check: Global `Calculation` storage
6. Modify answer recording:
   - During SCC computation: write to `NodeState::InProgress(Some(answer))`
   - This prevents "first write wins" conflicts
7. Add commit logic when SCC completes:
   - Copy all preliminary answers to global `Calculation`
   - Copy pending errors to base_errors
   - Clear the SCC's storage

**Updated Scc struct:**

```rust
pub struct Scc {
    node_state: HashMap<CalcId, NodeState>,  // Now includes answers in InProgress
    detected_at: CalcId,
    // New: thread-local errors during SCC computation
    pending_errors: Vec<Error>,
}
```

**What we defer to later phases:**
- Atomic commit semantics for multi-threading (Phase 6)
- Spin-lock waiting for concurrent computation (Phase 6)
- Commit anchor optimization (Phase 6)
- Determinism guarantees (Phase 6)

**Verification gate:**
- All existing tests pass (behavior should be identical for non-merging cases)
- Answers are correctly isolated per-SCC
- Errors are correctly isolated per-SCC
- Commit happens exactly once when outermost SCC completes

---

## Phase 5: SCC Merging

**Goal:** When a newly-discovered "cycle" connects to an existing SCC on the stack,
merge them into a single larger SCC.

**Relationship to Phases 1-4:**
For single-cycle detection (Phases 1-3.5), we break at the detection point and use node
state to determine when to return placeholders. Phase 4 added preliminary answer storage,
so answers are isolated per-SCC and can be discarded on merge.

Once merging occurs, the situation is more complex:
- Existing stack frames were computed with incomplete information about the true SCC
  membership - they didn't know about nodes from the merged-in cycle(s)
- Preliminary answers from superseded frames may be based on wrong assumptions
- We must restart fresh computation to ensure correctness

**Trigger:** We're computing within some SCC and we read an idx that belongs to an
*outer* SCC on the component stack (not the current one).

**Merge algorithm:**
1. Identify the target SCC (the one containing the idx we're trying to read)
2. Collect all participants from:
   - The target SCC
   - All SCCs above it on the component stack (including current)
   - CalcIds on the CalcStack between target_scc's detection point and current position
     that aren't part of any SCC (these are "free-floating nodes")
3. Create a new merged SCC with all these participants
4. **Important:** All participants are marked as belonging to this SCC, so subsequent
   hits during the fresh computation return placeholders rather than triggering new
   cycle detection (prevents infinite merge loops)
5. Mark all the original SCCs as "dead"/superseded
6. Pop the dead SCCs from the component stack
7. Push the merged SCC
8. Restart computation from a canonical entry point (e.g., the target SCC's detected_at,
   or the minimal idx if determinism is required)
9. Superseded frames detect they're dead and fetch authoritative answers

**Note on restart points:** The choice of restart point affects determinism. Using the
target SCC's detected_at is simpler but may produce different results depending on
entry order. Using minimal idx ensures deterministic results but requires more machinery.
This decision can be deferred until Phase 6 (atomic commit) when we tackle
determinism systematically.

**Skip-restart optimization:** When the minimal idx is already the detected_at of the
outermost SCC, we can skip restart entirely (see Appendix B). This is a performance
optimization that can be implemented as part of Phase 5 or as a follow-up, depending on
complexity. The correctness of Phase 5 doesn't depend on it.

**Superseded frame answer lookup:**
When a superseded frame completes, it must fetch the authoritative answer:
```rust
fn fetch_authoritative_answer(&self, idx: Idx<K>) -> Arc<K::Answer> {
    // First check global storage
    if let Some(answer) = self.get_calculation(idx).get() {
        return answer;
    }

    // Not in global yet - check the currently-active SCC's preliminary answers
    // (The merged SCC may still be computing)
    if let Some(scc) = self.scc_stack.current() {
        if let Some(answer) = scc.preliminary_answers.get(&CalcId::from(idx)) {
            return answer.clone();
        }
    }

    // If we get here, there's a bug
    panic!("Superseded frame could not find authoritative answer");
}
```

**What we accept at this stage:**
- Nondeterminism from evaluation order (determinism comes in Phase 6)
- We're getting the merge algorithm working with correct restart semantics

**Benefits of Phase 4 infrastructure:**
- Preliminary answers can be discarded when SCCs are marked superseded
- Merged SCC starts with empty preliminary_answers
- No "first write wins" conflicts with stale answers

**Verification gate:**
- Interlocking cycle tests pass (need to add these)
- Entry-point independence: same result regardless of which node we enter from
- Add telemetry for merge frequency and SCC sizes

---

## Phase 6: Thread-Local Isolation and Atomic Commit

**Goal:** Achieve determinism by isolating SCC computation to thread-local storage,
with atomic commit when the SCC completes.

**Terminology note:** In Phase 6, "minimal idx" refers to the **commit anchor** - the
deterministic CalcId used for thread synchronization. This is separate from the
**cycle-breaking point** (detection point) introduced in Phase 3.5. The commit anchor
is the minimum CalcId in the SCC, used for atomic commit semantics.

**Fresh state on merge/restart:**
- When we merge SCCs and restart from the detection point, reset all "in progress" markers
- All preliminary answers and pending errors from superseded SCCs are DISCARDED
- The merged SCC starts with empty preliminary_answers and pending_errors

**Thread-local preliminary answers:**
- All answers within an active SCC go to thread-local preliminary storage
- NOT written to global Calculations until SCC is complete

**Visibility rules (critical for determinism):**
- Preliminary answers are ONLY visible while the SCC is "active"
- "Active" means any node in the SCC is on the Rust call stack
- Specifically: if SCC={A,B,C} and we're computing A which calls external X which
  calls back to B, the SCC is still active (A is still on the stack) and B can see
  preliminary answers
- The SCC becomes inactive only when the commit anchor's computation completes (commits)
  or when we detect a merge and mark it as superseded
- Merged SCCs cannot see partial results from dead SCCs - this is ensured by
  discarding preliminary answers on merge

**What gets stored in preliminary answers:**
- Recursive placeholder when we hit an "in progress" binding
- Actual result for each completed binding within the SCC

**SCC completion and commit:**
- SCC is complete when computation of the commit anchor finishes
- At completion: copy all preliminary answers → global Calculations,
  preliminary errors → base_errors

**Commit atomicity:** Both answers and errors follow the same atomic commit semantics:
- If the commit anchor write succeeds (we won), commit all answers AND all errors
- If the commit anchor write fails (another thread won), discard all answers AND all errors
- This ensures error messages always correspond to the winning thread's computation

**Multi-thread synchronization:**
- Write to the commit anchor's Calculation FIRST
- If write succeeds → we won, proceed with committing everything else
- If write fails (another thread already wrote) → discard ALL our work (answers + errors),
  use existing answers

**Spin lock semantics:**
If we detected the SCC at a non-anchor node, another thread might be mid-commit:
```rust
fn wait_for_commit(&self, commit_anchor: CalcId) -> CommitResult {
    const MAX_SPINS: u32 = 1000;
    const SPIN_YIELD_THRESHOLD: u32 = 100;
    const SLEEP_THRESHOLD: u32 = 500;
    const SLEEP_DURATION: Duration = Duration::from_micros(100);

    for i in 0..MAX_SPINS {
        match self.get_calculation(commit_anchor).state() {
            CalculationState::Calculated(answer) => return CommitResult::UseExisting(answer),
            CalculationState::Calculating => {
                // Another thread is working on it
                if i > SLEEP_THRESHOLD {
                    std::thread::sleep(SLEEP_DURATION);
                } else if i > SPIN_YIELD_THRESHOLD {
                    std::thread::yield_now();
                }
            }
            CalculationState::NotCalculated => {
                // No one has started - we should compute
                return CommitResult::ShouldCompute;
            }
        }
    }

    // Timeout - recompute ourselves (self-healing)
    CommitResult::ShouldCompute
}
```

**Spin lock fairness:** Under high contention, multiple threads may spin simultaneously,
potentially causing redundant recomputation when timeouts occur. The short sleep after
`SLEEP_THRESHOLD` partially mitigates this by reducing CPU contention and giving the
committing thread more opportunity to complete. More sophisticated coordination (e.g.,
compare-and-swap based queuing) is deferred unless telemetry shows it's needed.

**Partial commit handling:**
If a thread panics mid-commit (after writing commit anchor but before other answers):
- Other threads detect "already committed" and try to use existing answers
- Missing answers trigger recomputation on next access (self-healing)
- This is acceptable: panics are rare, and the system recovers

**Merge-during-commit window:**
Once an SCC begins commit (writes commit anchor), it cannot be merged. Other threads
discovering connections must wait for the commit to complete before proceeding.

**Determinism invariants:**
- Use ordered collections (BTreeMap, sorted Vec) for any iteration that affects
  computation order. HashMap iteration order is non-deterministic.
- Thread-local SCC computation must not depend on thread-specific values (thread ID,
  allocation addresses, timing information).
- All threads computing the same SCC will produce identical results, so it doesn't
  matter which one "wins."

**Determinism guarantee:** Same code → same SCC → same computation order → same types
and errors. Only one thread's computation is kept; others discard their work.

**Verification gate:**
- Run test suite with different thread counts
- Results are identical regardless of thread scheduling
- Property-based tests across thread configurations

---

## Phase 7: Fixpoint Iteration

**Goal:** Instead of breaking recursion with placeholders that degrade to `Any`, iterate
until types converge.

**High-level approach:**
- First iteration: use `Any` (or similar) when hitting recursion
- Subsequent iterations: use prior iteration's answer instead of placeholder
- Check for convergence (types unchanged between iterations)
- Stop when converged or iteration limit reached (default: 3)

**Entry-point independence with iteration:**
After the initial placeholder phase, iteration order within an SCC is canonicalized
by CalcId regardless of entry point. This ensures determinism even with fixpoint iteration.

**Benefits:**
- Higher-quality types at cycle break points
- Fewer confusing error messages from `Any` propagation

**Configuration:** Consider making iteration limit configurable for users who prefer
speed over quality.

**Verification gate:**
- Type quality metrics improved (fewer `Any` at cycle break points)
- Cycles that need >1 iteration produce better types than before
- Measure iteration counts in practice (expect most converge in 1-2)

---

## Phase 8: Simplify Placeholders

**Goal:** With fixpoint iteration working, remove `Variable::Recursive` complexity.

**High-level approach:**
- `Variable::Recursive` exists because we only do one pass
- With multi-iteration fixpoint, we can just use `Any` on first iteration and refine
- Remove `Var` tracking, `force_var`, and related solver complexity

**Benefits:**
- Simpler code
- Fewer special cases
- Cleaner error messages

**Verification gate:**
- Before/after comparison of all cycle-involving code
- No regression in type quality
- Code is measurably simpler (fewer lines, fewer concepts)

---

## Future Optimization: Stack Unwinding

**This is optional** and should only be pursued if telemetry shows wasted stack frames
are a significant problem.

**Current approach (without unwinding):**
- When we merge SCCs and restart, superseded frames remain on the Rust call stack
- They complete normally but detect they're superseded and fetch authoritative answers
- This wastes work proportional to O(restarts × SCC_size) = O(N²) worst case
- Peak stack depth is O(D + N) where D = initial depth, N = SCC size

**Stack unwinding optimization:**
- Change `get_idx` return type to `Result<T, CycleUnwind>`
- Add `?` propagation to ~119 call sites
- When merging, unwind the stack to the merge point instead of letting frames complete
- Eliminates wasted work, reduces peak stack depth to O(D)

**Decision criteria:**
- Measure actual stack usage in production
- Count how often wasted frames occur
- Weigh engineering cost (~30-40 files affected) vs. benefit

**Telemetry to add (from Phase 4 onward):**
- Distribution of SCC sizes
- Restart frequency
- Time spent in superseded frame execution
- Peak stack depths during cycle resolution

**Recommendation:** Defer indefinitely unless data shows it's necessary. The algorithm
semantics are identical with or without unwinding - it's purely an optimization.

---

## Rollback Strategy

Each phase should have a rollback plan:

| Phase | Rollback Approach |
|-------|-------------------|
| 1 | Simple revert, no behavior change to external users |
| 2 | Revert, restore stack-based tracking |
| 3 | Simple rename revert |
| 3.5 | Restore break_at field and Continue variant |
| 4 | Feature flag to disable preliminary storage, write directly to global |
| 5 | Feature flag to disable merging, fall back to nested independent cycles |
| 6 | Feature flag to use global storage directly instead of thread-local |
| 7 | Configurable iteration limit, set to 1 for old behavior |
| 8 | Keep Variable::Recursive code paths behind flag |

**Recommendation:** Implement Phases 4, 5, and 6 together behind a single feature flag,
as merging without atomic commit produces non-deterministic results.

---

## Summary

| Phase | Description | Key Change |
|-------|-------------|------------|
| (prereq) | CalcId dispatch | Infrastructure for type-erased dispatch |
| (prereq) | Cross-module testing | Verify SCC handling across modules |
| 1 | Stack frame reuse | Reuse frames for single cycles, eliminate RestartFrom |
| 2 | In-progress tracking | Remove recursion_stack/unwind_stack |
| 3 | Rename Cycle → Scc | Conceptual shift |
| 3.5 | Break at detection point | Use node state, break at InProgress nodes |
| 4 | Preliminary answer storage | Thread-local answers that can be discarded on merge |
| 5 | SCC merging | Merge interlocking cycles |
| 6 | Thread-local isolation | Determinism via isolation + atomic commit |
| 7 | Fixpoint iteration | Better types through convergence |
| 8 | Simplify placeholders | Remove Variable::Recursive |
| (opt) | Stack unwinding | Performance optimization if needed |

The key insight driving this plan: transform the cycle machinery into SCC machinery
*before* attempting merging, rather than trying to bolt merging onto cycle-centric code.

---

## Appendix A: Explicit Non-Goals

The following are explicitly out of scope for this plan:
- **Incremental SCC updates**: Cache invalidation when code changes is not addressed
- **Parallel computation within an SCC**: All SCC nodes are computed sequentially
- **Alternative cycle-breaking strategies**: We break at detection point (InProgress nodes)
- **Formal verification**: Entry-point independence is a conjecture, validated by testing

---

## Appendix B: Why Restart is Necessary After Merge

This appendix provides a concrete example showing why we must restart computation after
merging SCCs, and why naive merging (without resetting node states) produces nondeterminism.

### Setup

```
Nodes with CalcId ordering:
  A = idx 1
  B = idx 2
  C = idx 3
  D = idx 4

Dependencies:
  A depends on B
  B depends on A, C    (A↔B forms one cycle, B→C crosses to other cycle)
  C depends on D
  D depends on C, A    (C↔D forms another cycle, D→A crosses back)

Cycle structure:
  CycleAB: A ↔ B  (contains minimal idx = 1)
  CycleCD: C ↔ D  (contains minimal idx = 3)
  Cross-edges: B → C and D → A (interlocking)

Merged SCC minimal idx = A (idx 1), which is in CycleAB
```

### Path 1: Enter at A

```
1. Compute A (idx 1)
2. A needs B → Compute B (idx 2)
3. B needs A → A on stack! Cycle detected
   - SCC1 = {A, B}, detected_at = A
   - A: InProgress, B: Fresh → InProgress
   - Return placeholder for A
4. Continue B's computation
5. B needs C → Compute C (idx 3)
6. C needs D → Compute D (idx 4)
7. D needs C → C on stack! Cycle detected
   - SCC2 = {C, D}, detected_at = C
   - C: InProgress, D: Fresh → InProgress
   - Return placeholder for C
8. Continue D's computation
9. D needs A → A is in SCC1 (outer SCC)!
   - MERGE triggered
   - Merged SCC = {A, B, C, D}
   - Restart from detected_at of outer SCC = A
```

At merge: All nodes InProgress. Restart from **A**.
With naive merge (no reset): Break immediately at **A** (InProgress).

### Path 2: Enter at C

```
1. Compute C (idx 3)
2. C needs D → Compute D (idx 4)
3. D needs C → C on stack! Cycle detected
   - SCC1 = {C, D}, detected_at = C
   - C: InProgress, D: Fresh → InProgress
   - Return placeholder for C
4. Continue D's computation
5. D needs A → Compute A (idx 1)
6. A needs B → Compute B (idx 2)
7. B needs A → A on stack! Cycle detected
   - SCC2 = {A, B}, detected_at = A
   - A: InProgress, B: Fresh → InProgress
   - Return placeholder for A
8. Continue B's computation
9. B needs C → C is in SCC1 (outer SCC)!
   - MERGE triggered
   - Merged SCC = {A, B, C, D}
   - Restart from detected_at of outer SCC = C
```

At merge: All nodes InProgress. Restart from **C**.
With naive merge (no reset): Break immediately at **C** (InProgress).

### The Nondeterminism

| Entry Point | Outer SCC | Restart Point | Break Point |
|-------------|-----------|---------------|-------------|
| A           | {A, B}    | A             | A (idx 1)   |
| C           | {C, D}    | C             | C (idx 3)   |

Same code structure → different break points → different placeholder locations →
potentially different inferred types.

### Why Restart is Necessary

Without restart, we'd continue with partial computations that assumed smaller SCCs.
The outer SCC's computation was based on the assumption that only {A,B} or {C,D}
were cyclic. After merging, we know all four nodes are in one SCC, so preliminary
answers from the partial view are potentially wrong.

### Why "Start From Scratch" Gives Determinism

If on merge we:
1. Reset all nodes to Fresh
2. Mark only the minimal idx (A) as InProgress
3. Restart from A

Then both paths restart from A, traverse the same order, break at A → deterministic.

This is why Phase 5 (thread-local storage with atomic commit) requires resetting
node states on merge, not just combining them.

### Optimization: Skip Restart When Minimal Idx is Already Active

There's an important special case where we can skip the restart: when the minimal idx
of the merged SCC is already **in or above** the outermost component on the stack.

**Why this works:**
- The minimal idx is already on the CalcStack (it's where we entered the outer SCC)
- The current control flow, starting from that minimal idx, is already the *same* as
  if we had started from scratch with that node as the entry point
- All intermediate results computed so far are the same as what we'd compute on restart
- No work is wasted, and we get the same deterministic result

**When this applies:**
- The minimal idx of the merged SCC equals the `detected_at` of the outermost SCC
- Or more generally: the minimal idx appears at or above the outermost SCC's position
  on the CalcStack

**Why this matters for performance:**
For cycles that occur within a single module, it's common for the minimal idx to be
the earliest node anyway. This is an artifact of how we typically process modules
top-down, and CalcId ordering is *mostly* top-down (with some exceptions for out-of-order
definitions). In practice, many merges will hit this fast path.

**Implementation note:**
When detecting a merge, check if `merged_scc.minimal_idx() == outer_scc.detected_at`.
If so, we can continue the current computation without restarting. The node states
are already correct because we entered through the minimal idx.

**Implementation timing:**
This optimization is not required for correctness - Phase 5 works correctly with
always-restart. Consider implementing it as a follow-up once the basic merge-and-restart
logic is working and tested. The optimization adds complexity to the merge code path,
and it's easier to debug issues when there's only one code path (always restart).

---

## Appendix C: Alternative Considered - Sparse Answers Table

This appendix documents an alternative approach to Phase 4 (Preliminary Answer Storage)
that was considered but not selected. The approach is preserved here for reference in
case requirements change or we need to revisit the decision.

### Overview

Instead of storing preliminary answers in `NodeState::InProgress`, use a separate
`TypeErasedPreliminaryAnswers` structure with runtime type erasure via `Arc<dyn Any>`.

### Data Structures

```rust
/// Type-erased key for preliminary answer lookup.
struct TypeErasedKey {
    module_name: ModuleName,
    key_type: TypeId,
    index: usize,
}

/// Sparse storage for preliminary answers during SCC computation.
pub struct TypeErasedPreliminaryAnswers {
    answers: RefCell<SmallMap<TypeErasedKey, Arc<dyn Any + Send + Sync>>>,
}

impl TypeErasedPreliminaryAnswers {
    pub fn new() -> Self {
        Self { answers: RefCell::new(SmallMap::new()) }
    }

    pub fn get<K: Keyed>(&self, key: &TypeErasedKey) -> Option<Arc<K::Answer>> {
        let erased = self.answers.borrow().get(key)?.clone();
        Arc::downcast::<K::Answer>(erased).ok()
    }

    pub fn insert<K: Keyed>(&self, key: TypeErasedKey, answer: Arc<K::Answer>) {
        self.answers.borrow_mut().insert(key, answer as Arc<dyn Any + Send + Sync>);
    }

    pub fn clear(&self) {
        self.answers.borrow_mut().clear();
    }
}
```

### Updated Scc Struct

```rust
pub struct Scc {
    node_state: HashMap<CalcId, NodeState>,  // Fresh/InProgress/Done only
    detected_at: CalcId,
    preliminary_answers: TypeErasedPreliminaryAnswers,  // Separate storage
    pending_errors: Vec<Error>,
}
```

### Trade-off Comparison

| Aspect | Sparse Table | NodeState-based (chosen) |
|--------|--------------|--------------------------|
| **Type safety** | Runtime (downcast can fail) | Compile-time (enum variants) |
| **LOC** | ~500-600 | ~195 |
| **Separation of concerns** | Better (separate HashMap) | Worse (coupled in enum) |
| **Merge handling** | Trivial (new empty table) | Update all HashMap entries |
| **Existing pattern** | Standard Rust `dyn Any` | Matches codebase's `AnyIdx` |
| **Future extensibility** | Easier to modify | More rigid |

### Advantages of Sparse Table

1. **Clean separation**: Node state logic (Fresh/InProgress/Done) remains separate from
   answer storage. The two concerns are decoupled.

2. **Simple merge semantics**: On SCC merge, clearing all preliminary answers is trivial:
   `new_scc.preliminary_answers = TypeErasedPreliminaryAnswers::new()`. No need to iterate
   through all NodeState entries.

3. **Sparse storage**: Only stores answers that were actually computed. The SmallMap is
   optimized for small collections (typical SCC sizes are 5-20 nodes).

4. **Proven pattern**: Uses standard Rust `Any + downcast` idiom that's well-documented
   and widely understood.

### Disadvantages of Sparse Table

1. **Runtime type checking**: Each lookup requires a `Arc::downcast()` call that can
   theoretically fail (though in correct code it never should).

2. **More code**: ~500-600 LOC vs ~195 for the NodeState-based approach.

3. **Key construction complexity**: Must construct `TypeErasedKey` on every lookup,
   requiring `ModuleInfo` context and `TypeId`.

4. **Requires `Send + Sync` bounds**: Would need to add these bounds to `Keyed::Answer`
   trait, which is a broader change to `binding.rs`.

5. **Inconsistent with codebase**: The codebase already uses enum-based type erasure
   (`AnyIdx`) rather than `dyn Any` for similar purposes.

### Why NodeState-based Was Chosen

The primary reasons for choosing the NodeState-based approach:

1. **Consistency with existing patterns**: The codebase's `AnyIdx` enum already handles
   type erasure for 20 key types using the same pattern. Following this pattern reduces
   cognitive load for developers familiar with the codebase.

2. **Compile-time type safety**: No risk of runtime downcast failures. The compiler
   validates that answer types match key types.

3. **Less code**: The implementation is ~60% smaller, reducing maintenance burden.

4. **Semantic coupling is actually appropriate**: A preliminary answer only exists while
   a node is `InProgress`, so storing them together accurately represents the invariant.

### When to Reconsider

Consider revisiting this decision if:

- We need to decouple node state from answer storage for other reasons
- Runtime answer manipulation (e.g., lazy evaluation, caching) becomes important
- The 20 `RecoverAnswer` implementations become a maintenance burden
- We add many more Key types and the enum becomes unwieldy

