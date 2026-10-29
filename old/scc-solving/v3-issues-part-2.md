# Iterative Fixpoint SCC Solving — Continued Investigation (v4 Part 2)

This document continues from `v3-issues-part-1.md`. The three correctness bugs
and Fix A (merge flag + deferred Fresh resets) from Part 1 have been
implemented. Empirically, the fixes may have helped slightly, but **the hang
and nondeterminism still reproduce**.

Debugger investigation of a hanging run (with `lldb`) shows:
- All cores except one are stopped (no active mutex contention).
- The single active thread is in `iterative_resolve_scc` →
  `drive_all_iteration_members` → `drive_member` → cross-module
  `solve_idx_erased` → `get_module`.
- Multiple backtrace samples show the thread IS making progress (different
  stack frames each sample: `RwLock::read`, then `Arc::drop`, etc.), but it
  remains stuck in the same overall loop.
- There is only ONE `iterative_resolve_scc` frame on the stack (no nested
  iterative driver active at the time of sampling).
- Single-threaded mode (`RAYON_NUM_THREADS=1`) completes in ~3 seconds for
  the same library.

This rules out two of the three factors from Part 1's work amplification
theory:
- **Factor 2 (thundering herd)** is not active: only one thread is running.
- **Factor 3 (mutex contention)** is not active: all other threads are stopped.

Since single-threaded solving takes ~3s, a 5000s hang cannot be explained by
a large-but-bounded SCC alone. Something about multi-threaded state from
earlier in the process must be causing the single remaining thread to do
enormously more work, or to loop indefinitely.

---

## Remaining Bug: Inverted Merge Priority

**Location:** `answers_solver.rs`, membership back-edge merge in `push()`
(line 279) vs `merge_sccs()` (line 914).

**Problem:** The two merge call sites construct `sccs_to_merge` in opposite
orders, which causes `Scc::merge_many` to give priority to different SCCs:

**`merge_sccs` (legacy path, line 914):**
```rust
// Pop from top of stack → sccs_to_merge = [top, ..., bottom]
while let Some(scc) = scc_stack.pop() {
    sccs_to_merge.push(scc);
    if is_target { break; }
}
```
`merge_many` takes `first = top SCC`. In `Scc::merge(self=top, other=next)`,
`self`'s iteration states are inserted unconditionally, `other`'s use
`or_insert`. **Top SCC gets priority.**

**Membership back-edge merge (line 279):**
```rust
// Drain from index → sccs_to_merge = [bottom, ..., top]
let sccs_to_merge: Vec<Scc> = scc_stack.drain(scc_idx..).collect();
```
`merge_many` takes `first = bottom SCC`. In `Scc::merge(self=bottom, other=next)`,
`self`'s iteration states are inserted unconditionally. **Bottom SCC gets
priority.**

**Why the top SCC should get priority:** The top SCC is the one currently being
iterated by `drive_all_iteration_members`. Its iteration states represent the
current iteration's progress: `Done` members have been driven, `Fresh` members
haven't yet. If a lower SCC happens to have a `Fresh` entry for a CalcId that
the top SCC has as `Done`, the inverted priority would reset it to `Fresh`,
causing the while loop to re-drive it.

In practice, this can only happen if the same CalcId is in two different
iterating SCCs' `iterative.node_states` simultaneously. The membership
back-edge merge itself prevents this from happening in most cases (the merge
fires precisely because two SCCs share a member, collapsing them into one).
However, the inconsistency is wrong as a matter of code correctness, and in
edge cases involving multi-threaded Phase 0 timing, it could contribute to
nondeterminism.

**Fix:** Reverse the drain in the membership back-edge merge to match
`merge_sccs`'s order:
```rust
let mut sccs_to_merge: Vec<Scc> = scc_stack.drain(scc_idx..).collect();
sccs_to_merge.reverse(); // Now [top, ..., bottom], matching merge_sccs
```

---

## New Theory: Nested Absorption Crash → Rayon Deadlock

### The Scenario

When a nested `iterative_resolve_scc` (called from within a parent's
`drive_member` → `get_idx` → `pop_and_drain_completed_sccs`) absorbs the
parent SCC via a membership back-edge merge, the parent's iteration driver is
left with an empty `scc_stack` and panics. In the context of rayon, this panic
is caught by `catch_unwind`, but it can leave the system in a state where the
panicked thread's unfinished work causes other threads to hang.

