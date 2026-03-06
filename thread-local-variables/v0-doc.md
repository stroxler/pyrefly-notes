# Making `Variables` Thread-Local (or Scoped)

## Motivation

The `Solver` struct stores all type variables in a `Mutex<Variables>` map
(`solver.rs`). This mutex is the only synchronization point in the solver's hot
path. If we can prove that no `Var` crosses a thread boundary, we can remove the
`Mutex` and make `Variables` thread-local — or go further and use a **stack of
scoped variable maps** with different lifetimes for different variable kinds.

A scoped design could also enforce at the type level that SCC-scoped variables
(Recursive/LoopRecursive) never leak across SCCs, which would eliminate an
entire class of bugs.

---

## Key Insight: Vars No Longer Cross Thread Boundaries

As of the current codebase (March 2025), **no live `Var` can appear in a
`Calculation` cell that another thread reads**. This is the result of two
changes:

### 1. `solve_binding` pins all Partial/Quantified/Unwrap vars before returning

At the end of `solve_binding` (`solve.rs`), every returned `TypeInfo` goes
through:

```rust
type_info.visit_mut(&mut |ty| {
    self.pin_all_placeholder_types(ty, true, range, errors);
    self.expand_vars_mut(ty);
});
```

This pins `PartialContained` (to `Any`), `PartialQuantified` (to gradual type),
`Unwrap` (to `Any`), and reports `Quantified` as an internal error. Then
`expand_vars_mut` resolves all `Answer`-state vars to concrete types.

For `NameAssign` bindings with first-use inference, the first-use side-effect
pinning happens inline within `solve_binding_with_first_use_pinning` — the
partial answer is stored, the first-use binding is evaluated for side effects,
and the partial answer is cleared, all before the pinning step runs.

### 2. Iterative fixpoint is the only SCC solving mode

The legacy `CyclesDualWrite` and `CyclesThreadLocal` modes have been removed.
All SCC members go through `calculate_and_record_answer_iterative`, which
deep-forces every answer before storing it in `IterationNodeState::Done`:

```rust
let mut forced = Arc::unwrap_or_clone(answer);
forced.visit_mut(&mut |x| self.current.solver().deep_force_mut(x));
let answer = Arc::new(forced);
```

These deep-forced answers are the only values that reach `Calculation` cells
(via `commit_final_answers`). Phase 0 SCC answers are never written to
`Calculation`.

### Why Recursive vars can't appear in non-SCC answers

Recursive/LoopRecursive vars are only created by `create_recursive`, which is
called during cycle breaking (`attempt_to_unwind_cycle_from_here` or
`NeedsColdPlaceholder`). Cycle breaking only happens for SCC members. Non-SCC
bindings cannot have Recursive vars, so the non-SCC write path
(`calculate_and_record_answer` → `record_value`) never stores a Recursive var.

### Summary of all write paths to `Calculation`

| Write path                | Vars possible? | Why safe                                       |
|---------------------------|----------------|-------------------------------------------------|
| Non-SCC, exported         | No             | `deep_force_mut` before `record_value`          |
| Non-SCC, non-exported     | No             | Partial pinned in `solve_binding`; Recursive impossible (no cycle) |
| SCC (iterative)           | No             | `deep_force_mut` in `calculate_and_record_answer_iterative` |
| Phase 0 SCC               | N/A            | Never written to `Calculation`                  |

---

## Var Lifetime Categories

Each `Variable` variant has a well-defined scope. Understanding these scopes
is the basis for a scoped-stack design.

### Binding-scoped (born and die within a single `solve_binding` call)

- **`Quantified`**: Created by `fresh_quantified*`, finalized by
  `finish_quantified` (enforced by `#[must_use]` on `QuantifiedHandle`).
  Always resolved before `solve_binding` returns.

- **`Unwrap` (decomposition pattern)**: Created by `fresh_unwrap` for type
  decomposition (e.g., `unwrap_awaitable`). Ephemeral — created and consumed
  within a single helper call.

- **`PartialContained`**: Created by `fresh_partial_contained` for empty
  container literals. Pinned to `Any` by `pin_all_placeholder_types` at the
  end of `solve_binding`.

- **`PartialQuantified`**: Created by `finish_quantified` / `finish_class_targs`
  when `infer_with_first_use` is true. Pinned to gradual type by
  `pin_all_placeholder_types` at the end of `solve_binding`.

- **`Unwrap` (lambda parameters)**: Created in `bind_lambda_param` during the
  binding phase, resolved during the solve phase. Pinned by
  `pin_all_placeholder_types`.

