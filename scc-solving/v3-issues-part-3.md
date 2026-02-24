# Iterative Fixpoint SCC Solving — Root Cause Found (v4 Part 3)

This document continues from `v3-issues-part-2.md`. Fixes A through E from
Parts 1 and 2 have been implemented. The hang still reproduced at a reduced
rate (~2.5%, down from ~10%). This session identified the **root cause** of
the remaining infinite loop.

---

## Root Cause: `solve_idx_erased` Returns `true` for Evicted Answers

**Location:** `state/state.rs`, `solve_idx_erased` method in the
`LookupAnswer` impl (line ~2583), and `lookup_target_answers` (line ~2289).

### The Bug

When `drive_all_iteration_members` drives a cross-module SCC member, it
calls `solve_idx_erased`, which routes to the target module's `Answers` to
construct a temporary `AnswersSolver` and call `get_idx`. The `get_idx` call
goes through the iterative bypass in `push()`, which transitions the member
from `Fresh` → `InProgress`, and `calculate_and_record_answer_iterative`
transitions it to `Done`. This is the correct path.

However, `solve_idx_erased` first calls `lookup_target_answers`, which reads
the target module's `Steps` under a shared lock. If another thread has
concurrently run `demand(Step::Solutions)` on the target module, that thread
evicts the `Answers` step as a memory optimization (`steps.answers.take()`).
When our thread reads `steps.answers`, it finds `None`.

The `lookup_target_answers` method handles this via `TargetAnswers::Evicted`,
and `solve_idx_erased` returns `true` for the `Evicted` case — indicating
"the operation was handled." But **no `get_idx` was called**, so no
`set_iteration_node_done` was called. The member's iteration state remains
**Fresh**.

```rust
fn solve_idx_erased(&self, calc_id: &CalcId, thread_state: &ThreadState) -> bool {
    let CalcId(_, ref any_idx) = *calc_id;
    match self.lookup_target_answers(calc_id) {
        TargetAnswers::ModuleNotFound => false,
        TargetAnswers::Evicted => true,   // ← BUG: returns true without driving
        TargetAnswers::Available { .. } => {
            // ... constructs solver, calls get_idx ...
            true
        }
    }
}
```

Back in `drive_all_iteration_members`, the member is still `Fresh`.
`next_fresh_member()` returns it again on the next iteration. The same
`Evicted` result occurs (the answers remain evicted). **The loop never
terminates.**

### Why This Causes an Infinite Loop (Not Just Bounded Extra Work)

Unlike the scenarios analyzed in Part 2 (where each member transitions
`Fresh → InProgress → Done` exactly once), the `Evicted` path creates a
member that is **permanently Fresh**. No amount of re-driving can change its
state because the code path that would change it (`get_idx` →
`calculate_and_record_answer_iterative` → `set_iteration_node_done`) is
never reached.

The safety limit added in this session (panic after 10× max SCC size drives)
now catches this and terminates with a diagnostic dump instead of hanging
indefinitely.

### Thread Scheduling Dependency (~2.5% Repro Rate)

The `Evicted` case requires a specific multi-threaded timing:

1. Thread A starts iterative SCC solving for an SCC that spans multiple
   modules (e.g., `steam.chat`, `steam.group`, `steam.message`).
2. Thread B independently runs `demand(Step::Solutions)` on one of those
   modules (e.g., `steam.group`), which solves all keys and then evicts
   `Answers` as a memory optimization.
3. Thread A's `drive_all_iteration_members` picks a cross-module member
   from `steam.group` and calls `solve_idx_erased`.
4. `lookup_target_answers` reads `steps.answers` → `None` (evicted by
   Thread B) → returns `Evicted`.
5. The member stays `Fresh` forever.

This timing is uncommon because it requires another thread to evict the
answers *during* iterative SCC resolution, which only happens in codebases
with cross-module cycles where different threads process overlapping module
sets.

---

## Diagnostic Evidence

### Panic Output from Reproduction (Run 29/50)

The post-drive invariant check (added during this debugging session) caught
the bug on the 29th run of `pyrefly check` on the `steam.py` project with
`PYREFLY_SCC_MODE=iterative-fixpoint RAYON_NUM_THREADS=32`:

```
drive_all_iteration_members: member CalcId(steam.group, .../steam/group.py,
  KeyClassMetadata(class0)) is still Fresh after drive #15
  (CalcStack depth=0, scc_stack depth=1)
```

### Iteration State Dump

```
scc_stack depth=1
top SCC: detected_at=CalcId(steam.chat, .../steam/chat.py,
  Key(Idx { idx: 233 })), anchor_pos=0, segment_size=1,
  node_state_len=76, has_iterative=true
iteration: total=76, fresh=4, in_progress=0, done=72,
  iter=5, merge=false, demoted=false, changed=true
fresh: CalcId(steam.group,   .../steam/group.py,   KeyClassMetadata(1))
fresh: CalcId(steam.message,  .../steam/message.py, KeyClassMetadata(2))
fresh: CalcId(steam.message,  .../steam/message.py, KeyClassMetadata(3))
fresh: CalcId(steam.chat,     .../steam/chat.py,    KeyClassMetadata(5))
```

