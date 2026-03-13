# Formal Specification of the SCC Graph Traversal

This document sketches a gradual TLA+ specification of the `CalcStack` SCC
algorithm in `answers_solver.rs`. It is intended as a personal learning
exercise — each level adds one layer of the real algorithm and introduces
one new TLA+ concept or verification goal. Work through a TLA+ resource
first (Lamport's video lectures or Hillel Wayne's "Practical TLA+"), then
return to each level here.

The bug described in `suspected-bug.md` is single-threaded. Something goes
wrong in the thread-local `CalcStack` state: an SCC that is being actively
iterated gets removed from `scc_stack` during the iteration, so the member
that triggered the removal finds no SCC when it tries to record its answer.
The multi-threaded shared cache (`Calculation<T>`) is peripheral and can
be ignored until the very end.

---

## Level 1: DFS stack, no cycles

**Goal**: model the basic demand-driven traversal before any SCC logic.

**State variables:**

- `stack`: a sequence of node IDs currently being computed (the `CalcStack.stack`)
- `computed`: a set of node IDs whose answers are final
- `graph`: a fixed function from node ID to set of dependency node IDs
  (model this as a TLA+ constant `DEPS`, not a state variable)

**Actions:**

- `Call(n)`: push `n` onto `stack` if `n ∉ computed` and `n ∉ stack`
- `Return(n)`: if `n = Head(stack)` and all `DEPS[n] ⊆ computed`, pop `n`
  and add it to `computed`

**Invariant to check:**

- `NoDuplicates`: no node appears more than once in `stack`

**What this teaches**: basic TLA+ sequence operations (`Head`, `Tail`,
`Append`), the Init/Next structure, and how to express a stack as a
TLA+ sequence.

**Note**: at this level the graph must be acyclic or `Return` will deadlock.
That deadlock is intentional — Level 2 resolves it.

---

## Level 2: Cycle detection and the SCC stack (Phase 0)

**Goal**: model the point where a back-edge is detected and an SCC is
created. This corresponds to `on_scc_detected` in `answers_solver.rs`.

**New state variables:**

- `scc_stack`: a sequence of SCC records, each containing:
  - `members`: set of node IDs in the SCC
  - `anchor_pos`: the index in `stack` of the outermost member when the
    SCC was first detected (0-indexed, matching the Rust code)
  - `iterative`: a boolean, `FALSE` in Phase 0

**New action:**

- `DetectCycle(n)`: fires when `Call(n)` would push `n` but `n` is already
  in `stack`. Instead of pushing again, create a new SCC record:
  - `members` = { all nodes in `stack` from the first occurrence of `n`
    onward }
  - `anchor_pos` = index of the first occurrence of `n` in `stack`
  - Push this SCC record onto `scc_stack`

**Modified `Return(n)` action (Phase-0 completion check):**

When `n` is about to return (all its dependencies are satisfied), check:

```
IF scc_stack ≠ <<>> /\ Last(scc_stack).anchor_pos + 1 ≥ Len(stack)
THEN move Last(scc_stack) to a pending_completed set
```

This mirrors the completion check in `on_calculation_finished`:
`stack_len <= anchor_pos + 1`.

**Invariant to check:**

- `SccCompletionSound`: when an SCC is moved to `pending_completed`, every
  member of that SCC must have already returned (be in `computed` or be
  the current returning node)

**What this teaches**: nested records in TLA+, sequence indexing, and how
to express a "trigger" condition on a stack depth.

**Note**: `anchor_pos` is set here at detection time. This is the value
that becomes *stale* in Level 4.

---

## Level 3: Iterative phase

**Goal**: model the fixpoint iteration loop. This corresponds to
`iterative_resolve_scc` and `drive_all_iteration_members`.

**Modified SCC record**: add an `iteration` counter (natural number) and
a `node_states` function from member to one of `{Fresh, InProgress, Done}`.

**New actions:**

- `StartIteration(scc)`: takes a completed Phase-0 SCC from
  `pending_completed`, sets `iterative = TRUE` and `iteration = 1`,
  resets all `node_states` to `Fresh`, and pushes it back onto `scc_stack`.
- `DriveNode(n)`: if the top SCC is iterating and `node_states[n] = Fresh`,
  set `node_states[n] = InProgress` and push `n` onto `stack`.
- `FinishNode(n)`: if `n = Head(stack)` and the top SCC has `node_states[n]
  = InProgress`, set `node_states[n] = Done` and pop `n`.
- `ConvergeOrContinue`: if all members of the top iterating SCC are `Done`,
  either commit (if answers are stable — model stability as a
  nondeterministic choice for now) or reset all `node_states` to `Fresh`
  and increment `iteration`.
- `ExceedMaxIterations`: if `iteration > MAX_ITERATIONS`, commit anyway
  (nonconvergence path).

**Invariant to check:**

- `IteratingTop`: while the top SCC has `iterative = TRUE`, no
  `on_calculation_finished`-style completion check should pop it. Formally:
  ```
  Last(scc_stack).iterative = TRUE =>
      ~(Last(scc_stack) ∈ pending_completed)
  ```

