# SCC-Based Cycle Resolution: V3 Implementation Plan (Revised)

This document describes the implementation plan starting from the current state (SCC merging
complete with existing break-at-minimal-idx semantics) and proceeding toward thread-local
isolation, atomic commit, and eventually fixpoint iteration.

**Key insight from implementation experience:** Thread-local preliminary answer storage is a
prerequisite for restart-after-merge and fixpoint iteration. Therefore, we implement thread-local
storage first, then tackle restart/iteration as later phases.

**Revision note:** This document incorporates feedback from multiple review rounds. Design
rationale is integrated throughout.

---

## Current State Summary

### What's Already Implemented

The following work has been completed in the current stack:

1. **SCC Detection and Merging** (`answers_solver.rs` lines 229-599)
   - `Scc` struct tracks `break_at` (set of anchors), `node_state` (Fresh/InProgress/Done),
     `detected_at`, and `min_stack_depth`
   - `Sccs` stack manages active SCCs with proper merging when cycles overlap
   - Merging preserves all break points from constituent cycles (behavioral equivalence)
   - Uses stack-depth optimization to efficiently find overlapping SCCs

2. **CalcStack and CalcId Infrastructure**
   - `CalcId(Bindings, AnyIdx)` uniquely identifies any calculation globally
   - `CalcStack` tracks in-progress calculations per-thread
   - Shared across module boundaries via `ThreadState`

3. **ThreadState** (lines 612-627)
   - Per-thread state containing `Sccs`, `CalcStack`, and debug flag
   - Passed through all cross-module calls via `LookupAnswer` trait
   - Already the natural home for thread-local preliminary answer storage

4. **Pre-existing Cycle Semantics Preserved**
   - Each cycle breaks at its minimal CalcId (existing behavior)
   - First-write-wins for `Calculation<Arc<Answer>, Var>` storage
   - Local error collection with conditional commit based on `did_write`

### Current Answer Storage Flow

```
get_idx(idx)
  ├─ Push CalcId to CalcStack
  ├─ Check sccs().pre_calculate_state(&current)
  │   ├─ NoDetectedCycle → propose_calculation()
  │   ├─ BreakAt → attempt_to_unwind_cycle_from_here()
  │   └─ Participant → short-circuit if already calculated
  ├─ calculate_and_record_answer()
  │   ├─ Create local_errors
  │   ├─ K::solve(binding, &local_errors)
  │   ├─ calculation.record_value(answer, finalize_callback)
  │   │   └─ Returns (final_answer, did_write)
  │   ├─ if did_write: base_errors.extend(local_errors)
  │   └─ sccs().on_calculation_finished(&current)
  ├─ Pop CalcId from CalcStack
  └─ Return answer
```

**Key limitation:** Answers are written directly to global `Calculation` objects. This means:
- No isolation between threads during SCC computation
- Cannot discard preliminary answers on merge (for restart)
- "First write wins" creates nondeterminism with multiple threads

---

## Phase 1: Preliminary Answer Storage in ThreadState

**Goal:** Store answers in thread-local storage during SCC computation, only committing to
global `Calculation` objects when the SCC completes.

### Motivation

1. **Prerequisite for restart:** If we want to restart after merge, we need answers that can
   be discarded. Global `Calculation` uses first-write-wins semantics.

2. **Determinism:** With thread-local storage, each thread computes independently. Only one
   thread's results are committed (the one that completes first). All threads computing the
   same SCC produce identical results.

3. **Error isolation:** Errors are already collected locally; we just need to delay their
   commit until SCC completion.

### Design: Callback-Based Commit Mechanism

**The challenge with commit orchestration:**
1. **Type erasure**: Preliminary answers must be stored as `Arc<dyn Any>`, but committing to
   `Calculation<Arc<K::Answer>, Var>` requires the type parameter `K`.
2. **Cross-module SCCs**: The SCC may contain nodes from multiple modules, each with its own
   `AnswersSolver` and `Calculation` references.
3. **Ownership**: `Sccs` cannot hold references to `Calculation` objects (circular dependency).

**Solution: Store preliminary results as structs with type-erased answers.**

Rationale: Commit callbacks must be created in `calculate_and_record_answer` (where we have
the type parameter `K`) but executed later when the SCC completes. This timing mismatch
requires type erasure via `Arc<dyn Any>`. We use a struct rather than closures to avoid
`Send` bound issues with capturing `Idx<K>`.

When `calculate_and_record_answer` stores a preliminary answer, it also stores all type-specific
information needed to commit later:

```rust
/// A preliminary result for one calculation within an SCC.
/// Stores everything needed to commit the answer when the SCC completes.
///
/// Design note: Errors are captured directly in this struct (by move from the local
/// ErrorCollector), not in separate storage. This ensures each calculation's errors
/// travel with its answer through commit.
pub struct PreliminaryResult {
    /// The type-erased answer to commit
    answer: Arc<dyn Any + Send + Sync>,
    /// The error collector for this calculation (captured by move)
    errors: ErrorCollector,
    /// Whether to call the recursive finalization callback
    /// (For Phase 1, this is always false; Phase 5 will set it based on placeholder presence)
    has_recursive_placeholder: bool,
}

/// Represent an SCC (Strongly Connected Component) we are currently solving.
///
/// Design rationale: `preliminary_results` lives in `Scc` rather than `ThreadState` because
/// each SCC owns its tentative computation state. This design makes SCC completion trivial
/// (just commit from the completed SCC), restart-after-merge cleaner (just clear the maps),
/// and merging straightforward (extend maps in `merge_many`, like `node_state`).
pub struct Scc {
    /// Where do we want to break the SCC (minimal CalcIds)
    break_at: BTreeSet<CalcId>,
    /// State of each participant in this SCC
    node_state: HashMap<CalcId, NodeState>,
    /// Where we detected the SCC (for debugging only)
    detected_at: CalcId,
    /// The minimum CalcStack depth of any participant
    min_stack_depth: usize,

    // NEW in Phase 1: Thread-local preliminary results
    /// Pending commits to execute when this SCC completes.
    /// Maps CalcId → (answer, errors, placeholder flag).
    ///
    /// This map serves dual purpose:
    /// - During SCC computation: lookup preliminary answers for cycle participants
    /// - On SCC completion: commit all answers to global storage
    ///
    /// A single map (rather than separate `preliminary_answers` and `pending_commits` maps)
    /// avoids redundancy since answers are already stored in `PreliminaryResult.answer`.
    preliminary_results: HashMap<CalcId, PreliminaryResult>,
}

pub struct ThreadState {
    sccs: Sccs,
    stack: CalcStack,
    debug: RefCell<bool>,
}
```

