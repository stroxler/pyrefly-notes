# SCC Solver: Synthesized Specification Gap Analysis

This document synthesizes two independent analyses of bugs in Pyrefly's SCC
solver (`answers_solver.rs`) relative to the TLA+ specification
(`PyreflyFixpoint.tla`). The two source analyses are referred to as the
"Claude analysis" and the "Codex analysis" throughout.

## 1. Background

The TLA+ specification models Pyrefly's SCC-based fixpoint solver. It tracks
each SCC with a record containing members, anchor position, phase number,
per-node state (`SccFresh` / `SccInProgress` / `SccHasPlaceholder` /
`SccDone`), and previous/current answer sets. Key spec actions include:

- **MergeOrCreateScc**: on any membership-expanding merge, `MergedPhase`
  always returns 0, clearing previous and current answers.
- **SccAllDone**: explicit check that all members are `SccDone` and none are
  on the stack.
- **TransitionPhase**: advances phase only when all members are done and off
  the stack; rotates current answers to previous answers and resets members
  to fresh.

The specification enforces four core invariants:
- **(a) NoCrossSccLeakage** -- no cross-SCC preliminary answer leakage.
- **(b) CommittedSccMatchesTruth** -- committed SCCs have correct membership.
- **(c) AllAnswersAtCommit** -- all members have answers at commit time.
- **(d) PrevAnswersComplete** -- at phase >= 2, `prev_answers` covers all members.

The implementation is known to have bugs causing nondeterminism (observed in
Sympy) and invariant-check panics (weakened in D96365463).

## 2. Issues Where Both Analyses Agree

### 2.1 Merge Preserves Iteration State Instead of Resetting to Phase 0

Both analyses identify this as a critical divergence. The spec's `MergedPhase`
always returns 0 on any membership-expanding merge, clearing all answer state.
The implementation's `Scc::merge` (around line 1750) takes `max(iteration)`
from the merging SCCs and unions `previous_answers`, preserving existing
`IterationNodeState::Done` answers.

**Consequences identified across both analyses:**

- `prev_answers` does not cover all members after merge. If SCC_A at
  iteration 3 merges with SCC_B at iteration 1, the merged SCC is at
  iteration 3 but `prev_answers` only covers SCC_A's original members.
  Back-edges hitting SCC_B nodes fall through to cold-placeholder paths.
  (Claude 2a)
- Stale Done answers from pre-merge SCCs are retained and used as if valid
  for the expanded SCC, but they were computed with the smaller membership.
  (Claude 2b)
- Demotion is deferred: `merge_happened` sets a flag, and demotion to
  iteration 1 happens only after the current drive loop completes. During
  the deferral window, warm-start reads can happen in the expanded SCC
  before restart is applied. (Claude 2c, Codex 1)

**Spec invariants violated:** (d) PrevAnswersComplete, (a) NoCrossSccLeakage.

**Key code refs:** `answers_solver.rs` lines ~1716, 1750, 1758, 1771, 2896.

### 2.2 SCC Completion Uses Anchor Arithmetic Instead of Explicit All-Done Check

Both analyses flag that `on_calculation_finished` pops SCCs based on
`stack_len <= scc.anchor_pos + 1` (line 844) rather than the spec's explicit
check that all members are `SccDone` and none remain on the stack.

**Consequences identified across both analyses:**

- SCCs can be popped prematurely if `anchor_pos` or `segment_size` is
  incorrect, leaving members still InProgress. This directly matches the
  observed class of bugs where nodes are "in an SCC but actually no SCC
  exists." (Claude 3a, 3c; Codex 2)
- `segment_size` is maintained through manual increment/decrement pairs
  across ~10 code paths, with `saturating_sub(1)` in `pop` masking
  potential underflow errors instead of surfacing them. (Claude 3b, Codex 7)

**Spec invariants violated:** (b) CommittedSccMatchesTruth,
(c) AllAnswersAtCommit, and the structural invariant that every InProgress
node belongs to a live SCC.

**Key code refs:** `answers_solver.rs` lines ~843-844, 345, 399-401, 523-524,
563.

### 2.3 Silent No-Op Fallbacks When SCC State Is Missing

Both analyses identify that multiple code paths silently return when expected
SCC state is absent, rather than failing fast as the spec's design implies.

**Key instances (combined):**

| Location | Fallback | What It Hides |
|----------|----------|---------------|
| `set_iteration_node_done` (~line 1062) | Silent return if no SCC | Premature SCC popping |
| `mark_iteration_changed` (~line 1090) | Silent return if no SCC | Premature SCC popping |
| `pop` (line 563) | `saturating_sub(1)` | `segment_size` underflow |
| `on_placeholder_recorded` (~line 1664) | Skip if already advanced | Duplicate placeholder recording |
| `push` (line 479) | `Calculate` on unexpected CycleDetected | Thread race / stale state |

These fallbacks convert invariant violations into nondeterministic behavior
rather than immediate failures. The weakened invariant checks from D96365463
are a specific instance.

**Key code refs:** `answers_solver.rs` lines ~1042, 1062, 1083, 1090.

### 2.4 `CycleDetected` Fallback to `Calculate` Without a Stack Cycle

Both analyses flag the code path where `Calculation::propose_calculation()`
returns `CycleDetected` but `current_cycle()` returns `None` and the node is
not in iteration state, causing a fallback to `BindingAction::Calculate`
(line 479). This admits inconsistent thread-local/global cycle state as
recoverable, and can create run-order-dependent behavior.

