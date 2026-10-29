# PyreflyFixpoint v2 — Design Plan

## Overview

This spec models Pyrefly's iterative fixpoint SCC solver with dynamic
dependency graphs. The key insight: dependency edges are discovered during
solving, so different phases may traverse different subsets of the true
graph. This means SCCs discovered in early phases may be incomplete, and
the solver must handle merges, demotions, and incomplete DFS coverage.

### Why no convergence check?

The real Pyrefly algorithm limits the number of fixpoint iterations (e.g.,
max 5). Convergence detection (checking whether answers stabilized) is an
optimization that allows early exit — if answers converge after iteration
2, iterations 3-5 are skipped. But the algorithm must be correct even
without convergence, because some SCCs genuinely don't converge.

This model uses a fixed number of iterations (MaxPhase) and skips
convergence entirely. This is sound because convergence just means "all
future iterations are no-ops" — omitting the optimization doesn't change
the correctness properties we want to verify.

---

## Constants

```
Nodes           — the set of node identifiers
full_graph      — [Nodes -> SUBSET Nodes], all real dependency edges
phase_graphs    — [0..MaxPhase -> [Nodes -> SUBSET Nodes]],
                  edges visible in each phase (subsets of full_graph)
MaxPhase        — Nat, number of phases (0 = discovery, 1..MaxPhase = iterations)
FullTraversalPhase — which phase always sees full_graph (e.g., 2)
TrueSccSets     — a set of sets of Nodes: the ground-truth SCCs of full_graph
                  (the strongly connected components with >= 2 members,
                  computed externally)
```

### Assumptions on Constants

```
\A p \in 0..MaxPhase :
    \A n \in Nodes : phase_graphs[p][n] \subseteq full_graph[n]

\A n \in Nodes :
    phase_graphs[FullTraversalPhase][n] = full_graph[n]
```

Making FullTraversalPhase a constant lets us:
- Test with FullTraversalPhase = 0 (every phase sees all edges) for fast traces
- Test with FullTraversalPhase = MaxPhase (full traversal only on last iteration)
  to stress-test invariant (c)
- Vary it to check that invariants hold regardless of when full traversal occurs

---

## Variables

```
state           — [Nodes -> GlobalState], calculation cell status
stack           — Seq(Nodes), the DFS/calculation stack
scc_stack       — Seq(SccRecord), stack of active SCCs
scc_anchors_read — [Nodes -> SUBSET Nat], per-node: set of SCC anchor_pos values
                   from which preliminary answers were read during computation
```

### GlobalState

```
{"Fresh", "InProgress", "Done"}
```

Same as v1 — models the Calculation cell.

### SccRecord

```
[
    members       : SUBSET Nodes,
    anchor_pos    : Nat,            \* position in stack of the deepest member
    phase         : 0..MaxPhase,    \* current iteration phase
    entry_idx     : Nodes,          \* min CalcId that started fixpoint for this SCC
    node_state    : [members -> SccNodeState],
    prev_answers  : SUBSET Nodes,   \* members with answers from previous phase
    curr_answers  : SUBSET Nodes,   \* members with answers from current phase
]
```

Note: `entry_idx` is set when we transition from phase 0 to phase 1 (the
start of fixpoint iteration). During phase 0, it can be unset / irrelevant.

### SccNodeState

```
[
    status           : {"SccFresh", "SccInProgress", "SccDone"},
    placeholder_used : BOOLEAN
]
```

We track `placeholder_used` to distinguish cold-start behavior (phases 0-1,
where back-edges create placeholders) from warm-start behavior (phases > 1,
where back-edges read previous answers).

---

## Actions

### Carried over from v1 (with modifications)

1. **StartRoot(n)** — Start DFS from a Fresh node when stack is empty.
   Unchanged from v1.

2. **Descend(dep)** — Top of stack has a Fresh dependency: push it.
   **Modified**: uses `phase_graphs[current_phase]` instead of `graph`.
   The "current phase" is the phase of the top SCC, or 0 if not in any SCC.
   For nodes not in any SCC, use `full_graph` (non-SCC nodes always see
   all edges; dynamic visibility only applies within SCC iteration context).

3. **DetectCycle(dep)** — Back-edge to an InProgress node on the stack.
   Same SCC creation/merging logic as v1. **Modified**: if we're in a
   fixpoint phase (phase > 0) and the merge expands the current SCC,
   mark the SCC for demotion.

