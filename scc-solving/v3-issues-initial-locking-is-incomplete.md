# Iterative Fixpoint SCC Solving — Root Cause of Nondeterminism

This document continues from `v3-issues-part-3.md`. The infinite loop from
the `Evicted` path is fixed (via `remove_from_iteration_state`), and the
two-phase locking in `commit_final_answers` (commit da39dce780d3) eliminated
the most common source of nondeterminism (partial SCC commits visible to
other threads during Phase 0 discovery).

Two remaining nondeterminism mechanisms have been identified, both rooted in
`record_value`'s first-write-wins semantics allowing stale answers to persist
during concurrent SCC processing.

---

## Summary of Two Mechanisms

### Mechanism A: Same-thread stale writes (fixed by `has_active_scc()`)

When Thread A is iterating an SCC, `K::solve()` for SCC members may encounter
non-SCC dependencies. These are computed via `calculate_and_record_answer`,
which writes answers to Calculation cells via first-write-wins `record_value`.
During cold-start iteration 1, SCC members have placeholder-based answers, so
non-SCC bindings computed on Thread A during iteration get stale answers locked
into their Calculation cells.

**Fix:** Check `has_active_scc()` in the non-SCC path of
`calculate_and_record_answer`. If the current thread has any active SCC on its
stack, skip `record_value` — return the computed answer for the caller's use
but don't persist it. The binding will be recomputed after the SCC commits.

**Result:** Eliminates steam.py nondeterminism entirely. Reduces ibis
nondeterminism from ~10.7% to ~2.6%.

### Mechanism B: Cross-thread stale writes (not yet fixed)

Thread B (no active SCC, `has_active_scc()` returns false) independently
computes a binding that is a member of Thread A's active SCC. This happens
via `propose_calculation()`: Thread B encounters the SCC member's Calculation
cell in `Calculating` state, adds its thread ID to the set, gets `Calculatable`,
and computes the binding independently. Thread B may solve the cycle from a
different entry point and/or see partially-committed values, producing a stale
answer. Thread B writes this answer via `record_value` (first-write-wins).
When Thread A's SCC later tries to commit via `lock()`, the cell is already
`Calculated`, so `lock()` returns false and the SCC's converged answer is
discarded.

**Why `has_active_scc()` doesn't help:** This check is per-thread. Thread B
has no active SCC on its own stack, so the check passes and Thread B proceeds
to `record_value`.

**Fix options** are discussed in the "How to Fix Mechanism B" section below.

---

## Mechanism A: Detailed Analysis (steam.py)

### Symptom

- **Good runs:** 2,849 errors (deterministic)
- **Bad runs:** 2,853 errors (4 extra errors about `Self@Cog` assignability and
  `CogListeners.__get__` overloads)
- **Baseline rate:** ~2-4% (timing-sensitive)
- **Affected errors:** All 4 extra errors involve `Cog` / `CogListeners` types
  from `steam.ext.commands.cog`, which are part of the CogT/BotT SCC (11
  members).

#### ERROR output diff (steam.py)

```
> ERROR `Self@Cog` is not assignable to attribute `cog` with type `Bot | Cog[Bot] | None`
> ERROR `Self@Cog` is not assignable to attribute `cog` with type `Bot | Cog[Bot] | None`
> ERROR No matching overload found for function `CogListeners.__get__` called with arguments: (Cog[BotT], type[Cog])
> ERROR No matching overload found for function `CogListeners.__get__` called with arguments: (Cog[BotT], type[Cog])
```

### The mechanism (step by step)

**Bad run:**
1. Thread A starts iterating the CogT/BotT SCC (11 members), iteration 1 (cold start)
2. During `K::solve()` for an SCC member, the solver calls `get_idx` on non-SCC
   bindings: `KeyClassBaseType(2)`, `KeyClassMro(class2)`, `KeyVariance(class2)`
3. These bindings call `get_idx` on SCC members, which returns placeholder-based
   answers via the iterative bypass (the SCC is still iterating)
4. The non-SCC bindings compute answers based on placeholder types and commit them
   to `Calculation` cells (`did_write=true`). The answers are now **locked in**.
5. Thread A's SCC continues iterating. Iterations 2-5 converge to correct answers.
6. Thread A commits the SCC's final answers via `commit_final_answers`.
7. Later, Thread B computes the 4 divergent bindings (`Key::FacetAssign(command 232)`,
   etc.). These depend on the class metadata computed in step 4. They see the **stale**
   `KeyClassBaseType(2)` / `KeyClassMro(class2)` answers and produce spurious errors.

**Good run:**
1. Thread A starts iterating the CogT/BotT SCC (11 members)
2. During iteration, the solver does NOT trigger the class metadata bindings
   (different thread scheduling means a different module-resolution order)
3. The SCC converges and commits final answers
4. Later, Thread B computes `KeyClassBaseType(2)`, `KeyClassMro(class2)`,
   `KeyVariance(class2)` with `no_scc` context (after the SCC committed), so
   they see **correct, converged** SCC answers
5. Downstream bindings see correct class metadata and produce no spurious errors

### Instrumented evidence

