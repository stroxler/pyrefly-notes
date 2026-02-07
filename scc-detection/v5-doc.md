# SCC Handling Improvements: V5 Implementation Plan

## Executive Summary

This document outlines the path forward for Pyrefly's SCC (Strongly Connected Component) handling improvements. Building on the recently completed merging refactor (`merge_sccs` and `on_scc_detected`), we now have a solid foundation for addressing the remaining correctness and isolation issues.

**Key Goals:**
1. Prevent `Var` leakage beyond SCC boundaries
2. Achieve deterministic type checking for a given SCC detection order (commit order is deterministic; detection order depends on thread scheduling)
3. Enable future phases (restart-after-merge, fixpoint iteration)

**Implementation Order:**
1. Debug macro infrastructure (Phase 0)
2. Preliminary answer storage (Phase 1)
3. Top-SCC-only invariant enforcement (Phase 2)
4. Var leakage prevention (Phase 3)
5. Deferred: Restart after merge, fixpoint iteration, simplify placeholders (Phases 4-6)

---

## Terminology

- **CalcId**: A `(Bindings, AnyIdx)` pair that uniquely identifies a binding/calculation across modules. `Bindings` identifies the module, `AnyIdx` identifies the specific binding within that module.

- **Break point**: The first node where a cycle was detected. When we encounter a node already `InProgress`, that node becomes the break point. Computation continues past the break point using a placeholder, and the answer is finalized when the break point completes.

- **Calculation storage**: The `AnswerEntry<K>` in `Answers` where computed answers are stored. This is the global, persistent storage that other threads/modules can read.

- **Variables map**: The solver's internal `Mutex<Variables>` that tracks `Var` state (unbound, recursive, answered). This is solver-local state, separate from `Calculation` storage.

- **Early finalization**: Calling `force_var` during SCC computation (in `finalize_recursive_answer`) to resolve Vars before the SCC commits. Contrasted with "batch commit time finalization" which would defer forcing to commit.

- **Batch commit**: Writing all preliminary answers from an SCC to `Calculation` storage at once when the SCC completes, rather than writing each answer immediately.

- **Participant**: A node that is part of the current SCC. Has `NodeState` of `Fresh`, `InProgress`, or `Done`.

- **NodeState**: Per-node state within an SCC: `Fresh` (not yet visited), `InProgress` (currently being computed), `Done` (computation complete, answer in preliminary storage).

- **SccState**: The result of `pre_calculate_state`, indicating what state we're in: `NotInScc`, `Participant`, `RevisitingDone`, `RevisitingPreviousScc`, `RevisitingTargetState`.

- **Top SCC**: The SCC at the top of the `Sccs` stack. Only the top SCC is actively being computed; lower SCCs are waiting for the top to complete.

---

## Concurrency Model

### Per-Thread SCC State

Each thread has its own `ThreadState` containing an `Sccs` stack (a `RefCell<Vec<Scc>>`). This means:

- **SCC stacks are per-thread**: Thread A's `Sccs` stack is independent of Thread B's stack
- **Preliminary results are per-thread**: Stored in the thread's top SCC, invisible to other threads
- **Solver state is shared**: The `Solver` and its `Variables` map are shared across threads

### Cross-Thread Coordination

When multiple threads encounter the same cycle:

1. **SCC Detection**: Each thread independently detects cycles based on its own traversal order. Detection order may differ between threads.

2. **Merge on Overlap**: When Thread B accesses a node that Thread A has in its SCC, Thread B detects `RevisitingPreviousScc` and merges. Both threads now have equivalent SCC membership (though stored in separate thread-local structs).

3. **Leader Election at Commit**: When an SCC completes, threads race to commit. The first thread to successfully write the minimal CalcId becomes the leader and commits everything. Other threads spin-wait for results.

4. **Global Visibility After Commit**: Once committed to `Calculation` storage (global), answers are visible to all threads.

### Key Invariant

**Preliminary results are thread-local until commit.** Cross-thread access only happens via:
- Global `Calculation` storage (after commit)
- The `LookupAnswer::get` trait method (for cross-module reads)
- The `LookupAnswer::commit_to_module` trait method (for cross-module writes)

### Error Collector Hierarchy

```
base_errors (per-module, persistent, shared across threads)
    ↑ extend (leader only, on SCC commit)
pending_errors (per-SCC, thread-local, transient)
    ↑ collect (during calculation within SCC)
local_errors (per-calculation, thread-local, transient)
```

- **local_errors**: Created per `calculate_and_record_answer` call, collected into `pending_errors`
- **pending_errors**: Accumulated in the SCC, committed to `base_errors` only by the leader
- **base_errors**: Module-level errors, visible to all threads after commit

---

## Current State Assessment

### What We Have (Post-Merging Refactor)

The `Scc` struct in `pyrefly/lib/alt/answers_solver.rs`:

```rust
pub struct Scc {
    break_at: BTreeSet<CalcId>,      // Where to break cycles (preserved during merge)
    node_state: HashMap<CalcId, NodeState>,  // Fresh/InProgress/Done per participant
    detected_at: CalcId,              // Stable identifier for the SCC
    min_stack_depth: usize,           // Fast filter for overlap detection
}
```

Key capabilities now working:
- **Correct merge semantics**: `merge_sccs` and `Scc::merge_many` correctly union SCCs
- **RevisitingPreviousScc handling**: Proper detection and merge of cross-SCC reads
- **Overlap detection**: `check_overlap` efficiently identifies overlapping cycles
- **LIFO SCC stack**: Clean separation of nested SCCs

### What Is Missing

1. **No `preliminary_results` field**: Answers stored directly in `Calculation`, not per-SCC
2. **No Var ownership tracking**: No mechanism to track which SCC created which `Var`
3. **No error isolation**: Errors flow directly to `base_errors` during SCC solving
4. **No batch commit**: Answers visible globally before SCC completes

### Critical Vulnerability: Var Leakage

When `RevisitingDone` returns an answer:
```rust
SccState::RevisitingDone => {
    match calculation.propose_calculation() {
        ProposalResult::Calculated(v) => v,  // May contain unresolved Vars!
        ...
    }
}
```

If the preliminary answer contains a `Var` created within the SCC, and that answer is returned before the SCC commits, the `Var` leaks outside its intended scope.

---


## Phase 1: Preliminary Answer Storage

**Goal**: Store answers per-SCC until completion, then batch commit.

### Data Structure Design

Add to `Scc`:

```rust
pub struct Scc {
    // ... existing fields ...

    /// Preliminary answers stored during SCC solving.
    /// Type-erased via Arc<dyn Any + Send + Sync> to handle different Key types.
    preliminary_results: HashMap<CalcId, PreliminaryResult>,

    /// Errors collected during SCC solving.
    /// Only committed to base_errors when the SCC successfully completes.
    pending_errors: ErrorCollector,
}

/// A preliminary result stored during SCC computation.
pub struct PreliminaryResult {
    /// Type-erased answer: Box<Arc<K::Answer>> stored as Box<dyn Any>
    /// The double-boxing is necessary because Arc<T> as Arc<dyn Any> loses type info
    answer: Box<dyn Any + Send + Sync>,
    /// Errors collected during computation of this answer
    errors: Vec<Error>,
}
// Note: `has_recursive_var: bool` deferred to Phase 5 (fixpoint iteration)
```

### Type Erasure Strategy

The challenge: `AnswerEntry<K>` is generic over `K: Keyed`, but `Scc` must store answers for multiple key types.

**Why double-boxing?** Storing `Arc<K::Answer> as Arc<dyn Any>` loses the original type - you can't downcast `Arc<dyn Any>` back to `Arc<K::Answer>`. Instead, we box the Arc: `Box::new(answer) as Box<dyn Any>`, then downcast back to `Box<Arc<K::Answer>>`.

Solution using `dispatch_anyidx!` macro:

```rust
/// Macro to dispatch on AnyIdx variants, avoiding 20-line match statements.
macro_rules! dispatch_anyidx {
    ($any_idx:expr, $self:expr, $method:ident $(, $args:expr)*) => {
        match $any_idx {
            AnyIdx::Key(idx) => $self.$method::<Key>(*idx $(, $args)*),
            AnyIdx::KeyExport(idx) => $self.$method::<KeyExport>(*idx $(, $args)*),
            AnyIdx::KeyClass(idx) => $self.$method::<KeyClass>(*idx $(, $args)*),
            // ... all 20 variants
        }
    };
}
```

### Store Preliminary Answer

```rust
fn store_preliminary<K: Keyed>(
    &self,
    calc_id: CalcId,
    answer: Arc<K::Answer>,
    errors: Vec<Error>,
) where
    K::Answer: Send + Sync + 'static,
{
    let scc = self.sccs().top_mut();
    scc.preliminary_results.insert(calc_id, PreliminaryResult {
        // Box the Arc to preserve type info through Any
        answer: Box::new(answer),
        errors,
    });
}
```

### Retrieve Preliminary Answer

```rust
fn get_preliminary<K: Keyed>(&self, calc_id: &CalcId) -> Option<Arc<K::Answer>>
where
    K::Answer: Send + Sync + 'static,
{
    let scc = self.sccs().top();
    scc.preliminary_results.get(calc_id)
        .and_then(|pr| pr.answer.downcast_ref::<Arc<K::Answer>>())
        .cloned()
}
```

### Commit Trigger Flow

The commit is triggered from `calculate_and_record_answer` when the current node completes and the SCC is done:

```rust
fn calculate_and_record_answer<K: Keyed>(&self, idx: Idx<K>, ...) -> Arc<K::Answer>
where
    K::Answer: Send + Sync + 'static,
{
    // ... compute answer ...

    // Store in preliminary results (Phase 1a change)
    self.store_preliminary::<K>(calc_id, answer.clone(), local_errors);

    // Mark node as Done
    self.sccs().mark_done(&calc_id);

    // Check if SCC is complete (all participants Done)
    if self.sccs().is_complete() {
        // Trigger batch commit (Phase 1b)
        let scc = self.sccs().pop();
        // commit_scc_typed handles the downcast from Box<dyn Any> to Arc<K::Answer>
        return self.commit_scc_typed::<K>(scc, &calc_id);
    }

    answer
}

/// Typed wrapper around commit_scc that handles downcast.
fn commit_scc_typed<K: Keyed>(&self, scc: Scc, entry_calc_id: &CalcId) -> Arc<K::Answer>
where
    K::Answer: Send + Sync + 'static,
{
    let boxed_answer = self.commit_scc(scc, entry_calc_id);
    // Downcast from Box<dyn Any> to Arc<K::Answer>
    // The box contains Arc<K::Answer>, so we downcast to that type
    *boxed_answer.downcast::<Arc<K::Answer>>()
        .expect("type mismatch: entry_calc_id type doesn't match K")
}
```

**Key Points:**
- `is_complete()` checks if all nodes in `node_state` have `NodeState::Done`
- `pop()` removes the SCC from the stack and returns ownership
- The thread that completes the last node triggers the commit race
- Other threads participating in this SCC will hit `RevisitingDone` and wait
- `commit_scc_typed` handles the downcast from type-erased storage back to typed answer

**Note on method names:** Methods like `sccs()`, `top()`, `mark_done()`, `is_complete()`, `pop()` are proposed helpers to be implemented in Phase 1a. They wrap the underlying `RefCell<Vec<Scc>>` with ergonomic accessors.

### Batch Commit Protocol

When SCC completes (`is_complete()` returns true):

1. **Leader Election via First-Write-Wins**: Sort CalcIds, attempt to commit the minimal idx first. If the write succeeds (first-write-wins), this thread becomes the leader and commits everything else. If it fails, another thread is the leader.

2. **Collect Answers**: Gather all `preliminary_results` from the SCC

3. **Commit in CalcId Order**: For determinism, iterate in sorted order

4. **Handle Concurrent Commit**: If we're not the leader but need the result from our entry point (which may not be the minimal idx), spin-wait until the leader commits it.

5. **Error Transfer**: Move `pending_errors` to `base_errors` only if we were the leader

6. **Cleanup**: Pop the completed SCC from the stack

```rust
/// Commit SCC and return the type-erased answer for our entry point.
/// The caller (commit_scc_typed) will downcast back to the correct type.
fn commit_scc(&self, scc: Scc, entry_calc_id: &CalcId) -> Box<dyn Any + Send + Sync> {
    // Sort for determinism - minimal idx is the leader election point
    let mut calc_ids: Vec<_> = scc.preliminary_results.keys().cloned().collect();
    calc_ids.sort();

    let min_calc_id = &calc_ids[0];
    let min_result = scc.preliminary_results.get(min_calc_id).unwrap();

    // Try to become leader by committing the minimal idx
    let is_leader = dispatch_anyidx!(
        &min_calc_id.1, self, try_commit_first, min_calc_id, min_result
    );

    if is_leader {
        // We're the leader - commit everything else
        for calc_id in &calc_ids[1..] {
            let result = scc.preliminary_results.get(calc_id).unwrap();
            dispatch_anyidx!(&calc_id.1, self, commit_single_result, calc_id, result);
        }
        self.base_errors().extend(scc.pending_errors);

        // Return our entry point's answer from preliminary results (we just committed it)
        return scc.preliminary_results.remove(entry_calc_id)
            .expect("entry_calc_id not in SCC")
            .answer;
    }

    // Not the leader - wait for committed answer, then return type-erased
    self.wait_for_answer(entry_calc_id)
}

/// Spin-wait for an answer to become available in committed storage.
/// Returns the answer as Box<dyn Any> for type erasure.
fn wait_for_answer(&self, calc_id: &CalcId) -> Box<dyn Any + Send + Sync> {
    const MAX_ATTEMPTS: usize = 10_000;  // ~1 second with 100μs sleeps

    // Try a few yields first (cheap)
    for _ in 0..10 {
        if let Some(answer) = self.try_get_committed(calc_id) {
            return answer;
        }
        std::thread::yield_now();
    }

    // Then add short sleeps (avoid starving the committing thread)
    for attempt in 0..MAX_ATTEMPTS {
        if let Some(answer) = self.try_get_committed(calc_id) {
            return answer;
        }
        std::thread::sleep(std::time::Duration::from_micros(100));

        // Log warning after extended wait (indicates potential issue)
        if attempt == 1000 {
            eprintln!("Warning: extended wait for SCC commit of {:?}", calc_id);
        }
    }

    // Timeout - this indicates a bug (leader panicked or deadlock)
    panic!("Timeout waiting for SCC commit of {:?}", calc_id);
}

/// Try to get a committed answer from Calculation storage.
/// Returns None if not yet committed, Some(boxed answer) if available.
fn try_get_committed(&self, calc_id: &CalcId) -> Option<Box<dyn Any + Send + Sync>> {
    // Dispatch on AnyIdx to get typed answer, then box for type erasure
    dispatch_anyidx!(&calc_id.1, self, try_get_committed_typed, calc_id)
}

fn try_get_committed_typed<K: Keyed>(&self, calc_id: &CalcId) -> Option<Box<dyn Any + Send + Sync>>
where
    K::Answer: Send + Sync + 'static,
{
    let calculation = self.get_calculation::<K>(calc_id);
    calculation.get().map(|answer| Box::new(answer) as Box<dyn Any + Send + Sync>)
}

/// Attempt to become the leader by writing the first answer.
/// Returns true if we successfully wrote (we're the leader), false otherwise.
fn try_commit_first<K: Keyed>(&self, calc_id: &CalcId, result: &PreliminaryResult) -> bool
where
    K::Answer: Send + Sync + 'static,
{
    let answer = result.answer.downcast_ref::<Arc<K::Answer>>()
        .expect("type mismatch in preliminary result");

    // Get the Calculation for this CalcId
    let calculation = self.get_calculation::<K>(calc_id);

    // First-write-wins: record_value returns (answer, did_write)
    // If did_write is true, we're the first writer (leader)
    let (_answer, did_write) = calculation.record_value(answer.clone(), |var, ans| {
        // Finalize any recursive Vars in the answer
        self.solver().finalize_var_in_answer(var, ans)
    });

    did_write
}
```