4. **CreatePlaceholder(dep)** — In phases 0 and 1, back-edge within an SCC
   to an SccInProgress member. Creates a placeholder. Sets
   `placeholder_used = TRUE` on dep. Records the SCC's anchor_pos in
   `scc_anchors_read[top]`.

5. **FinishCalculation** — Pop top of stack. Update node state to SccDone
   (if in SCC) or Done (if not). Add node to `curr_answers`. If SCC is
   ready, trigger phase transition or commit.

### New actions for fixpoint iteration

6. **ReadPreviousAnswer(dep)** — In phases >= 2, back-edge within an SCC
   to an SccInProgress member that has a previous answer
   (`dep \in scc.prev_answers`). This fires at the same DFS back-edge point
   where phases 0 and 1 would use CreatePlaceholder. Returns the previous answer (modeled as:
   the dep is treated as resolved for purposes of the current node's
   FinishCalculation guard). Records the SCC's anchor_pos in
   `scc_anchors_read[top]`.

7. **TransitionPhase(scc_idx)** — When all members of an SCC are SccDone
   in the current phase and none remain on the stack (same readiness check
   as batch commit, but phase < MaxPhase):
   - Move `curr_answers` -> `prev_answers`
   - Reset all members to `SccFresh`
   - Clear `curr_answers`
   - Increment `phase`
   - If phase was 0 -> 1: set `entry_idx` to min(members)

8. **StartNextMember(n)** — Within fixpoint phases (1..MaxPhase), when:
   - The top of stack is at or above the SCC's anchor position
   - The current DFS tree within the SCC has fully unwound
   - There exists a member `n` with status `SccFresh`
   - `n` is the *minimum* SccFresh member (by node ordering)
   Push `n` onto the stack and mark it `SccInProgress`.
   This models the `while let Some(id) = next_fresh_member()` loop.
   Starting from the minimum is essential: it ensures deterministic
   traversal order, and invariant (c) verifies that this is sufficient
   to reach all members (given that some phase sees all edges).

9. **DemoteScc(scc_idx)** — When a merge during fixpoint iteration expanded
   the SCC's membership:
   - Reset phase to 1
   - Reset all members to SccFresh
   - Clear prev_answers and curr_answers
   - Recompute entry_idx as min(expanded members)
   This is a separate action from the merge itself; the merge sets a flag,
   demotion happens after the current drive loop completes. (In our model
   we can simplify and do it eagerly.)

10. **CommitScc(scc_idx)** — When all members are SccDone in phase MaxPhase:
    - Mark all members globally Done
    - Remove SCC from scc_stack

---

## Invariants

### Structural (carried from v1)
- **TypeOk** — type correctness of all variables
- **SccWellFormed** — SCC records have valid structure
- **StackIsInProgress** — everything on stack is globally InProgress
- **DepsBeforeDone** — Done nodes have all deps (in full_graph) Done
- **SccMembersGloballyInProgress** — SCC members are never globally Done
- **SccMembersDisjoint** — no node in multiple SCCs
- **SccHasLiveMember** — every SCC has at least one member on the stack
- **SccStackOrdered** — SCCs ordered by anchor_pos on scc_stack

### New invariants

**(a) No cross-SCC preliminary answer leakage:**

```
NoCrossSccLeakage ==
    \A n \in Nodes :
        LET anchors == scc_anchors_read[n]
            scc_idx == SccOf(n)
        IN  \/ anchors = {}
                \* No preliminary SCC answers were read. Either n is not
                \* in an SCC, or all its cyclic deps were dynamically dropped.
            \/ /\ Cardinality(anchors) = 1
               /\ scc_idx /= 0
               /\ scc_stack[scc_idx].anchor_pos \in anchors
                \* Exactly one SCC's answers were read, and it's the
                \* SCC that n belongs to.
```

A violation means a node read a preliminary answer from a *different* SCC
without being merged into it — the essential SCC merge correctness property.

**(b) Committed SCCs have correct minimal idx:**

```
CommittedSccHasCorrectMinIdx ==
    \* Checked at CommitScc time: the entry_idx of the committed SCC
    \* must equal the true minimum of its members.
    \* Since phase FullTraversalPhase traverses all edges, the SCC should
    \* have discovered all its true members by commit time.
    \A i \in 1..Len(scc_stack) :
        scc_stack[i].phase = MaxPhase =>
            scc_stack[i].entry_idx = MinOf(scc_stack[i].members)
```

