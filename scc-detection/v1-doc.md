# SCC-Based Cycle Resolution: Phased Implementation Plan

This document describes a phased approach to implementing SCC (Strongly Connected Component)
based cycle resolution in Pyrefly. The approach achieves determinism and improved type quality
**without** requiring the `get_idx` signature change to return `Result`. Stack unwinding is
deferred as an optional future optimization.

**Companion documents:**
- `v0-doc.md` - Original SCC design with stack unwinding (the "target" algorithm)
- `../thread-local-cycles/v2-doc.md` - Thread-local preliminary answers (infrastructure we'll use)

---

## Motivation

### Current Problems

1. **Nondeterminism**: When multiple threads compute the same cycle, the order of completion
   affects which thread's errors are kept and which placeholder values are used.

2. **Poor type quality at cycle break points**: When we break a cycle with `Variable::Recursive`,
   the resulting type often degrades to `Any`, which:
   - Produces confusing error messages
   - Blocks Instagram's Python→Hack transpiler (requires types everywhere)
   - Makes upgrade work harder when new features create new cycles

3. **Interlocking cycles**: When cycles share nodes (e.g., A→B→C→A and D→E→B), the order
   of cycle discovery affects the final types. This is a source of nondeterminism.

### Goals

1. **Determinism**: Same code → same types → same errors, regardless of thread scheduling
2. **Better types**: Use fixpoint iteration to produce converged types instead of `Any`
3. **Incremental implementation**: Deliver value at each phase, validate before proceeding
4. **Minimal disruption**: Avoid changing `get_idx` signature (~119 call sites)

---

## Design Principles

### Why Not Stack Unwinding First?

The original v0-doc proposes changing `get_idx` to return `Result<T, CycleUnwind>` to enable
clean stack unwinding. While this is the theoretically cleanest approach, it has costs:

1. **~119 call sites** must change to add `?` propagation
2. **~22+ files** directly affected, 30-40 transitively
3. **Risk**: A refactor of this scope could introduce subtle bugs
4. **All-or-nothing**: Hard to validate incrementally

Instead, we implement the SCC algorithm **without** unwinding:
- When we need to "restart" from a merged SCC, we start a fresh calculation
- Parent frames on the Rust stack become "wasted work" but complete normally
- Results are already committed by the fresh calculation; wasted frames detect this

**Trade-off**: Wastes work proportional to O(restarts × SCC_size) = O(N²) worst case.
However, **peak stack depth** is only O(D + N) where D = initial depth, N = SCC size:
- Restarts ≤ final_SCC_size (each restart adds ≥1 node)
- Most cycles are small (10-20 nodes based on Instagram data)
- Stack overhead is bounded and unlikely to overflow

Stack unwinding can be implemented later as a pure optimization if stack usage proves
problematic. The algorithm logic is identical either way.

### The "Dead SCC" Pattern

Without stack unwinding, we need a mechanism to handle wasted frames. When an SCC is
superseded by a merge:

1. Mark the Rust stack frames as belonging to a "dead" SCC
2. Start a fresh calculation from the merged SCC's anchor
3. When wasted frames complete, they detect they were superseded and re-fetch from storage

**Key insight:** Dead SCCs are popped from the SCC stack during the merge operation,
so `is_in_dead_scc()` cannot simply scan the current SCC stack. Instead, we need to
track "deadness" on a per-frame basis using the calc stack.

**Implementation approach:**

```rust
struct CalcStackFrame {
    calc_id: CalcId,
    /// Set to true when this frame's SCC is superseded by a merge
    superseded: bool,
}

// During merge operation:
fn mark_frames_as_superseded(&mut self, from_anchor: &CalcId) {
    // Mark all frames from the target anchor to the top as superseded
    for frame in self.calc_stack.frames_since(from_anchor) {
        frame.superseded = true;
    }
}
```

At the end of `get_idx`, before returning:

```rust
if self.is_current_frame_superseded() {
    // Our computation was superseded - fetch the real answer
    // The merged SCC may still be computing, so we need to handle that case
    return self.fetch_authoritative_answer(idx);
}
```

**Race condition handling:** The merged SCC might not have committed yet when a
superseded frame finishes. We handle this by:

```rust
fn fetch_authoritative_answer(&self, idx: Idx<K>) -> Arc<K::Answer> {
    // First check global storage
    if let Some(answer) = self.get_calculation(idx).get() {
        return answer;
    }

    // Not in global yet - check the currently-active SCC's preliminary answers
    // (The merged SCC is still computing but has our answer in its local storage)
    if let Some(scc) = self.scc_stack.current() {
        if let Some(answer) = scc.preliminary_answers.get(&CalcId::from(idx)) {
            return answer.clone();
        }
    }

    // If we get here, there's a bug - the merged SCC should have our answer
    panic!("Superseded frame could not find authoritative answer");
}
```

This ensures correctness without signature changes.

### Worked Example: Dead SCC Pattern

Consider the interlocking cycle from v0-doc (f→g→h→f with h→k→m→k where m→h):

```
Initial call: get_idx(f)
Call stack: [f, g, h, k, m]
SCC stack: [SCC1={f,g,h}, SCC2={k,m}]

m needs h → detect connection to SCC1!

Merge operation:
1. Pop SCC2, pop SCC1
2. Create MergedSCC = {f,g,h,k,m}, anchor=f
3. Mark frames [f,g,h,k,m] as superseded
4. Push MergedSCC
5. Start fresh get_idx(f) from the anchor

Call stack after fresh start: [f, g, h, k, m, f', g', h', k', m']
(Primed names represent the fresh computation)

Fresh computation completes:
- f' finishes, commits to global storage
- g', h', k', m' all commit

Now the superseded frames unwind:
- m returns: is_current_frame_superseded() = true
  → fetch_authoritative_answer(m) returns global[m]
- k returns: is_current_frame_superseded() = true
  → fetch_authoritative_answer(k) returns global[k]
- h returns: superseded = true → returns global[h]
- g returns: superseded = true → returns global[g]
- f returns: superseded = true → returns global[f]

Result: The wasted frames simply return the already-computed answers.
No duplicate work affects the final result.
```

**Stack depth in this example:**
- Initial depth to m: 5 frames
- Fresh computation adds: 5 more frames
- Peak depth: 10 frames (original 5 + fresh 5)
- This is O(D + N) where D=initial depth, N=SCC size

**Callers outside the SCC:** What about callers that depend on SCC nodes but aren't
themselves in the SCC? They continue computing normally. When they request an SCC
node's answer, they get it from global storage (which is already populated by the
fresh computation).

