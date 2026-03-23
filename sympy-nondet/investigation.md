# SymPy nondeterminism root-cause plan

This note captures the current understanding of the SymPy nondeterminism and a
targeted plan for tracing it to the source binding / solve path.

## Current anchor

The improved repro is the `sympy/sets` slice:

```bash
/data/users/stroxler/fbsource/buck-out/v2/art/fbcode/3a95de1f9f273d7a/pyrefly/pyrefly/__fbpyrefly__/fbpyrefly \
  check ~/kode/mypy-primer-2026-03-19-v2/sympy/sympy/sets
```

This is materially faster than checking all of SymPy and still reproduces the
same structural divergence:

- stable run: `310` errors
- divergent run: `309` errors
- dropped diagnostic:
  `sympy/sets/fancysets.py:855:28-858:39 [missing-attribute]`
  `Object of class NoneType has no attribute reversed`

The source site is:

```python
return self.reversed[
    stop if stop is None else -stop + 1:
    start if start is None else -start:
    step].reversed
```

in [`sympy/sets/fancysets.py`](//home/stroxler/kode/mypy-primer-2026-03-19-v2/sympy/sympy/sets/fancysets.py#L855).

## Binding anchor

From `--debug-info`, the relevant binding in Pyrefly is:

- `Key::ReturnExplicit(855:21-858:39)`

with binding text:

```text
ReturnExplicit(None, self.reversed[
                        stop if stop is None else -stop + 1:
                        start if start is None else -start:
                        step].reversed)
```

The attribute site itself is the range `855:28-858:39`.

`--report-trace` maps that attribute expression back to the property definition:

- [`sympy/sets/fancysets.py`](//home/stroxler/kode/mypy-primer-2026-03-19-v2/sympy/sympy/sets/fancysets.py#L687): `Range.reversed`

The property definition's committed answer was stable in sampled runs:

- `Key::Definition(reversed 687:9-17) -> (self: Self@Range) -> Range | Self@Range`

The enclosing return binding's committed answer was also stable in sampled runs:

- `Key::ReturnExplicit(855:21-858:39) -> Unknown`

## Important conclusion

The stable and divergent runs had the same committed answers for the obvious
bindings above, but only one run retained the `NoneType.reversed` diagnostic.

That shifts the debugging target:

- this does not currently look like "final answer differs"
- it looks more like "a `MissingAttribute` diagnostic is emitted on some solve
  path in some runs and not in others, even though the final committed answer is
  the same"

The emission point is in
[`pyrefly/lib/alt/attr.rs`](/data/users/stroxler/fbsource/fbcode/pyrefly/pyrefly/lib/alt/attr.rs),
inside `type_of_attr_get`.

## Root-cause plan

### 1. Log the exact `MissingAttribute` emission

Add temporary logging in
[`pyrefly/lib/alt/attr.rs`](/data/users/stroxler/fbsource/fbcode/pyrefly/pyrefly/lib/alt/attr.rs)
inside `type_of_attr_get`.

Filter aggressively:

- current module is `sympy.sets.fancysets`
- `range == 855:28-858:39`
- `attr_name == "reversed"`

For each hit, log:

- current binding via `show_current_binding()`
- current stack via `show_current_stack()`
- whether we are in cold iteration or normal error-collecting iteration
- input `base` type
- `as_attribute_base(base)` result
- decomposed lookup result:
  - found
  - not_found
  - internal_error
- whether we took the success branch or emitted `MissingAttribute`
- emitted message text

This is the most important first step. It identifies the exact solve path that
creates the unstable diagnostic.

### 2. Trace the base of the final `.reversed`

The likely unstable value is not the property definition itself, but the type of
the base expression:

```python
self.reversed[...]
```

Add temporary logging in
[`pyrefly/lib/alt/expr.rs`](/data/users/stroxler/fbsource/fbcode/pyrefly/pyrefly/lib/alt/expr.rs)
for the same filtered site:

- `attr_infer`
- `subscript_infer`

Log:

- type of the first `self.reversed`
- result type of `self.reversed[...]`
- base type seen by the final `.reversed`

If one run sometimes feeds `None | ...` into the final attribute lookup, this is
where that should first become visible.

### 3. Log property getter execution

Because the chain starts from a property access, add temporary logging in
[`pyrefly/lib/alt/class/class_field.rs`](/data/users/stroxler/fbsource/fbcode/pyrefly/pyrefly/lib/alt/class/class_field.rs)
where properties are handled.

Relevant site: the `ClassAttribute::Property` branch around
`call_property_getter`.

For the `reversed` property only, log:

- getter type
- returned type
- current binding
- current stack

This separates two hypotheses:

- the getter itself sometimes returns an unstable type
- the getter is stable, but the later subscript / attribute chain is unstable

### 4. Log iteration and commit context

Because the final committed answer seems stable while the diagnostic is not, add
targeted logging in
[`pyrefly/lib/alt/answers_solver.rs`](/data/users/stroxler/fbsource/fbcode/pyrefly/pyrefly/lib/alt/answers_solver.rs)
around `K::solve` for the specific binding:

- `Key::ReturnExplicit(855:21-858:39)`

Log:

- whether the solve is in cold iteration
- whether errors are swallowed or collected
- raw answer before deep-force
- whether this calculation's diagnostics are from the final committed iteration

This should answer whether the missing diagnostic is produced only on some
iteration path and then either preserved or discarded inconsistently.

## Suggested logging control

Use a single env var to gate all temporary logging, for example:

```bash
PYREFLY_DEBUG_DETERMINISM_FILTER=sympy.sets.fancysets:855:28-858:39
```

The implementation can start simpler than that, including a hardcoded filter if
that makes iteration faster, but the filter should stay extremely narrow to keep
logs readable.

Useful fields for every log line:

- module
- binding
- range
- attribute name
- iteration state
- stack
- input type
- output type
- error text

## Recommended execution order

1. Add the `type_of_attr_get` log in `attr.rs`.
2. Run the `sympy/sets` repro until there is one `310` run and one `309` run.
3. Diff only the filtered logs.
4. If the first divergence is already visible there, stop and chase that
   upstream solve path.
5. If not, add the `subscript_infer` and property-getter logs and repeat.

## Why this order

The existing trace and debug-report outputs are too coarse:

- `--report-trace` showed `855:28-858:39 -> Unknown` in both stable and
  divergent runs
- `--debug-info` showed the same committed answers for the relevant bindings in
  both runs

So the next useful signal is not in committed answers. It is in the transient
solve path inside attribute lookup and intermediate expression evaluation.

---

## Root Cause Confirmed (2026-03-19)

### Instrumentation findings

Added `[det]` logging gated by `PYREFLY_DEBUG_DETERMINISM` env var to three sites:
1. `type_of_attr_get` entry in `attr.rs` — logs for every `reversed` attr access in `sympy.sets.fancysets`
2. `type_of_attr_get` MissingAttribute emission in `attr.rs`
3. `calculate_and_record_answer` `did_write=false` in `answers_solver.rs` — logs dropped errors
4. `write_unlock_same_module` `did_write=false` in `answers_solver.rs` — logs dropped SCC errors

Ran `sympy/sets` repro with opt-mode build. Captured 5 runs; Run 1 = 310 errors (stable), Run 2 = 309 errors (divergent).

**Key comparison (Run 1 vs Run 2 det logs):**

Run 1 (310 errors) sees:
- `ReturnExplicit(855:21-858:39)` solved 4 times: 1 pre-cold-iteration + 1 cold + 3 hot
- Hot solves see `base=Range | Unknown | Self@Range | None` → emits NoneType.reversed error
- `did_write=false` drops for `__new__` (×2), `doit` (×2), `normalize_theta_set` (×2)

Run 2 (309 errors) sees:
- `ReturnExplicit(855:21-858:39)` solved only once: cold iteration only (cold=true)
- Hot-mode solves **never run** — `K::solve` is never called in hot mode → no error
- Additional `did_write=false` drops for `get_symsetmap` (3), `ReturnExplicit(tfn[...])` (1), `_contains` (2)

### Mechanism

The nondeterminism is a **transactional write-race** in the SCC iteration:

1. Thread Y (computing some dependency that transitively reaches `ReturnExplicit(855:21-858:39)`) calls `get_idx` for this binding. From Thread Y's perspective (different thread-local `CalcStack`), the binding is `NotInScc` → `propose_calculation()` → `Calculatable` → Thread Y calls `K::solve` on the non-SCC path → `calculation.record_value()` → `did_write=true` → commits the cold-context answer (`Unknown`, no errors because `error_swallower()`).

2. Thread X's fancysets SCC runs its cold and hot iterations. `K::solve` IS called during iterations (via `calculate_and_record_answer_iterative`). But when `commit_final_answers` tries to commit the hot-iteration answer+errors, it calls `write_lock_single` → the Calculation cell is already `Calculated` (Thread Y won the race) → `write_lock_single` returns `false` → this member is **skipped** in the batch commit → hot-iteration errors are **dropped**.

3. Additionally (or alternatively): because Thread Y committed `Unknown` to the global Calculation cell, and the SCC's cold-iteration answer is also `Unknown`, the convergence check may find no change → the SCC terminates without running hot iterations for this binding.

4. The extra `did_write=false` drops in Run 2 are Thread Y's footprint — Thread Y's cold-context solves for `get_symsetmap`, `tfn[...]`, `_contains` also won their write races, keeping those bindings committed with cold answers.

### Root cause summary

**Cold-context external thread commits win the write race against the SCC's hot iterations.**

When another thread (not part of the fancysets SCC) computes a binding that IS an SCC member, it goes through the non-SCC path and permanently commits the cold-context answer. The SCC's `commit_final_answers` then cannot commit the converged hot-iteration answer+errors for that binding, because `write_lock_single` sees the cell already in `Calculated` state.

This is nondeterministic because it depends on thread scheduling: which thread first reaches a given binding determines whether the cold or hot answer gets committed, and whether errors are emitted.

### Fix directions

**Option A (targeted): Commit errors even when the answer write is lost.**

In `commit_final_answers`, when `write_lock_single` returns false for a member (answer already committed by another thread), still commit the errors from the last hot iteration if:
- We are past the cold iteration (iteration ≥ 2)
- The committed answer matches our computed answer (the answers are stable)

This requires comparing answers before deciding to drop errors.

**Option B (architectural): Prevent non-SCC threads from committing SCC member cells.**

When a binding is being iterated by an SCC (its Calculation cell is in `Calculating` state), external threads that call `propose_calculation()` should block or spin until the SCC commits the final answer. This would eliminate the race entirely but requires more synchronization.

**Option C: Track commit mode (cold vs hot) in the Calculation cell.**

Add a `committed_in_cold_mode: bool` flag to the `Calculation` cell. The SCC's `commit_final_answers` can check this flag and overwrite if the prior commit was cold. This allows the hot-converged answer+errors to always win.

**Recommended next step:** Verify Option A is sound by checking whether the committed answer always matches the SCC's final computed answer. If they always match, Option A is the safest minimal fix.

---

## Deep Root Cause: `HasPlaceholder` Merge-Detection Gap (2026-03-19)

The section above correctly identifies that Thread Y commits `ReturnExplicit(855:21-858:39)`
via the non-SCC path before Thread X's SCC can. What was missing was a precise,
mechanistic explanation of *why* Thread Y reaches that binding as a non-SCC dependency
and *why* cycle detection fails to merge it into Thread Y's SCC.

This section documents the complete explanation, derived from fanout-tracing instrumentation
(`FANOUT_START` / `FANOUT: get_idx(…) → …` log lines).

### The dependency cycle

The function `Range.__getitem__` (line 813) contains the expression
`self.reversed[stop:start:step].reversed`. The subscript `self.reversed[…]` calls
`Range.__getitem__` — the same function. So the dependency graph contains a true cycle:

```
ReturnExplicit(855:21-858:39)
  → subscript access on Range
    → Key::Definition(__getitem__ 813:9-20)
      → ReturnExplicit(855:21-858:39)    ← cycle closes
```

### Phase 0: Thread Y forms an SCC around `813:9-20`, not `855:21-858:39`

Thread Y's DFS starts from an entry point that reaches
`Key::Definition(__getitem__ 813:9-20)` **directly** — without first traversing through
`ReturnExplicit(855:21-858:39)`. Thread Y pushes `813:9-20` onto its raw CalcStack.
During computation of `813:9-20`, the DFS traverses into the function body and
encounters `813:9-20` again via the subscript chain.

At that point `current_cycle()` sees two positions for `813:9-20` in `position_of`,
returns the cycle, `on_scc_detected` fires, and the Phase 0 SCC is created. The SCC
contains `813:9-20` and the other function-level bindings
(`Key::Return`, `KeyClassField`, `KeyDecoratedFunction`) but **not**
`ReturnExplicit(855:21-858:39)`, because Thread Y never pushed `855:21-858:39` before
hitting the back-edge.

The `HasPlaceholder` state is set for `813:9-20`. `Unwind` propagates back up the
CalcStack. The raw CalcStack fully unwinds. `position_of[813:9-20]` is emptied.

### Thread Y computes `855:21-858:39` as a non-SCC dependency

Thread Y's SCC enters iterative mode and begins driving its members. Driving one of
those members eventually requires `ReturnExplicit(855:21-858:39)` as a dependency.
`push(855:21-858:39)` is called. The `Calculation` cell for `855:21-858:39` is in
`Calculating({thread_X})` (Thread X has started it). `propose_calculation` returns
`Calculatable` because Thread Y's ID is not in the `Calculating` set — the permeable
design that prevents deadlocks.

Neither the iterative bypass (`get_iteration_node_state`) nor `find_iterating_scc_containing`
fire for `855:21-858:39` (it is not in Thread Y's SCC). `pre_calculate_state` returns
`NotInScc`. `current_cycle()` returns `None` (only one position: the one just added).
`push` returns `Calculate`. Thread Y enters `calculate_and_record_answer` for
`855:21-858:39` via the **non-SCC path**. `855:21-858:39` is now on Thread Y's raw
CalcStack.

### The merge-detection failure: `HasPlaceholder` + `current_cycle()` = `None`

Inside `K::solve` for `855:21-858:39`, Thread Y evaluates `self.reversed[…].reversed`.
Evaluating the subscript access eventually calls `get_idx` for
`Key::Definition(__getitem__ 813:9-20)`. `push(813:9-20)` is called.

At the start of `push`, `813:9-20` is pushed onto the raw CalcStack.
`position_of[813:9-20]` now has **exactly one entry** — the one just added.

The `HasPlaceholder` arm runs (since `813:9-20` is still in Phase 0 `HasPlaceholder`
state — the iterative bypass at line 392 does not fire because `813:9-20` is not in
the top SCC's `IterationNodeState`):

```rust
SccState::HasPlaceholder => {
    if let Some(current_cycle) = self.current_cycle() {
        self.on_scc_detected(current_cycle);  // ← would merge 855:21-858:39 here
    }
    // ...
    BindingAction::CycleBroken(var)
}
```

`current_cycle()` checks `position_of[813:9-20]`. It finds **one position** (just added
in this `push` call). `target_positions.len() == 1` → returns `None`.

`on_scc_detected` is **not called**. `855:21-858:39` is **not merged** into Thread Y's
SCC. `CycleBroken(var)` is returned — Thread Y uses the placeholder Var for the
subscript type and continues.

This happens **twice**: once for the subscript `self.reversed[…]` and once for the
final `.reversed` attribute access. Both times `current_cycle()` returns `None` for
the same reason.

The fanout log confirms this precisely:

```
[det] FANOUT: get_idx(813:9-20) → CycleBroken   ← no merge fired
[det] FANOUT: get_idx(813:9-20) → CycleBroken   ← no merge fired
```

No `Unwind`, no `SccLocalAnswer`, no merge.

### Thread Y commits, Thread X loses

After `K::solve` for `855:21-858:39` completes, `self.stack().is_scc_participant(&current)`
is `false` (the binding was never merged). Thread Y takes the non-SCC branch:

```rust
let (answer, did_write) = calculation.record_value(raw_answer);
```

The `Calculation` cell transitions from `Calculating({thread_X, thread_Y})` to
`Calculated(Unknown)`. `did_write=true`. `base_errors` is empty (the subscript base
was `Unknown`, so `MissingAttribute` was not triggered). Thread Y commits
`ReturnExplicit(855:21-858:39)` with `Unknown` type and 0 errors.

Thread X's SCC later computes the correct type (`Range | Unknown | Self@Range | None`)
and emits `MissingAttribute`. But `commit_final_answers` calls `write_lock_single`,
which sees the cell already `Calculated`, returns `false`, and the hot-iteration errors
are silently dropped.

### The invariant that failed

`HasPlaceholder` arm's cycle detection relies on `current_cycle()`, which checks
whether the *just-pushed* CalcId appears at **more than one position** in `position_of`.
After Phase 0 unwinds, all positions for `813:9-20` are removed. When `813:9-20` is
encountered again during a non-SCC computation, it has only one (freshly-added)
position, so `current_cycle()` returns `None` and no merge fires.

The true cycle (`855:21-858:39` → subscript → `813:9-20` → `855:21-858:39`) **is**
traversed by Thread Y, but the merge detection cannot see it because it depends on the
live CalcStack state from Phase 0, which has already been torn down.

### Correction to earlier analysis (error_collector vs error_swallower)

An earlier version of this document stated that Thread Y's non-SCC path used
`error_swallower()`, causing errors to be suppressed. This was incorrect.

The non-SCC path in `calculate_and_record_answer` (line 2426) always uses
`error_collector()` (ErrorStyle::Delayed). The iterative SCC path
(`calculate_and_record_answer_iterative`, lines 2610–2617) is what conditionally uses
`error_swallower()` during cold-start iteration.

The 0 errors in Thread Y's non-SCC commit are because the base type seen by
`type_of_attr_get` is `Unknown` (the placeholder Var resolved to `Unknown` in cold
context), and `Unknown` does not trigger `MissingAttribute`. It is a type-weakness
issue, not an error-suppression issue.

### Why this is nondeterministic

The nondeterminism is in which thread gets assigned which starting entry point by the
parallel work scheduler. In stable runs, the thread that first processes the
`fancysets` module starts from `ReturnExplicit(855:21-858:39)` or from a path that
includes it in the SCC from the start. Thread X's SCC then correctly computes the full
union type and emits the error.

In divergent runs, some other thread starts from `Key::Definition(__getitem__ 813:9-20)`
directly, forms a smaller Phase 0 SCC, and later computes `855:21-858:39)` as a
non-SCC dependency where the merge-detection gap allows it to be committed early with
a cold-context answer.

### Two-layer fix required

The full fix has two independent components that each address one layer of the problem:

**Layer 1 — Fix the merge-detection gap in `HasPlaceholder`.**

When `SccState::HasPlaceholder` is returned for a binding B, and some other binding N
is currently being computed as non-SCC (N is on the raw CalcStack but not in any SCC's
iteration state), the encounter of B via N's dependency chain IS a cycle
(N → … → B → … → N). The `HasPlaceholder` arm should detect this and merge N into the
SCC.

The current mechanism (`current_cycle()`) cannot detect this because it looks for B
appearing at two positions on the CalcStack, and B's prior position was removed during
Phase 0 unwind. A fix would need to recognize that any non-SCC binding currently on
the CalcStack that reaches a `HasPlaceholder` binding is part of the cycle.

**Layer 2 — Fix the write-race in `commit_final_answers`.**

Even if Layer 1 is fixed, there may be other paths where a non-SCC thread commits an
SCC member's cell before `commit_final_answers` can lock it. Layer 2 addresses the
consequence: when `write_lock_single` returns `false` for an SCC member (already
committed by another thread), the SCC's hot-iteration errors for that member are
currently dropped. At minimum, those errors should still be emitted even if the answer
write is lost.

Layer 1 fixes the root cause. Layer 2 is a defensive safety net.