**Implementation Note: Consider Extracting Thread-Local State**

Currently, `AnswersSolver` is a large struct (>1600 lines). As we add thread-local preliminary
storage (`sccs`, `stack`, and `preliminary_results` within each `Scc`), consider extracting
these into a dedicated `ThreadLocalState` or `ThreadLocalAnswers` struct. This would:

1. **Enforce separation of concerns**: Clearly distinguish shared solver state from per-thread
   computation state.
2. **Make commit logic explicit**: The boundary between "thread-local work" and "global commit"
   becomes a struct boundary.
3. **Simplify testing**: Thread-local state can be tested in isolation.
4. **Prepare for future phases**: Phases 4-5 (restart and fixpoint) will add more thread-local
   state; having a dedicated struct now prevents `AnswersSolver` from growing further.

Example refactoring:

```rust
/// Thread-local computation state, extracted from AnswersSolver for clarity.
pub struct ThreadLocalState {
    sccs: Sccs,
    stack: CalcStack,
    debug: RefCell<bool>,
    // Future: iteration_count for Phase 5
}

impl ThreadLocalState {
    /// Commit all preliminary results from completed SCCs to global storage.
    pub fn commit_completed_sccs(&mut self, answers: &AnswersSolver) {
        // ... commit logic moved here ...
    }
}
```

This refactoring is optional for Phase 1 but recommended before Phase 2 to keep the codebase
maintainable.

### Implementation Steps

#### Step 1.1: Extend Scc Struct

Add the `preliminary_results` field to the `Scc` struct as shown above. This map serves dual
purpose: preliminary answer lookup during SCC computation, and commit when the SCC completes.

Initialize as an empty `HashMap` in `Scc::new()`.

#### Step 1.2: Modify Answer Lookup in get_idx

When looking up an answer during SCC computation, iterate the SCC stack to find it in
`preliminary_results`:

```rust
// In get_idx, before calling calculate_and_record_answer:
// Check if this CalcId has a preliminary answer in any active SCC
let mut scc_stack = self.sccs().0.borrow_mut();
for scc in scc_stack.iter().rev() {
    if let Some(pending) = scc.preliminary_results.get(&current) {
        // Downcast to the concrete type
        if let Ok(answer) = pending.answer.clone().downcast::<K::Answer>() {
            return answer;
        }
    }
}
drop(scc_stack);  // Release borrow before computing
```

**Note on cross-SCC lookup:** The loop iterates `scc_stack.iter().rev()` (top to bottom),
checking all active SCCs on the stack. This handles the case where an answer is in a
different SCC lower on the stack that hasn't yet been merged with the current SCC. Each
SCC maintains its own `preliminary_results`, so answers computed by lower SCCs are still
visible to upper SCCs. This is important for correctness when SCCs are nested or when
computation crosses SCC boundaries before a merge is detected.

#### Step 1.3: Modify Answer Recording with SCC Participation Flag

**Important:** The `is_scc_participant` flag must be passed from `get_idx`, where it is
determined by the `pre_calculate_state` result. It cannot be recomputed in
`calculate_and_record_answer` because:
1. `pre_calculate_state` has side effects (Fresh → InProgress transition)
2. Checking `!sccs().is_empty()` is **incorrect**

**Why `!sccs().is_empty()` is wrong:** When a node outside any SCC depends on other
nodes, those dependency computations happen while SCCs exist on the stack. Using
`!sccs().is_empty()` would incorrectly route non-SCC nodes to preliminary storage
just because they're computed while an unrelated SCC is active.

The `is_scc_participant` flag is `true` when:
- The call comes from `SccDetectedResult::Continue` (node just joined an SCC)
- The call comes from `SccState::Participant` branch (node was already in an SCC)

The flag is `false` when:
- The call comes from `ProposalResult::Calculatable` within `SccState::NoDetectedCycle`
  (no cycle was detected for this node)

**Design improvement:** Consider refactoring `pre_calculate_state` to return an enum that
explicitly carries the SCC participation status, rather than relying on call-site convention:

```rust
enum PreCalculateResult {
    /// No cycle detected - proceed with calculation, not an SCC participant
    NoCycle,
    /// Cycle detected but we should continue computing (break point or new participant)
    SccParticipant,
    /// Short-circuit: answer already available
    AlreadyCalculated(Arc<dyn Any + Send + Sync>),
}
```

This makes the contract between `get_idx` and `calculate_and_record_answer` explicit and
prevents bugs from incorrect flag propagation at call sites.

```rust
fn calculate_and_record_answer<K: Solve<Ans>>(
    &self,
    current: CalcId,
    idx: Idx<K>,
    calculation: &Calculation<Arc<K::Answer>, Var>,
    is_scc_participant: bool,  // NEW: passed from get_idx
) -> Arc<K::Answer>
where
    AnswerTable: TableKeyed<K, Value = AnswerEntry<K>>,
    BindingTable: TableKeyed<K, Value = BindingEntry<K>>,
{
    let binding = self.bindings().get(idx);
    let range = self.bindings().idx_to_key(idx).range();
    let local_errors = self.error_collector();  // Creates ErrorCollector with current module

    // Solve the binding
    let answer = Arc::new(K::solve(self, binding, range, &local_errors));

    if is_scc_participant {
        // Store answer and errors in preliminary_results for this SCC
        let mut scc_stack = self.sccs().0.borrow_mut();
        if let Some(scc) = scc_stack.last_mut() {
            let pending = PreliminaryResult {
                answer: answer.clone() as Arc<dyn Any + Send + Sync>,
                errors: local_errors,  // Move ownership
                has_recursive_placeholder: false,  // Simplified for Phase 1
            };
            // CalcId is the map key - no need to store it in PreliminaryResult
            scc.preliminary_results.insert(current.dupe(), pending);
        }
        drop(scc_stack);  // Release borrow

        // Track SCC progress - may trigger commit if SCC(s) are complete.
        //
        // IMPORTANT: `on_calculation_finished` returns whether *any* SCCs remain active.
        // When merged SCCs share nodes, finishing the last shared node can complete
        // multiple SCCs simultaneously. Therefore, `execute_preliminary_results` must
        // drain ALL completed SCCs, not just one. See the implementation below.
        let any_sccs_active = self.sccs().on_calculation_finished(&current);
        if !any_sccs_active {
            self.execute_preliminary_results();
        }

        return answer;
    }

    // No active SCC participation - write directly to global storage (unchanged behavior)
    let (final_answer, did_write) = calculation.record_value(
        answer,
        |var, answer| self.finalize_recursive_answer::<K>(idx, var, answer, &local_errors),
    );
    if did_write {
        self.base_errors.extend(local_errors);
    }

    self.sccs().on_calculation_finished(&current);
    final_answer
}
```