---

## Phase A: Start Cycles at Minimal Idx

> **Phasing note:** This phase could alternatively be combined with Phase C (SCC merging).
> The restart mechanism introduced here is primarily useful for Phase C's merge operation.
> However, implementing A separately provides:
> - Early validation that the restart mechanism works
> - A smaller, testable change that doesn't require thread-local infrastructure
> - Foundation for understanding how "fresh starts" work
>
> If preferred, skip A and implement the restart mechanism as part of C.

### Current Behavior

When a cycle is detected at node X:
1. Find the minimal idx in the cycle (call it M)
2. If X == M: Break here with a placeholder
3. If X != M: Continue computing toward M, tracking cycle state

The computation continues from wherever we detected the cycle, which means:
- We do work computing nodes between X and M
- When we reach M, we install a placeholder and start unwinding
- The work from X to M happened in "cycle detection mode" with special state tracking

### New Behavior

When a cycle is detected at node X:
1. Find the minimal idx M
2. Immediately start a **fresh** `get_idx(M)` call
3. This fresh call will also detect the cycle at M and handle it
4. The fresh call completes the entire SCC computation
5. Return the result for the originally-requested node X

This simplifies later phases because:
- We always start SCC computation from a canonical point (minimal idx)
- The "cycle detection mode" logic becomes simpler
- SCC merging (Phase C) is easier when there's a single entry point