### Cross-Module Commit

SCCs can span modules. When module A imports module B and module B imports module A with mutually recursive classes, the SCC contains `CalcId`s from both modules. At batch commit time, we need to write answers to both modules' `Answers` storage.

**Implementation Approach**

1. **Extend `LookupAnswer` trait** with `commit_to_module`:
   ```rust
   pub trait LookupAnswer: Sized {
       // ... existing get method ...

       /// Commit a preliminary result to a target module during SCC resolution.
       /// Returns true if commit succeeded, false if module unavailable.
       fn commit_to_module(
           &self,
           bindings: &Bindings,
           any_idx: AnyIdx,
           result: PreliminaryResult,
           thread_state: &ThreadState,
       ) -> bool {
           // Default: not supported (e.g., for single-module analysis)
           false
       }
   }
   ```

2. **Implement for `TransactionHandle`** (in `state.rs`):
   ```rust
   impl<'a> LookupAnswer for TransactionHandle<'a> {
       fn commit_to_module(
           &self,
           bindings: &Bindings,
           any_idx: AnyIdx,
           result: PreliminaryResult,
           _thread_state: &ThreadState,
       ) -> bool {
           // Look up the target module
           let module_name = bindings.module().name();
           let module_path = bindings.module().path();
           let module_data = match self.get_module(module_name, Some(module_path)) {
               FindingOrError::Finding(f) => f.finding,
               FindingOrError::Error(_) => return false,
           };

           // Acquire the module's answers and error collector
           let lock = module_data.state.read();
           let (answers, errors) = match (&lock.steps.answers, &lock.steps.load) {
               (Some(a), Some(l)) => (&a.1, &l.errors),
               _ => return false,
           };

           // Dispatch on AnyIdx to write the typed answer
           dispatch_anyidx!(&any_idx, self, commit_typed_to_module, answers, result, errors)
       }
   }
   ```

3. **Dispatch in `commit_single_result`**:
   ```rust
   fn commit_single_result(&self, calc_id: CalcId, result: PreliminaryResult) {
       let CalcId(bindings, any_idx) = calc_id;

       if bindings.module() != self.bindings().module() {
           // Cross-module: use LookupAnswer trait method
           // Return value intentionally ignored - if module is unavailable,
           // it will recompute on next access. No rollback needed.
           let _ = self.answers.commit_to_module(&bindings, any_idx, result, self.thread_state);
           return;
       }

       // Same-module: use typed optimization path (faster, avoids downcasting)
       dispatch_anyidx!(&any_idx, self, commit_typed, result)
   }
   ```

**Key Insight**: Cross-module commit is read-write access to another module's `Answers` struct, not the solver state. The `TransactionHandle` already has the infrastructure to look up modules by name/path.

**Cross-Module Var Coherence**: If a preliminary answer in module A contains a `Var` created by module A's solver, module B's solver has no knowledge of that Var. This means:
- All Vars MUST be forced (via `force_var`) before cross-module commit
- Phase 3's Var validation ensures this: any unforced Var triggers fallback forcing before commit
- Cross-module answers should never contain unresolved Vars

