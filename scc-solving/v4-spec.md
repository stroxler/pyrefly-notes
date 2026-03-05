# Iterative Fixpoint SCC Solving — v4 Specification

## Goals

### 1. Determinism

SCC solving must produce identical answers and errors regardless of thread
scheduling, DFS entry order, or any other source of nondeterminism. Given the
same set of bindings and dependencies, the output must be the same every time.

### 2. Better cycle-breaking UX

The current cycle-breaking approach produces "inconsistent types breaking
cycles" errors that are confusing and unhelpful to users. These errors arise
because the solver picks an arbitrary break point in a cycle, assigns a
placeholder there, and the resulting type mismatch is reported as an error.

Iterative fixpoint solving eliminates this class of errors: instead of breaking
a cycle once and reporting the inconsistency, we iterate until the answers
stabilize. Cycles that have a consistent solution produce no errors. Cycles
that are genuinely inconsistent still produce errors, but the errors reflect
the actual inconsistency rather than an artifact of where we happened to break
the cycle.

---

## Top-Level Invariants

These are the properties that must hold for the goals to be achieved. Everything
else in the design follows from these.

### Invariant 1: Iterative solving produces deterministic results based on SCC membership

Given a set of SCC members, the iterative fixpoint process must produce the
same answers and errors regardless of:
- Which member was the DFS entry point
- What order members are driven in
- What thread is running the iteration

This requires:
- A well-defined iteration protocol: cold start (iteration 1) uses uniform
  initial values, warm iterations use the previous iteration's answers, and
  convergence is checked uniformly across all members.
- When SCC membership changes (merge/demotion), iteration restarts from a
  clean cold start so that the expanded membership gets the same deterministic
  treatment.
- The final answers and errors come from a single, well-defined final
  iteration. Earlier iterations' errors are discarded.

### Invariant 2: Committed answers contain no live Vars

When an SCC's answers are committed, every `Type::Var` in the answer must be
deep-forced to a concrete type. No live (unforceable) `Var` may escape into a
committed answer.

This invariant is independent of Invariant 3. Even if preliminary answers never
leak (Invariant 3 is fully satisfied), a committed answer containing a live
`Var` produces nondeterminism: `Var` is mutable and can be unified or forced by
whoever touches it next, so the same `Var` can resolve to different concrete
types depending on thread scheduling and access order.

Additionally, a `Var` created in one module's solver is meaningless in another
module's context, so cross-module answers with live `Var`s will panic.

All unforced `Var`s are sources of nondeterminism, including partial `Var`s
(partially-solved type variables). However, the partial `Var` problem is out of
scope for this stack and is being addressed separately. This stack is
responsible for ensuring that the iterative fixpoint process deep-forces all
`Var`s in committed answers; the partial `Var` issue is a pre-existing problem
independent of SCC solving.

### Invariant 3: Preliminary SCC answers never leak outside the SCC

Until an SCC's iterative solving is complete and its final answers are
committed, no preliminary answer (from any iteration, including the discovery
phase) may be visible to any computation outside the SCC. A "preliminary
answer" is any answer produced during iteration that is not the final committed
result — this includes placeholder-based answers, partially-converged answers,
and discovery-phase answers.

Leaks can occur through several mechanisms:

**(a) Read-back without merge.** A computation outside the SCC reads a value
from an SCC member and gets a preliminary answer. The correct response is to
merge the reader into the SCC (since it now depends on the SCC's answers and
must iterate with it). Any failure to detect this read-back and merge is a
leak.

**(b) Returning stale results to the entry point.** The original caller that
triggered SCC discovery gets back the discovery-phase answer instead of the
final committed answer. The return value from `get_idx` for the entry point
must reflect the committed result.

**(c) Persisting intermediate answers.** Non-SCC bindings computed during
iteration may depend on preliminary SCC answers. If these are written to
`Calculation` cells via `record_value`, the stale answer is locked in
permanently (first-write-wins). Bindings computed in the presence of an active
SCC must not be persisted.

### Invariant 4: Cross-thread answer contamination is prevented

Even when the SCC's own iteration is correct, another thread may independently
compute the same binding (via `propose_calculation`'s parallel-compute
semantics) and write a stale answer before the SCC commits. The SCC's converged
answer must always win.