### Implementation Details

**In `on_cycle_detected`** (answers_solver.rs, ~line 383):

```rust
fn on_cycle_detected(&self, raw: Vec1<CalcId>) -> CycleDetectedResult {
    let cycle = Cycle::new(raw);

    if cycle.break_at == cycle.detected_at {
        // We ARE the minimal idx - handle cycle normally
        self.0.borrow_mut().push(cycle);
        CycleDetectedResult::BreakHere
    } else {
        // We're not the minimal - start fresh from minimal idx
        self.0.borrow_mut().push(cycle);

        // Start fresh computation from break_at
        // This will re-detect the cycle at break_at and handle it there
        CycleDetectedResult::RestartFromMinimal(cycle.break_at.clone())
    }
}
```

**New `CycleDetectedResult` variant**:

```rust
enum CycleDetectedResult {
    BreakHere,
    Continue,
    DuplicateCycleDetected,
    RestartFromMinimal(CalcId),  // NEW
}
```

**In `get_idx`**, handle the new variant:

```rust
CycleDetectedResult::RestartFromMinimal(minimal_calc_id) => {
    // Start fresh computation from the minimal idx
    // The result for our idx will be computed as part of that SCC
    let answer = self.dispatch_get_idx(&minimal_calc_id);

    // Now fetch OUR answer from global storage (it was computed in the SCC)
    self.get_calculation(idx).get().unwrap_or_else(|| {
        // Fallback: if not in global, it's in the SCC's preliminary storage
        // (This shouldn't happen if SCC commits properly, but defensive)
        answer.clone()
    })
}
```

**Note**: `dispatch_get_idx` needs to handle the type-erased `CalcId`. This requires
a dispatch mechanism similar to what we'd need for SCC commits anyway.

### Verification

- All existing cycle tests should pass with identical results
- The only observable difference is internal: which stack frame handles the cycle
- Add tracing to verify cycles are now always handled at minimal idx

### Risks

- **Stack depth**: Each restart adds a stack frame. But this is bounded by cycle size.
- **Type erasure**: Need a way to call `get_idx` from a `CalcId`. This infrastructure
  is needed anyway for Phase C.

---

## Phase B: Thread-Local Data for Cycles

### Goal

Eliminate nondeterminism by isolating cycle computation to the thread that detects it.
Only the detecting thread's computation matters; other threads that stumble into the
same cycle just wait or re-fetch.

### Key Changes

1. **Preliminary answers storage**: Store tentative answers in thread-local `SccState`
   instead of global `Calculation` during cycle resolution.

2. **Error buffering**: Collect errors locally during cycle resolution; only commit
   them when the authoritative computation completes.

3. **Atomic commit**: When the SCC is fully resolved, commit all answers and errors
   atomically to global storage.

### Data Structures

**`NodeState`** (per-node computation state within an SCC iteration):

```rust
enum NodeState {
    /// Ready to compute (reset at start of each iteration).
    Fresh,
    /// Currently on the Rust call stack within this SCC.
    InProgress,
    /// Finished for this iteration, answer in current_answers.
    Done,
}
```

**`SccState`** (rename from `Cycle`):

```rust
pub struct SccState {
    /// All participants in this SCC
    participants: Vec<CalcId>,

    /// The anchor point for deterministic ordering
    anchor: CalcId,

    /// Tracking stacks (kept from Cycle)
    recursion_stack: Vec<CalcId>,
    unwind_stack: Vec<CalcId>,
    unwound: Vec<CalcId>,
    detected_at: CalcId,

    /// NEW: Is this SCC still active, or has it been merged/superseded?
    alive: bool,

    /// NEW: Per-node computation state for current iteration
    node_state: HashMap<CalcId, NodeState>,

    /// NEW: Thread-local preliminary answers
    preliminary_answers: TypeErasedPreliminaryAnswers,

    /// NEW: Buffered errors (only committed on success)
    pending_errors: ErrorCollector,
}
```

