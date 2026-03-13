# SCC Stack Invariants and the Stale `anchor_pos` Bug

This document records our current understanding of invariants around the SCC
stack in `answers_solver.rs`, and a production bug involving panics in
`set_iteration_node_done` (and likely also `mark_iteration_changed`) that has
been observed in LSP mode.

## Background: Two-Phase SCC Resolution

Pyrefly resolves cyclic dependencies using a two-phase process managed by the
`CalcStack` and its `scc_stack`.

**Phase 0 (discovery)**: As `get_idx` calls recurse, nodes are pushed onto the
`CalcStack`. When a cycle is detected (a node appears twice on the stack),
`on_scc_detected` creates an `Scc` struct with `iterative: None` and pushes it
onto `scc_stack`. Cycle members get placeholder values and continue computing.
The SCC is considered complete when the anchor node's `on_calculation_finished`
call satisfies `stack_len <= anchor_pos + 1` — i.e., the CalcStack has unwound
back to (or past) the anchor's position. At that point the SCC is moved to
`pending_completed_sccs` and drained by `pop_and_drain_completed_sccs` in the
anchor's `get_idx` frame.

**Iterative phase**: `iterative_resolve_scc` takes the completed Phase-0 SCC,
sets up fresh iteration state (`iterative: Some(...)`), and calls
`push_scc` to put it back on `scc_stack`. It then drives all members via
`drive_all_iteration_members`, iterating until answers converge or
`MAX_ITERATIONS` is exceeded, then commits final answers via
`commit_final_answers`.

## The `anchor_pos` Invariant and How It Breaks

### What `anchor_pos` means in Phase 0

During Phase 0, `anchor_pos` is the CalcStack position of the anchor node's
**first** occurrence. The completion check:

```rust
if stack_len <= scc.anchor_pos + 1 { /* SCC is complete */ }
```

is sound in Phase 0 because:

- The anchor is the shallowest (outermost) SCC member frame.
- All deeper member frames have already returned before the anchor's frame
  begins returning.
- `on_calculation_finished` is called while the anchor frame is still on the
  CalcStack, so `stack_len = anchor_pos + 1` at completion time.
- No SCC member frames exist below the anchor, so no frames can interact with
  the SCC after it completes.

### What breaks during iterative solving

When `iterative_resolve_scc` calls `push_scc`, the SCC is pushed back with its
**original Phase-0 `anchor_pos`** unchanged. During iterative solving, however,
the CalcStack starts from whatever depth it was at when the Phase-0 anchor's
`get_idx` frame called `pop_and_drain_completed_sccs`. This is typically much
shallower than the Phase-0 depth.

For example: if the Phase-0 anchor was at CalcStack position 50, but during
iterative solving the CalcStack has only 3 frames (the outer context frames),
the iterating SCC on `scc_stack` still has `anchor_pos = 50`.

### The premature-pop trigger

During iterative solving, `drive_all_iteration_members` calls `get_idx` for
each member. A member's `K::solve` may call `get_idx` on dependencies that are
**not** in the iterating SCC and **not** yet cached. If such a dependency chain
forms a **new Phase-0 cycle** (SCC_T), `on_scc_detected` pushes SCC_T on top
of the iterating SCC_S.

When SCC_T's anchor completes, `on_calculation_finished` runs the completion
loop:

```rust
while let Some(scc) = scc_stack.last() {
    if stack_len <= scc.anchor_pos + 1 {
        pending_completed_sccs.push(scc_stack.pop().unwrap());
    } else {
        break;
    }
}
```

SCC_T pops correctly. The loop then checks the **next** SCC — SCC_S — which
has its stale `anchor_pos = 50`. The current `stack_len` is, say, 5. The check
`5 <= 51` is **true**, so SCC_S is also popped into `pending_completed_sccs`
**prematurely**.

`pop_and_drain_completed_sccs` in SCC_T's anchor `get_idx` then drains both
SCC_T and SCC_S, calling `iterative_resolve_scc` on each. The **nested**
`iterative_resolve_scc(SCC_S)` commits SCC_S's answers and removes it from
`scc_stack`.