This requires that the commit protocol ensures atomicity: when an SCC commits,
either all of its answers are written or none are. No other thread can interleave
writes to SCC member cells during the commit window.

---

## Architectural Consequences

The design choices below are not goals in themselves — they are consequences of
the invariants above. Each is motivated by which invariant it serves.

### Iteration protocol (serves Invariant 1)

**Cold start on iteration 1:** All members start with the same uniform initial
value (a placeholder or sentinel), regardless of DFS entry order. This ensures
the first iteration's results depend only on the SCC's structure, not on
discovery order.

**Warm start on iteration 2+:** Each member's back-edge returns the previous
iteration's answer. This provides a monotonically-improving approximation.

**Convergence check:** After each iteration, compare all members' answers to
the previous iteration. If nothing changed, the fixpoint is reached. This must
use deep-forced answers to avoid `Var`-identity false negatives.

**Restart on membership change:** When a merge expands the SCC, restart from
iteration 1 (cold start) with the expanded membership. This ensures the
expanded SCC gets the same deterministic treatment as if it had been discovered
as a single SCC from the start. (Without restart, the pre-merge iterations'
answers for the original members would depend on the original, smaller
membership — violating the "deterministic based on membership" requirement.)

**Error handling across iterations:** Errors from non-final iterations are
discarded. Only the final (converged) iteration's errors are committed. This
prevents placeholder-induced errors from leaking to the user.

### Merge detection (serves Invariant 3a)

The primary mechanism for preventing read-back leaks is detecting when a
computation outside the SCC accesses an SCC member and merging the reader in.

This requires tracking which `CalcId`s belong to the active SCC and checking
every access against this membership set. The detection must cover:

- **Non-top SCC access:** A computation in a higher SCC (or no SCC) accesses
  a member of a lower iterating SCC on the stack. Requires merging all SCCs
  from the target to the top.

- **Top SCC access from outside the SCC region:** A computation that is on the
  CalcStack but outside the SCC's segment (between the SCC's anchor and the
  current stack top) accesses an SCC member. The intermediate non-SCC nodes
  form a cycle through the SCC and must be merged in.

- **Cross-module access:** A cross-module `solve_idx_erased` call may access
  an SCC member. The same merge logic must apply across module boundaries.

The stack metadata used for merge detection (anchor position, segment size,
membership sets) must be kept accurate through all code paths — including the
iterative bypass, which skips the normal push/pop accounting. Inaccuracy in
this metadata leads to missed merges, which leads to preliminary answer leaks.

### Return value freshness (serves Invariant 3b)

After `iterative_resolve_scc` commits final answers, the return path to the
original `get_idx` caller must reflect the committed answer. Since
`calculate_and_record_answer` returns the discovery-phase answer (before
iteration), the return value must be refreshed from the `Calculation` cell
after SCC completion.

### Write suppression during iteration (serves Invariant 3c)

Non-SCC bindings computed during iteration may depend on preliminary SCC
answers. These must not be persisted to `Calculation` cells. The mechanism is
to check whether the current thread has any active SCC on its stack; if so,
return the computed answer to the immediate caller (who needs it for their
computation) but skip `record_value`.

These bindings will be recomputed after the SCC commits, at which point they
will see the final answers and produce correct results.

### Atomic commit with write locking (serves Invariant 4)

SCC batch commits use a two-phase protocol:
1. **Lock phase:** Acquire write locks on all member `Calculation` cells (in
   deterministic order to avoid deadlocks between threads).
2. **Write phase:** Write all answers through the locked cells.

While a cell is write-locked, `record_value` from other threads blocks on a
condvar. This ensures that if two threads independently solve the same SCC,
the first to start committing writes all of its answers atomically. The second
thread's writes are all no-ops (first-write-wins on the already-`Calculated`
cells).

An RAII guard releases all locks on panic to prevent deadlocks.

---

## Key Boundary Points

The invariants above are enforced at specific points in the code where
information crosses a boundary. These are the places where violations are
possible and where the detailed contracts (specified in a later section) must
be precisely correct. Most of the v3 bugs occurred at one of these boundaries.