**`TypeErasedPreliminaryAnswers`** (from thread-local-cycles doc):

```rust
pub struct TypeErasedPreliminaryAnswers {
    answers: RefCell<SmallMap<TypeErasedKey, Arc<dyn Any + Send + Sync>>>,
}

struct TypeErasedKey {
    module_name: ModuleName,
    key_type: TypeId,
    index: usize,
}
```

### Lookup Cascade

When computing within an SCC, lookups follow this order:

1. **Check current SCC's preliminary answers** - if found, return it
2. **Check outer SCCs' preliminary answers** (for nested cycles)
3. **Check global `Calculation`** - if `Calculated`, return it
4. **Compute** - if `NotCalculated` or `Calculating`, compute the binding

For intra-SCC recursion (hitting a node we're currently computing):
- Return a placeholder (`Any` or `Variable::Recursive` initially)
- Phase D will replace this with the prior iteration's answer

### Commit Protocol

When an SCC completes (all participants computed):

```rust
fn commit_scc(&self, scc: &SccState) {
    // Commit all answers to global Calculation storage
    for (calc_id, answer) in scc.preliminary_answers.iter() {
        let calculation = self.get_calculation_for_calc_id(&calc_id);
        let (_, did_write) = calculation.record_value(answer);
        if did_write {
            // We wrote - this thread "owns" this binding
        }
    }

    // Commit errors only if we wrote answers
    self.base_errors.extend(scc.pending_errors.take());
}
```

### Determinism Guarantee

With thread-local preliminary answers:
- Each thread computes independently during SCC resolution
- Only the first thread to call `record_value` commits to global
- Other threads' work is discarded (they'll re-fetch from global)
- Errors only come from the winning thread

**Result**: Same code → same SCC → same computation order → same types and errors.

### Verification

- Run test suite with different thread counts
- Results should be identical regardless of thread scheduling
- Add tests that specifically exercise multi-thread cycle scenarios

---

## Phase C: SCC Finding and Merging

### Goal

Handle interlocking cycles by detecting when a newly-discovered cycle connects to an
existing SCC, merging them, and restarting computation from the merged SCC's anchor.

### When Merging Occurs

Cycle detection can yield three outcomes:

1. **Independent cycle**: No connection to any existing SCC → create new SCC
2. **Self-connection**: We hit a node in our current SCC → intra-SCC recursion
3. **Connection to outer SCC**: We hit a node in an SCC higher on the stack → MERGE

### Merge Algorithm

When we detect a connection to an outer SCC:

```rust
fn handle_scc_connection(&self, target_node: CalcId) -> MergeResult {
    let mut all_nodes = HashSet::new();

    // 1. Find which SCC (if any) contains target_node
    let target_depth = self.find_scc_containing(&target_node);

    // 2. Collect all nodes from current position to target SCC
    for scc in self.scc_stack.iter().skip(target_depth) {
        all_nodes.extend(scc.participants.iter().cloned());
        scc.alive = false;  // Mark as dead
    }

    // 3. Add any "free-floating" nodes on the calc stack
    for node in self.calc_stack.nodes_since(&target_node) {
        all_nodes.insert(node);
    }

    // 4. Create merged SCC with fresh state
    let merged = SccState {
        participants: all_nodes.into_iter().collect(),
        anchor: all_nodes.iter().min().unwrap().clone(),
        preliminary_answers: TypeErasedPreliminaryAnswers::new(), // FRESH
        pending_errors: ErrorCollector::new(),
        alive: true,
        ..Default::default()
    };

    // 5. Pop dead SCCs, push merged
    self.scc_stack.truncate(target_depth);
    self.scc_stack.push(merged);

    // 6. Signal restart from merged anchor
    MergeResult::RestartFrom(merged.anchor.clone())
}
```

### The "Fresh Start" Property

**Critical invariant**: After a merge, we start with completely fresh state:
- No prior_answers from the incomplete computation
- No pending_errors from the incomplete computation
- All nodes are marked Fresh, ready to compute

