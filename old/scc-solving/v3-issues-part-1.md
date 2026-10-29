# Iterative Fixpoint SCC Solving — Bug Fixes (v4 Plan)

This plan addresses bugs discovered in the current iterative fixpoint
implementation (landed from v3). The implementation is functionally complete
but exhibits two user-visible problems:

- **Nondeterminism:** Different error outputs across runs for some libraries
  (e.g. steam.py). The iterative mode was specifically designed to eliminate
  the nondeterminism inherent in min-idx cycle breaking, so this represents a
  new bug in the implementation.
- **Hanging:** ~5-10% of multi-threaded runs get stuck for 5000+ seconds at
  ~120% CPU. The hang does not reproduce with `RAYON_NUM_THREADS=1`.

Investigation (across 5 independent code-analysis agents) found no true
infinite loop. Every individual code path is bounded. The primary theory is
that the hang is caused by bounded-but-enormous work arising from the
multiplicative interaction of three factors described in the "Multi-Threaded
Work Amplification" section below.

In addition, three correctness bugs were identified. Two of them —
`segment_size` asymmetry and absorption orphaning — may actively contribute
to the hang and nondeterminism rather than being merely latent issues. All
three should be fixed as part of this work.

---

## Correctness Bugs

These bugs were found during root-cause investigation. Bugs (1) and (2) may
contribute to the hang and nondeterminism in addition to being correctness
issues; bug (3) is primarily a correctness and nondeterminism concern.

### 1) `segment_size` Asymmetric Tracking

**Location:** `answers_solver.rs`, `push()` (lines 333-378) and `pop()`
(lines 494-513).

**Problem:** When a node goes through the iterative bypass path in `push()`
(lines 341-378), the early return bypasses the `SccState::Participant` arm
(line 469) where `segment_size += 1` occurs. But `pop()` at lines 506-510
unconditionally checks `top_scc.node_state.contains_key(calc_id)` and calls
`saturating_sub(1)` on `segment_size`. So iterative-bypass nodes don't
increment `segment_size` on push but do decrement it on pop.

The `saturating_sub` prevents underflow panics, but `segment_size` becomes
inaccurate between merges. This could affect:
- `is_within_scc_segment()` checks in `pre_calculate_state`
- Overlap detection in `check_overlap`
- `merge_sccs`'s `segment_size` recomputation

The `segment_size` recomputation at line 914
(`calc_stack_vec.len() - merged.anchor_pos`) and at line 284
(`stack_len - merged.anchor_pos`) corrects the value whenever a merge
happens, but between merges the value may be wrong.

**Relationship to hang:** An inaccurate `segment_size` can cause
`is_within_scc_segment()` to return wrong answers, which affects
`pre_calculate_state`'s branching. This can trigger spurious merges
(increasing K in the merge-amplification model) or miss merges that should
happen, leading to extra iterations. Either outcome feeds directly into
Factor 1 of the work amplification theory.

**Fix:** Either increment `segment_size` in the iterative bypass path
before the early return, or skip the decrement in `pop()` when the node
went through the iterative bypass. The simplest approach is to increment
in the iterative bypass, since the node IS being pushed onto the raw
CalcStack (line 244 runs unconditionally before the bypass checks).

### 2) Absorption Check Can Orphan SCCs

**Location:** `answers_solver.rs`, `iterative_resolve_scc()` (line 2568)
and `Scc::merge()` (line 1657).

**Problem:** When a merge during iteration changes the top SCC's
`detected_at` to a smaller value (because the absorbed SCC had a smaller
`detected_at`), the absorption check at line 2568:

```rust
if self.stack().top_scc_detected_at() != scc_identity {
    return;
}
```