**Call sites in get_idx:**

```rust
// After SccDetectedResult::Continue (line 742)
SccDetectedResult::Continue => {
    self.calculate_and_record_answer(current, idx, calculation, true)
}

// After ProposalResult::Calculatable (line 758) - no cycle
ProposalResult::Calculatable => {
    self.calculate_and_record_answer(current, idx, calculation, false)
}

// SccState::Participant with CycleDetected (line 774)
SccState::Participant => {
    match calculation.propose_calculation() {
        ProposalResult::CycleDetected => {
            self.calculate_and_record_answer(current, idx, calculation, true)
        }
        // ...
    }
}
```

#### Step 1.4: Commit Execution with Type-Erased Dispatch

**Important threading constraints:**
- `execute_preliminary_results` is called only on the thread that finished the SCC
- Must not hold locks from `Sccs` or `CalcStack` during execution (commit re-enters `Calculation::record_value`)
- All `PreliminaryResult` instances are created and consumed on the same thread (no cross-thread closure execution)

```rust
impl<'a, Ans: LookupAnswer> AnswersSolver<'a, Ans> {
    /// Execute all preliminary results from completed SCCs and clear their state.
    ///
    /// This method drains ALL completed SCCs from the stack, not just one.
    ///
    /// **Why multiple SCCs can complete at once:**
    /// When SCCs are merged, they share nodes. When the last shared node finishes
    /// its calculation, `on_calculation_finished` marks ALL merged constituent SCCs
    /// as complete simultaneously. If we only popped one SCC, the remaining completed
    /// SCCs would leave uncommitted results behind.
    ///
    /// **Example scenario:**
    /// - SCC A contains nodes {1, 2}
    /// - SCC B contains nodes {2, 3}
    /// - After merge: merged SCC contains nodes {1, 2, 3}
    /// - When node 3 finishes (the last node), the entire merged structure completes
    /// - We must commit all preliminary results from the merged SCC
    ///
    /// Called when `on_calculation_finished` returns false (no active SCCs remain).
    fn execute_preliminary_results(&self) {
        // Drain ALL completed SCCs, not just one.
        // Merged SCCs may complete together when their last shared node finishes.
        loop {
            let completed_scc = {
                let mut scc_stack = self.sccs().0.borrow_mut();
                // Check if the top SCC is complete (all nodes Done)
                if scc_stack.last().map_or(false, |scc| scc.is_complete()) {
                    scc_stack.pop()
                } else {
                    None
                }
            };

            match completed_scc {
                Some(scc) => self.commit_scc(scc),
                None => break,
            }
        }
    }

    /// Commit all preliminary results from a single completed SCC.
    fn commit_scc(&self, completed_scc: Scc) {
        // Get preliminary results from the completed SCC
        let commits = completed_scc.preliminary_results;

        // Execute in CalcId order for determinism
        let mut ordered: Vec<_> = commits.into_iter().collect();
        ordered.sort_by_key(|(calc_id, _)| calc_id.clone());

        // Dispatch on AnyIdx to commit each pending answer with its concrete type
        for (calc_id, pending) in ordered {
            self.dispatch_commit(calc_id, pending);
        }
    }

    /// Dispatch a preliminary result to the appropriate type-parametric handler.
    ///
    /// This uses a match on `AnyIdx` to recover the concrete type `K` and then
    /// performs the commit with full type information.
    fn dispatch_commit(&self, calc_id: CalcId, pending: PreliminaryResult) {
        let CalcId(bindings, any_idx) = calc_id;

        // Type-erased dispatch: match on all 20 AnyIdx variants
        // Each arm downcasts the answer and calls the typed commit helper
        match any_idx {
            AnyIdx::Key(idx) => self.commit_typed::<Key>(bindings, idx, pending),
            AnyIdx::KeyExpect(idx) => self.commit_typed::<KeyExpect>(bindings, idx, pending),
            AnyIdx::KeyConsistentOverrideCheck(idx) => {
                self.commit_typed::<KeyConsistentOverrideCheck>(bindings, idx, pending)
            }
            AnyIdx::KeyClass(idx) => self.commit_typed::<KeyClass>(bindings, idx, pending),
            AnyIdx::KeyTParams(idx) => self.commit_typed::<KeyTParams>(bindings, idx, pending),
            AnyIdx::KeyClassBaseType(idx) => {
                self.commit_typed::<KeyClassBaseType>(bindings, idx, pending)
            }
            AnyIdx::KeyClassField(idx) => {
                self.commit_typed::<KeyClassField>(bindings, idx, pending)
            }
            AnyIdx::KeyVariance(idx) => self.commit_typed::<KeyVariance>(bindings, idx, pending),
            AnyIdx::KeyClassSynthesizedFields(idx) => {
                self.commit_typed::<KeyClassSynthesizedFields>(bindings, idx, pending)
            }
            AnyIdx::KeyExport(idx) => self.commit_typed::<KeyExport>(bindings, idx, pending),
            AnyIdx::KeyDecorator(idx) => self.commit_typed::<KeyDecorator>(bindings, idx, pending),
            AnyIdx::KeyDecoratedFunction(idx) => {
                self.commit_typed::<KeyDecoratedFunction>(bindings, idx, pending)
            }
            AnyIdx::KeyUndecoratedFunction(idx) => {
                self.commit_typed::<KeyUndecoratedFunction>(bindings, idx, pending)
            }
            AnyIdx::KeyAnnotation(idx) => {
                self.commit_typed::<KeyAnnotation>(bindings, idx, pending)
            }
            AnyIdx::KeyClassMetadata(idx) => {
                self.commit_typed::<KeyClassMetadata>(bindings, idx, pending)
            }
            AnyIdx::KeyClassMro(idx) => self.commit_typed::<KeyClassMro>(bindings, idx, pending),
            AnyIdx::KeyAbstractClassCheck(idx) => {
                self.commit_typed::<KeyAbstractClassCheck>(bindings, idx, pending)
            }
            AnyIdx::KeyLegacyTypeParam(idx) => {
                self.commit_typed::<KeyLegacyTypeParam>(bindings, idx, pending)
            }
            AnyIdx::KeyYield(idx) => self.commit_typed::<KeyYield>(bindings, idx, pending),
            AnyIdx::KeyYieldFrom(idx) => self.commit_typed::<KeyYieldFrom>(bindings, idx, pending),
        }
    }

    /// Commit a pending answer with full type information.
    ///
    /// This is called from `dispatch_commit` after recovering the concrete type `K`.
    fn commit_typed<K: Solve<Ans>>(
        &self,
        bindings: Bindings,
        idx: Idx<K>,
        pending: PreliminaryResult,
    ) where
        AnswerTable: TableKeyed<K, Value = AnswerEntry<K>>,
        K::Answer: 'static + Send + Sync,
    {
        // Downcast the type-erased answer to the concrete type
        let answer = pending
            .answer
            .downcast::<K::Answer>()
            .expect("Type mismatch in preliminary result");

        // Look up the Calculation object from the appropriate module's Answers
        // If the bindings are from a different module, we need to access that module's table
        let calculation = if bindings.module() == self.module() {
            // Same module - use our current table
            self.current.table.get::<K>().get(idx).unwrap()
        } else {
            // Cross-module - look up via LookupAnswer mechanism
            // See "Cross-module commit implementation plan" below
            panic!("Cross-module commit not yet implemented in this sketch")
        };

        // Commit the answer (simplified finalization for Phase 1)
        let (_final_answer, did_write) = calculation.record_value(
            answer,
            |_var, answer| answer, // Simplified: skip force_var for now
        );

        // Race condition handling: If did_write is false, another thread won the race.
        // We continue processing the rest of the preliminary results for consistency,
        // but their record_value calls will also return did_write=false.
        // This means errors from the losing thread are discarded entirely.
        //
        // Error deduplication note: This design relies on commit atomicity - errors are only
        // committed by the thread that wins the first-write-wins race for the anchor node.
        // Since all threads computing the same SCC produce identical results, discarding the
        // loser's errors is correct (they would be duplicates). If threads could produce
        // different errors for the same SCC, this would need reconsideration.
        if did_write {
            self.base_errors.extend(pending.errors);
        }
        // Note: We don't abort the commit loop early even if we lose the race, because:
        // 1. The loop is short (typically <10 iterations for most SCCs)
        // 2. Aborting early could leave some preliminary results unprocessed
        // 3. record_value is cheap when did_write=false (just returns existing answer)
    }
}
```

