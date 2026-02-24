# Iterative SCC Solving: Cross-Module Var Leak Panic

## Summary

When `PYREFLY_SCC_MODE=iterative-fixpoint` is enabled, Pyrefly panics with
"Internal error: a variable has leaked from one module to another" on several
open-source projects (pandera, altair, narwhals, helion, sympy, Tanjun,
tornado, ibis). The panic does not occur on trunk or without the env var.

## Root Cause

`KeyExport` was creating a real `Type::Var` placeholder during recursion
breaking, and this `Var` could leak across module boundaries.

### Background: How Recursion Breaking Works

Each key type in Pyrefly implements `create_recursive` and `promote_recursive`
on the `Solve` trait. When a back-edge is detected during solving:

1. `create_recursive` allocates a `Var` in the current module's `Solver`.
2. `promote_recursive` converts that `Var` into the key's answer type (e.g.,
   `Type::Var(var)` for `Key` and formerly `KeyExport`).
3. The promoted value is returned to the caller as a `CycleBroken` answer.
4. Later, `record_recursive` / `finalize_recursive_answer` unifies the
   placeholder `Var` with the actual answer.

Most exported keys (KeyTypeAlias, KeyTParams, KeyClassField, etc.) use
`Var::ZERO` as a dummy and return a static sentinel from `promote_recursive`
that ignores the `Var` entirely. Only `Key` and `KeyExport` created real `Var`s.

### Why This Causes a Panic in Iterative Mode

In iterative-fixpoint mode, every back-edge breaks immediately (unlike
non-iterative modes which try to break at a minimal idx). This means a
cross-module lookup can hit a `KeyExport` that is `InProgressWithPlaceholder`
and get back a `CycleBroken(var)` containing a `Type::Var` from the target
module's solver.

The specific path:

1. Module B is solving a binding. It calls `get_from_module(module_A, key)`.
2. This delegates through `LookupAnswer::get` → `solve_exported_key`, which
   creates a new `AnswersSolver` for module A.
3. Module A's `AnswersSolver` calls `get_idx`. The shared `CalcStack`'s
   iterative bypass finds the target is `InProgressWithPlaceholder` and returns
   `CycleBroken(var)` where `var` was created by module A's solver.
4. `get_idx` returns `Arc::new(K::promote_recursive(heap, var))` — a
   `Type::Var(var)` from module A. No deep-forcing happens on this path.
5. This answer propagates back through `solve_exported_key` to module B.
6. Module B incorporates this `Var`-containing value into its own computation.
7. Module B's `calculate_and_record_answer_iterative` tries to deep-force with
   module B's solver → encounters `var` from module A → panics in
   `Variables::get_node` (`solver.rs:285-292`).

### Why Non-Iterative Modes Don't Have This Bug

In non-iterative (cycle-breaking) modes, the break point is chosen at a minimal
idx. Since `KeyExport` always wraps a `Binding::Forward` pointing to a `Key`,
the cycle breaks at the underlying `Key` (which has a lower idx), not at the
`KeyExport`. The `Key`'s `Var` stays within the module that created it and gets
finalized there before any cross-module answer is written to a `Calculation`
cell.

## Fix

The fix is to stop `KeyExport` from creating its own placeholder `Var`.
`KeyExport` doesn't need one: its `solve` method delegates to
`solve_binding(&binding.0, ...)`, which resolves the underlying `Key`. The
`Key` handles its own recursion-breaking with a `Var` in the correct module's
solver.

Changes in `traits.rs` (`impl Solve for KeyExport`):

- **Removed `create_recursive` override** — defaults to `Var::ZERO` (no real
  Var allocated).
- **Changed `promote_recursive`** from `Type::Var(x)` to
  `Type::Any(AnyStyle::Implicit)` — discards the Var and returns a safe
  fallback. This is equivalent to what you'd get after forcing an unsolved
  recursive `Var`.
- **Removed `record_recursive` override** — defaults to identity (no
  finalization needed since no real `Var` was created).

## Implications for a Redesign

This bug highlights a general principle: **exportable keys that delegate to
other keys should not create their own placeholder `Var`s.** The `Var` should
only be created at the level where the actual type computation happens.

In a future redesign of iterative SCC solving, consider:

1. **Eliminate `Var::Recursive` for all keys in iterative mode.** The iterative
   fixpoint provides its own convergence mechanism via `previous_answers`, so
   recursive `Var` placeholders may be unnecessary. Using `Type::Any` or
   `Type::Never` as a cold-start sentinel would avoid the entire class of
   cross-module `Var` leak bugs.

2. **Enforce at the type level that `promote_recursive` for exported keys
   cannot produce `Type::Var`.** This would make the invariant that `Var`s
   don't cross module boundaries structurally guaranteed rather than relying
   on each key type getting it right.

3. **Consider whether cross-module SCC members need special handling at the
   `CalcStack` boundary.** Even with this fix, the shared `CalcStack` allows
   other forms of cross-module state sharing that may have subtle invariant
   violations.

## Key Files

| File | Lines | Description |
|------|-------|-------------|
| `lib/alt/traits.rs` | ~198-222 | `Solve` impl for `KeyExport` (the fix) |
| `lib/alt/answers_solver.rs` | ~362-418 | Iterative bypass in `push()` |
| `lib/alt/answers_solver.rs` | ~2262-2324 | `get_idx` — where `CycleBroken` is consumed |
| `lib/alt/answers_solver.rs` | ~2443-2555 | `calculate_and_record_answer_iterative` — deep-force site |
| `lib/alt/answers.rs` | ~662-699 | `solve_exported_key` — cross-module entry point |
| `lib/solver/solver.rs` | ~62-67, 285-292 | `VAR_LEAK` panic site |
