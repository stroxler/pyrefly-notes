# Iterative Fixpoint SCC Solving — v4 Pre-Plan

## Goal

Rewrite the iterative SCC solving stack from scratch, incorporating all lessons
learned from v3 and its bugfix cycle. The v3 implementation was functionally
complete but required 7+ post-landing bugfixes across 4 investigation documents.
The v4 effort should produce the same result with fewer bugs by:

1. **Fixing some bugs in-place:** Where the v3 plan's design led directly to a
   bug, change the v4 plan so the bug is never introduced. Examples:
   - Inverted merge priority in membership back-edge merges (v3-issues-part-2)
   - `KeyExport` creating real `Var` placeholders (v3-issues-panic)
   - `segment_size` not being incremented in the iterative bypass (v3-issues-part-1)
   - Free-floating nodes not added to `iterative.node_states` (v3-issues-part-1)

2. **Patching trunk before the main stack:** Where a bug is in pre-existing code
   that the v3 stack built on top of, land the fix on trunk first so the stack
   starts from a clean baseline. Examples:
   - `solve_idx_erased` returning `true` for evicted answers (v3-issues-part-3)
   - Possibly the `KeyExport` `Var` leak fix, if it's cleaner as a standalone
     trunk patch

3. **Addressing design gaps earlier in the commit plan:** Where the v3 plan
   deferred a concern and it turned out to cause cascading problems, the v4 plan
   should address it in the commit where it first matters. Examples:
   - Nested absorption handling (v3-issues-part-2) should be part of the
     iteration driver commit, not a follow-up fix
   - Cross-module answer eviction should be handled when cross-module iteration
     is added, not discovered later

---

## Reference Documents

### v3 Plan
- [`v3-doc.md`](v3-doc.md) — Consolidated plan for iterative fixpoint SCC
  solving. Describes the algorithm, data structures, commit plan, and
  invariants.

### v3 Bug Investigation Documents
- [`v3-issues-part-1.md`](v3-issues-part-1.md) — Three correctness bugs
  (`segment_size` asymmetry, absorption orphaning, free-floating nodes) and
  the initial multi-threaded work amplification theory.
- [`v3-issues-part-2.md`](v3-issues-part-2.md) — Inverted merge priority bug,
  nested absorption crash theory, and the detailed fix for safe absorption
  handling (Fix D). Includes the `top_scc_contains_member` design and
  double-commit / CalcStack cleanliness analysis.
- [`v3-issues-part-3.md`](v3-issues-part-3.md) — Root cause of the infinite
  loop: `solve_idx_erased` returns `true` for evicted answers, leaving
  cross-module members permanently Fresh.
- [`v3-issues-panic.md`](v3-issues-panic.md) — Cross-module `Var` leak panic
  caused by `KeyExport` creating real placeholder `Var`s during recursion
  breaking.

### Other
- [`v1-doc.md`](v1-doc.md) — Earlier iteration of the plan (for historical
  context only).
- [`iterative-issues.md`](iterative-issues.md) — Pre-v3 issue tracking.

---

## v3 Stack Commit Reference

Stack ending at `c27c19a2c5`, listed in stack order (bottom to top).

### Pre-stack trunk patch (already landed)

This commit is already landed on trunk. A new v4 stack does not need to include
it; it will be in the baseline.

| Commit | Title | Summary |
|--------|-------|---------|
| `9a0c3e130bee` | Make KeyExport break recursion with Unknown | Changes `KeyExport` cycle-breaking to use `Unknown` instead of `Type::Var`, avoiding cross-module `Var` leaks. |

### Phase A — Infrastructure (dead code)

| Commit | Title | Summary |
|--------|-------|---------|
| `323886182732` | Mode + config plumbing | Adds `SccSolvingMode::Iterative`, `SccMode` config enum, and `PYREFLY_SCC_MODE` env var override. |
| `45e0de3b5169` | Propagate mode to CalcStack | Adds `scc_solving_mode` field and `is_iterative()` helper to `CalcStack`, threaded from `ThreadState`. |
| `33b33d0746a9` | Convergence helpers | Adds `answers_equal` / `answers_equal_typed` for comparing type-erased answers between iterations. |
| `80599d158e89` | Iteration structs | Adds `SccIterationState`, `IterationNodeState`, `IterationNodeStateKind`; updates `Scc::merge` to demote when merging iterating SCCs. |
| `8de2967c88d3` | CalcStack accessors | Adds 14 iteration accessor methods to `CalcStack` for reading/writing SCC-scoped iteration state. |

### Phase B — Core integration

| Commit | Title | Summary |
|--------|-------|---------|
| `bd9ddc74b573` | Eager breaking | `on_scc_detected` always returns `BreakHere` in iterative mode (no min-idx breaking). |
| `dfc2ef351148` | Iterative bypass in push | Adds iterative bypass in `CalcStack::push` dispatching on iteration node state; adds `NeedsColdPlaceholder` and `SccLocalAnswer` `BindingAction` variants. |
| `71ab0cc2a1a6` | Membership back-edge detection | Detects cross-SCC back-edges in `push` by merging SCCs when target is in a non-top iterating SCC; sets `demoted = true`. |
| `5c86830b28ea` | get_idx plumbing | Handles `NeedsColdPlaceholder` by allocating placeholder via `K::create_recursive`; adjusts `CycleDetected` for iterative mode. |
| `996fe11cefe2` | calculate_and_record_answer iterative path | Stores answers in SCC-local iteration state, deep-forces for convergence comparison, suppresses errors during cold-start iteration 1. |
| `21fe73ce5b8f` | Iteration driver | Implements `iterative_resolve_scc` with outer demotion loop (max 10), inner fixpoint loop (max 5), absorption detection, and final commit. |