**Cross-module commit implementation plan:**

The `panic!` above is a placeholder. The actual implementation requires:

1. **Add `Calculation` lookup method to `LookupAnswer` trait:**
   ```rust
   trait LookupAnswer {
       // Existing method
       fn get<K: Solve<Self::Answer>>(&self, idx: Idx<K>) -> Arc<K::Answer>;

       // NEW: Get the Calculation object for a given CalcId
       fn get_calculation<K: Solve<Self::Answer>>(
           &self,
           bindings: &Bindings,
           idx: Idx<K>,
       ) -> &Calculation<Arc<K::Answer>, Var>;
   }
   ```

2. **Implementation in `AnswersForResolve`:**
   ```rust
   /// Access the Calculation object for a cross-module CalcId.
   ///
   /// Implementation note: The actual implementation will require extending
   /// the module lookup infrastructure used by `LookupAnswer::get()` (which
   /// calls `solve_exported_key` internally). The specific API will be
   /// determined during Phase 1 implementation based on how the Answers
   /// registry is structured.
   fn get_calculation<K>(&self, bindings: &Bindings, idx: Idx<K>) -> &Calculation<...> {
       // Use the same module lookup infrastructure as LookupAnswer::get(),
       // but return the Calculation instead of computing the answer.
       todo!("Requires extending the module registry pattern")
   }
   ```

3. **`ThreadState` access:** Since `LookupAnswer` implementations already receive
   `ThreadState` (for SCC tracking), the cross-module commit can share the same
   thread context. No additional synchronization is needed.

4. **Commit ordering:** Cross-module SCCs commit in the same CalcId order as
   single-module SCCs. The module boundary is transparent to the commit logic.

The cross-module case is architecturally identical to the same-module case; the only
difference is which `Calculation` reference we obtain.

**Note on the 20-variant match:** This boilerplate could be generated via a macro in the actual
implementation to reduce code duplication and maintenance burden.

**Design choice: Struct vs Closure for PreliminaryResult:**

An earlier version of this design used `Box<dyn FnOnce() + Send>` closures instead of the
`PreliminaryResult` struct. The struct approach was chosen to avoid `Send` bound issues with
capturing `Idx<K>` (which is not `Send` due to containing `PhantomData`). The trade-offs:

- **Struct approach** (current): More boilerplate (20-variant match), but compile-time type safety
  and no `Send` issues. Can inspect preliminary results for debugging.
- **Closure approach**: Less boilerplate, but requires careful handling of captured types and
  makes debugging harder (closures are opaque).

The struct approach is recommended unless runtime inspection of preliminary results is not needed
and the `Send` bound issue can be resolved.

### Handling Cross-Module SCCs

When an SCC spans modules:

1. Module A's `AnswersSolver` calls into Module B via `LookupAnswer::get`
2. Module B creates its own `AnswersSolver` but shares `ThreadState`
3. Both push `CalcId`s with their respective `Bindings` onto the shared stack
4. When a node in the SCC finishes, it stores its preliminary result (including errors)
5. The SCC completes in whichever `AnswersSolver` happens to be active at that moment
6. `execute_preliminary_results()` executes all commits, regardless of which module created them