This section identifies *where* the boundaries are and *which invariants* are
at risk at each one. The detailed contracts (exactly what must be checked and
what action must be taken) are a further level of specification.

### `push` — entry into a computation

Every request to compute a `CalcId` goes through `push`. This is the primary
detection point for read-backs into an SCC (Invariant 3a). It must determine
whether the target is an SCC member and, if so, whether the caller is inside
or outside the SCC. Failure to detect a read-back here means a preliminary
answer leaks to a non-member.

This boundary is also where the iterative bypass lives: when the target is
an SCC member being iterated, `push` returns a cached/placeholder answer
instead of recomputing. The choice of which answer to return (previous
iteration, placeholder, cold placeholder) affects Invariant 1 (determinism
of the iteration protocol).

Invariants at risk: **1, 3a**

### `pop` and SCC draining

When a computation completes, `pop` removes it from the CalcStack and may
trigger SCC completion (draining completed SCCs). This is where the iteration
driver is entered (`iterative_resolve_scc`) for newly-completed SCCs.

The stack metadata (segment size, membership) must be updated consistently
here. Asymmetric accounting between `push` and `pop` (e.g., the iterative
bypass incrementing on one side but not the other) corrupts the metadata
that `push` relies on for merge detection.

Invariants at risk: **3a** (via metadata accuracy)

### `calculate_and_record_answer` — where results are persisted

This is the point where a computed answer is written to a `Calculation` cell.
Two sub-paths exist:

- **SCC member path:** The answer is stored in SCC-local iteration state, not
  in the `Calculation` cell. Deep-forcing must happen here (Invariant 2).
  Convergence comparison happens here (Invariant 1).

- **Non-SCC path:** The answer is written to the `Calculation` cell via
  `record_value`. If the current thread has an active SCC, this write must
  be suppressed (Invariant 3c) — the answer may depend on preliminary SCC
  values.

Invariants at risk: **1, 2, 3c**

### `get_idx` return path — where results are handed to callers

After `push`, computation, `pop`, and possible SCC draining, `get_idx` returns
a result to the caller. If the `CalcId` was an SCC entry point, the result
from `calculate_and_record_answer` is the discovery-phase answer, not the
final iterated answer. The return value must be refreshed from the committed
`Calculation` cell after SCC completion.

Invariants at risk: **3b**

### SCC merge points — where membership changes

There are two code paths that merge SCCs:

- **`merge_sccs`** (legacy path): triggered by `on_scc_detected` during
  Phase 0 discovery.
- **Membership back-edge merge** in `push`: triggered when the iterative
  bypass detects a read-back into an SCC.