The Claude analysis further notes this as a likely source of the Sympy
nondeterminism, since two threads may compute the same node concurrently with
different placeholder resolution orders.

**Spec invariant violated:** (a) NoCrossSccLeakage.

**Key code refs:** `answers_solver.rs` lines ~458, 471, 479.

## 3. Issues Flagged Only in the Claude Analysis

### 3.1 Dual State Machines (Claude Issue 1)

The implementation tracks SCC node state in two parallel data structures:
legacy `NodeState` (`Fresh` / `InProgress` / `HasPlaceholder` / `Done`) and
`IterationNodeState` (`Fresh` / `InProgress { placeholder }` / `Done`). The
spec has a single `node_state` map.

Three sub-problems are identified:

- **Inconsistent state after absorb:** `absorb_calc_stack_members` (line 1807)
  adds nodes as `NodeState::InProgress` in the legacy map but
  `IterationNodeState::Fresh` in the iterative map. The `Fresh` iterative
  state causes the drive loop to re-push them, creating duplicate stack
  frames.
- **`pre_calculate_state` ignores iteration state:** The method (line 760)
  only consults legacy `node_state`. For nodes in iterating SCCs, this
  produces incorrect actions (e.g., `RevisitingInProgress` instead of
  returning an SCC-local answer).
- **State machines can contradict each other:** A node can be `Done` in one
  map but `Fresh` in the other after a merge. The ~300-line `push` method
  queries these maps in different orders depending on which early-return
  path is taken.

This is described as a structural issue contributing to violations of all four
invariants.

### 3.2 Additional `Calculation` Cell Race Conditions (Claude Issue 4b, 4c)

Beyond the `CycleDetected` fallback (covered in Section 2.4), the Claude
analysis identifies two more race conditions:

- **Participant + CycleDetected -> Calculate** (line 532): A Participant node
  that gets `CycleDetected` from the `Calculation` cell proceeds to
  `Calculate`, potentially running two concurrent computations of the same
  SCC member.
- **HasPlaceholder reads from `Calculation` before SCC-local state**
  (lines 512-514): If another thread committed a final answer between the
  SCC state check and the `Calculation` read, the node returns the committed
  answer instead of its placeholder, breaking SCC isolation.

## 4. Issues Flagged Only in the Codex Analysis

### 4.1 Iteration Membership Dropped Ad Hoc (Codex Issue 5)

If a member remains `Fresh` after driving (e.g., due to an evicted module
path), it is removed from iteration state to avoid infinite looping. While
operationally pragmatic, this weakens the "all SCC members driven" invariant
from the model. At commit time, the SCC may not have complete answer coverage.

**Key code refs:** `answers_solver.rs` lines ~1277, 2881, 2889.

### 4.2 Cross-Module Eviction Paths Weaken Solver Guarantees (Codex Issue 6)

`solve_idx_erased` and `commit_to_module` treat `TargetAnswers::Evicted` as
success/no-op, allowing drive and commit loops to proceed with missing target
context. This compounds with the ad-hoc membership dropping (4.1 above) to
increase partial-state outcomes.

**Key code refs:** `state/state.rs` lines ~2639, 2665.

## 5. Issues Considered and Rejected

No issues from either analysis are rejected. All flagged issues have concrete
code references and plausible invariant violations. The eviction-related
issues (4.1, 4.2) are pragmatic accommodations for real-world conditions the
spec does not model, but they still represent genuine weakening of the spec's
safety contract and are worth tracking.

## 6. Recommended Fixes

Prioritized from most to least critical, synthesized from both analyses.

### High Priority (Correctness)

1. **Phase-0 reset on merge.** When `Scc::merge` expands membership, reset
   iteration to 0 (or 1 in the code's 1-indexed scheme) and clear all
   answers, matching the spec's `MergedPhase`. The deferred demotion
   optimization can be re-added later only if it can be proven that no stale
   warm reads occur during the deferral window. *(Addresses 2.1)*

2. **Explicit all-done completion.** Replace the anchor-based SCC completion
   check with an explicit check that all members are `SccDone` and off the
   stack, matching the spec's `SccAllDone`. Remove `segment_size` tracking.
   *(Addresses 2.2)*

3. **Single state machine.** Unify `NodeState` and `IterationNodeState` into
   one enum used across all phases. The `iterative` field on `Scc` should
   contain only SCC-level metadata (iteration number, convergence flag,
   previous answers), not per-node state. *(Addresses 3.1)*

### Medium Priority (Correctness + Determinism)

4. **Remove `Calculation` cell reads during SCC computation.** SCC members
   should only read from SCC-local state. The `calculation.get()` checks in
   `HasPlaceholder` and `attempt_to_unwind_cycle_from_here` break SCC
   isolation and are a likely source of nondeterminism. *(Addresses 2.4, 3.2)*

5. **Replace silent fallbacks with panics.** Once fixes 1-3 are in place,
   convert defensive silent returns to `unreachable!` or `.expect()` to
   surface any remaining invariant violations. In the interim, add runtime
   counters or logging for fallback paths to quantify frequency and correlate
   with nondeterminism. *(Addresses 2.3)*

### Lower Priority (Robustness)

6. **Handle eviction explicitly.** Rather than silently treating evicted
   members as success, model a degraded-mode transition or at minimum log
   and track eviction-driven membership drops. *(Addresses 4.1, 4.2)*

7. **Simplify `push`.** With a single state machine and explicit completion
   checking, the ~300-line `push` method can be substantially simplified,
   reducing the surface area for interleaving bugs. *(Addresses 3.1)*