### Key Observations

1. **All 4 stuck-Fresh members are cross-module `KeyClassMetadata` indices.**
   These go through `solve_idx_erased` for cross-module driving, which is
   where the `Evicted` path is hit.

2. **72 out of 76 members are Done.** The SCC is functioning correctly for
   same-module members and cross-module members whose answers haven't been
   evicted.

3. **`iter=5, changed=true`** — the iterative driver reached `MAX_ITERATIONS`
   and broke out multiple times (many "exceeded 5 iterations" warnings in
   stderr), but could never converge because these 4 members were never
   driven to completion.

4. **`CalcStack depth=0`** — the CalcStack is fully unwound. `drive_member`
   called `solve_idx_erased`, which returned `true` (Evicted) without
   pushing anything onto the CalcStack. No `get_idx` was called, so no
   frame was pushed or popped.

5. **Multiple threads hit the panic.** Two dump_iteration_state outputs
   appear with different `anchor_pos` values (0 and 3), confirming that
   two rayon threads independently encountered the same SCC with the same
   stuck-Fresh members.

---

## How the Root Cause Was Found

### Debugging Approach

The investigation spanned three sessions with extensive code analysis:

1. **Session 1-2:** Identified and fixed 6 correctness bugs (A-E plus the
   segment_size asymmetry fix). These reduced the hang rate from ~10% to
   ~2.5% but did not eliminate it. Extensive theoretical analysis ruled out
   many potential causes (recursion limits, cross-thread CycleDetected,
   merge state overwriting, set_iteration_node_done writing to wrong SCC).

2. **Session 3 (this session):** Shifted from theoretical analysis to
   **observational debugging**:

   a. Added a **post-drive invariant check** in `drive_all_iteration_members`
      that panics if any member is still `Fresh` after being driven. This
      directly catches the symptom (permanent Fresh) rather than trying to
      reason about all possible causes.

   b. Added a **safety limit** (panic after 10× max SCC size drives) as a
      secondary catch.

   c. Ran 50 reproduction attempts on the original failing workload
      (`steam.py` with `PYREFLY_SCC_MODE=iterative-fixpoint
      RAYON_NUM_THREADS=32`).

   d. Run 29 triggered the panic. The diagnostic dump showed **4 cross-module
      `KeyClassMetadata` members stuck as Fresh** with `CalcStack depth=0`.

   e. Traced the cross-module driving path: `drive_member` →
      `solve_idx_erased` → `lookup_target_answers`. The `CalcStack depth=0`
      indicated that `get_idx` was never called — the code returned early.

   f. Read `lookup_target_answers` and found the `Evicted` case: when
      another thread evicts the target module's `Answers`, `solve_idx_erased`
      returns `true` without performing any computation.

### Why Previous Analysis Missed This

All previous analysis focused on the single-thread mechanics of the
CalcStack, SCC merge, and iteration state. The `Evicted` case is invisible
from that perspective because it involves **cross-thread module lifecycle
events** (answer eviction) that are orthogonal to the SCC solving algorithm.

The key insight was that `solve_idx_erased` has a "silently succeed" path
(`Evicted → true`) that bypasses all of the iterative SCC machinery. This
violates the invariant that `drive_member` always transitions a Fresh member
to InProgress or Done.

---

## Proposed Fix

The fix must ensure that when `solve_idx_erased` encounters the `Evicted`
case for a member that is in the iterative SCC's state, the member is
still marked as `Done` in the iteration state.

### Option A: Mark Done in `drive_member` (Recommended)

After calling `solve_idx_erased`, check the member's iteration state. If
it's still `Fresh`, the drive was a no-op (e.g., `Evicted`). Since the
answers have already been computed and committed by another thread, mark
the member as `Done` with the globally available answer.

This requires reading the answer from the `Calculation` cell, which is
type-erased at this point. The `solve_idx_erased` / `lookup_target_answers`
mechanism could be extended to return the answer for the `Evicted` case,
or a separate method could read it.

### Option B: Handle in `solve_idx_erased` Directly

Modify `solve_idx_erased` in `state.rs` to, for the `Evicted` case,
read the answer from the target module's `Solutions` (which exist when
`Evicted` is returned) and call `set_iteration_node_done` on the
`thread_state`'s CalcStack.

This keeps the fix localized to `state.rs` but requires `solve_idx_erased`
to be aware of iteration state, which it currently is not.

### Option C: Skip Evicted Members in `drive_all_iteration_members`

After driving a member, if it's still `Fresh`, remove it from the
iteration state (or mark it Done with a sentinel answer). This is the
simplest fix but may lose convergence information.

### Considerations

- The `Evicted` case means `Solutions` exist — all answers are already
  committed to `Calculation` cells. The iterative SCC's convergence is
  not affected because the member's answer will not change between
  iterations (it's already finalized).
- The simplest correct approach may be to have `solve_idx_erased` return
  a tri-state: `Driven`, `Evicted`, or `NotFound`. Then `drive_member`
  can handle the `Evicted` case by marking the member Done without an
  answer (skipping convergence comparison for this member, since its
  answer is already final).