Both paths must produce consistent results: the merged SCC's membership sets
(`node_state` and `iterative.node_states`) must agree, merge priority must
be consistent (the actively-iterated SCC's state should take priority), and
free-floating CalcStack nodes between SCCs must be absorbed.

When a merge happens during iteration, the iteration must be restarted
(demotion) to maintain determinism (Invariant 1).

Invariants at risk: **1, 3a**

### `iterative_resolve_scc` — the iteration driver

This is the top-level loop that drives iterative solving. It manages the
outer demotion loop and inner fixpoint loop. Key boundary concerns:

- **Absorption detection:** After driving all members, the SCC that was pushed
  may have been absorbed into an ancestor (or committed by a nested driver).
  The driver must detect this and either continue with the merged SCC or
  return safely without panicking or orphaning state.

- **Nested drivers:** A member's computation may trigger discovery of a new
  SCC, which starts its own `iterative_resolve_scc`. If the nested SCC merges
  with the parent, one driver must yield to the other. The protocol for
  determining which driver continues must be unambiguous.

- **Commit:** When iteration converges, the driver commits final answers. This
  is where the two-phase write locking (Invariant 4) and deep-forcing
  (Invariant 2) must happen.

Invariants at risk: **1, 2, 4**

### Cross-module boundary — `solve_idx_erased`

When an SCC spans multiple modules, driving a cross-module member goes through
`solve_idx_erased`, which constructs a temporary `AnswersSolver` for the
target module. This boundary has several concerns:

- The target module's `Answers` may have been evicted by another thread. The
  cross-module call must handle this gracefully — it cannot silently succeed
  without actually driving the member, or the member stays `Fresh` forever.

- The same merge detection logic that applies to same-module access must apply
  to cross-module access. A cross-module read-back into an SCC must trigger
  a merge.

- Write locking during commit must work across modules: the commit protocol
  needs to acquire locks on cross-module `Calculation` cells through the
  `LookupAnswer` trait.

Invariants at risk: **1, 3a, 4**

### `Calculation` cell — the shared state boundary

The `Calculation` cell is the interface between threads. It is where
Invariant 4 (cross-thread contamination) is enforced. Key operations:

- **`propose_calculation`:** Allows multiple threads to independently compute
  the same binding. This is the entry point for cross-thread races.

- **`record_value`:** First-write-wins semantics. Must block while write locks
  are held (Invariant 4). Must be skipped when the current thread has an
  active SCC (Invariant 3c).

- **`write_lock` / `write_unlock`:** Two-phase commit protocol for SCC batch
  commits. Must be acquired in deterministic order to avoid deadlocks.

Invariants at risk: **3c, 4**

---

## Boundary Contracts

This section specifies the detailed invariants that must hold at each boundary
point. Each contract is tied to the invariant it serves and describes what must
be checked and what action must be taken.

### Verification philosophy

Some of these contracts are hard to test directly (they involve specific
multi-threaded timing or nested SCC topologies). For contracts that cannot be
reliably exercised by tests, we require **runtime guardrail panics with
diagnostic context**. Contracts that must be enforced as runtime panics are
marked with **[panic]** below. These are not optional assertions — they are
required proof points that catch violations before they propagate into silent
nondeterminism. Guardrail panics are the primary non-test verification
mechanism for this system; where a contract cannot be reliably exercised by
unit or integration tests, a runtime panic with diagnostic context is
required.

### Contract → code touchpoints

This map indicates where each contract is primarily enforced. Since this is a
rewrite spec, exact line numbers will shift, but the file/function structure
is stable.

| Contracts | Primary location |
|---|---|
| P1–P4 | `answers_solver.rs` — `CalcStack::push` |
| Q1–Q2 | `answers_solver.rs` — `pop`, `pop_and_drain_completed_sccs` |
| R1–R6 | `answers_solver.rs` — `calculate_and_record_answer`, `calculate_and_record_answer_iterative` |
| G1 | `answers_solver.rs` — `get_idx` |
| M1–M4 | `answers_solver.rs` — `merge_sccs`, membership back-edge merge in `push` |
| I1–I8 | `answers_solver.rs` — `iterative_resolve_scc`, `drive_all_iteration_members` |
| X1–X3 | `state/state.rs` — `solve_idx_erased`; `alt/traits.rs` — `Solve` impls |
| C1–C5 | `calculation.rs` — `record_value`, `write_lock`, `write_unlock` |

### Contracts on `push`

**Contract P1: Membership back-edge detection must cover all SCC access
patterns (Invariant 3a)**

When iterative mode is active, `push` must check whether the target `CalcId`
is a member of *any* iterating SCC on the `scc_stack`, not just non-top SCCs.
There are two cases:

- *Non-top SCC:* The target is in an iterating SCC below the top of the
  `scc_stack`. All SCCs from the target's index to the top must be merged.
  The merged SCC must be marked `demoted` (triggering cold-start restart)
  because membership has changed.

- *Top SCC, caller outside the SCC region:* The target is in the top iterating
  SCC, but the caller (the `CalcId` at stack position - 1) is not an SCC
  member. This means non-SCC nodes exist on the CalcStack between the SCC
  region and the current position, forming a cycle through the SCC
  (`SCC member → ... → non-SCC node → SCC member`). These intermediate nodes
  must be merged into the SCC. The merge adds them to both `node_state` and
  `iterative.node_states` (as `Fresh`) and sets `merge_happened`.

The check for non-top SCCs must run before the top-SCC iterative bypass,
because cross-SCC back-edges take priority. SCCs still in Phase 0 discovery
(`iterative: None`) are handled by the existing `on_scc_detected` path.

**Contract P2: Iterative bypass returns the correct answer variant
(Invariant 1)**

When the target is in the top SCC's iteration state, `push` returns an answer
based on the member's `IterationNodeState`:

| Iteration node state | Action |
|---|---|
| `Fresh` | Mark `InProgress`, return `Calculate` |
| `InProgress` + previous answer exists | Return `SccLocalAnswer(previous)` |
| `InProgress` + placeholder exists | Return `CycleBroken(placeholder)` |
| `InProgress` + neither (cold start) | Return `NeedsColdPlaceholder` |
| `Done` | Return `SccLocalAnswer(answer)` |

These are the only valid states. If the target was found in an iterating SCC
but is not in the SCC's `iterative.node_states`, this is unreachable (the merge
should have added it). Violation must panic with diagnostic context. **[panic]**