**Design note:** Errors are captured directly in `PreliminaryResult` by moving the local
`ErrorCollector`. There is no separate `pending_errors` field because errors naturally
travel with their associated answer through the commit process.

**The preliminary results capture their module's resources**, so cross-module commits work correctly.

### SCC Merging with Per-SCC Storage

**Why per-SCC storage makes merging cleaner:**

When SCCs are merged (in `Sccs::on_scc_detected`), the existing `Scc::merge_many` logic
already merges `break_at` and `node_state` maps. With per-SCC storage, we extend this
to also merge preliminary answers and preliminary results:

```rust
impl Scc {
    fn merge_many(sccs: Vec<Scc>, detected_at: CalcId) -> Self {
        let mut merged_break_at = BTreeSet::new();
        let mut merged_node_state = HashMap::new();
        let mut merged_preliminary_results = HashMap::new();  // NEW
        let mut merged_detected_at = detected_at;
        let mut merged_min_stack_depth = usize::MAX;

        for scc in sccs {
            // Existing logic
            for b in scc.break_at {
                merged_break_at.insert(b);
            }
            for (k, v) in scc.node_state {
                merged_node_state.entry(k).and_modify(|existing| *existing = (*existing).max(v)).or_insert(v);
            }
            if scc.detected_at < merged_detected_at {
                merged_detected_at = scc.detected_at;
            }
            if scc.min_stack_depth < merged_min_stack_depth {
                merged_min_stack_depth = scc.min_stack_depth;
            }

            // NEW: Merge preliminary results
            merged_preliminary_results.extend(scc.preliminary_results);
        }

        Scc {
            break_at: merged_break_at,
            node_state: merged_node_state,
            detected_at: merged_detected_at,
            min_stack_depth: merged_min_stack_depth,
            preliminary_results: merged_preliminary_results,
        }
    }
}
```

**For Phase 4 (restart after merge):** When we implement restart, the merged SCC will
discard preliminary answers and preliminary results by simply clearing the map. The
per-SCC ownership makes this trivial:

```rust
// Phase 4: After merge, before restart
merged_scc.preliminary_results.clear();
// Reset node states to Fresh and restart from canonical entry point
```

### Error Handling

**How errors are handled in Phase 1:**

Errors are stored in the `PreliminaryResult` struct, moved from the local `ErrorCollector`
created in `calculate_and_record_answer`:

```rust
let pending = PreliminaryResult {
    answer: answer.clone() as Arc<dyn Any + Send + Sync>,
    errors: local_errors,  // Move ownership from calculate_and_record_answer
    has_recursive_placeholder: false,
};
```

When commits execute (in `commit_typed`), errors are only extended to `base_errors` if
the write succeeded:

```rust
if did_write {
    self.base_errors.extend(pending.errors);
}
```

**Why this approach:**

1. **Module context preservation**: Each `ErrorCollector` is created with `self.error_collector()`,
   which embeds the current module's `ModuleInfo`. When errors are added, this context travels
   with each `Error`.

2. **Automatic cleanup**: Errors that don't win the commit race are automatically dropped when
   the `PreliminaryResult` is consumed.

3. **Cross-module SCCs**: Each preliminary result stores its own module-specific error collector,
   so cross-module SCCs naturally preserve per-module error context.

### Recursive Answer Finalization and Regression Risk

The `finalize_recursive_answer` method performs critical work for recursive types:
- Takes the raw answer and a `Var` (recursive placeholder)
- Calls `K::record_recursive` which updates the solver's `Variables` map
- Calls `solver().force_var(var)` to finalize the recursive variable

For Phase 1, we use simplified finalization in `commit_typed`:

```rust
let (_final_answer, did_write) = calculation.record_value(
    answer,
    |_var, answer| answer,  // Simplified: skip force_var for now
);
```

**Regression Risk:**

Bindings that currently rely on `force_var` to resolve recursive placeholders may exhibit
degraded type quality or errors with Phase 1. Specifically:

- Loop phi nodes that depend on `Variable::LoopRecursive` being forced
- Mutually recursive class definitions that use `Variable::Recursive`
- Any code path where `Type::Var(v)` propagates instead of resolving to a concrete type

**Mitigation Strategy:**

1. **Regression testing**: Before merging Phase 1, run the full test suite and identify any
   new failures or type quality degradations related to recursive types.

2. **Feature flag**: Implement Phase 1 behind a feature flag (e.g., `--experimental-scc-isolation`)
   so it can be tested in CI without affecting production use.

3. **Monitoring**: Add telemetry to track how often `force_var` is called on recursive
   placeholders vs. skipped in Phase 1.

4. **Guardrails**: If regressions are severe, consider adding basic `force_var` support to
   Phase 1 by storing the `Var` in `PreliminaryResult` and checking for its presence at commit time.

5. **Documentation**: Update known issues documentation to list any type quality regressions
   introduced by Phase 1, with explicit note that Phase 5 will resolve them.