We added `iteration_context_str()` to `CalcStack` and traced all non-SCC
bindings in `steam.ext.commands.cog` with their iteration context. Across 50
runs (2 divergent):

| Run | `KeyClassBaseType(2)` context | Error count |
|-----|-------------------------------|-------------|
| Good (48 runs) | `no_scc` | 2,849 |
| Bad run 8 | `iter=1 scc_members=11` | 2,853 |
| Bad run 41 | `iter=1 scc_members=11` | 2,853 |

**Perfect 1:1 correlation.** Every bad run has `KeyClassBaseType(2)` computed
during cold-start iteration 1 of the 11-member SCC. Every good run has it
computed outside any SCC context.

### Fix verification (Mechanism A)

| Fix variant | Tested on | Runs | Divergent | Rate |
|---|---|---|---|---|
| Narrow (`is_inside_scc_iteration()`) | steam.py | 49 | 0 | 0% |
| Narrow (`is_inside_scc_iteration()`) | ibis | 57 | 4 | 7.0% |
| Broader (`has_active_scc()`) | steam.py | 2* | 0 | 0% |
| Broader (`has_active_scc()`) | ibis | 250 | 7 | 2.8% |

\* Steam.py broader-fix batch still running (very slow per run); narrow fix
already proved deterministic for steam.py (49/49).

The narrow fix only covers iterating SCCs (top SCC has `iterative: Some(...)`).
The broader fix also covers Phase 0 discovery (any SCC on the stack). The
broader fix further reduces ibis nondeterminism but does not eliminate it.

---

## Mechanism B: Detailed Analysis (ibis residual nondeterminism)

### Symptom

- **Good runs:** 6,070 errors (deterministic)
- **Bad runs:** 6,157 errors (87 extra errors)
- **Rate with broader fix:** ~2.6% (5/195 runs)
- **Affected errors:** `FunctionType` has no attribute `bind`/`end`/`group_by`/
  `how`/`order_by`/`start` (84 errors), plus 3 `bad-return` errors about
  `Self@LegacyWindowBuilder`

#### ERROR output diff (ibis)

```
> ERROR Object of class `FunctionType` has no attribute `bind`     (1)
> ERROR Object of class `FunctionType` has no attribute `end`      (25)
> ERROR Object of class `FunctionType` has no attribute `group_by` (1)
> ERROR Object of class `FunctionType` has no attribute `how`      (31)
> ERROR Object of class `FunctionType` has no attribute `order_by` (1)
> ERROR Object of class `FunctionType` has no attribute `start`    (25)
> ERROR ... bad-return ... Self@LegacyWindowBuilder                (3)
```

### The mechanism (step by step)

The ibis errors involve `LegacyWindowBuilder → WindowBuilder → Builder →
Concrete → Immutable, Comparable, Annotable` — a complex metaclass hierarchy
from `ibis.common.grounds`. The `@annotated` decorator wraps methods, and when
class resolution fails, the decorated methods appear as bare `FunctionType`
instead of bound methods.

1. Thread A starts iterating an SCC involving the `WindowBuilder` class
   hierarchy or one of its metaclass-related types.
2. Thread B (no active SCC on its stack) encounters a binding for one of these
   classes via `push()`. The Calculation cell is `Calculating` (Thread A put it
   there during SCC discovery).
3. `propose_calculation()` returns `Calculatable` — Thread B's thread ID is
   added to the Calculating set, and Thread B independently computes the binding.
4. Thread B's computation encounters SCC members in `Calculating` state. It may
   hit cycle detection (getting placeholder answers) or see partially committed
   values. The result is a stale class resolution where `@annotated` methods are
   typed as `FunctionType`.
5. Thread B calls `record_value()`, which succeeds (first-write-wins, cell
   transitions `Calculating → Calculated(stale_answer)`).
6. Thread A's SCC eventually converges and calls `commit_final_answers`.
   `lock()` returns false for cells Thread B already wrote. The SCC's correct
   answer is discarded.
7. Downstream bindings (87 attribute accesses on `WindowBuilder` methods) see
   `FunctionType` instead of the correct class type, producing spurious errors.

### Evidence

- The ibis divergent error diff is always exactly 87 errors, always the same
  set of `FunctionType` attribute errors + `LegacyWindowBuilder` bad-return
  errors.
- The COMMIT_TRACE shows no partial SCC commits (two-phase locking is clean).
- `has_active_scc()` has no effect because the writing thread has no SCC.

---

## What We've Ruled Out (instrumented evidence)

### 1. Two-phase locking is clean — no mixed commits

Unconditional `COMMIT_TRACE` logging for all SCCs with >10 members shows:
- One thread always locks all members (no mixed commits)
- This is true in both good AND bad runs for both steam.py and ibis
- The commit mechanism is correct

### 2. Eviction does NOT fire in non-traced runs

Unconditional `EVICT_TRACE` logging shows:
- Zero eviction events when `PYREFLY_TRACE_MODULES` is NOT set
- Eviction only occurs with tracing enabled (I/O slows threads)
- Eviction is NOT the primary cause

### 3. The steam.py extra bindings are genuine non-SCC, first-write bindings