And the stronger check: the committed members should be a true SCC (or
union of true SCCs — since our model forces full traversal at some phase,
it should match exactly):

```
CommittedSccMatchesTruth ==
    \* At commit time, the SCC's members should be exactly one of
    \* the ground-truth SCCs from TrueSccSets.
    \A i \in 1..Len(scc_stack) :
        scc_stack[i].phase = MaxPhase =>
            scc_stack[i].members \in TrueSccSets
```

**(c) No missing answer lookups:**

```
NoMissingPreviousAnswers ==
    \* During warm phases (> 1), whenever ReadPreviousAnswer fires
    \* for dep, dep must be in prev_answers. This is enforced as a
    \* guard on the ReadPreviousAnswer action, so this invariant
    \* checks that we never get stuck (a back-edge in a warm phase
    \* where the dep has no previous answer and no placeholder).
    \A i \in 1..Len(scc_stack) :
        scc_stack[i].phase > 1 =>
            \A n \in scc_stack[i].members :
                scc_stack[i].node_state[n].status = "SccDone" =>
                    n \in scc_stack[i].curr_answers

AllAnswersAtCommit ==
    \* At batch commit, every member has a current answer.
    \A i \in 1..Len(scc_stack) :
        scc_stack[i].phase = MaxPhase =>
            SccReadyToCommit(i) =>
                scc_stack[i].curr_answers = scc_stack[i].members
```

---

## Graph visible to a node

The graph a node sees depends on context:

```
VisibleGraph(n) ==
    LET scc_idx == SccOf(n)
    IN  IF scc_idx = 0
        THEN full_graph[n]          \* not in SCC: always see all edges
        ELSE phase_graphs[scc_stack[scc_idx].phase][n]
```

This means Descend's guard uses `dep \in VisibleGraph(top)` instead of
`dep \in graph[top]`.

---

## Phase lifecycle for an SCC

```
Phase 0 (Discovery):
    - Normal DFS with phase_graphs[0] visibility
    - Back-edges create SCCs / merge SCCs
    - CreatePlaceholder for within-SCC back-edges
    - prev_answers = {}, curr_answers grows as members complete
    - When all members SccDone: TransitionPhase -> Phase 1

Phase 1 (Cold Start):
    - All members reset to SccFresh
    - entry_idx set to min(members)
    - prev_answers = {} (phase 0 answers discarded)
    - StartNextMember drives members; back-edges use CreatePlaceholder
    - New cycle members discovered -> DemoteScc (restart at phase 1)
    - When all members SccDone: TransitionPhase -> Phase 2

Phase 2..MaxPhase-1 (Warm Iterations):
    - prev_answers = previous phase's curr_answers
    - Back-edges to SccInProgress members use ReadPreviousAnswer (read from prev_answers)
    - Phase FullTraversalPhase sees full_graph -> may discover new members
    - New members -> DemoteScc (restart at phase 1)
    - When all members SccDone: TransitionPhase -> next phase

Phase MaxPhase (Final Iteration):
    - Same as warm iteration
    - When all members SccDone: CommitScc (batch commit, all become Done)
```

---

## Model configuration for TLC

For tractable checking, suggest:
- Nodes = {"a", "b", "c", "d"} (4 nodes)
- MaxPhase = 3 (phases 0, 1, 2, 3)
- FullTraversalPhase = 2
- MaxDeps = 2 (keep graph simple)

For fast sanity checking:
- MaxPhase = 1 (just discovery + one iteration)
- FullTraversalPhase = 0 (all phases see everything)

---

## Differences from v1

| Aspect | v1 | v2 |
|--------|----|----|
| Graph | Single static `graph` | `full_graph` + per-phase `phase_graphs` |
| Phases | None (just discovery) | 0..MaxPhase with distinct behavior |
| Node state | Simple 3-state | Rich: status + placeholder + anchors_read |
| SCC record | members + anchor + node_state | + phase + entry_idx + prev/curr_answers |
| Placeholders | Generic SccHasPlaceholder | Phase-aware (only in phases 0-1) |
| Warm answers | N/A | ReadPreviousAnswer action (phases >= 2) |
| Multiple DFS roots | N/A | StartNextMember action |
| Demotion | N/A | DemoteScc action on membership expansion |
| Invariants | Stack/SCC structure | + cross-SCC leakage, correct min idx, no missing answers |