**Contract P3: Eager breaking in iterative mode (Invariant 1)**

In iterative mode, `on_scc_detected` must always return `BreakHere`. Min-idx
breaking is never used. This ensures that Phase 0 is purely membership
discovery; all actual solving happens during iteration.

**Contract P4: `segment_size` must be maintained on all paths (Invariant 3a)**

The iterative bypass path returns early, before the normal `push` code that
increments `segment_size`. Since the `CalcId` is pushed onto the raw
CalcStack unconditionally (before the bypass check), `segment_size` must be
incremented in the bypass path as well. Otherwise `pop` will decrement a value
that was never incremented, corrupting the metadata that determines whether
a caller is inside or outside the SCC region.

**`push` self-audit checklist:**
- Does every early-return path (iterative bypass, merge) update `segment_size`?
- Does `find_iterating_scc_containing` run before the top-SCC bypass?
- Does the top-SCC case check whether the caller is inside the SCC region?
- When `position == 0` (root entry), is the caller treated as in-SCC? (There
  is no caller to check, so no merge is needed.)
- Does every code path that finds the target in an iterating SCC end with
  either a merge or a dispatch on `IterationNodeState`?

### Contracts on `pop` and SCC draining

**Contract Q1: Symmetric accounting with `push` (Invariant 3a)**

Every code path in `pop` that decrements `segment_size` or removes entries
from `position_of` must be symmetric with the corresponding `push` path. If
a `CalcId` was pushed via the iterative bypass (which skips the normal
`SccState::Participant` arm), `pop` must still handle it correctly. The
invariant is: after `push` + `pop` for any code path combination, the
CalcStack metadata is in the same state as before.

**Contract Q2: SCC draining triggers the iteration driver (Invariant 1)**

When `pop_and_drain_completed_sccs` drains an SCC that has `break_at` entries
and iterative mode is active, it must call `iterative_resolve_scc` for that
SCC. This is the only entry point for the iteration driver.

### Contracts on `calculate_and_record_answer`

**Contract R1: SCC members store answers in iteration-local state, not
`Calculation` cells (Invariant 3)**

When the current `CalcId` is a member of the top SCC's iteration state,
the answer must be stored in `IterationNodeState::Done` — never written to the
`Calculation` cell via `record_value`. Writing to the `Calculation` cell would
make the preliminary answer visible to other threads immediately, violating
Invariant 3.

**Contract R2: Deep-force all answers before storing (Invariant 2)**

Before storing an answer in `IterationNodeState::Done`, all `Var`s in the
answer must be deep-forced using the current module's solver. This ensures
that the stored answer contains no live `Var`s. The convergence comparison
(Contract R3) depends on this: comparing answers with live `Var`s produces
false negatives (two structurally identical answers with different `Var` IDs
would appear different).

**Contract R3: Convergence comparison against previous iteration (Invariant 1)**

After storing the deep-forced answer, compare it to the previous iteration's
answer for the same member (if one exists). If they differ, set `has_changed`
on the SCC's iteration state. The convergence check after driving all members
uses `has_changed` to decide whether another iteration is needed.

The comparison must use `answers_equal` (a type-erased deep equality check),
not pointer equality or `Var`-sensitive equality.

**Contract R4: Error suppression during cold-start iterations (Invariant 1)**

During iteration 1 (cold start), errors are suppressed (collected into a
swallowed collector). During iteration 2+, errors are collected normally. Only
the final iteration's errors are committed. This prevents placeholder-induced
errors from the cold start from reaching the user.

**Contract R5: Non-SCC bindings are not persisted during active SCC iteration
(Invariant 3c)**