### Detailed Trace

Consider two SCCs: A (parent, iterating) and B (nested, discovered during
A's drive loop):

1. **Parent driver starts.** `iterative_resolve_scc(A)` calls
   `set_fresh_iteration_state`, pushes A → `scc_stack = [A]`.

2. **Parent drives members.** `drive_all_iteration_members` picks member M,
   calls `drive_member(M)` → `get_idx(M)`.

3. **M's computation discovers a new SCC.** `K::solve(M)` requires dependency
   D. D's computation discovers a true cycle → Phase 0 creates SCC B.

4. **Nested driver starts.** `pop_and_drain_completed_sccs` drains B (line
   2168-2172). Since B has `break_at` entries and iterative mode is active,
   `iterative_resolve_scc(B)` is called. B is pushed →
   `scc_stack = [A, B]`. Both A and B are iterating.

5. **B's drive loop hits a member of A.** While driving B's members, a
   dependency on CalcId F (which is in A's `node_state`) is encountered.
   `push(F)` → `find_iterating_scc_containing(F)` finds A at index 0.
   A is non-top → membership back-edge merge fires.

6. **Merge consumes A.** `scc_stack.drain(0..)` produces `[A, B]`.
   `merge_many([A, B], A.detected_at)` produces `merged(A,B)`.
   `scc_stack = [merged(A,B)]`.

7. **B detects absorption.** After `drive_all_iteration_members` returns, B's
   driver checks `top_scc_detected_at()`. The merged SCC's `detected_at` is
   `min(A.detected_at, B.detected_at) = A.detected_at` (A was discovered
   first). This differs from B's `scc_identity` → absorption detected.

8. **`has_ancestor_iterating_scc()` returns false.** The scc_stack has only
   one element `[merged(A,B)]`. The check at line 1264 scans
   `scc_stack[..len-1]` which is empty → `false`.

9. **B takes over the merged SCC.** B updates its `scc_identity` to
   `A.detected_at` and continues driving the merged SCC (all of A's and B's
   members). B eventually converges, calls `commit_final_answers(merged(A,B))`,
   which commits all members' answers to the shared Calculation cells.
   B pops the merged SCC → `scc_stack = []`. B's `iterative_resolve_scc`
   returns.

10. **Control returns to A's call chain.** B's `iterative_resolve_scc` was
    called from within A's `get_idx(D)` (via `pop_and_drain_completed_sccs`).
    `get_idx(D)` returns D's answer. `K::solve(M)` continues, eventually
    completes. `calculate_and_record_answer(M)` runs.

11. **M takes the legacy path.** At line 2215,
    `get_iteration_node_state(&current)` checks the top SCC's iteration state.
    But `scc_stack` is empty → returns `None`. M falls through to the legacy
    (non-SCC) path, which commits M's answer directly to the Calculation cell
    via `record_value`.

12. **Pop returns to A's drive loop.** `pop_and_drain_completed_sccs` pops M
    from the CalcStack. No SCCs to drain. Back in `drive_all_iteration_members`,
    `next_fresh_member()` → `scc_stack.last()` returns `None` → loop ends.

13. **A's driver panics.** Back in `iterative_resolve_scc`, line 2708:
    `self.stack().top_scc_detected_at()` calls
    `.expect("top_scc_detected_at: SCC stack is empty")` → **panic**.

### Why This Could Cause a Hang (Not Just a Crash)

Rayon catches the panic via `catch_unwind`. The rayon worker thread survives
and can execute other tasks. However:

- The panicking thread's CalcStack is in an inconsistent state. If the thread
  had pushed CalcIds onto the CalcStack that were never popped (because the
  panic unwound through `get_idx` frames that normally pop in their epilogue),
  those CalcIds' `position_of` entries become stale.

- If the thread is later reused by rayon for another task that shares the same
  `ThreadState`, the stale CalcStack state can cause spurious cycle detection
  (via `current_cycle()` seeing stale entries in `position_of`), incorrect SCC
  merges, or infinite loops.

- Even if the CalcStack is not reused, if any CalcIds were mid-computation
  (pushed but not popped, with `Calculating` status in their Calculation cells
  but no committed answer), other threads waiting for those CalcIds via
  `propose_calculation` would see `CycleDetected` forever and may never make
  progress.

Note: Step 9 commits all members of the merged SCC, so MOST CalcIds should
have committed answers. The risk is limited to CalcIds that were on the
CalcStack between the merge point and the panic point (e.g., M itself and any
CalcIds pushed during M's `K::solve` that were not part of the merged SCC).

### Conditions for Triggering

This scenario requires:
1. A parent `iterative_resolve_scc(A)` is active.
2. A member of A's drive loop triggers a nested `iterative_resolve_scc(B)`.
3. B's iteration discovers a dependency that is a member of A.
4. A's SCC is at the bottom of the range drained by the membership back-edge
   merge (so `has_ancestor_iterating_scc` finds nothing below).

This is realistic in codebases with circular module imports, where bindings
in module M1 depend on bindings in module M2 and vice versa. The cross-module
`solve_idx_erased` path creates exactly this pattern.

### Relationship to ~5-10% Repro Rate

The scenario depends on thread scheduling: whether other threads' earlier
`propose_calculation` calls created `CycleDetected` results that caused the
nested SCC B to form with members that cross back to A. Different thread
orderings produce different Phase 0 SCC compositions.

---

## Bounded Work Analysis (Inner While Loop)

Despite the hang, the inner while loop in `drive_all_iteration_members` IS
bounded after Fix A:

1. `push()` marks Fresh → InProgress (line 321).
2. `calculate_and_record_answer_iterative()` always calls
   `set_iteration_node_done()` (line 2438-2439).
3. `Scc::merge()` preserves existing Done/InProgress states via `or_insert`
   (lines 1786-1791). Only genuinely new members are added as `Fresh`.
4. Each CalcId transitions Fresh → InProgress → Done exactly once per inner
   loop call.

Total drive_member calls per `drive_all_iteration_members` invocation: at
most N (total SCC members after all merges in that call).

The outer loop is bounded by `MAX_ITERATIONS(5) × (MAX_DEMOTIONS(10) + 1)`
= ~55 iterations, plus up to 10 demotion restarts = ~65 total loop
iterations. `check_demotion_limit` panics after 10 demotions.

Total work per `iterative_resolve_scc` call: ≤ 65 × N drive_member calls.
At single-threaded per-member cost (~0.3ms), this is ≤ 65 × 3s = ~195s even
if ALL bindings end up in one SCC. The 5000s hang timing exceeds this bound,
supporting the theory that the hang is caused by a crash → deadlock rather
than bounded-but-large work.

### False CycleDetected Does Not Inflate SCCs

An earlier theory suggested that multi-threaded `CycleDetected` races (from
`propose_calculation`'s add-to-set semantics) could inflate SCC membership.
Code review shows this does NOT happen:

When `propose_calculation` returns `CycleDetected` but `current_cycle()`
returns `None` (CalcId not on the current thread's CalcStack), the code at
lines 441-461 handles it:
- In iterative mode with the CalcId in the top SCC's iteration state:
  `NeedsColdPlaceholder` (no SCC created).
- Otherwise: `Calculate` (computed normally, no SCC created).

SCCs are only created via `on_scc_detected`, which requires
`current_cycle()` to return `Some` — meaning the CalcId genuinely appears
twice on the current thread's CalcStack. Multi-threaded `CycleDetected` from
other threads' `Calculating` state does not trigger `on_scc_detected`.

---

## Proposed Fixes

### Fix D: Guard Against Nested Absorption Crash (Critical)

In `iterative_resolve_scc`, after `drive_all_iteration_members` returns,
check whether the scc_stack is empty or the parent SCC was consumed by a
nested driver before calling `top_scc_detected_at()`:

```rust
// After drive_all_iteration_members():
if self.stack().scc_stack_is_empty() {
    // Our SCC was absorbed and committed by a nested iteration driver.
    // All members have been committed. Nothing left to do.
    return;
}
```

This prevents the panic. The nested driver (B) has already committed all
members of the merged SCC, so the parent driver (A) can safely return.

Additionally, check for the case where the scc_stack is non-empty but the
top SCC is not the one we pushed (another SCC was pushed on top during the
drive loop and the original was merged away):

```rust
if self.stack().top_scc_detected_at() != scc_identity {
    if self.stack().has_ancestor_iterating_scc() {
        return; // Ancestor will handle it.
    }
    // Check if our SCC still exists on the stack at all.
    // If not, a nested driver committed it.
    if !self.stack().scc_stack_contains_detected_at(&scc_identity) {
        return; // Committed by nested driver.
    }
    // Our SCC was merged but is still on the stack (detected_at changed).
    // Continue with the updated identity.
    scc_identity = self.stack().top_scc_detected_at();
}
```

### Fix E: Correct Inverted Merge Priority

In the membership back-edge merge in `push()`, reverse the drained vec
before calling `merge_many`:

```rust
let mut sccs_to_merge: Vec<Scc> = scc_stack.drain(scc_idx..).collect();
sccs_to_merge.reverse();
```

This makes the top SCC (currently being iterated) appear first in
`merge_many`, giving it priority — matching the behavior of `merge_sccs`.

### Fix B (from Part 1): Early-Exit for Committed Members

If Fix D resolves the hang, Fix B becomes less urgent. But it remains
valuable for performance: before driving a member in
`drive_all_iteration_members`, check `calculation.get()`. If another thread
has already committed a final answer, store it in
`IterationNodeState::Done` and skip re-solving. This reduces redundant work
when multiple threads independently iterate overlapping SCCs.

---

## Debugging Checklist

To confirm or refute the nested absorption theory, check the following
from the debugger or via instrumentation:

1. **Are there panicking/dead rayon tasks?** Check rayon's panic log or
   add `catch_unwind` instrumentation around `iterative_resolve_scc`.

2. **What are `iteration` and `demotions` in `iterative_resolve_scc`'s
   local variables?** If they are within normal bounds (iteration ≤ 5,
   demotions ≤ 10), the outer loop is not the problem. If they are 0/0
   (never incremented), the thread might be stuck in the first
   `drive_all_iteration_members` call.

3. **How big is the SCC?** Check the size of the top SCC's
   `iterative.node_states`. If it's thousands of entries, the bounded
   work might be large enough to explain part of the delay. If it's
   small (< 100), the work should complete quickly.

4. **Is the CalcStack clean?** Check `position_of` for stale entries
   from a previous panic. Stale entries would cause spurious
   `current_cycle()` results and incorrect SCC detection.

5. **Are there CalcIds stuck in `Calculating` with no committed answer?**
   If a previous panic left CalcIds in this state, other threads' attempts
   to compute them via `propose_calculation` would return `CycleDetected`
   without a true cycle, potentially causing the thread to spin on
   placeholder creation without progress.
# Solution Sketch: Nested Absorption Fix (Staff → Senior → Review)

## 1) Staff Engineer Plan (high-level)

**Goal:** Prevent nested absorption from leaving the SCC stack empty or "owned by nobody," which can panic and cause downstream hangs.

### A. Fix correctness/liveness in `iterative_resolve_scc`
- Add **post-drive safety checks**:
  - If the SCC stack is empty after `drive_all_iteration_members`, return early.
  - If the top SCC identity changed, verify an ancestor driver exists.
    - If no ancestor exists, check whether the top SCC absorbed our members
      (by testing if our original `detected_at` CalcId is in the top SCC's
      `node_state`).
      - If yes, our SCC was merged into the top SCC — update `scc_identity`
        and continue driving.
      - If no, our SCC was committed by a nested driver and an unrelated SCC
        remains on the stack — return.
- This preserves the invariant that each SCC has *exactly one* driver and prevents a driver from panicking after its SCC was fully absorbed/committed by a nested driver.

### B. Align merge priority in membership back-edge merges
- Reverse the drained vector so the **top SCC gets merge priority**.
- Low risk: simply matches the order used in `merge_sccs`.

### C. (Optional performance) Avoid redundant work
- Before driving a member, check if its Calculation already has a committed answer. If so, mark it Done and skip.
- Not required for correctness, but reduces thread-level redundant work.

### D. Testing
- Add a regression test to exercise "nested absorption → empty stack" if feasible.
  A unit test that directly manipulates `CalcStack`/`Scc` state may be more
  practical than an end-to-end test, since triggering this scenario requires
  cross-module cycles with specific thread scheduling.

---

## 2) Senior Engineer (Claude agent) Implementation Sketch

**Primary target:** `answers_solver.rs`

### Step 0: Add new `CalcStack` helper methods

Two methods referenced by Steps 1 and 2 do not exist yet and must be added
to `CalcStack`:

```rust
/// Returns true if the SCC stack has no entries.
fn scc_stack_is_empty(&self) -> bool {
    self.scc_stack.borrow().is_empty()
}

/// Returns true if the top SCC's `node_state` contains the given CalcId.
///
/// Used after nested absorption to distinguish two cases:
/// - Our SCC was merged into the top SCC (detected_at changed, but our
///   members are in the top SCC's node_state) → continue driving.
/// - Our SCC was committed by a nested driver, and an unrelated SCC
///   remains on top → return.
///
/// This works because `detected_at` is always a member of the SCC's
/// `node_state`, and merges union the `node_state` maps. Within a single
/// thread's `scc_stack`, SCCs are disjoint (overlapping membership
/// triggers a merge), so an unrelated SCC will not contain our CalcId.
fn top_scc_contains_member(&self, calc_id: &CalcId) -> bool {
    self.scc_stack
        .borrow()
        .last()
        .map(|scc| scc.node_state.contains_key(calc_id))
        .unwrap_or(false)
}
```

**Borrow discipline note:** Both methods acquire and immediately release a
shared borrow on `scc_stack`. Call sites must not hold an existing borrow
on `scc_stack` when calling these methods.

### Step 1: Guard against empty stack after drive
In `iterative_resolve_scc` after `drive_all_iteration_members()`:

```rust
if self.stack().scc_stack_is_empty() {
    // Nested driver absorbed and committed our SCC.
    return;
}
```

### Step 2: Safe absorption handling
Replace the current absorption check:

```rust
if self.stack().top_scc_detected_at() != scc_identity {
    if self.stack().has_ancestor_iterating_scc() {
        return;
    }
    // Our detected_at changed. Check whether the top SCC absorbed our
    // members (merge case) or whether our SCC was committed by a nested
    // driver and an unrelated SCC remains.
    //
    // We check if the top SCC's node_state contains our original
    // detected_at CalcId. After a merge, the merged SCC's node_state
    // contains all members from both SCCs, so our CalcId will be present.
    // An unrelated SCC (e.g. a Phase 0 SCC that was below us on the
    // stack) will not contain it.
    if !self.stack().top_scc_contains_member(&scc_identity) {
        // The top SCC doesn't contain our member. Our SCC was committed
        // by a nested driver; the remaining SCC is unrelated.
        return;
    }
    // The top SCC absorbed our SCC via merge. Continue driving with the
    // updated identity.
    scc_identity = self.stack().top_scc_detected_at();
}
```

**Why `top_scc_contains_member` instead of `scc_stack_contains_detected_at`:**
An earlier draft used `scc_stack_contains_detected_at(&scc_identity)` to check
whether our original `detected_at` still appeared on any SCC in the stack. This
is wrong: when our SCC is merged with another SCC that has a *smaller*
`detected_at`, the merged SCC's `detected_at` becomes that smaller value. Our
original `scc_identity` no longer appears as any SCC's `detected_at`, so the
check returns false — and the driver returns early, orphaning the merged SCC
with no driver. This is the exact bug we're trying to fix.

The `top_scc_contains_member` check avoids this by testing *membership* (which
survives merges) rather than *identity* (which changes on merge).

**Why "unrelated SCC remaining" is possible:** During Phase 0, the DFS can
discover SCC X before SCC A. X sits below A on `scc_stack` (lower index). If
X is not iterating (`iterative: None`), `has_ancestor_iterating_scc()` returns
false. After a nested driver commits and pops merged(A,B), `scc_stack = [X]`.
X is now the top, but it's an unrelated Phase 0 SCC that has its own lifecycle.
Without the `top_scc_contains_member` check, the driver would take over X and
drive/commit it incorrectly.

### Step 3: Fix merge priority
In membership back-edge merge in `push()`, reverse the drain to match the
order used by `merge_sccs`:

```rust
let mut sccs_to_merge: Vec<Scc> = scc_stack.drain(scc_idx..).collect();
sccs_to_merge.reverse(); // match merge_sccs order: top SCC first
let sccs_to_merge = Vec1::try_from_vec(sccs_to_merge)
    .expect("membership back-edge: at least the found SCC must be present");
let detected_at = sccs_to_merge.first().detected_at.dupe();
let mut merged = Scc::merge_many(sccs_to_merge, detected_at);
```

**Why reverse:** `Scc::merge(self, other)` gives `self`'s iteration states
priority (inserted unconditionally; `other`'s use `or_insert`). `merge_many`
folds from the first element, so the first element becomes the initial `self`.

- `merge_sccs` pops from the top of the stack → `[top, ..., bottom]` → top is
  initial accumulator → **top SCC wins**.
- `push()` back-edge drains in stack order → `[bottom, ..., top]` → bottom is
  initial accumulator → **bottom SCC wins** (inverted).

The reversal makes both paths consistent. The `detected_at` outcome is
unaffected because `Scc::merge` always takes `min(self, other)`.

### Step 4 (Optional): Early exit if already committed
In `drive_all_iteration_members()` before driving a member:
- If `calculation.get()` already has a committed answer, store it in
  `IterationNodeState::Done` and skip re-solving.

---

## 3) Known Consequences and Edge Cases

### Double-commit for in-flight CalcIds

After nested driver B commits the merged SCC, control returns up through A's
call chain: `get_idx(D)` → `calculate_and_record_answer(D)` →
`calculate_and_record_answer(M)`. At this point `scc_stack` is empty, so both
D and M take the legacy (non-iterative) commit path via `record_value`.

Both D and M were already committed by B. Here's why: when B's drive loop
first finishes, M is still `InProgress` (M was being driven by A when the
nested SCC formed). This sets `merge_happened = true` → `demoted = true`.
B's outer loop restarts at iteration 1, `set_fresh_iteration_state` resets
ALL members (including M) to `Fresh`. B's next drive loop picks up M,
drives it to `Done`. B eventually converges and calls `commit_final_answers`,
which requires ALL members to be `Done` (it panics on `Fresh` or `InProgress`
members). So both D and M are committed by B.

When A's in-flight `K::solve(M)` completes and `calculate_and_record_answer(M)`
runs, the `scc_stack` is empty so M takes the legacy commit path. This is a
double-write — a no-op via `record_value`'s first-write-wins semantics.
Similarly for D.

Neither case causes a hang. The legacy path does not apply iterative error
suppression, but since B already committed the authoritative answers, A's
legacy writes are no-ops and the errors from A's computation are discarded
(they go to the error context of an already-committed binding).

**TODO:** Verify that `record_value` / `Calculation` uses first-write-wins
semantics (or is otherwise safe for double-writes). If it panics or overwrites,
a guard is needed.

### CalcStack double-push for M

When B drives M during its restarted iteration, `push(M)` adds a second entry
to `position_of[M]`. A's original entry is still present because A's
`K::solve(M)` hasn't returned yet (A's CalcStack frame for M was never popped).
This means `position_of[M]` temporarily has two positions.

This is safe: the iterative bypass in `push()` handles M by checking the top
SCC's iteration state and returning `Calculate` — it returns before
`pre_calculate_state` or `current_cycle()` are reached, so the duplicate
position is never used for cycle detection. And `pop()` properly removes only
the most recent entry via `positions.pop()`.

### CalcStack cleanliness after early return

After the Step 1 early return, the CalcStack's raw `stack` is clean: all
CalcIds pushed during `drive_all_iteration_members` were popped as their
computations completed (each `get_idx` call pushes and pops). The in-flight
CalcIds (D, M) complete and pop during the normal unwind of the call chain
before the driver reaches the empty-stack check.

---

## 4) Reviewer Checklist

**Correctness:**
- `iterative_resolve_scc` never calls `top_scc_detected_at()` when the stack can be empty.
- If a nested driver committed the SCC, the parent driver returns without committing again.
- If the SCC is still on stack but its `detected_at` changed, the driver continues correctly.
- The `top_scc_contains_member` check correctly distinguishes "merge changed detected_at"
  from "SCC committed and unrelated SCC remains."

**Merge Priority:**
- Membership back-edge merge order matches `merge_sccs`.
- `merge_many` gives priority to the top SCC's iteration state.

**No silent fallbacks:**
- Unreachable paths use `expect` / `unreachable!` as per project guidelines.

**Borrow safety:**
- New helper methods acquire and release borrows atomically; call sites do not
  hold overlapping borrows on `scc_stack`.

**Perf + determinism:**
- Optional early-commit skip doesn't change convergence semantics.

**Testing:**
- Existing tests still pass.
- Any regression test exercises nested absorption and avoids panic.

---

## 5) Observability (Optional, Likely Not Landed)

These are useful during development and debugging but would typically be
removed before landing:

- `tracing::debug!` when Step 1 fires (empty stack → nested driver committed).
- `tracing::debug!` when Step 2's `top_scc_contains_member` returns false
  (SCC committed by nested driver, unrelated SCC remains).
- A merge counter per `iterative_resolve_scc` invocation to quantify how many
  merges occur during a single drive loop.
