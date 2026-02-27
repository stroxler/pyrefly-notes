# Iterative Fixpoint SCC Solving — v4 Plan (Draft A)

This plan rewrites the iterative SCC solving stack from scratch, incorporating
all lessons from the v3 implementation and its 7+ post-landing bugfixes. The
v3 algorithm was correct in its final state; v4 reproduces the same result
with the bugfixes folded into the commits that should have contained them
from the start.

See `v4-preplan.md` for the full v3 commit reference and bugfix disposition
analysis.

---

## Reference Documents

- [`v3-doc.md`](v3-doc.md) — v3 algorithm, data structures, commit plan
- [`v3-issues-part-1.md`](v3-issues-part-1.md) — segment_size, absorption
  orphaning, free-floating nodes, deferred merge demotion
- [`v3-issues-part-2.md`](v3-issues-part-2.md) — inverted merge priority,
  nested absorption crash, safe absorption handling
- [`v3-issues-part-3.md`](v3-issues-part-3.md) — `solve_idx_erased` infinite
  loop from evicted answers
- [`v3-issues-panic.md`](v3-issues-panic.md) — `KeyExport` cross-module `Var`
  leak (already fixed on trunk)

---

## Goals

Same as v3:
1. **Determinism:** SCC solving independent of DFS entry order.
2. **Convergence:** Iterative fixpoint with warm-start until stabilized.
3. **Correctness:** Disjoint SCCs, late merges, LoopPhi, cross-module cycles.
4. **Stack safety:** Iterative mode never uses min-idx breaking.
5. **Isolation:** Iteration state is SCC-scoped.