When `calculate_and_record_answer` is called for a `CalcId` that is NOT in
any SCC's iteration state, but the current thread has an active SCC on its
`scc_stack` (i.e., `has_active_scc()` returns true), the answer must NOT be
written to the `Calculation` cell via `record_value`. The answer is returned
to the immediate caller (who needs it for their in-progress computation) but
is not persisted.

Rationale: the non-SCC binding's computation may have read preliminary SCC
answers via the iterative bypass. Persisting this answer would lock in a stale
value via first-write-wins. The binding will be recomputed after the SCC
commits, at which point it will see the final answers.

**Contract R6: Placeholder finalization for SCC members (Invariant 2)**

If a placeholder `Var` was created for the current member (via
`NeedsColdPlaceholder` during a back-edge), the placeholder must be finalized
(unified with the actual answer) before storing the answer in iteration state.
This ensures the placeholder is resolved and does not escape as a live `Var`.

### Contracts on `get_idx` return path

**Contract G1: Return value reflects committed answer after SCC completion
(Invariant 3b)**

After `pop_and_drain_completed_sccs` completes (which may trigger
`iterative_resolve_scc` and commit final answers), `get_idx` must check
whether the `Calculation` cell now contains a committed answer. If so, it
must return the committed answer, not the original result from
`calculate_and_record_answer`.

This is necessary because `calculate_and_record_answer` returns the
discovery-phase answer (the first time the member was computed, before
iteration). The iteration driver computes the final answer and commits it to
the `Calculation` cell. Without this refresh, the entry-point caller sees a
stale discovery-phase answer.

The override is unconditional: if `calculation.get()` returns `Some(v)`, use
`v` as the return value even if it differs from the earlier computed result.
The committed answer is always more authoritative than the in-flight result.

### Contracts on SCC merge points

**Contract M1: Merge priority is consistent — top SCC wins (Invariant 1)**

This is a determinism guarantee, not just an implementation detail. All merge
sites must present the top SCC (the one being actively iterated) as the first
element passed to `merge_many`. Inconsistent priority between merge sites
produces different results depending on which merge path fires, which depends
on thread scheduling and DFS order.

`Scc::merge(self, other)` gives `self`'s iteration states priority (inserted
unconditionally; `other`'s use `or_insert`). `merge_many` folds from the first
element, making it the initial accumulator.

Both merge paths must present the top SCC first:
- `merge_sccs` pops from the stack top → `[top, ..., bottom]` → correct.
- Membership back-edge merge drains in stack order → `[bottom, ..., top]` →
  must be reversed before calling `merge_many`.

If the top SCC's iteration states don't take priority, a member that was
already driven to `Done` can be reset to `Fresh` by a lower SCC's stale state,
causing redundant re-driving and potential nondeterminism.

**Contract M2: `node_state` and `iterative.node_states` must agree after merge
(Invariants 1, 3a)**

After any merge, every key in `node_state` must also appear in
`iterative.node_states` (when iteration is active). Both maps must contain the
same set of `CalcId`s. A member present in `node_state` but absent from
`iterative.node_states` is invisible to `next_fresh_member()` and will not be
driven during the current iteration.

This applies to:
- Members from the merged SCCs (handled by `Scc::merge_many`)
- Free-floating CalcStack nodes between the merged SCCs that are absorbed
  during the merge (must be explicitly added to both maps)

**Contract M3: Merges during iteration set `merge_happened`, not immediate
demotion (Invariant 1)**

When a merge occurs during an active `drive_all_iteration_members` call, the
merge must NOT immediately reset all members to `Fresh` and restart. Instead:
- Existing iteration states are preserved (`Done` stays `Done`, `InProgress`
  stays `InProgress`). Only genuinely new members are added as `Fresh`.
- The `merge_happened` flag is set on the iteration state.
- After `drive_all_iteration_members` returns, the driver checks
  `merge_happened` and triggers demotion (restart at iteration 1 with all
  members reset to `Fresh`).

This prevents the K×N work amplification from v3, where K merges within a
single drive loop each reset N members to `Fresh`, causing already-driven
members to be re-driven K times.

**Contract M4: `detected_at` uses `min` across merged SCCs (Invariant 1)**