This ensures determinism: the final SCC is computed the same way regardless of
which cycle path discovered the connection.

### Dead SCC Detection

Wasted frames (from the pre-merge computation) must not pollute results:

```rust
fn get_idx<K>(&self, idx: Idx<K>) -> Arc<K::Answer> {
    // ... computation ...

    // Before returning, check if we've been superseded
    if self.is_in_dead_scc(&current) {
        // Our SCC was merged - fetch authoritative answer
        return self.get_calculation(idx).get()
            .expect("Merged SCC should have committed by now");
    }

    result
}

fn is_in_dead_scc(&self, calc_id: &CalcId) -> bool {
    for scc in self.scc_stack.iter() {
        if scc.participants.contains(calc_id) {
            return !scc.alive;
        }
    }
    false
}
```

### Complexity Analysis

**Peak stack depth:** O(D + N) where D = initial call depth, N = final SCC size
- When a merge occurs, we add N fresh frames on top of the superseded frames
- The superseded frames are still on the Rust stack, just marked
- Peak depth = original depth to detection point + fresh SCC computation

**Total wasted work:** O(N²) in worst case
- At most N restarts (each adds ≥1 node to the SCC)
- Each restart may duplicate up to N frames of work
- N restarts × N frames = O(N²) total wasted frame-evaluations