6. **Stress testing for `force_var`**: Add a specific stress test that artificially triggers
   `force_var` on a variable that is currently being computed in a different thread (or in
   the same thread's restart loop, once Phase 4 is implemented). This will verify the failure
   mode and ensure the mitigation strategy is effective.

**Phase 5 will eliminate the need for `force_var`** by using fixpoint iteration, which naturally
resolves recursive types through convergence rather than placeholder forcing.

### Placeholder Handling in Phase 1

In the current implementation, `attempt_to_unwind_cycle_from_here` writes placeholders
directly to the global `Calculation` via `record_cycle`. This uses first-write-wins
semantics at the placeholder level.

**Phase 1 decision:** Keep placeholders global.

Rationale:
- Phase 1 does not implement restart-after-merge, so placeholder discarding is not needed
- Placeholders are consumed by `record_value` and not persisted after SCC completion
- All threads computing the same SCC use the same placeholder (via first-write-wins),
  which is acceptable when we don't restart

**Critical: Global state isolation during thread-local phase:**

During Phase 1, when using thread-local preliminary answers, the placeholder mechanism
(`attempt_to_unwind_cycle_from_here` → `calculation.record_cycle`) continues to work
as before. However, there's an important constraint:

- **Do NOT call `record_cycle` on the global `Calculation` during thread-local computation**
- Instead, the recursive placeholder should be created and **returned immediately**, leaving
  the global `Calculation` in the `Calculating` state
- This prevents other threads from seeing premature "Cycle" state before the SCC commits
- The existing `attempt_to_unwind_cycle_from_here` already returns the placeholder value;
  Phase 1 doesn't change this behavior

**Migration Path to Thread-Local Placeholders (Phase 4):**

When implementing restart-after-merge in Phase 4, we'll need to move placeholders to
thread-local storage. The migration strategy:

1. **Add thread-local placeholder storage**:
   ```rust
   pub struct ThreadState {
       // ... existing fields ...
       preliminary_placeholders: RefCell<HashMap<CalcId, Var>>,  // NEW in Phase 4
   }
   ```

2. **Modify `attempt_to_unwind_cycle_from_here`** to check for existing placeholder
   in thread-local storage first:
   ```rust
   // Phase 4 implementation
   if let Some(var) = thread_state.preliminary_placeholders.borrow().get(&current) {
       return Ok(Arc::new(K::promote_recursive(var)));
   }

   let rec = K::create_recursive(self, binding);
   thread_state.preliminary_placeholders.borrow_mut().insert(current, rec);
   Err(rec)  // No longer calls calculation.record_cycle()
   ```

3. **Feature flag for gradual rollout**: Use a config flag to switch between global
   (Phase 1) and thread-local (Phase 4) placeholder strategies:
   ```rust
   if config.use_thread_local_placeholders {
       // Phase 4 path
   } else {
       // Phase 1 path (fallback)
   }
   ```

4. **Commit placeholders atomically**: When SCC completes, commit thread-local placeholders
   to global `Calculation` objects using the same `dispatch_commit` pattern used for answers.

This staged approach avoids a "big bang" migration and allows testing each strategy
independently.

**Phase 4 dependency:** When implementing restart-after-merge, placeholders must be
moved to thread-local storage alongside preliminary answers.

### Verification Gates

- All existing tests pass (behavior identical for non-cycle cases)
- Answers correctly isolated per-thread during SCC computation
- Errors correctly isolated and only committed on SCC completion
- Cross-module cycle tests show correct preliminary answer visibility

---

## Phase 2: Atomic Commit with First-Write-Wins

**Goal:** When an SCC completes, atomically commit all answers. If another thread already
committed (for the same SCC), discard our work and use their results.

### The Commit Anchor

Use the minimal CalcId in the SCC as the "commit anchor":
- Attempt to write the commit anchor's answer first
- If write succeeds (we won), commit all other answers
- If write fails (another thread won), discard our work

This is already handled by the Phase 1 callback mechanism - each callback performs
a `record_value` which uses first-write-wins semantics. The callbacks are executed
in CalcId order, so the anchor is committed first.

### Commit Visibility Semantics

**Clarification:** "Atomic commit" in this design means **first-write-wins at the SCC level**,
not transactional batch insert. During the commit loop, another thread may observe some but
not all results from the SCC.

**Why partial visibility is acceptable:**

The commit loop calls `record_value` sequentially for each node in the SCC. Between these
calls, there is a window where some nodes are committed and others are not. This is
intentional and does not affect correctness for the following reasons:

1. **The anchor determines SCC ownership**: The first thread to commit the anchor (minimal
   CalcId) wins the entire SCC. Other threads either:
   - See "Calculating" status on nodes they need and wait (via `wait_for_commit`)
   - Race-lose their commit attempt and discard their work

2. **Per-node waiting**: A thread needing a specific node waits for THAT node specifically
   (see `wait_for_commit` below). It does not assume that seeing the anchor means all nodes
   are ready.

3. **Blocking semantics prevent observation of partial state**: Threads that might observe
   partial commits are either:
   - **Same SCC participants**: Already blocked waiting for SCC completion
   - **Outside threads**: Use `Calculation::propose_calculation` which blocks on "Calculating"
     status, then transitions to `wait_for_commit` spin-lock

4. **Transient window**: The partial visibility window is extremely short (microseconds for
   typical SCCs of <10 nodes). No semantic decisions are made based on "some nodes present,
   others missing."

**Race scenario walkthrough:**

```
Thread A (winner):                    Thread B (loser):
─────────────────                    ─────────────────
commit anchor (key_A)  ───────────>  sees key_A committed
commit key_B                         needs key_C, calls wait_for_commit(key_C)
commit key_C           ───────────>  wait_for_commit returns UseExisting(answer_C)
commit key_D                         continues with answer_C
```

Thread B does not assume key_C is ready just because key_A exists. It explicitly waits for
key_C via spin-lock.

**If strict all-or-nothing visibility were required:**

A batch-insert lock could be added around the entire commit loop:

```rust
// Hypothetical strict atomic commit (NOT IMPLEMENTED - not needed for correctness)
fn execute_preliminary_results_strict(&self) {
    let _batch_lock = self.global_batch_commit_lock.lock();
    for (calc_id, pending) in ordered {
        self.dispatch_commit(calc_id, pending);
    }
}
```

This is not needed for correctness given the current wait semantics, but the option exists
if future requirements change.

### Handling "Loser" Threads

**Reviewer concern:** If a thread loses the race (sees anchor is already written), it needs
to wait for the specific node it requested, not just the anchor.

**Solution:** Losers wait on their specific node via spin-lock.

When a thread detects it might be racing with another thread on an SCC, it waits for
the **specific node** it needs:

```rust
/// Result of waiting for another thread to complete a calculation
enum WaitResult<A> {
    /// Another thread committed this node - use their answer
    UseExisting(A),
    /// We should compute this ourselves
    ShouldCompute,
}

/// Wait for a specific node's answer from another thread.
///
/// Called when we detect we might be racing with another thread on an SCC.
/// We wait for OUR specific node, not the anchor, because:
/// 1. The anchor being written only means the commit started
/// 2. The caller needs an answer of type K::Answer, not the anchor's answer type
///
/// **Note:** This requires adding a `state()` method to `Calculation` that exposes
/// a read-only view of the internal `Status` enum. This is a Phase 2 infrastructure
/// requirement.
fn wait_for_commit<K: Keyed>(
    &self,
    calculation: &Calculation<Arc<K::Answer>, Var>,
) -> WaitResult<Arc<K::Answer>>
where
    K::Answer: 'static + Send + Sync,
{
    // Spin-lock tuning constants. These values are initial estimates subject to
    // benchmarking and tuning based on production workloads. Consider making them
    // configurable via config options if they prove sensitive to workload characteristics.
    const MAX_SPINS: u32 = 1000;      // Total iterations before timeout
    const YIELD_THRESHOLD: u32 = 100; // Switch from busy-wait to yield_now()
    const SLEEP_THRESHOLD: u32 = 500; // Switch from yield to sleep()

    for i in 0..MAX_SPINS {
        // Check calculation status (requires new Calculation::state() method)
        // Alternative: use existing get() method, but loses ability to distinguish
        // NotCalculated vs Calculating states
        match calculation.state() {
            Calculated(answer) => return WaitResult::UseExisting(answer.clone()),
            Calculating => {
                // Someone is working on it - keep waiting
                if i > SLEEP_THRESHOLD {
                    std::thread::sleep(Duration::from_micros(100));
                } else if i > YIELD_THRESHOLD {
                    std::thread::yield_now();
                }
                // Otherwise, busy-wait
            }
            NotCalculated => {
                // Node not yet started - we should compute it ourselves
                return WaitResult::ShouldCompute;
            }
        }
    }
    // Timeout - recompute (self-healing behavior)
    WaitResult::ShouldCompute
}
```

**Infrastructure requirement:** The `Calculation` struct currently doesn't expose a `state()`
method. Phase 2 implementation requires adding:

```rust
// In crates/pyrefly_graph/src/calculation.rs
impl<T: Dupe, R> Calculation<T, R> {
    /// Get a read-only view of the calculation's current state.
    pub fn state(&self) -> CalculationState<T> {
        let lock = self.0.lock();
        match &*lock {
            Status::NotCalculated => CalculationState::NotCalculated,
            Status::Calculating(_) => CalculationState::Calculating,
            Status::Calculated(v) => CalculationState::Calculated(v.dupe()),
        }
    }
}

pub enum CalculationState<T> {
    NotCalculated,
    Calculating,
    Calculated(T),
}
```

**Alternative approach** (if modifying `Calculation` is undesirable): Use the existing `get()`
method which returns `Option<T>`, but acknowledge we lose the ability to distinguish between
`NotCalculated` and `Calculating` states. For the spin-lock use case, this is acceptable:
- If `get()` returns `Some(answer)`, use it
- If `get()` returns `None`, keep spinning (or timeout)

**Robustness: Orphaned Calculations**

With thread-local storage, if a thread panics before committing, it may leave global
`Calculation` objects in the `Calculating` state indefinitely. Mitigation:

1. **Existing timeout mechanism**: The `wait_for_commit` spin-lock already has a timeout
   (MAX_SPINS) that triggers recomputation if a thread appears stuck.

2. **Calculation cleanup**: Verify that the existing `Calculation` implementation handles
   abandoned `Calculating` states gracefully - other threads should be able to detect
   the state and recompute if needed.

3. **Thread death detection**: Consider adding a mechanism to detect when a thread dies
   mid-SCC computation and mark its preliminary results as abandoned, though this is likely
   unnecessary given the timeout-based self-healing.

The combination of spin-lock timeout and first-write-wins semantics provides natural
resilience against thread panics.

**Why wait on the specific node:**

1. **Type safety**: The caller needs `Arc<K::Answer>` for their specific `K`. The anchor's
   answer type is different (unless coincidentally the same).

2. **Completeness**: The winning thread commits answers in order. When a loser sees the anchor
   is written, it only knows the commit started. The specific node they need might not be
   written yet.

3. **Correctness**: By waiting on the specific node, we get exactly the answer we need, with
   the correct type, when it's available.

### Partial Commit Handling

If a thread panics mid-commit (after writing some answers but not all):
- Other threads detect answers exist and try to use them
- Missing answers trigger recomputation on next access (self-healing via timeout)
- This is acceptable: panics are rare, and the system recovers

### Verification Gates

- Run test suite with different thread counts
- Results identical regardless of thread scheduling
- No duplicate errors from concurrent computation

---

## Phase 3: Determinism Invariants

**Goal:** Ensure that the same code always produces the same types and errors, regardless of
thread interleaving.

### Key Invariants

1. **Ordered collections:** Use `BTreeMap`/`BTreeSet` instead of `HashMap`/`HashSet` for any
   iteration that affects computation order.

2. **Thread-independent computation:** Don't use thread IDs, allocation addresses, or timing
   information in type computation.

3. **Canonical SCC processing:** Process SCC participants in CalcId order during commit
   (already done in `execute_preliminary_results`).

### Verification

- Re-enable the cross-module cycle tests currently commented out
- Add stress tests with varying thread counts
- Verify identical results across 100+ runs with different thread schedules

---

## Phase 4: Restart After Merge (Future)

**Goal:** When SCCs merge, restart computation from a canonical entry point with fresh state.

### Why This Comes Later

Restart requires:
1. ✅ Thread-local preliminary answers (Phase 1)
2. ✅ Ability to discard preliminary answers (Phase 1)
3. ❌ Type-erased dispatch from CalcId to get_idx
4. ❌ State reset mechanism for merged SCCs

### Design Sketch

When a merge is detected:
1. Collect all participants from merged SCCs
2. Clear preliminary answers and preliminary results for all participants
3. Reset NodeState to Fresh for all participants
4. Dispatch to `get_idx` for the canonical entry point (minimal CalcId)

The type-erased dispatch requires a match on `AnyIdx`:

```rust
fn dispatch_get_idx(solver: &AnswersSolver, calc_id: &CalcId) -> Arc<dyn Any> {
    match calc_id.1 {
        AnyIdx::Key(idx) => solver.get_idx(idx),
        AnyIdx::KeyClass(idx) => solver.get_idx(idx),
        // ... 18 more variants
    }
}
```

**Note:** This could be generated via macro to reduce boilerplate.

**Implementation consideration: Stack depth**

The recursive dispatch pattern (`dispatch_get_idx` → `get_idx` → `dispatch_get_idx` for nested
SCCs) could stress the call stack for deeply nested or large SCCs. During implementation,
consider one of the following mitigations:

1. **Iterative trampoline pattern:** Instead of direct recursion, have `dispatch_get_idx`
   return a continuation or restart-request that the caller processes in a loop:
   ```rust
   enum DispatchResult {
       Done(Arc<dyn Any>),
       Restart(CalcId),  // Restart from this entry point
   }

   fn run_dispatch_loop(solver: &AnswersSolver, initial: CalcId) -> Arc<dyn Any> {
       let mut current = initial;
       loop {
           match dispatch_get_idx_step(solver, &current) {
               DispatchResult::Done(answer) => return answer,
               DispatchResult::Restart(next) => current = next,
           }
       }
   }
   ```

2. **Explicit recursion limit:** Add a depth counter to `ThreadState` and return an error
   or fallback answer if the limit is exceeded:
   ```rust
   const MAX_RESTART_DEPTH: usize = 100;

   if thread_state.restart_depth.get() > MAX_RESTART_DEPTH {
       // Log warning and return Any/error to break the recursion
   }
   ```

3. **Increase stack size for type-checking threads:** A pragmatic workaround if typical
   SCC depths are known to be bounded.

This is an implementation detail to address when building Phase 4, not a design blocker.
The recursive approach is correct; we just need to guard against pathological inputs.

### Thread-Local Placeholders

When implementing restart, placeholders must also become thread-local:

1. **Why:** After merge detection and restart, the previous placeholder (written globally)
   cannot be discarded. The restarted computation might determine a different break point
   or create a different placeholder type.

2. **Implementation:**
   ```rust
   pub struct ThreadState {
       // ... existing fields ...
       preliminary_placeholders: RefCell<HashMap<CalcId, Var>>,  // NEW in Phase 4
   }
   ```

3. **Modified `attempt_to_unwind_cycle_from_here`:**
   - Write placeholder to `preliminary_placeholders` instead of `calculation.record_cycle`
   - Look up existing placeholder from thread-local storage first
   - First-write-wins only among threads that haven't restarted

4. **On commit:** The winning thread's placeholder is passed to `on_recursive` callback
5. **On discard:** Clear `preliminary_placeholders` along with `preliminary_answers`

### Skip-Restart Optimization

When the minimal CalcId is already at or above the merge detection point on the CalcStack,
we can skip restart entirely - the current computation is already proceeding from the
canonical entry point.

---

## Phase 5: Fixpoint Iteration (Future)

**Goal:** Instead of breaking cycles with placeholders that degrade to `Any`, iterate until
types converge.

### Approach

1. First iteration: Use `Any` (or recursive placeholder) when hitting cycle back-edge
2. Record preliminary answer for each SCC participant
3. Second iteration: Use prior iteration's preliminary answers
4. Compare: If all answers unchanged, converged; otherwise iterate again
5. Limit iterations (default: 3) to prevent infinite loops

### Convergence Detection

Requires comparing answers across iterations. For types, this means structural equality
(not pointer equality). The `Type` enum should implement `PartialEq` appropriately.

### Benefits

- Higher-quality types at cycle break points
- Fewer confusing error messages from `Any` propagation
- Better inference for recursive data structures

---

## Phase 6: Simplify Placeholders (Future)

**Goal:** With fixpoint iteration working, remove `Variable::Recursive` complexity.

Currently, `Variable::Recursive` exists because we only do one pass through cycles.
With multi-iteration fixpoint, we can:
- Use `Any` on first iteration
- Refine through subsequent iterations
- Remove `Var` tracking, `force_var`, and related solver complexity

---

## Summary

| Phase | Description | Prerequisite For |
|-------|-------------|------------------|
| 1 | Callback-based preliminary storage in ThreadState | Phases 2-5 |
| 2 | Atomic commit with first-write-wins | Phase 3 |
| 3 | Determinism invariants | - |
| 4 | Restart after merge | Phase 5 |
| 5 | Fixpoint iteration | Phase 6 |
| 6 | Simplify placeholders | - |

**Rationale for ordering:** Thread-local storage (Phase 1) is the foundation. It enables
atomic commit (Phase 2), which enables determinism (Phase 3). Restart (Phase 4) builds on
the ability to discard preliminary answers. Fixpoint iteration (Phase 5) requires both
restart and preliminary answer comparison. Placeholder simplification (Phase 6) is a
cleanup once fixpoint is working.

---

## Appendix A: Key Files and Locations

**Note:** Line numbers are approximate and may drift as the codebase evolves. Use the
component/function names for reliable lookup via code search.

| Component | File | Lines |
|-----------|------|-------|
| Scc, Sccs structs | `answers_solver.rs` | 229-599 |
| ThreadState | `answers_solver.rs` | 612-627 |
| get_idx | `answers_solver.rs` | 723-794 |
| calculate_and_record_answer | `answers_solver.rs` | 805-840 |
| Calculation struct | `crates/pyrefly_graph/src/calculation.rs` | 40-170 |
| ErrorCollector | `error/collector.rs` | 88-197 |
| AnyIdx enum | `binding/binding.rs` | 121-143 |
| LookupAnswer trait | `answers.rs` | 458-473 |

---

## Appendix B: Alternatives Considered

### Alternative 1: NodeState-based Answer Storage (from v2-doc)

Store answers in `NodeState::InProgress(Option<AnyAnswer>)` using an enum with 20 variants
matching `AnyIdx`. Rejected because:
- Couples two separate concerns (state tracking and answer storage)
- Makes merge semantics more complex (must update all HashMap entries)
- Callback approach is more idiomatic

### Alternative 2: Type-Erased Dispatch Without Callbacks

Use a match on `AnyIdx` in `execute_preliminary_results` to dispatch to type-specific code.
Rejected because:
- Requires ~20-arm match statement
- Must maintain module/solver access across commit
- Callbacks are more composable and less coupled

### Alternative 3: Simplify by Deferring Only Errors

Commit answers immediately but defer error commits until SCC completion. This provides
partial isolation and is simpler than full answer+error deferral.

Rejected because:
- Doesn't enable restart-after-merge (answers can't be discarded)
- Doesn't provide full determinism (first-write-wins on answers still applies)
- Phase 4 and Phase 5 would require refactoring anyway