---

## Phase 2: Top-SCC-Only Invariant Enforcement

**Goal**: Answers are only visible within their SCC until committed.

### The Keystone Invariant

**Merge-before-read guarantees top-SCC-only visibility.**

When `pre_calculate_state` returns `RevisitingPreviousScc`, we merge before returning any answer. This ensures all participants are in the same (now top) SCC before any reads occur.

### Enforcement Points

1. **`get_idx`**: Before returning from `RevisitingDone`, verify the answer comes from the current top SCC or from committed storage.

2. **`calculate_and_record_answer`**: Store to `scc.preliminary_results` instead of directly to `Calculation`.

3. **Cross-module lookup**: Only return committed answers, never in-flight preliminary answers from another module.

### Debug Assertion

Add assertion to catch violations during development:

```rust
fn get_preliminary<K: Keyed>(&self, calc_id: &CalcId) -> Option<Arc<K::Answer>> {
    // Only the top SCC should be queried for preliminary answers
    debug_assert!(
        self.sccs().is_top_scc_participant(calc_id),
        "Attempted to read preliminary answer from non-top SCC: {}",
        calc_id
    );
    // ... lookup logic
}

impl Sccs {
    /// Check if calc_id is a participant in the top SCC.
    fn is_top_scc_participant(&self, calc_id: &CalcId) -> bool {
        self.stack.borrow().last()
            .map(|scc| scc.node_state.contains_key(calc_id))
            .unwrap_or(false)
    }
}
```

---

## Phase 3: Var Leakage Prevention

**Goal**: Ensure `Var` values created within an SCC cannot escape before commit.

### Context: Early Finalization Handles Most Cases

Because we use early finalization (calling `force_var` during `finalize_recursive_answer`), most Vars are resolved before they would be committed. The tracking and validation in this phase is a **safety net** to catch any edge cases where a Var might slip through unforced.

### The Problem

`Var` is created in these places:
- `solver.fresh_recursive()` - for cycle breaking
- `solver.fresh_loop_recursive()` - for loop phi
- `solver.fresh_quantified()` - for generic instantiation
- etc.

In the normal flow, `finalize_recursive_answer` calls `force_var` which resolves the Var. However, there may be edge cases where:
- A Var is created but the binding doesn't go through `finalize_recursive_answer`
- A Var appears in an answer via a different path (e.g., copied from another type)

The validation ensures we catch these cases before committing.

### Tracking Strategy

Add to `Scc`:

```rust
pub struct Scc {
    // ... existing fields ...

    /// Vars created within this SCC.
    /// These must be forced before answers can be committed.
    created_vars: BTreeSet<Var>,
}
```

### Registration

Registration happens in `AnswersSolver` immediately after calling `solver.fresh_*`, not inside `Solver` itself. This keeps `Solver` unaware of SCC mechanics while ensuring Vars are tracked before any use.

```rust
impl<Ans: LookupAnswer> AnswersSolver<'_, Ans> {
    /// Create a fresh recursive Var and register it with the current SCC.
    fn fresh_recursive_var(&self, binding: &Binding) -> Var {
        let var = self.solver().fresh_recursive(self.uniques(), binding);
        // Register immediately - finalize_recursive_answer will need access to this
        if let Some(scc) = self.thread_state.sccs().top_mut() {
            scc.register_var(var);
        }
        var
    }
}
```

**Important**: Registration must happen immediately after `fresh_*`, not deferred to finalization. The preliminary results storage needs to track which Vars belong to which SCC, and finalization will need to access this information.

### Validation Before Commit

Before committing each answer, validate it contains no unforced Vars:

```rust
impl Scc {
    fn validate_for_commit<T: VisitTypes>(&self, answer: &T) -> Result<(), VarLeakError> {
        let mut leaked = Vec::new();
        answer.visit_types(&mut |ty| {
            if let Type::Var(v) = ty {
                if self.created_vars.contains(v) {
                    leaked.push(*v);
                }
            }
        });
        if leaked.is_empty() {
            Ok(())
        } else {
            Err(VarLeakError { leaked })
        }
    }
}
```

### On force_var

Remove the `Var` from `created_vars` when it's forced. This happens in `AnswersSolver` (not `Solver`) to keep Solver unaware of SCC mechanics:

```rust
impl<Ans: LookupAnswer> AnswersSolver<'_, Ans> {
    /// Force a Var and unregister it from the current SCC.
    fn force_and_unregister(&self, var: Var) -> Type {
        let ty = self.solver().force_var(var);
        // Unregister after forcing - Var is now resolved
        if let Some(scc) = self.sccs().top_mut() {
            scc.created_vars.remove(&var);
        }
        ty
    }
}
```

This wrapper is called from `finalize_recursive_answer` instead of calling `solver.force_var` directly.

### Fallback Behavior