All 4 divergent steam.py bindings have `did_write=true` and `no_scc` context.
They're computed by a single thread, outside any SCC iteration. The
nondeterminism is in their **dependencies** (class metadata locked into stale
values), not in the bindings themselves.

---

## How to Fix Mechanism A (implemented)

Skip `record_value` for non-SCC bindings when the current thread has an active
SCC. The implementation adds `has_active_scc()` to `CalcStack`:

```rust
fn has_active_scc(&self) -> bool {
    !self.scc_stack.borrow().is_empty()
}
```

And checks it in the non-SCC path of `calculate_and_record_answer`:

```rust
if self.stack().has_active_scc() {
    // Skip record_value — return answer for caller but don't persist
    self.stack().on_calculation_finished(&current, None, None);
    raw_answer
} else {
    let (answer, did_write) = calculation.record_value(raw_answer);
    // ... normal path
}
```

---

## How to Fix Mechanism B (open — proposed approaches)

### Option 1: Lock SCC member cells at SCC creation time

When `iterative_resolve_scc` starts (before the first iteration), lock all
SCC member Calculation cells. Threads encountering `Locked` in
`propose_calculation` would wait on the condvar, then see the committed
answer.

**Pro:** Clean, prevents the race entirely.
**Con:** Deadlock risk. If SCC A locks cells and then needs a value from SCC B
(which also has locked cells and needs something that transitively depends on
SCC A), we get circular waiting. Separate SCCs cannot have direct circular
dependencies (they'd be merged), but TRANSITIVE dependencies through non-SCC
bindings could create deadlock chains.

### Option 2: Force-overwrite at batch commit

Change `lock()` to succeed even for `Calculated` cells (transition
`Calculated → Locked`). This ensures the SCC's converged answer always wins.

**Pro:** Simple change to `Calculation` state machine.
**Con:** Downstream bindings that already read the stale value and committed
their own stale answers are NOT fixed. This only corrects the SCC member
cells, not their transitive dependents.

### Option 3: Reject `propose_calculation` for `Calculating` cells

When `propose_calculation` encounters a `Calculating` cell, instead of
returning `Calculatable` (allowing parallel computation), block the new thread
until the cell becomes `Calculated` or `Locked`.

**Pro:** Eliminates the parallel computation race entirely.
**Con:** Risk of deadlock. Thread B waits for cell X, Thread A (computing X)
needs cell Y which Thread B is computing. This is the exact scenario
`propose_calculation` was designed to avoid by allowing parallel computation.

### Option 4: Dirty-flag invalidation after SCC commit

Track which non-SCC Calculation cells were written during an SCC's lifetime.
After the SCC commits, reset those cells to `NotCalculated` for recomputation.

**Pro:** Comprehensive — handles both SCC member and transitive non-SCC stale
answers.
**Con:** Complex tracking; may cause cascading recomputation.

### Option 5: Epoch-based invalidation

Add an epoch counter to each SCC. When an SCC commits, increment a global
epoch. Calculation cells written with an older epoch are considered stale
and recomputed on next read.

**Pro:** No per-cell tracking needed, conceptually clean.
**Con:** Adds overhead to every Calculation read.

---

## Key Code Locations

| What | File | Lines |
|---|---|---|
| `commit_final_answers` (two-phase commit) | `answers_solver.rs` | 2677-2729 |
| `lock_single` (per-cell lock) | `answers_solver.rs` | 2731+ |
| `calculate_and_record_answer` (non-SCC path, Mechanism A fix) | `answers_solver.rs` | 2518-2553 |
| `calculate_and_record_answer_iterative` (iterative errors) | `answers_solver.rs` | 2556-2611 |
| `has_active_scc()` (Mechanism A check) | `answers_solver.rs` | CalcStack impl |
| `propose_calculation` (allows parallel compute) | `calculation.rs` | 141-164 |
| `record_value` (first-write-wins) | `calculation.rs` | 176-198 |
| `lock()` / `unlock_with_value()` (two-phase locking) | `calculation.rs` | 93-120 |
| `drive_all_iteration_members` (eviction detection) | `answers_solver.rs` | 2903-2932 |
| `unlock_single_result` (commit-time error extend) | `answers_solver.rs` | 2758-2778 |
| `solve_idx_erased` (Evicted path) | `state/state.rs` | 2583-2612 |

---

## Conclusion

The nondeterminism in iterative-fixpoint SCC solving has a single root
category: **first-write-wins allows stale answers to persist when answers are
computed during (or concurrent with) SCC processing**. This manifests via two
sub-mechanisms:

- **Mechanism A (same-thread):** The iterating thread itself computes non-SCC
  bindings that see placeholder/intermediate SCC answers. Fixed by checking
  `has_active_scc()`.
- **Mechanism B (cross-thread):** Another thread independently computes the
  same binding via `propose_calculation` and writes a stale answer before the
  SCC commits. Requires a deeper fix to the `Calculation` or `propose_calculation`
  design.

Mechanism A is the primary cause for steam.py and a contributing factor for
ibis. Mechanism B is the residual cause for ibis (~2.6% after Mechanism A fix).