Non-goals: redesigning the solver, changing the type system, solving
multi-thread nondeterminism from `Calculation` cell races (see "Deferred
Design Work" at the end).

---

## Pre-Stack Trunk Patches

These changes should land on trunk before the v4 stack begins. They are
beneficial or harmless without the iterative stack, and having them in the
baseline simplifies the stack.

### Already landed

| Commit | Title | Notes |
|--------|-------|-------|
| `9a0c3e130bee` | Make KeyExport break recursion with Unknown | Prevents cross-module `Var` leaks. Already on trunk. |

### New trunk patch

**`UniqueFactory.get_or_fresh()` extension.** Add a `keyed_cache:
Mutex<HashMap<usize, Unique>>` field to `UniqueFactory` and a
`get_or_fresh(&self, key: usize) -> Unique` method in
`crates/pyrefly_util/src/uniques.rs`. This is a purely additive API
extension with no callers on trunk; callers are added in the stack. The
cache ensures that parallel threads solving the same `Quantified` type
parameter produce identical `Unique` IDs, which is needed for convergence
in iterative mode.

The `solve.rs` caller changes (replacing `Quantified::from_type_var` with
`Quantified::new(self.uniques.get_or_fresh(key), ...)`) land in the stack,
not on trunk, since the nondeterminism they fix only manifests with
parallel multi-thread iteration.

---

## Algorithm Overview

Unchanged from v3. Summary:

### Solving Modes
- `CyclesDualWrite` / `CyclesThreadLocal` (legacy)
- `Iterative` (new)

Config enum `SccMode` maps to `SccSolvingMode`, with `PYREFLY_SCC_MODE` env
var override.

### Two Loops
- **Outer loop (demotion):** If membership expands mid-iteration, restart at
  iteration 1. Max demotions = 10 (panic if exceeded).
- **Inner loop (fixpoint):**
  - Iteration 1 (cold): back-edges allocate placeholders.
  - Iteration 2+ (warm): back-edges reuse previous answers.
  - Converge when `has_changed == false` after iteration >= 2.
  - Max iterations = 5 (warn and commit last answers).

### Phase 0 Discovery
Phase 0 is the existing DFS. In iterative mode, back-edges always break
immediately (`BreakHere`). Phase 0 is membership discovery only; its
outputs are discarded when iteration begins.

---

## Data Structures

### `SccIterationState`

**v4 change from v3:** Includes `merge_happened` from the start (v3 added
this in a bugfix). The correct merge semantics — preserving existing
iteration node states — are the design from day one.

```rust
pub struct SccIterationState {
    /// Current iteration number (1-indexed).
    iteration: u32,
    /// Per-member iteration state. Membership is `node_states.keys()`.
    node_states: BTreeMap<CalcId, IterationNodeState>,
    /// Deep-forced answers from the previous iteration, for convergence
    /// comparison. Empty on iteration 1 (cold start).
    previous_answers: BTreeMap<CalcId, Arc<dyn Any + Send + Sync>>,
    /// Set to true when a merge adds new members during `drive_all_iteration_members`.
    /// Checked after the drive loop; triggers demotion if set.
    /// Invariant: cleared at the start of each iteration.
    merge_happened: bool,
    /// Set to true when a merge expands the SCC and the driver should
    /// restart at iteration 1 after the current drive loop completes.
    /// Unlike v3, this is NOT set during `Scc::merge` — it is set by the
    /// iteration driver after checking `merge_happened`.
    demoted: bool,
    /// Set to true when any member's answer differs from `previous_answers`.
    has_changed: bool,
}
```

### `Scc::merge` — Correct Semantics (v4 vs v3)

**v3 initial design (wrong):** `Scc::merge` reset ALL iteration node states
to `Fresh` and set `demoted = true`. This caused O(K×N) work amplification
when K merges happened during a single `drive_all_iteration_members` call,
because already-driven `Done` members were reset to `Fresh` and re-driven.

**v4 design (from start):** `Scc::merge` preserves existing iteration node
states from both SCCs. Genuinely new members (not present in either SCC's
`node_states`) are added as `Fresh`. The merged SCC gets
`iteration = max(self, other)`, `previous_answers = union(self, other)`,
and `merge_happened = true`. `demoted` is NOT set during merge — the
iteration driver checks `merge_happened` after the drive loop completes
and defers demotion.

```rust
/// Merge `other` into `self`. `self` gets priority for node states
/// (important: the top/currently-iterating SCC must be `self`).
fn merge(mut self, other: Scc) -> Scc {
    // Merge node_state (membership). self wins on conflict.
    for (k, v) in other.node_state {
        self.node_state.entry(k).or_insert(v);
    }

    // Merge iteration state if either SCC is iterating.
    match (self.iterative.take(), other.iterative) {
        (Some(mut self_iter), Some(other_iter)) => {
            // Preserve self's states; add other's with or_insert.
            for (k, v) in other_iter.node_states {
                self_iter.node_states.entry(k).or_insert(v);
            }
            // Take max iteration count.
            self_iter.iteration = self_iter.iteration.max(other_iter.iteration);
            // Union previous_answers; self wins on conflict.
            for (k, v) in other_iter.previous_answers {
                self_iter.previous_answers.entry(k).or_insert(v);
            }
            self_iter.merge_happened = true;
            self.iterative = Some(self_iter);
        }
        (Some(mut self_iter), None) => {
            // Add other's members as Fresh.
            for k in other.node_state.keys() {
                self_iter.node_states.entry(k.dupe()).or_insert(IterationNodeState::Fresh);
            }
            self_iter.merge_happened = true;
            self.iterative = Some(self_iter);
        }
        (None, Some(mut other_iter)) => {
            // Add self's members as Fresh.
            for k in self.node_state.keys() {
                other_iter.node_states.entry(k.dupe()).or_insert(IterationNodeState::Fresh);
            }
            other_iter.merge_happened = true;
            self.iterative = Some(other_iter);
        }
        (None, None) => {}
    }

    // Other fields: detected_at = min, anchor_pos = min, etc.
    self
}
```

### Free-Floating Nodes — Kept in Sync

**v3 bug:** `merge_sccs` adds free-floating CalcStack nodes to
`merged.node_state` AFTER calling `Scc::merge_many`, but did not add them
to `merged.iterative.node_states`. They were invisible to
`drive_all_iteration_members` until the next iteration.

**v4 invariant:** Any code path that adds a CalcId to `node_state` must also
add it to `iterative.node_states` (as `Fresh`) if iteration is active. This
applies in two places:

1. **`merge_sccs` (in `pop`):** After adding free-floating nodes to
   `merged.node_state`, also add them to `iterative.node_states` as `Fresh`.
   If any new nodes are added, set `merge_happened = true`.

2. **Membership back-edge merge (in `push`):** Same treatment for
   free-floating nodes discovered during the back-edge merge.

---

## Core Mechanics

### Iterative Bypass in `push`

Same as v3 with one fix integrated:

**v3 bug:** The bypass path returned early without incrementing
`segment_size`, but `pop` unconditionally decrements it. This caused
`segment_size` to drift inaccurate via `saturating_sub`.

**v4 fix:** Increment `segment_size` in the bypass path before returning,
since the node IS unconditionally pushed onto the raw CalcStack.

```
When top SCC is iterating and target is a member:
  segment_size += 1   // ← v4 addition
  match get_iteration_node_state(target):
    Fresh → mark InProgress, return Calculate
    InProgress + previous answer → SccLocalAnswer(prev)
    InProgress + placeholder → CycleBroken(var)
    InProgress + neither → NeedsColdPlaceholder
    Done → SccLocalAnswer(answer)
```

### Membership Back-Edge Detection

Same as v3 with two fixes integrated:

1. **Merge priority (v3 bug: inverted drain order):** The drain produces
   `[bottom, ..., top]` but `merge_many` gives priority to the first
   element. Reverse the drained vec before calling `merge_many` so the top
   SCC (currently being iterated) gets priority, matching `merge_sccs`.

2. **Free-floating nodes:** After the back-edge merge, add free-floating
   CalcStack nodes to both `node_state` and `iterative.node_states`,
   matching the treatment in `merge_sccs`.

### Iteration Driver (`iterative_resolve_scc`)

Same two-loop structure as v3 with three fixes integrated:

1. **Empty-stack guard (from v3-issues-part-2 step 1):** After
   `drive_all_iteration_members()`, check `scc_stack_is_empty()`. If empty,
   a nested driver absorbed and committed our SCC — return without
   committing.

2. **3-case absorption handling (from v3-issues-part-2 step 2):** Replace
   the original 2-case absorption check with 3 cases:
   - **Ancestor exists** (`has_ancestor_iterating_scc()`): return, ancestor
     will handle it.
   - **No ancestor, top SCC contains our member**
     (`top_scc_contains_member(&scc_identity)`): our SCC was merged into
     the top SCC. Update `scc_identity` and continue driving.
   - **No ancestor, top SCC does NOT contain our member**: our SCC was
     committed by a nested driver; an unrelated SCC remains. Return.

3. **Deferred demotion (from v3-issues-part-1 Fix A):** After the drive
   loop, check `merge_happened`. If set, set `demoted = true`. This
   converts mid-iteration merges into a single demotion, bounding
   per-iteration work to O(N) instead of O(K×N).

```
fn iterative_resolve_scc(mut scc: Scc):
    let scc_identity = scc.detected_at
    iteration = 1
    demotions = 0

    loop:
        if iteration > MAX_ITERS:
            warn; break

        previous_answers = if iteration > 1 { extract_done_answers(&scc) } else { empty }
        scc.iterative = Some(fresh_state(iteration, previous_answers))
        push scc

        drive_all_iteration_members()

        // ① Empty-stack guard (v3-issues-part-2 step 1)
        if scc_stack_is_empty():
            return  // nested driver committed our SCC

        // ② 3-case absorption (v3-issues-part-2 step 2)
        if top_scc_detected_at() != scc_identity:
            if has_ancestor_iterating_scc():
                return  // ancestor will handle
            if top_scc_contains_member(&scc_identity):
                scc_identity = top_scc_detected_at()
                // fall through to pop and continue
            else:
                return  // committed by nested driver

        scc = pop()

        // ③ Deferred demotion (v3-issues-part-1 Fix A)
        if scc.iterative.merge_happened:
            scc.iterative.demoted = true

        if scc.iterative.demoted:
            demotions += 1
            if demotions > MAX_DEMOTIONS: panic!
            iteration = 1
            continue

        if iteration >= 2 && !scc.iterative.has_changed:
            break

        iteration += 1

    commit_final_answers(scc)
```

### Cross-Module `solve_idx_erased`

Same as v3 with one fix integrated:

**v3 bug:** `solve_idx_erased` returned `true` for the `Evicted` case
(another thread evicted the target module's `Answers`). This left the
member permanently `Fresh`, causing an infinite loop in
`drive_all_iteration_members`.

**v4 fix:** `solve_idx_erased` returns `false` for `Evicted`. The caller
(`drive_member`) handles this by checking whether the member is still
`Fresh` after the call, and if so, removes it from `iterative.node_states`
(the member's answer was already committed by another thread).

An alternative (cleaner) design is to make `solve_idx_erased` return a
tri-state (`Driven | Evicted | NotFound`) instead of `bool`, so the caller
can handle each case explicitly. This avoids the post-hoc state check.

### Quantified Unique Caching

The `solve_legacy_tparam` function (in `solve.rs`) uses
`UniqueFactory.get_or_fresh(cache_key)` instead of `Quantified::from_type_var`
to ensure that parallel threads produce identical `Unique` IDs for the same
type parameter. The `UniqueFactory` extension is landed on trunk as a
pre-stack patch; the caller change lands in the stack.

### LoopPhi Bypass

Same as v3. During iteration 1, `LoopPhi` bindings are intercepted in
`get_idx` and resolved directly to their prior/default index. This avoids
the `LoopRecursive` placeholder that eager breaking would otherwise
interfere with.

---

## Commit Plan

Every commit keeps legacy mode green. Each commit title begins with
`[pyrefly][scc-solving][v4]`.

### Phase A — Infrastructure (dead code)

**A1: Mode + config plumbing**
- Add `SccSolvingMode::Iterative`, config enum `SccMode`, and
  `SccSolvingMode::resolve(SccMode)` with `PYREFLY_SCC_MODE` env override.

**A2: Propagate mode to CalcStack**
- Add `scc_solving_mode` field and `is_iterative()` helper to `CalcStack`,
  threaded from `ThreadState`.

**A3: Convergence helpers**
- Add `answers_equal` / `answers_equal_typed` via `dispatch_anyidx!`.

**A4: Iteration structs**
- Add `SccIterationState` (with `merge_happened` from the start),
  `IterationNodeState`, `IterationNodeStateKind`.
- Add `Scc::iterative` field.
- Implement `Scc::merge` with state-preserving semantics (no reset-to-Fresh).
- Ensure `merge_sccs` adds free-floating nodes to `iterative.node_states`.

**v3 bugs folded in:**
- `merge_happened` field (v3: `287b6c5ecedd`)
- State-preserving merge (v3: `287b6c5ecedd`)
- `max(iteration)` and `union(previous_answers)` (v3: `250c7e6e5fdb`)
- Free-floating nodes in `merge_sccs` (v3: `d07241c55fbc`)

**A5: CalcStack accessors**
- Iteration scanning helpers: `find_iterating_scc_containing`,
  `is_iterating_member`, `get_iteration_node_state`,
  `set_iteration_placeholder`, `get_iteration_placeholder`,
  `set_iteration_node_done`, `mark_iteration_changed`,
  `get_previous_answer`, `next_fresh_member`,
  `extract_previous_answers`, `read_iteration_outcome`.
- Absorption helpers (new in v4, were bugfix-added in v3):
  `scc_stack_is_empty`, `top_scc_contains_member`,
  `has_ancestor_iterating_scc`, `top_scc_merge_happened`,
  `set_top_scc_demoted`.

### Phase B — Core Integration

**B1: Eager breaking**
- In iterative mode, `on_scc_detected` always returns `BreakHere`.

**B2: Iterative bypass in `push`**
- Add `BindingAction::NeedsColdPlaceholder` and `SccLocalAnswer`.
- Implement SCC-scoped iteration state bypass.
- **Include `segment_size += 1`** in the bypass path (v3: `2c89e856ead1`).

**B3: Membership back-edge detection**
- Scan `scc_stack` for target in non-top iterating SCC.
- Merge + set `merge_happened = true`.
- **Reverse drain order** for correct merge priority (v3: `c6c7fad06286`).
- **Add free-floating nodes** to both `node_state` and `iterative.node_states`
  (v3: `28c200680a01`).

**B4: `get_idx` plumbing**
- Handle `NeedsColdPlaceholder` → `K::create_recursive`.
- Handle `SccLocalAnswer`.
- Handle `CycleDetected` without active cycle (stale `Calculating` from
  Phase 0).

**B5: `calculate_and_record_answer` iterative path**
- Store `IterationNodeState::Done`.
- Deep-force answers before storage.
- Compare to `previous_answers` for convergence.
- Error suppression: `error_swallower` for iteration 1, `error_collector`
  for iteration >= 2.

**B6: Iteration driver**
- Implement `iterative_resolve_scc` + `drive_all_iteration_members`.
- **Include all three absorption/safety fixes from the start:**
  - Empty-stack guard (v3: `81c1af33ddba` step 1)
  - 3-case absorption handling (v3: `81c1af33ddba` step 2, `27be6c05697d`)
  - Deferred demotion via `merge_happened` (v3: `287b6c5ecedd`)

### Phase C — Features

**C1: Cross-module iteration**
- Add `LookupAnswer::solve_idx_erased` (default no-op).
- Add `Answers::solve_idx_erased`.
- **Return `false` for `Evicted` case** (v3: `6613eb6ed879`). Handle
  permanently-Fresh members by removing them from `iterative.node_states`
  after a no-op drive.

**C2: Robust module commit**
- Handle edge case where `Answers` are evicted when a second thread tries
  to commit.

**C3: LoopPhi bypass**
- Intercept `Binding::LoopPhi` during iteration 1 and resolve prior/default
  index directly.

**C4: Quantified unique caching**
- Replace `Quantified::from_type_var` calls in `solve_legacy_tparam` with
  `Quantified::new(self.uniques.get_or_fresh(cache_key), ...)`.

### Phase D — Config + Tests

**D1: Config exposure + test helpers**
- Wire `SccMode` from config into `ThreadState`.
- Add `iterative_env()` test helper.

**D2: Targeted tests**
- LoopPhi simple / multi-var / increment (use corrected test from v3:
  `61c462aaaad7`)
- Warm-start convergence (mutually recursive functions)
- Error suppression across iterations
- Cross-module SCC cycle
- Disjoint SCC independence
- Membership back-edge merge + demotion (unit test)
- Absorption detection (nested SCC merged into ancestor)
- Demotion limit panic

---

## Invariants (Must Hold)

1. Iteration state is owned by `Scc`, not `CalcStack`.
2. Any access to a member of an active SCC from outside that SCC is a
   back-edge.
3. Iterative mode never uses min-idx breaking.
4. **Merges during iteration preserve existing node states.** Only genuinely
   new members are added as `Fresh`. `merge_happened` is set; `demoted` is
   deferred until after the drive loop. (v3 invariant 4 was wrong: "merges
   always demote to cold start" caused O(K×N) amplification.)
5. Answers stored in `IterationNodeState::Done` are deep-forced.
6. **All code paths that add a CalcId to `node_state` must also add it to
   `iterative.node_states` if iteration is active.** This includes
   `merge_sccs` and back-edge merge.
7. Unreachable states must panic (`unreachable!` / `expect`).
8. **The iteration driver must handle all absorption scenarios safely:**
   empty stack (nested commit), changed identity with ancestor, changed
   identity without ancestor.
9. **`solve_idx_erased` must not return `true` for a no-op drive.** Members
   that were not actually driven must not remain permanently `Fresh`.
10. **Both merge paths (merge_sccs and back-edge merge) must give merge
    priority to the top SCC** — the one currently being iterated.

---

## V3 Bugfix Integration Summary

| v3 Bugfix | v3 Commit | Disposition | v4 Commit |
|-----------|-----------|-------------|-----------|
| Fix LoopPhi increment test | `61c462aaaad7` | Squash into test | D2 |
| segment_size asymmetry | `2c89e856ead1` | Integrate | B2 |
| Absorption orphaning | `27be6c05697d` | Integrate | B6 |
| Free-floating in merge_sccs | `d07241c55fbc` | Integrate | A4 |
| Defer merge demotion | `287b6c5ecedd` | Integrate (split) | A4 + B6 |
| merge_happened for free-floating | `250c7e6e5fdb` | Integrate (split) | A4 |
| Free-floating in back-edge | `28c200680a01` | Integrate | B3 |
| Part-2 helpers (step 0) | `3631353ae342` | Integrate | A5 |
| Part-2 absorption guards (1+2) | `81c1af33ddba` | Integrate | B6 |
| Part-2 merge priority (step 3) | `c6c7fad06286` | Integrate | B3 |
| Evicted answers infinite loop | `6613eb6ed879` | Integrate | C1 |
| Quantified unique cache | `c2dcf288bc23` | Split: trunk + stack | Trunk + C4 |
| Two-phase locking | `c27c19a2c55c` | Exclude / redesign | — |

---

## Deferred Design Work

### Atomic SCC Batch Commit

The v3 two-phase locking commit (`c27c19a2c55c`) is excluded from v4. The
problem it addresses — partial SCC visibility during batch commit causing
nondeterminism — is real, but the v3 design (adding a `Locked` state to
`Calculation<T>`) has recognized shortcomings:

- It complicates the `Calculation` state machine for all consumers, not
  just iterative SCC solving.
- It does not fully solve nondeterminism (as noted in the v4 pre-plan).
- The RAII guard is tightly coupled to the current `AnswersSolver` method
  structure.

A v4 solution should explore alternatives:
1. **Batch-level visibility control:** Write to a shadow table and swap
   atomically, or use a generation counter.
2. **Separate the SCC commit protocol from the core Calculation state
   machine:** Keep `Calculation<T>` as a clean 3-state machine.
3. **Architectural elimination:** If SCC members can be committed
   atomically at a higher level (e.g., all-at-once swap), per-cell locking
   is unnecessary.

This is a separate design effort and should not block the v4 stack.

### Multi-Thread Coordination

The thundering-herd problem (multiple threads independently iterating the
same SCC) is partially mitigated by the deferred demotion fix (bounding
per-iteration work) but not eliminated. A full solution would involve a
"first-iterator-wins" protocol where only one thread iterates an SCC and
others wait. This is also deferred.

---

## Key Files

| File | Role |
|------|------|
| `pyrefly/lib/alt/answers_solver.rs` | `CalcStack`, `Scc`, iterative driver, `BindingAction` |
| `pyrefly/lib/alt/answers.rs` | `Answers`, `LookupAnswer`, cross-module dispatch |
| `pyrefly/lib/state/state.rs` | `TransactionHandle` and module lookup wiring |
| `pyrefly/lib/alt/solve.rs` / `traits.rs` | `Solve` trait, solver helpers, `Quantified` caching |
| `pyrefly/lib/binding/binding.rs` | `AnyIdx`, `dispatch_anyidx!`, binding definitions |
| `crates/pyrefly_config/src/base.rs` | `SccMode` config enum |
| `crates/pyrefly_util/src/uniques.rs` | `UniqueFactory`, `get_or_fresh` |

---

## Validation

- **Before each commit:** `./test.py --no-test --no-conformance`
- Full tests as time allows; CI covers the rest.