If validation fails (a `Var` would leak):
1. Force all remaining `Var`s in `created_vars` to their current best type
2. Log a debug message (indicates a bug in the solver)
3. Proceed with commit (graceful degradation)

---

## Phases 4-6: Deferred Work

These phases require the foundation from Phases 0-3 to be complete.

### Phase 4: Restart After Merge

**When**: A new cycle is detected that causes SCC merge.

**What**: Restart computation from the merged SCC's break point, rather than continuing with potentially stale intermediate state.

**Prerequisites**:
- Preliminary answer storage (Phase 1)
- Top-SCC-only invariant (Phase 2)
- Design decision: How to avoid stack overflow on deep restarts (trampoline pattern or recursion limit)

### Phase 5: Fixpoint Iteration

**When**: Self-referential types where the initial placeholder affects the final answer.

**What**: Re-solve the SCC until answers stabilize:
1. Iteration 1: Use `Any`/placeholder at cycle back-edge
2. Store preliminary answer for each participant
3. Iteration 2+: Use prior iteration's preliminary answers
4. Compare answers for convergence; limit iterations (default 3)

**Prerequisites**:
- Restart mechanism (Phase 4)
- Answer comparison for equality
- `has_recursive_var` tracking in `PreliminaryResult`

### Phase 6: Simplify Placeholders

**When**: After fixpoint stabilizes.

**What**: Replace complex recursive type representations with simpler equivalents. Potentially remove `Variable::Recursive` complexity entirely.

**Prerequisites**:
- Fixpoint iteration (Phase 5)
- Type simplification infrastructure

---

## Determinism Considerations

For fully deterministic behavior:

1. **Sort CalcIds at commit time** (required for correctness)
   - Commit in sorted CalcId order ensures deterministic commit sequence
   - Leader election uses minimal CalcId, which is deterministic

2. **HashMap→BTreeMap migration** (optional, for debugging)
   - `break_at` already uses `BTreeSet`
   - `node_state` and `preliminary_results` can remain `HashMap` since:
     - We sort CalcIds before committing
     - Iteration order during computation doesn't affect final answers
   - Consider migrating only if debugging requires predictable iteration

3. **Avoid thread-dependent ordering**: Don't use thread IDs, allocation addresses, or timing

---

# Possible Cross-cutting Work: add debug macro infrastructure for observability

An early version of this plan included adding debug macros to make observability
easier in the rest of the implementation. This may be necessary, but actually implementing
the debug macro can itself run into hurdles so it is deferred for now.

### Rationale

The existing infrastructure has the pieces but lacks a consistent macro:
- `ThreadState` has a `debug: RefCell<bool>` flag
- `AnswersSolver` has `is_debug()` and `set_debug()` methods
- The pattern from `call_graph.rs` works well

### Implementation

Add to `pyrefly/lib/alt/answers_solver.rs` (or a new `debugging.rs` module):

```rust
/// Debug print macro that compiles to nothing when debug is false.
/// Usage: debug_println!(self.is_debug(), "SCC detected: {}", scc);
macro_rules! debug_println {
    ($debug:expr, $($arg:tt)*) => {
        if $debug {
            eprintln!($($arg)*);
        }
    };
}
```

### Key Instrumentation Points

1. **`on_scc_detected`**: Log cycle detection, overlap found, merge decisions
2. **`pre_calculate_state`**: Log state transitions (NotInScc → Participant, etc.)
3. **`calculate_and_record_answer`**: Log answer computation start/complete
4. **`merge_sccs`**: Log before/after merge state
5. **`finalize_recursive_answer`**: Log Var resolution

### Zero Runtime Cost

When `debug == false`:
- No string formatting
- No function calls beyond the bool check
- Compiler optimizes out dead branches

---

---

## Testing Strategy

### Test File Locations

- **Unit tests for SCC mechanics**: `pyrefly/lib/alt/answers_solver.rs` - the `scc_tests` module starting at line ~1568
- **Integration tests for cycles**: `pyrefly/lib/test/cycles.rs` - tests for mutually recursive types
- **Full test suite**: Run `./test.py` to verify no regressions

### Unit Tests (extend `scc_tests` module in `answers_solver.rs`)

1. **Preliminary storage**: Test that answers are not visible until SCC commits
2. **Merge commit**: Test that merged SCCs commit atomically
3. **Var tracking**: Test that created Vars are tracked and validated
4. **Error isolation**: Test that errors from failed SCCs don't pollute base_errors

### Integration Tests (extend `cycles.rs`)

1. **Cross-module cycles**: Test SCCs spanning multiple modules
2. **Nested cycles**: Test sub-cycles within larger SCCs
3. **Recursive types**: Test mutually recursive classes, loop phi nodes

### Determinism Tests

1. **100-run validation**: Same input produces identical output across 100 runs
2. **Thread sanitizer**: Detect data races
3. **Property-based testing**: Randomized inputs with deterministic outputs