### Phase C — Features

| Commit | Title | Summary |
|--------|-------|---------|
| `feff83f235a8` | Cross-module iteration | Adds `solve_idx_erased` plumbing so cross-module SCC members can be driven during iterative solving. |
| `ed6d971e23c8` | Robust module commit | Handles edge case where `Answers` are evicted when a second thread tries to commit. |
| `88a2560d5c53` | LoopPhi bypass | Intercepts `LoopPhi` bindings during cold-start iteration 1 to resolve prior/default index directly. |

### Phase D — Config + tests

| Commit | Title | Summary |
|--------|-------|---------|
| `c422482bc5f1` | Config exposure + test helpers | Wires `SccMode` from config into `ThreadState`; adds test helpers for iterative mode. |
| `630c9911d50e` | Test: LoopPhi simple | Simple while loop verifying `LoopPhi` cold-start bypass infers `int`. |
| `e6a784243932` | Test: LoopPhi multi-var | Multiple loop variables (`int`, `float`, `list[int]`) in one while loop. |
| `911ad5251cdc` | Test: LoopPhi increment | Loop variable widening (`int` → `int \| None`) across iterations. |
| `58748579b60f` | Test: warm-start convergence | Mutually recursive functions forming a true SCC; cold-start placeholders, warm-start convergence. |
| `b43e4f3864b6` | Test: error suppression | Error suppression across iterations; no spurious placeholder errors, real errors reported after convergence. |
| `09d731a6d9c7` | Test: cross-module SCC cycle | SCC spanning multiple modules with mutually recursive functions. |
| `d6e49783b9c2` | Test: disjoint SCC independence | Two independent mutual-recursion pairs solve independently. |
| `e9925b189d43` | Test: membership back-edge merge + demotion | Unit test: `push` merges non-top iterating SCC with `demoted = true`. |
| `7e56d01138d1` | Test: absorption detection | Unit test: inner SCC merged into ancestor; inner driver detects absorption. |
| `93d85464aff0` | Test: demotion limit panic | Extracts `MAX_ITERATIONS`/`MAX_DEMOTIONS` to constants; tests panic behavior. |

### Post-v3.1 bugfixes (v3.2–v3.7)

| Commit | Title | Summary | Issue doc |
|--------|-------|---------|-----------|
| `61c462aaaad7` | Fix LoopPhi increment test | Updates test to avoid newly-detected type error; uses direct assignment + annotation. | — |
| `2c89e856ead1` | Fix segment_size asymmetry | Increments `segment_size` in iterative bypass path; removes stale debug prints. | part-1 bug #1 |
| `27be6c05697d` | Fix absorption orphaning | Adds `has_ancestor_iterating_scc()` check before absorption early-return. | part-1 bug #2 |
| `d07241c55fbc` | Fix free-floating nodes in merge | Inserts free-floating nodes into `iterative.node_states` as `Fresh` during `merge_sccs`. | part-1 bug #3 |
| `287b6c5ecedd` | Defer merge demotion | Preserves iteration node states during merge; defers demotion until after drive loop. | part-1 Fix A |
| `250c7e6e5fdb` | Set merge_happened for free-floating expansion | Sets `merge_happened` flag when free-floating nodes expand an iterating SCC. | part-1 Fix A (cont.) |
| `28c200680a01` | Free-floating nodes in back-edge merge | Adds free-floating nodes to both `node_state` and `iterative.node_states` in membership back-edge merge. | part-1 bug #3 (cont.) |
| `3631353ae342` | Part 2 fixes: step 0 | Adds `scc_stack_is_empty()`, `top_scc_contains_member()` helpers. | part-2 Fix D step 0 |
| `81c1af33ddba` | Part 2 fixes: steps 1+2 | Guards against empty stack and safe absorption handling in `iterative_resolve_scc`. | part-2 Fix D steps 1+2 |
| `c6c7fad06286` | Part 2 fixes: step 3 | Reverses drain order in membership back-edge merge to fix inverted merge priority. | part-2 Fix E |
| `6613eb6ed879` | Fix infinite loop from evicted Answers | Removes evicted cross-module members from `iterative.node_states` after a no-op drive. | part-3 |
| `c2dcf288bc23` | Unique cache for Quantified | Cross-thread cache for `Quantified` uniques so parallel threads produce identical IDs. | nondeterminism |
| `c27c19a2c55c` | Two-phase locking for SCC batch commits | `Locked` state + condvar in `Calculation` cells for atomic two-phase SCC commit. | nondeterminism |

**Note on `c27c19a2c55c` (two-phase locking):** This commit is not considered a
core part of the stack. The locking mechanism does not fully solve determinism
problems; a locking solution will likely be needed but the design needs to be
reworked for v4.

---

## Next Steps

1. ~~Fill in the v3 stack commit reference above.~~ Done.
2. Read the v3 stack diffs to understand the actual implementation (vs. the
   plan), noting where the implementation diverged and where bugs were
   introduced.
3. Write the v4 plan (`v4-doc.md`) with a revised commit plan that
   incorporates the fixes and design changes described above.