When SCCs are merged, the resulting SCC's `detected_at` must be
`min(all merged detected_at values)`. This is used for absorption detection
in the iteration driver and must be deterministic regardless of merge order.

### Contracts on `iterative_resolve_scc`

**Contract I1: Empty stack after driving means nested driver committed
(Invariant 3)**

After `drive_all_iteration_members` returns, if the `scc_stack` is empty, a
nested `iterative_resolve_scc` absorbed and committed the current SCC. The
driver must return without attempting to access the stack. All members have
been committed by the nested driver.

**Contract I2: Changed `detected_at` requires safe absorption handling
(Invariants 1, 3)**

After driving, if the top SCC's `detected_at` differs from the driver's
`scc_identity`, the SCC was modified by a merge. The driver must distinguish
three cases:

1. *An ancestor iterating SCC exists below the current SCC on the stack:*
   The ancestor's driver will handle the merged SCC. Return.

2. *No ancestor, but the top SCC contains the driver's original `scc_identity`
   CalcId as a member:* The current SCC was merged with another SCC (changing
   `detected_at`), but no other driver exists. The current driver must continue
   with the updated identity.

3. *No ancestor, and the top SCC does not contain the driver's CalcId:* The
   driver's SCC was committed by a nested driver, and an unrelated SCC (e.g.,
   a Phase 0 SCC) remains on the stack. Return.

The check must use *membership* (`top_scc_contains_member`), not *identity*
(`detected_at` matching). When two SCCs merge and the other has a smaller
`detected_at`, the merged SCC's `detected_at` becomes that smaller value. The
original `scc_identity` no longer appears as any SCC's `detected_at`, but it
IS still in the merged SCC's `node_state`.

**Contract I3: Drive all members, not single DFS (Invariant 1)**

Because every back-edge breaks immediately in iterative mode, a single DFS
from one entry point can miss reachable members (they're on the other side of
a broken back-edge). The driver must use:
```
while let Some(id) = next_fresh_member() { drive_member(id) }
```
This ensures all members are driven regardless of the dependency graph's
structure.

**Contract I4: Cold start on iteration 1, warm start on iteration 2+
(Invariant 1)**

- Iteration 1: all members start `Fresh`. Back-edges to `InProgress` members
  with no previous answer return `NeedsColdPlaceholder` (producing a uniform
  placeholder).
- Iteration 2+: `previous_answers` is populated from the previous iteration's
  `Done` answers. Back-edges to `InProgress` members return
  `SccLocalAnswer(previous)`.

**Contract I5: Demotion restarts from clean cold start (Invariant 1)**

When `merge_happened` is detected after driving, increment the demotion
counter and restart at iteration 1. `set_fresh_iteration_state` must rebuild
`iterative.node_states` from `node_state.keys()` (the expanded membership),
clearing all previous answers and iteration state. This ensures the expanded
SCC is treated as if it were discovered as a single SCC from the start.

**Contract I6: Convergence requires iteration >= 2 and no changes
(Invariant 1)**

The fixpoint loop exits when `iteration >= 2` and `has_changed == false`. This
is correct because:
- Iteration 1 uses placeholders, so its answers are always provisional.
- Iteration 2 uses iteration 1's real answers. If iteration 2 produces the
  same answers, the fixpoint is reached.
- Checking `has_changed` after iteration 1 would always succeed (nothing
  to compare against), producing incorrect results.

**Contract I7: Bounded iteration with safe limits (Invariant 1) [panic on
demotion limit]**

- `MAX_ITERATIONS` (e.g., 5): if exceeded, emit a warning and commit the last
  iteration's answers. Do not panic — some SCCs may genuinely not converge
  within the limit.
- `MAX_DEMOTIONS` (e.g., 10): if exceeded, panic. Unbounded demotion indicates
  a bug in merge detection (SCCs that should have been merged earlier keep
  merging late). Violation must panic with diagnostic context. **[panic]**

**Contract I8: Post-drive invariant check (Invariant 1) [panic]**

After `drive_all_iteration_members` returns (and before the absorption check),
verify that no member is still `Fresh`. A `Fresh` member after driving
indicates a `drive_member` call that did not transition the member (e.g., the
`solve_idx_erased` eviction bug). This should panic with a diagnostic dump
including the stuck member's `CalcId`, the SCC's iteration state, and the
CalcStack depth. Violation must panic with diagnostic context. **[panic]**