### Verification Commands

```bash
# Run SCC-specific unit tests
buck2 test pyrefly:pyrefly_library -- scc_tests

# Run cycle integration tests
buck2 test pyrefly:pyrefly_library -- cycles

# Run full test suite (before committing)
./test.py
```

---

## Early Finalization Design Decision

### Why Early Finalization Is Necessary

We must call `force_var` during SCC computation (before batch commit), not after. This is required for:

1. **Semantic preservation**: We want to force Vars at the same point as today. For complex SCCs, this is sometimes *before* the full SCC commits. Changing when forcing happens would change type inference behavior.

2. **Avoiding stack overflows during batch commit**: Previous attempts that deferred `force_var` to batch commit time caused stack overflows. The issue was visibility of data during commit - if `force_var` tries to access answers that are mid-commit, it can cause infinite recursion.

3. **Solver state isolation**: `force_var` operates on the solver's `Variables` map, which is separate from the `Calculation` storage where answers are committed. This means early finalization doesn't create circular dependencies with preliminary answer storage.

### Why Early Finalization Is Safe

Investigation confirmed that `force_var` operates purely on solver-internal state:

```rust
pub fn force_var(&self, v: Var) -> Type {
    let lock = self.variables.lock();  // Only accesses Variables map
    let mut e = lock.get_mut(v);
    match &mut *e {
        Variable::Answer(t) => t.clone(),
        Variable::LoopRecursive(prior_type, bound) => { ... }
        _ => {
            // Convert unbound vars to concrete type or Any
            let ty = ...;
            *e = Variable::Answer(ty.clone());
            ty
        }
    }
}
```

Key properties:
- **No dependency on `Calculation`**: `force_var` doesn't query committed answers
- **Variables map populated during solving**: When `record_recursive` is called, the `Variables` map gets the binding
- **Cycle detection via VarRecurser**: Self-referential Var chains are handled by the guard mechanism

### Implication for Phase 1

Preliminary answer storage does NOT need to change `force_var` behavior. The solver's internal `Variables` map is orthogonal to the `Calculation` commit path. We continue to:
1. Create Vars via `fresh_*` methods (registers in `Variables` map)
2. Call `force_var` during `finalize_recursive_answer` (resolves in `Variables` map)
3. Store preliminary answers (separate from `Variables` map)
4. Batch commit on SCC completion (writes to `Calculation` storage)

---

## Risk Assessment

### Low Risk
- **Type erasure complexity**: The `dispatch_anyidx!` macro is already implemented (covers all 20 `AnyIdx` variants with two patterns for dereferenced vs. non-dereferenced idx)
- **Cross-module commit**: The approach is well-understood - extend `LookupAnswer` with `commit_to_module` and implement for `TransactionHandle`. With leader election and deterministic SCC detection, concurrent modification is a non-issue.
- **Error deduplication**: Leader election ensures only one thread commits errors, avoiding duplication.
- **Recursive variable handling**: `force_var` operates on solver state (`Variables` map), not `Calculation` storage, so it's unaffected by preliminary answer storage
- **Debug macro**: Simple, additive change
- **BTreeMap migration**: Optional (sorting at commit time is sufficient for determinism)

### Implementation Notes

- **`Send + Sync` requirements**: Type erasure requires `K::Answer: Send + Sync + 'static` for all key types. Add a compile-time assertion test:
  ```rust
  fn assert_send_sync<T: Send + Sync + 'static>() {}
  #[test]
  fn verify_answer_bounds() {
      assert_send_sync::<Arc<TypeInfo>>();      // Key
      assert_send_sync::<Arc<EmptyAnswer>>();   // KeyExpect
      assert_send_sync::<Arc<Type>>();          // KeyExport
      // ... all 20 answer types
  }
  ```
- **Cross-module partial failure**: If an SCC spans modules A and B and commit to B fails (e.g., module unloaded), the commit to A has already succeeded. This is acceptable - the failed module will recompute on next access. No rollback needed.

---

## Phase Dependencies

```
Phase 0 (Debug Macro)
    ↓
Phase 1a (preliminary_results field)
    ↓
Phase 1b (batch commit) ←── requires commit_to_module implementation
    ↓
Phase 2 (top-SCC-only invariant)
    ↓
Phase 3a (Var tracking) ←── register in AnswersSolver after solver.fresh_*()
    ↓
Phase 3b (validate before commit)
    ↓
[Deferred] Phase 4-6
```

**Key Dependencies:**
- Phase 0 can be done independently
- Phase 1a/1b are tightly coupled - 1a adds storage, 1b uses it
- Phase 2 depends on Phase 1 being complete (needs preliminary storage to enforce invariant)
- Phase 3 depends on Phase 2 (Var validation is a layer on top of the invariant)