returns early without committing. This is correct when an ancestor
iteration driver exists and will pick up the merged SCC. But if no
ancestor iteration driver is active (e.g. the merge brought in a cycle
from an SCC that completed Phase 0 but wasn't yet iterating), the SCC may
be left on the stack with no driver.

**Relationship to hang:** This is not just a correctness bug — it is a
potential liveness bug. An SCC left on the stack with no iteration driver
will sit indefinitely until some other thread's DFS happens to touch it
and trigger a merge. If that never happens, the thread that returned from
the driver could be blocked waiting for that SCC's members to resolve.
This could directly cause hang behavior independent of the work
amplification theory. It deserves investigation as a potential standalone
hang cause.

**Fix:** Before returning from the absorption early-exit, verify that an
ancestor iteration driver exists. One approach: check whether the SCC
stack below the current position has an entry whose `iterative` state is
`Some(...)`. If not, the current driver should continue with the merged
SCC rather than returning.

### 3) Free-Floating Nodes Invisible During Current Iteration

**Location:** `answers_solver.rs`, `merge_sccs()` (lines 904-909) and
`Scc::merge()` (lines 1669-1688).

**Problem:** When `merge_sccs` is called, it first calls `Scc::merge_many`
which rebuilds `iterative.node_states` from the merged `node_state` maps.
Then lines 905-909 add free-floating CalcStack nodes to
`merged.node_state` via `or_insert(NodeState::InProgress)`. These
free-floating nodes are therefore in `node_state` but NOT in
`iterative.node_states`.

During the current iteration, `next_fresh_member()` scans
`iterative.node_states`, so these nodes are invisible to
`drive_all_iteration_members`. They complete through the legacy path
(`calculate_and_record_answer` sees that `get_iteration_node_state`
returns `None` and takes the non-iterative code path). This means their
answers bypass the iterative error suppression and convergence tracking.

On the next iteration, `set_fresh_iteration_state` rebuilds
`iterative.node_states` from `self.node_state.keys()`, which now includes
the free-floating nodes, so they get properly driven. But the first
iteration after the merge has inconsistent handling.

**Relationship to hang:** Unlikely to cause hangs directly, but
contributes to nondeterminism and convergence issues. These nodes bypass
error suppression and convergence tracking in the first iteration after a
merge, which changes which answers participate in `has_changed` and can
alter the number of iterations required for convergence.

**Fix:** After adding free-floating nodes to `merged.node_state` in
`merge_sccs`, also add them to `merged.iterative.node_states` (as
`IterationNodeState::Fresh`) if the merged SCC has iteration state. This
ensures they are visible to `drive_all_iteration_members` immediately.

---

## Multi-Threaded Work Amplification

The hang and nondeterminism share a common root cause: multiple threads
independently iterate the same SCC with no coordination mechanism. The
total work is bounded but enormous due to three multiplicative factors.

Note: the correctness bugs above (particularly #1 and #2) may interact
with these factors. Bug #1 can increase the merge count K in Factor 1,
and bug #2 could cause hangs independently of this amplification model.

### Factor 1: Merge-Amplification Inside `drive_all_iteration_members`

**Location:** `answers_solver.rs`, `drive_all_iteration_members()` (lines
2491-2500), `Scc::merge()` (lines 1642-1691), demotion check (line 2584).

**Mechanism:** The while loop in `drive_all_iteration_members`:

```rust
while let Some(id) = self.stack().next_fresh_member() {
    self.drive_member(&id);
}
```

drives each Fresh member. But if `drive_member` triggers a cross-SCC
merge (via the membership back-edge at lines 265-330 or via nested
`iterative_resolve_scc` absorption), `Scc::merge` resets ALL members to
Fresh:

```rust
// Scc::merge, lines 1674-1679
let all_members: BTreeMap<CalcId, IterationNodeState> = self
    .node_state.keys().duped()
    .map(|k| (k, IterationNodeState::Fresh))
    .collect();
```

This includes members that were already driven to Done in the current
loop iteration. The while loop then re-discovers them as Fresh and
re-drives them.

If K merges happen during one `drive_all_iteration_members` call, the
total work is approximately K x N (where N is the final SCC size). But
the demotion counter only increments once per `drive_all_iteration_members`
return (line 2584), so multiple merges within one call count as a single
demotion. This means the effective work can be much larger than
`MAX_DEMOTIONS` would suggest.

**Contribution to hang:** With K = 5-10 merges per iteration and N = 70-100
members, a single `drive_all_iteration_members` call does 350-1000 drive
calls instead of 70-100. Over `MAX_DEMOTIONS(10) x MAX_ITERATIONS(5) = 50`
outer iterations, this becomes 17,500-50,000 drive calls per thread.

### Factor 2: Thundering Herd (Duplicate Iteration Across Threads)

**Location:** `calculation.rs`, `propose_calculation()` (lines 86-102);
`answers_solver.rs`, `calculate_and_record_answer_iterative()` (lines
2289-2297).

**Mechanism:** `propose_calculation` uses add-to-set semantics for the
`Calculating` state: when multiple threads call it for the same binding,
each gets `Calculatable` and independently computes the answer. In
iterative mode, answers are stored in per-thread SCC-local iteration state
(line 2289: "Do NOT write to Calculation"), so the Calculation cell stays
in `Status::Calculating` throughout the entire iteration process.

This means there is no mechanism for Thread B to detect that Thread A has
already committed final answers. Thread B's iterative bypass (lines
341-378) reads from its own per-thread CalcStack's iteration state, never
checking the shared Calculation cells. Each thread runs the full
`MAX_ITERATIONS x MAX_DEMOTIONS` cycle independently.

**Contribution to hang:** With T threads, total work is approximately
`T x (single-thread work)`. With T = 9-15 and single-thread work already
amplified by Factor 1, this multiplies the total by another order of
magnitude.

### Factor 3: Mutex Contention on `Solver.variables`

**Location:** `solver.rs`, `force_var()` (lines 458-480),
`deep_force_mut()` (lines 518-522), `is_subset_eq_var()` (lines
1467-1477).

**Mechanism:** The `Solver` struct contains `variables: Mutex<Variables>`
which is shared across all threads. Every call to `force_var`,
`deep_force_mut`, and `is_subset_eq_var` acquires this mutex. During
iterative solving, `deep_force_mut` is called at line 2267 for every
member's answer on every iteration:

```rust
forced.visit_mut(&mut |x| self.current.solver().deep_force_mut(x));
```

Each `deep_force_mut` call acquires and releases the Variables mutex
multiple times (once per Var node in the type tree, up to TYPE_LIMIT=20
depth). With T threads contending on the same mutex, each lock acquisition
is delayed, inflating per-member cost from microseconds to milliseconds.

**Contribution to hang:** Under heavy contention, per-member cost of
~10-50ms is plausible. Combined with Factors 1 and 2, this produces:
`50 outer-iterations x 7 merges x 80 members x 20ms ≈ 5600s per thread`.

### Why This Explains Both Symptoms

**Hang (multi-thread only):** The three factors are multiplicative. With a
single thread, K (merges) is deterministic and typically small, there is
no thundering herd, and there is no mutex contention. Total work is
`50 x 1 x 76 x 0.001s ≈ 3.8s`. With multiple threads, the same work
becomes `50 x 7 x 80 x 0.02s ≈ 5600s`.

**Nondeterminism:** Different threads claim `Calculating` state at
different times via `propose_calculation`. This creates nondeterministic
`CycleDetected` outcomes, which lead to nondeterministic merge patterns,
different SCC compositions, different iteration orders, different
`force_var` write orderings in the shared Variables map, and ultimately
different committed answers via the first-write-wins race on
`record_value`.

**~5-10% repro rate:** Most runs get "lucky" merge patterns where K is
small. Unlucky runs where multiple threads trigger cascading merges
simultaneously experience the full blow-up.

---

## Proposed Fixes (Prioritized)

Correctness bugs should be fixed first, since they are simpler changes and
bugs #1 and #2 may reduce the severity of the amplification problem. After
that, Fix A is the highest-value change for addressing the hang.

### Phase 1: Correctness Bugs

1. **Bug #1 — `segment_size` fix.** Increment `segment_size` in the
   iterative bypass path. Smallest, most mechanical fix.
2. **Bug #2 — Absorption orphan fix.** Verify ancestor iteration driver
   exists before the absorption early-return. Potential direct hang fix.
3. **Bug #3 — Free-floating nodes fix.** Add free-floating nodes to
   `iterative.node_states` during `merge_sccs`. Straightforward addition.

### Phase 2: Work Amplification

4. **Fix A (highest value): Merge flag + defer Fresh resets.** Track whether
   a merge happened during the current drive loop. If a merge occurred,
   demote at the end of the iteration and *then* reset all members to Fresh
   as part of the demotion. This removes the K x N amplification from Factor
   1 by preventing mid-iteration merge events from resetting already-driven
   members. If merge amplification isn't controlled, the work can explode
   even with only ~10 threads, making Fixes B and C insufficient on their
   own.

5. **Fix B: Early-exit when another thread has committed.** During
   `drive_all_iteration_members`, before driving a member, check
   `calculation.get()` for that member. If another thread has already
   committed a final answer, skip re-solving. This reduces redundant work
   from Factor 2. Care is needed to ensure the skipped member's answer is
   still stored in SCC-local iteration state for convergence checking.

6. **Fix C: First-iterator-wins guard.** When entering
   `iterative_resolve_scc`, atomically mark the SCC (e.g. via an
   `AtomicBool` on the SCC's anchor `Calculation` cell). Other threads
   finding this mark should wait for the iterating thread to commit, then
   read the committed answers. This eliminates Factor 2 entirely but
   requires a wait/notify mechanism and is more invasive.

---

## Concrete Plan (v4)

This plan fixes the three correctness bugs first, since they are simpler
changes and bugs #1 and #2 may reduce the severity of the amplification
problem. After that, it addresses multi-thread work amplification. Each
step should keep legacy mode green.

### Phase 1 — Fix the three correctness bugs

1. **Fix `segment_size` asymmetry.**
   - Increment `segment_size` in the iterative bypass path before returning,
     or skip decrement in `pop()` for bypassed nodes.
   - Prevents inaccurate overlap detection that can trigger spurious merges.

2. **Prevent absorption orphaning.**
   - If `iterative_resolve_scc` sees `top_scc_detected_at != scc_identity`,
     verify an ancestor SCC is iterating before returning.
   - If no ancestor iterating SCC exists, continue with the merged SCC.

3. **Include free-floating nodes in `iterative.node_states`.**
   - After `merge_sccs` adds free-floating nodes to `node_state`, also insert
     them into `iterative.node_states` (as `Fresh`) if iteration is active.

### Phase 2 — Bound work per iteration (hang mitigation)

4. **Track a merge flag and defer Fresh resets.**
   - Add a `merge_happened` flag in `CalcStack` (or on the SCC) that is set
     whenever a merge occurs (membership back-edge merge or `merge_sccs`).
   - During a merge, *do not* reset iteration node states to Fresh. Only
     update the SCC membership (`node_state`) to include the new members and
     mark `merge_happened = true`.
   - Clear the flag at the start of each iteration.
   - After driving all members, if the flag is set, demote and *then* reset
     all members to Fresh (rebuilding iteration state). This converts the
     K×N amplification into a single demotion, which is already bounded by
     `MAX_DEMOTIONS`.

5. **Optional early-exit for committed members (if needed).**
   - Before driving a member, check `calculation.get()`.
   - If present, store it in `IterationNodeState::Done` and skip solving.
   - Only do this if Phase 2 still shows heavy duplication.

### Phase 3 — Only if nondeterminism persists

6. **First-iterator-wins guard (more invasive).**
   - Add a per-SCC atomic marker to ensure only one thread iterates an SCC.
   - Other threads wait for commit or fall back to legacy cycle-breaking.
   - This should remove cross-thread answer races entirely.

---

## Notes on Relationships

- Bugs (1) and (2) can directly increase merge frequency or leave SCCs
  orphaned, so they may contribute to hangs as well as correctness issues.
- Bug (3) is less likely to cause hangs, but it can affect convergence and
  error stability, contributing to nondeterminism.

## Additional Ideas (Optional)

- **Merge counter for observability.** In addition to the merge flag, a
  counter can be recorded (per-SCC or per-iteration) to quantify how many
  merges occur. This is useful for logging and profiling but is not required
  for correctness or to fix the hang.