All of these are pinned/resolved by the `pin_all_placeholder_types` +
`expand_vars_mut` tail in `solve_binding`, so they never escape into the
returned `Arc<TypeInfo>`.

### SCC-scoped (born at cycle detection, die at SCC commit)

- **`Recursive`**: Created by `fresh_recursive` during cycle breaking. Finalized
  by `finalize_recursive_answer` (which calls `record_recursive` + `force_var`).
  Deep-forced before storage in `IterationNodeState::Done`.

- **`LoopRecursive`**: Created by `fresh_loop_recursive` for `LoopPhi` bindings.
  Same lifecycle as `Recursive` but with additional bound-checking logic.

These are deep-forced in `calculate_and_record_answer_iterative` before
being stored in SCC iteration state, so they never escape the SCC.

---

## Proposed Design: Scoped Variable Maps

### Option A: Thread-local flat map

Replace `Mutex<Variables>` with a thread-local `Variables`. This is the minimal
change — same data structure, just without the lock.

Pros: Simple, minimal code change.
Cons: Doesn't enforce scoping invariants at the type level.

### Option B: Stack of scoped maps

Use a stack of variable maps with different lifetimes:

1. **Binding scope**: Pushed when `solve_binding` begins, popped when it returns.
   Holds `Quantified`, `PartialContained`, `PartialQuantified`, `Unwrap` vars.
   These vars are guaranteed to be resolved before the scope is popped (by
   `pin_all_placeholder_types` + `expand_vars_mut`).

2. **SCC scope**: Pushed when an SCC iteration begins, popped when the SCC
   commits. Holds `Recursive` and `LoopRecursive` vars. These vars are
   guaranteed to be deep-forced before the scope is popped (by
   `calculate_and_record_answer_iterative`).

This could potentially be enforced in the type system by having separate
`BindingVarMap` and `SccVarMap` types, making it a compile-time error to store
a Recursive var in the binding map or vice versa.

Pros: Enforces scoping invariants; makes it impossible for SCC vars to leak
across SCCs; makes the variable lifecycle visible in the code structure.
Cons: More invasive refactor; need to handle the nesting correctly (bindings
within an SCC need access to both their binding scope and the SCC scope).

### Option C: Hybrid — thread-local with SCC-scope tracking

Thread-local flat map (like Option A) but with debug assertions that verify
scoping invariants:
- Assert that no `Recursive`/`LoopRecursive` var outlives its SCC.
- Assert that no `Partial*`/`Quantified`/`Unwrap` var outlives its `solve_binding`.

Pros: Simple implementation with runtime safety checks.
Cons: Invariants not enforced at compile time.

---

## Prerequisites / Risks

### Verify: no concurrent same-module solving

Two threads can operate on the same module's `Solver` concurrently: thread A
solving end-to-end, thread B entering via `solve_exported_key`. Even though no
Vars cross threads through `Calculation` cells, both threads currently share the
same `Variables` map via the `Mutex`.

With thread-local `Variables`, each thread would have its own map. This is safe
**if and only if** thread B never needs to look up a Var created by thread A.
The analysis above shows this holds: thread B only reads from `Calculation`
cells (which contain no live Vars) or computes fresh bindings (creating its own
Vars in its own map).

However, this should be verified carefully. One subtle concern: if thread B
computes a binding that thread A is also computing (via `propose_calculation`'s
parallel-compute semantics), both threads create their own Vars for the same
binding. The first to finish writes to the `Calculation` cell (first-writer-wins)
and the loser's answer (with its thread-local Vars) is discarded. This should be
safe since the discarded answer's Vars are never read by anyone.

### Verify: `expand_vars` on read paths

Some read paths call `expand_vars` or `deep_force` on answers read from
`Calculation` cells (e.g., `Answers::get_type_at`). If the answer is already
Var-free (as we've established), these calls are no-ops. But we should verify
they don't panic on an empty thread-local `Variables` map — they would need to
handle the case where a `Type::Var` is encountered but the var isn't in the
local map (which would indicate a bug, but shouldn't happen given the
invariants).

### The `Answer` variant

With thread-local or scoped variables, the `Variable::Answer` variant becomes
less important. Currently, once a var is resolved to `Answer(ty)`, it stays in
the `Variables` map so that subsequent `expand_vars` calls can resolve it. With
scoped maps, vars are resolved (expanded) before the scope is popped, so the
`Answer` entries don't need to persist beyond the scope. This simplifies
cleanup — popping a scope just drops the entire map.