**Incremental Deployment:**
- After Phase 1a: No behavior change, just added fields
- After Phase 1b: Answers batch-commit but are still visible during computation (no isolation yet)
- After Phase 2: Full isolation - answers only visible within their SCC until commit
- After Phase 3: Var leakage validation

---

## Behavioral Changes

### Error Message Ordering

Currently, errors are committed per-calculation as each completes. With batch commit, all SCC errors are committed together when the SCC completes. This may change the order in which errors appear in output.

**Mitigation**: Errors are stored in `preliminary_results` per-CalcId. During commit, process in sorted CalcId order for deterministic error ordering.

### RevisitingDone vs RevisitingPreviousScc

Two different scenarios that should not be conflated:

- **`RevisitingDone`**: Revisiting a node marked `Done` *within the same SCC*. This is normal - we just return the preliminary answer. No merge needed.

- **`RevisitingPreviousScc`**: Revisiting a node that's in a *different (previous) SCC* on the stack. This triggers merge-before-read to maintain the top-SCC-only invariant.

Phase 2's invariant enforcement only affects `RevisitingDone` within the same SCC - it must read from preliminary storage, not from global `Calculation` storage.

---

## Implementation Order (Detailed)

### Phase 0: Debug Macro (1 diff, ~50 lines)
- Add `debug_println!` macro
- Instrument key SCC functions
- **Merge criteria**: Compiles, zero test failures

### Phase 1a: Add preliminary_results to Scc (1 diff, ~150 lines)
- Define `PreliminaryResult` struct
- Add `preliminary_results` and `pending_errors` fields to `Scc`
- Add `store_preliminary`/`get_preliminary` methods
- Add helper methods: `sccs().top()`, `sccs().top_mut()`, `sccs().mark_done()`, `sccs().is_complete()`, `sccs().pop()`
- Modify `calculate_and_record_answer` to call `store_preliminary` (data now written to SCC, not directly to Calculation)
- **Merge criteria**: Unit tests pass, answers still computed correctly (stored in SCC but also written to Calculation for now - dual write)

### Phase 1b: Implement batch commit (1 diff, ~150 lines)
- Implement `commit_scc` with leader election
- Implement `try_commit_first` (first-write-wins semantics)
- Implement `wait_for_answer` with timeout
- Handle cross-module dispatch via `LookupAnswer::commit_to_module`
- Remove dual-write from Phase 1a (answers now ONLY go through batch commit)
- **Merge criteria**: Integration tests pass, answers committed atomically

### Phase 2: Enforce top-SCC-only (1 diff, ~100 lines)
- Modify `get_idx` to check for `RevisitingDone` and read from `get_preliminary` instead of `Calculation`
- Add `is_top_scc_participant` helper method
- Add debug assertions in `get_preliminary`
- **Merge criteria**: No visibility leaks in tests (answers not visible until SCC commits)

### Phase 3a: Add Var tracking to Scc (1 diff, ~80 lines)
- Add `created_vars: BTreeSet<Var>` field to `Scc`
- Add wrapper methods in `AnswersSolver` (e.g., `fresh_recursive_var`) that call `solver.fresh_*` then register
- **Merge criteria**: Vars tracked correctly

### Phase 3b: Validate before commit (1 diff, ~100 lines)
- Add validation logic
- Implement fallback (force remaining Vars)
- **Merge criteria**: No Var leaks in tests

---

## Critical Files

- `pyrefly/lib/alt/answers_solver.rs` - Core SCC handling, Scc struct, ThreadState
- `pyrefly/lib/alt/answers.rs` - LookupAnswer trait, Answers struct
- `pyrefly/lib/solver/solver.rs` - Var creation (fresh_* methods), force_var
- `pyrefly/lib/alt/traits.rs` - Solve trait, record_recursive

---

## Future Optimizations

### O(n²) → O(n) SCC Completion Check

The current `is_complete()` implementation iterates over all nodes to check if all are `Done`:

```rust
fn is_complete(&self) -> bool {
    self.node_state.values().all(|state| *state == NodeState::Done)
}
```

This is O(n) per call, and since it's called after each node completes, the total cost is O(n²) for an SCC of size n.

**Impact**: In practice, most SCCs are small (2-3 nodes). However, we've observed SCCs with 500+ nodes in SymPy, where this becomes non-trivial.

**Proposed optimization**: Track completion count incrementally:

```rust
struct Scc {
    // ... existing fields ...
    done_count: usize,  // Track how many are Done
}

impl Scc {
    fn on_calculation_finished(&mut self, current: &CalcId) {
        if let Some(state) = self.node_state.get_mut(current) {
            if *state != NodeState::Done {
                *state = NodeState::Done;
                self.done_count += 1;
            }
        }
    }

    fn is_complete(&self) -> bool {
        self.done_count == self.node_state.len()
    }
}
```

This makes `is_complete()` O(1) instead of O(n), reducing total cost from O(n²) to O(n).

**Priority**: Low - defer until performance profiling shows this as a bottleneck.