**Why this is acceptable:**
- Peak stack depth is linear, not quadratic
- The O(N²) is wasted *work*, not stack *depth*
- SCCs are typically small (most bindings aren't in cycles)
- The quadratic cost is isolated to pathological interlocking cases
- In practice: restarts are rare (most cycles discovered in first pass)

### Verification

- Create test cases with interlocking cycles (A→B→C→A, D→E→B patterns)
- Verify same result regardless of entry point
- Add telemetry for merge frequency and SCC sizes

### Entry-Point Independence

**Claim (Conjecture):** Given a fixed iteration bound, the detected SCC is the same
regardless of which node in the true SCC we enter from.

**Reasoning:**

1. **SCC Closure Property:** Each SCC being resolved is "closed" with respect to every
   other SCC. No result from a potentially-enclosing outer SCC can influence the
   computation of an inner SCC without immediately triggering a merge. This is because:
   - If inner SCC tries to access a node that's InProgress on the outer call stack,
     we detect the connection and merge.
   - If inner SCC tries to access a node that's in an outer SCC on the stack, we
     detect the connection and merge.

2. **Deterministic Edge Traversal:** Starting from any given idx, the order of lookups
   (edge traversals) is deterministic. Even though the Rust call stack differs based
   on entry point, the edges traversed during SCC resolution are determined by the
   computation, not the call stack.

3. **Same Edges → Same Merges:** Since the same edges are traversed regardless of
   entry point, and merging is triggered by edge traversal, the same merges occur.
   Therefore, the final detected SCC is the same.

4. **Same SCC → Same Computation:** Once we have the same SCC, we process nodes in
   deterministic order (sorted by idx), use deterministic placeholders, and run
   deterministic iterations.

**⚠️ CAUTION:** This reasoning has not been formally verified. The argument relies on
the closure property holding in all cases, which should be validated through testing
with diverse cycle structures.

**⚠️ NUANCE: Type-Dependent Edge Exploration:** The edges discovered during computation
can depend on the type of a placeholder. Consider:

```python
def f(x):
    if isinstance(x, SomeClass):
        return x.method()  # Only explored if x narrows to SomeClass
    return x
```

If placeholder types differ between entry points, different edges could be explored.
**Mitigation:** We use a fixed placeholder (`Any`) for nodes with no prior answer,
ensuring consistent behavior regardless of entry point.

---

## Phase D: Multi-Iteration Fixpoint

### Goal

Instead of breaking cycles with `Any` or `Variable::Recursive`, iterate until types
converge. This produces higher-quality types.

### Iteration Protocol

```rust
fn solve_scc(&self, scc: &mut SccState) {
    const MAX_ITERATIONS: u8 = 3;

    for iteration in 0..MAX_ITERATIONS {
        // Reset node states for this iteration
        scc.reset_for_iteration();

        // Compute all nodes starting from anchor
        self.compute_scc_nodes(scc);

        // Check convergence
        if iteration > 0 && scc.has_converged() {
            break;
        }

        // Prepare for next iteration: current becomes prior
        scc.swap_answers();
    }

    // Emit non-convergence errors for unstable bindings
    for node in &scc.participants {
        if !scc.has_converged_at(node) {
            self.emit_non_convergence_error(node);
        }
    }

    // Commit final answers
    self.commit_scc(scc);
}
```

### Placeholder Strategy During Iteration

**Iteration 0** (first pass):
- When we hit a back-edge (recursion to a node currently being computed), use `Any`
- This is conservative but always valid

**Iteration 1+**:
- When we hit a back-edge, use the prior iteration's answer
- This allows types to "flow around" the cycle

### Convergence Detection

```rust
impl SccState {
    fn has_converged(&self) -> bool {
        self.participants.iter().all(|node| self.has_converged_at(node))
    }

    fn has_converged_at(&self, node: &CalcId) -> bool {
        match (self.prior_answers.get(node), self.current_answers.get(node)) {
            (Some(prior), Some(current)) => types_equal(prior, current),
            _ => false,
        }
    }
}
```

### Error Handling

Errors are only collected in the **final** iteration:
- Iterations 0..N-1: Use a discarding error collector
- Iteration N (final): Use the real error collector
- This ensures errors reference converged types, not intermediate placeholders

### Verification

- Test cycles that need >1 iteration to converge
- Verify fewer `Any` types in cycle outputs
- Measure iteration counts in practice (expect most cycles converge in 1-2)

---

## Phase E: Remove Variable::Recursive

### Goal

With multi-iteration fixpoint in place, we can simplify placeholder handling:
- `Variable::Recursive` → just use `Any` on first iteration
- `Variable::LoopRecursive` → same treatment

### Why This Is Possible

Currently, `Variable::Recursive` serves as a "promise" that gets resolved later.
The complexity exists because we only do one pass. With fixpoint iteration:
- Pass 1: Use `Any` → get a rough type
- Pass 2: Use pass 1's type → get a better type
- Pass 3: Usually converged

The final type is often the same, but the mechanism is simpler.

### Benefits

1. **Simpler code**: Remove `Var` tracking, `force_var`, solver complexity
2. **Fewer special cases**: No distinction between recursive and non-recursive answers
3. **Cleaner errors**: No confusing "recursive type" messages

### Migration Strategy

1. First, make fixpoint iteration work with existing `Var` machinery
2. Add a flag: `use_simple_placeholders: bool`
3. Test with simple placeholders enabled
4. If results are equivalent, remove `Var` machinery

### Verification

- Compare types before/after with comprehensive test suite
- Ensure no regressions in type quality
- May need to increase iteration count for some edge cases

---

## Phase F: Stack Unwinding (Optional Optimization)

### When To Consider

Only pursue this phase if:
- Telemetry shows stack depth approaching limits
- Large SCCs (100+ nodes) are common in real codebases
- Stack frames are expensive enough to matter

### What It Provides

- O(D) peak stack depth instead of O(D + N)
- Cleaner control flow (explicit abort vs. "detect and discard")
- No wasted computation (eliminates O(N²) wasted work)

### Implementation

This is the Phase 1-2 from v0-doc.md:
1. Change `get_idx` return type to `Result<T, CycleUnwind>`
2. Add `?` propagation to ~119 call sites
3. Catch `CycleUnwind` at SCC anchor and restart

### Decision Criteria

Before implementing:
- Measure actual stack usage in production
- Count how often "wasted frames" occur
- Weigh engineering cost vs. benefit

**Recommendation**: Defer indefinitely unless data shows it's necessary.

---

## Implementation Timeline

| Phase | Description | Dependencies | Risk | Effort |
|-------|-------------|--------------|------|--------|
| A | Start at minimal idx | None | Low-Medium | 1-2 weeks |
| B | Thread-local data | None (or Phase A) | Medium | 2-3 weeks |
| C | SCC merging | Phase A, Phase B | Medium-High | 2-3 weeks |
| D | Multi-iteration | Phase C | Low | 1 week |
| E | Remove Var | Phase D | Medium | 1-2 weeks |
| F | Stack unwinding | Phase D | High | 3+ weeks |

**Total for Phases A-E**: ~8-11 weeks
**Phase F**: Deferred unless needed

**Hidden blockers to address:**
- **Type-erased dispatch**: Phases A and C require calling `get_idx` from a `CalcId`.
  This needs a dispatch mechanism to map `CalcId` → appropriate `Idx<K>` type.
- **Cross-module SCC commits**: When an SCC spans modules, commits must coordinate
  across the different `AnswersSolver` instances. Needs testing.
- **CalcStackFrame tracking**: The `superseded` flag requires modifying the calc stack
  to track per-frame state.

**Alternative ordering (B→A→C):** If Phase A's standalone value is questionable, consider:
1. Implement Phase B first (thread-local infrastructure, useful independently)
2. Then implement A+C together (restart mechanism + merging)
3. This may be more efficient if A's only purpose is enabling C

---

## Testing Strategy

### Phase A Tests

- Existing cycle tests pass unchanged
- New tracing confirms cycles start at minimal idx

### Phase B Tests

- Multi-thread cycle tests produce deterministic results
- Error messages are consistent across runs

### Phase C Tests

- Interlocking cycle patterns (crafted examples)
- Entry-point independence (same result from different starting nodes)
- Telemetry for merge frequency

### Phase D Tests

- Cycles that require >1 iteration
- Fewer `Any` types in output
- Convergence rate measurement

### Phase E Tests

- Before/after comparison of all cycle-involving code
- No regression in type quality

---

## Success Criteria

1. **Determinism**: Multiple runs produce identical results
2. **Type quality**: Measurable reduction in `Any` at cycle break points
3. **Performance**: No significant regression (small constant factor acceptable)
4. **Maintainability**: Code is simpler after Phase E than before Phase A

---

## Open Questions

1. **Iteration bound**: 2 or 3 iterations? Need empirical data. Current hypothesis:
   most cycles converge in 2 iterations; 3 is a safety margin.

2. **Placeholder type**: Use `Any` or something more specific? `Any` is safest and
   ensures consistent behavior regardless of entry point (see Entry-Point Independence).

3. **Cross-module SCCs**: The design should work (ThreadState is shared), but
   needs explicit testing.

4. **Type equality for convergence**: Options for comparing types between iterations:
   - **Structural equality**: Recursive comparison of type trees. Simplest to implement
     but potentially expensive for deeply nested types.
   - **Pointer equality**: If types are interned (same type → same pointer), this is O(1).
     Pyrefly does not currently intern all types, so this may not be viable.
   - **Hash equality**: Compute a hash of the type structure. Fast comparison but
     requires maintaining hashes.
   - **Recommended**: Start with structural equality. Profile if convergence checking
     becomes a bottleneck, then consider caching/hashing.

5. **Non-convergence handling**: Recommended approach:
   - Emit a type error at the binding that didn't converge
   - Use the last iteration's result as the final type (better than `Any`)
   - Error message suggests adding type annotation to break the cycle

---

## Appendix: Key Code Locations

| Concept | File | Lines (approx) |
|---------|------|----------------|
| `get_idx` | answers_solver.rs | 545-615 |
| Cycle detection | answers_solver.rs | 557-577 |
| `Cycle` struct | answers_solver.rs | 177-203 |
| `Cycles` stack | answers_solver.rs | 349-420 |
| `propose_calculation` | calculation.rs | 80-115 |
| `record_value` | calculation.rs | 140-180 |
| `CalcId` ordering | answers_solver.rs | 94-107 |