Execution then returns to the current member M's `calculate_and_record_answer_iterative`.
M's frame calls `mark_iteration_changed` and then `set_iteration_node_done`,
but SCC_S is no longer on the stack. Both functions contain:

```rust
let top_scc = scc_stack.last_mut().expect("no SCC on the stack");
let iter_state = top_scc.iterative.as_mut().expect("top SCC is not iterating");
```

This is the source of the observed production panics.

### Why this is LSP-only (or LSP-predominant)

In batch type-checking, `iterative_resolve_scc` is always called after all
modules have been loaded and all non-SCC dependencies are pre-computed. By the
time iterative solving runs, any `get_idx` call on a non-SCC dependency hits a
cached `Calculated(v)` result immediately. No new Phase-0 cycles can form
during iterative solving.

In LSP mode, an ad-hoc solver is created on-demand for a specific query. It
starts with a fresh `ThreadState` and empty `CalcStack`. Non-SCC dependencies
of SCC members may not be in the Calculation cache yet, so they can trigger
full computation — including new Phase-0 cycle detection — during iterative
solving. This makes the stale-`anchor_pos` premature-pop reachable only (or
primarily) via the LSP path.

## Affected Functions

All of the following use the same `.expect("no SCC on the stack")` /
`.expect("top SCC is not iterating")` pattern and are exposed to this bug:

| Function | Called from | Notes |
|---|---|---|
| `set_iteration_node_done` | `calculate_and_record_answer_iterative` | Confirmed panic site |
| `mark_iteration_changed` | `calculate_and_record_answer_iterative` | Called *before* `set_iteration_node_done`; likely also panics |
| `mark_recursion_break` | `push()` back-edge handling | Less exposed; small gap between guard and call |
| `set_iteration_node_in_progress` | `push()` iterative bypass | Guarded by `get_iteration_node_state`; small gap |
| `set_iteration_placeholder` | `get_idx` `NeedsColdPlaceholder` arm | Guarded similarly |

## Current Fix (Stop-Gap)

`set_iteration_node_done` was changed to return `Option<()>` and use `?`
instead of `.expect(...)`, silently doing nothing when the SCC is missing or
not iterating. This prevents the crash.

When the SCC has been prematurely popped and committed by a nested
`iterative_resolve_scc`, the member's answer has already been committed via
that nested path. Silently skipping the `IterationNodeState::Done` write is
therefore likely safe for correctness in this specific scenario — but this
assumption is not verified.

`mark_iteration_changed` has the same vulnerability and is called immediately
before `set_iteration_node_done`. It should receive the same treatment to
prevent the next crash once the `set_iteration_node_done` panic is suppressed.

## Proper Fix Direction

The root cause is that `anchor_pos` retains its Phase-0 value when the SCC is
re-pushed during iterative solving, making the Phase-0 completion check
(`stack_len <= anchor_pos + 1`) always trivially true.

**Option A**: When `push_scc` is called inside `iterative_resolve_scc`, update
`anchor_pos` to the current CalcStack depth. The completion check would then
not fire spuriously during iterative solving because `stack_len` during
iterative solving would never exceed a freshly-set `anchor_pos`.

**Option B**: Skip the `anchor_pos`-based completion check entirely for
iterating SCCs (`iterative: Some`). Their lifecycle is driven by
`drive_all_iteration_members` returning (all members Done), not by CalcStack
depth. The `on_calculation_finished` loop could be conditioned on
`scc.iterative.is_none()`.

Option B is arguably cleaner because it makes the two phases fully independent:
Phase-0 completion is depth-driven; iterative completion is member-state-driven.
Option A is simpler but requires care to reset `anchor_pos` consistently across
merge and demotion paths.

Either fix should be accompanied by a test that constructs the scenario:
an iterating SCC whose member has a dependency that forms a new Phase-0 cycle
during iterative solving.