**What this teaches**: nondeterminism in TLA+ (modelling "answers changed"
as a nondeterministic choice lets TLC explore both branches), and how to
express a two-phase protocol.

---

## Level 4: The stale `anchor_pos` bug

**Goal**: introduce the bug and let TLC find a violation of `IteratingTop`.

**The bug in the model**: in Level 3, `StartIteration` pushes the SCC back
onto `scc_stack` without updating `anchor_pos`. At the start of iterative
solving the real `stack` has unwound to a much shallower depth than the
original Phase-0 value. Add a `DriveNodeDep` action that models a member's
solve discovering a new uncached dependency:

- `DriveNodeDep(n, x)`: while `n` is `InProgress` in the top iterating SCC,
  push a dependency `x ∉ scc_stack.members` onto `stack`. If `x` has its
  own dependencies that cycle back to each other, `DetectCycle` fires again,
  creating a new Phase-0 SCC_T on top of SCC_S.

**The violation**: when SCC_T's anchor completes, the Phase-0 completion
check runs:

```
Len(stack) ≤ Last(scc_stack_before_T).anchor_pos + 1
```

Because `anchor_pos` was set during Phase 0 (when `stack` was deep) but
`stack` is now shallow, this is `TRUE` for SCC_S even though SCC_S is
mid-iteration. TLC will find a trace where `IteratingTop` is violated.

**What TLC will show you**: the shortest counterexample trace —
likely something like:

1. `Call(A)`, `Call(B)`, `DetectCycle(A)` → SCC_AB created, `anchor_pos=0`
2. Phase-0 completes. `StartIteration(SCC_AB)` → pushed back, `anchor_pos`
   still 0 but `stack` is now empty.
3. `DriveNode(A)` → A is InProgress, stack = `<<A>>`
4. `DriveNodeDep(A, X)`, `Call(Y)`, `DetectCycle(X)` → SCC_XY created
5. SCC_XY anchor returns. Completion check: `Len(<<A,X>>) = 2 ≤ 0+1 = 1`?
   No... hmm, let me think about what length the stack would actually be here.

Actually the completion loop checks `stack_len <= scc.anchor_pos + 1` and
pops the top SCC if true, then continues to the *next* SCC. So TLC should
find: after SCC_XY pops, the loop checks SCC_AB with `anchor_pos=0` and
`stack_len` at whatever depth A's frame is at, which may satisfy the check
spuriously.

**Two candidate fixes to check** (from `suspected-bug.md`):

- **Option A**: in `StartIteration`, set `anchor_pos := Len(stack)`. The
  completion check for the iterating SCC will never spuriously fire because
  `stack` during iterative driving never grows deeper than the fresh
  `anchor_pos`.
- **Option B**: add a guard `~Last(scc_stack).iterative` to the completion
  check loop. Iterating SCCs are skipped entirely; they are only removed by
  `ConvergeOrContinue`.

With either fix applied to the spec, TLC should find no violation of
`IteratingTop` for graphs up to the scope you choose.

---

## Level 5: Multithreading (future extension)

**Skip this until the single-threaded model is working.**

The concurrent aspect is that multiple threads share a `Calculation` cache.
Each thread has its own `CalcStack` (the model above), but they share a
global `cache` mapping node IDs to optional values (TLA+ `CHOOSE` or a
function). The relevant property is write-once:

- `WriteOnce`: `cache[n] ≠ None => []cache[n] = cache[n]`
  (once written, a cache entry never changes)

A thread consults the cache before pushing a node (hitting `Calculated(v)`
immediately); it writes the cache only via `commit_final_answers`. The
interesting interaction: in LSP mode a fresh thread starts with an empty
local cache view, so nodes that batch-mode threads would see as
`Calculated` appear as `Fresh` and can trigger new Phase-0 cycles.
This is why the bug is LSP-predominant — but the bug itself is in the
single-thread stack logic, not in the cache.

Modeling the multi-thread case adds a set `Threads` of processes in TLA+,
each running a copy of the Level-4 state machine, with a shared `cache`
variable and interleaving via the standard PlusCal or raw TLA+ `\E t \in
Threads` action form.

---

## Practical notes for working through this

- Start with a concrete graph of 3–4 nodes. Name them `A`, `B`, `X`, `Y`.
  Hard-code `DEPS` as a TLA+ function literal.
- Use TLC's state constraint to bound stack depth (e.g., `Len(stack) ≤ 6`)
  so model checking terminates quickly.
- Check one invariant per level before adding more state. The workflow is:
  write the Init/Next spec, add the invariant, run TLC, fix until no
  violation, then proceed.
- The violation in Level 4 should appear with `DEPS = [A |-> {B}, B |->
  {A}, X |-> {Y}, Y |-> {X}]` and `A`'s solve triggering `X` during
  iterative driving. TLC should produce the counterexample trace directly.
- When Option A or Option B is applied and TLC finds no violation, that is
  genuine evidence (for the bounded graph) that the fix is correct — much
  stronger than unit tests on manually constructed `Scc` structs.