### Contracts on `solve_idx_erased` (cross-module boundary)

**Contract X1: Evicted answers must not silently succeed (Invariant 1, 3a)
[panic]**

When `lookup_target_answers` returns `Evicted` (another thread evicted the
target module's `Answers`), `solve_idx_erased` must NOT return `true`.
Evicted must be treated as a failure return: `solve_idx_erased` returns
`false` (or an equivalent failure signal), and the iteration driver must
remove the member from `iterative.node_states` (since its answers are already
committed to `Calculation` cells by the thread that evicted the `Answers`).
If the member is left in iteration state as `Fresh`, the drive loop spins
forever.

**Contract X2: Cross-module write locking for batch commit (Invariant 4)**

The commit protocol must be able to acquire write locks on cross-module
`Calculation` cells. The `LookupAnswer` trait must provide
`write_lock_in_module`, `write_unlock_in_module`, and
`write_unlock_empty_in_module` methods that route to the target module's
`Answers`.

For evicted modules, the write lock methods should return `false` / be no-ops
(the answers are already finalized).

**Contract X3: Exported keys must not create real `Var` placeholders
(Invariant 2)**

Keys that cross module boundaries (like `KeyExport`) must not create real
`Type::Var` placeholders during recursion breaking. A `Var` created in module
A's solver is meaningless in module B's context and will panic when deep-forced
by module B's solver.

Exported keys that delegate to underlying keys should use inert placeholders
(e.g., `Type::Any(AnyStyle::Implicit)` or `Var::ZERO`) and let the underlying
key handle its own recursion breaking.

### Contracts on `Calculation` cell (shared state boundary)

**Contract C1: `record_value` blocks during write locks (Invariant 4)**

When a `Calculation` cell's `write_locked` flag is true, `record_value` must
block on the condvar until the flag is cleared. This prevents a concurrent
thread from writing a stale answer while an SCC batch commit is in progress.

After unblocking, `record_value` proceeds with normal first-write-wins
semantics: if the cell is now `Calculated` (the SCC commit wrote it), the
write is a no-op.

**Contract C2: Write locks are acquired in deterministic order (Invariant 4)**

When `batch_commit_scc` or `commit_final_answers` locks multiple cells, the
locks must be acquired in a deterministic order (sorted by `CalcId`). This
prevents deadlocks between two threads that independently solve the same SCC
and try to commit simultaneously.

`BTreeMap` iteration order provides this naturally when iterating `node_state`
or `iterative.node_states`.

**Contract C3: RAII guard releases locks on panic (Invariant 4)
[panic-safety]**

*(This is a panic-safety contract, not a runtime-panic-on-violation contract.
It ensures that if other code panics during the commit window, write locks are
cleaned up to prevent deadlocks.)*

An `SccWriteLockGuard` must track all acquired write locks. If the commit
panics (or any intervening code panics during the write phase), the guard's
`Drop` implementation must call `write_unlock_empty` on every locked cell.
On successful commit, `disarm()` clears the guard so `Drop` is a no-op.

Without this guard, a panic during commit leaves cells permanently
write-locked, causing all future `record_value` calls to block forever
(deadlock). Violation (missing guard) must be treated as a correctness bug.
**[panic-safety]**

**Contract C4: `write_lock` returns false for `Calculated` cells
(Invariant 4)**

If a cell is already `Calculated` when `write_lock` is called, the lock is
not acquired and `write_lock` returns `false`. This is correct because
`record_value` on an already-`Calculated` cell is a no-op (first-write-wins),
so there is nothing to protect. The commit code must skip `write_unlock` for
cells where `write_lock` returned `false`.

**Contract C5: `propose_calculation` is unaffected by write locks
(Invariant 4)**

Write locks only affect `record_value`, not `propose_calculation`. A thread
can still propose computation of a write-locked cell and receive `Calculatable`
or `CycleDetected`. The write lock only blocks at the point of writing the
result, not at the point of starting computation. This prevents deadlocks
where a thread needs to compute a dependency of the SCC being committed.
