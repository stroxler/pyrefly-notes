# Minimal Example: break_at Nondeterminism in Pyrefly's SCC Cycle-Breaking

## Elevator Pitch

Pyrefly discovers sub-cycles incrementally during DFS and computes each
sub-cycle's `break_at` as its minimum `Def` node. When sub-cycles merge, their
break_at sets are unioned. Different DFS entry points into the same SCC cause
the same edges to be decomposed into different sub-cycles -- a small sub-cycle
discovered independently contributes its own minimum (e.g., `M`), but the same
nodes discovered as part of a larger sub-cycle that also contains a smaller node
(`A < M`) are shadowed. The result: `M` appears in `break_at` in one run but
not the other.

## The Graph

### ASCII Diagram

```
              +-----+
         +--->| S   |----+
         |    +-----+    |
         |               v
      +-----+         +-----+
      | A   |         | P   |
      +-----+         +-----+
         ^               |
         |               v
         |    +-----+    +-----+
         +----| Q   |<---+     |
    (1st edge)+-----+          |
                  |             |
            (2nd edge)         |
                  v             |
              +-----+          |
              | M   |          |
              +-----+          |
                  |             |
                  v             |
              +-----+          |
              | R   |------> (to S)
              +-----+
```

More precisely:

```
    S ----> P ----> Q ----> A ----> S       (Cycle C_A: 4 nodes)
                    |
                    +-----> M ----> R ----> S ----> P ...  (Cycle C_M: 5 nodes)
```

### Adjacency List (edge ordering is fixed per node)

| Node | Edges (in fixed order) |
|------|----------------------|
| S    | [P]                  |
| P    | [Q]                  |
| Q    | [A, M]  (A first)   |
| A    | [S]                  |
| M    | [R]                  |
| R    | [S]                  |

### CalcId Ordering

```
Def(A) < Def(M) < Aux(P) < Aux(Q) < Aux(R) < Aux(S)
```

`Def` nodes have smaller CalcIds than `Aux` nodes. Among `Def` nodes, `A < M`.

### True SCC

All 6 nodes form a single SCC: {A, M, P, Q, R, S}.

### Sub-Cycles

| Cycle | Members           | Def nodes | min(Def) |
|-------|-------------------|-----------|----------|
| C_A   | {S, P, Q, A}      | {A}       | A        |
| C_M   | {S, P, Q, M, R}   | {M}       | M        |

C_A and C_M share nodes {S, P, Q}. The full SCC is their union.

## Why This Example Is Minimal

- **5 nodes would not suffice.** We need two overlapping sub-cycles C_A and C_M
  that share at least two nodes (to form a single SCC) but differ in their Def
  membership. C_A needs at least A plus shared nodes; C_M needs at least M, R,
  plus shared nodes. With the shared set {S, P, Q} being the minimum for two
  overlapping cycles that share an edge path (3 nodes), plus A and M as the
  differentiating Def nodes, plus R as M's private intermediate node, we arrive
  at 6 nodes.
- **The graph has exactly 6 edges.** Each node has 1 outgoing edge except Q
  (which has 2). The Q branch is essential: it creates the two overlapping
  sub-cycles.
- **R is necessary.** Without R, M would connect directly to S, but then C_M
  would be {S, P, Q, M} -- the same size as C_A. The nondeterminism requires
  M's sub-cycle to be larger (or at least different enough) so that it can be
  discovered independently or merged, depending on the entry point. R provides
  the extra hop in M's path back to S.

## The Two Scenarios

### Scenario 1: Enter at S

**Result: break_at = {A, M}** -- M IS in break_at.

The DFS enters the SCC at node S. Because M is not on the CalcStack when the
M-containing sub-cycle is discovered during re-solve, M's sub-cycle is found
as an independent sub-cycle with break_at = {M}.

### Scenario 2: Enter at M

**Result: break_at = {A}** -- M is NOT in break_at.

The DFS enters the SCC at node M. Because M is on the CalcStack at position 0
(the entry point), when the re-solve reaches M via Q's second edge, M is already
on the stack. The back-edge to M creates a cycle from position 0 to the current
top -- including A. Since A < M, A is the minimum and M is shadowed.

## Scenario 1: Full Trace (Enter at S)

### Phase 1: Original DFS and Initial Cycle Detection

**Step 1.** External code calls `get_idx(S)`.
```
push S
Stack: [S]
       pos 0
pos_of: {S:[0]}
Action: NotInScc, Calculatable -> Calculate
```
S.solve() begins.

**Step 2.** S.solve() calls `get_idx(P)`.
```
push P
Stack: [S, P]
       0  1
pos_of: {S:[0], P:[1]}
Action: NotInScc, Calculatable -> Calculate
```
P.solve() begins.

**Step 3.** P.solve() calls `get_idx(Q)`.
```
push Q
Stack: [S, P, Q]
       0  1  2
pos_of: {S:[0], P:[1], Q:[2]}
Action: NotInScc, Calculatable -> Calculate
```
Q.solve() begins.

**Step 4.** Q.solve() calls `get_idx(A)` (Q's first edge).
```
push A
Stack: [S, P, Q, A]
       0  1  2  3
pos_of: {S:[0], P:[1], Q:[2], A:[3]}
Action: NotInScc, Calculatable -> Calculate
```
A.solve() begins.

**Step 5.** A.solve() calls `get_idx(S)`.
```
push S
Stack: [S, P, Q, A, S]
       0  1  2  3  4
pos_of: {S:[0,4], P:[1], Q:[2], A:[3]}
```
**Back-edge detected!** S has positions [0, 4].

`pre_calculate_state(S)`: No SCC exists yet. Returns NotInScc.
`propose_calculation()`: S is Calculating (from Step 1). Returns CycleDetected.

`current_cycle()`:
- cycle_start = pos_of[S][0] = 0 (second-to-last position)
- cycle_entries = stack[1..] reversed = [S, A, Q, P]
- raw = [S, A, Q, P]

`on_scc_detected(raw)`:
- detected_at = S (raw.first())
- break_at = min(S, A, Q, P) = **A**
- SCC created: members = {S, A, Q, P}, break_at = {A}
- break_at.contains(S)? No -> **Continue**

```
SCC #1: members={S, A, Q, P}, break_at={A}, detected_at=S, anchor_pos=0
```

Action: Calculate. `calculate_and_record_answer(S)` at pos 4 begins.

### Phase 2: Re-solve of SCC (S at pos 4)

**Step 6.** S(pos 4).solve() calls `get_idx(P)`.
```
push P
Stack: [S, P, Q, A, S, P]
       0  1  2  3  4  5
pos_of: {S:[0,4], P:[1,5], Q:[2], A:[3]}
```
`pre_calculate_state(P)`: P is in SCC #1, state = Fresh -> InProgress. Returns **Participant**.
`propose_calculation()`: P is Calculating. Returns CycleDetected.
Action: Calculate.

**Step 7.** P(pos 5).solve() calls `get_idx(Q)`.
```
push Q
Stack: [S, P, Q, A, S, P, Q]
       0  1  2  3  4  5  6
pos_of: {S:[0,4], P:[1,5], Q:[2,6], A:[3]}
```
`pre_calculate_state(Q)`: Q in SCC #1, Fresh -> InProgress. **Participant**. CycleDetected. Calculate.

**Step 8.** Q(pos 6).solve() calls `get_idx(A)` (Q's first edge).
```
push A
Stack: [S, P, Q, A, S, P, Q, A]
       0  1  2  3  4  5  6  7
pos_of: {S:[0,4], P:[1,5], Q:[2,6], A:[3,7]}
```
`pre_calculate_state(A)`: A is in break_at of SCC #1. A's state = Fresh. Returns **BreakAt**.
Action: Unwind. `attempt_to_unwind_cycle_from_here(A)` creates placeholder variable for A.
`on_placeholder_recorded(A, var)`: A's state -> HasPlaceholder(var).
Returns Err(var) -> promoted to placeholder type.
```
pop A
Stack: [S, P, Q, A, S, P, Q]
       0  1  2  3  4  5  6
```

**Step 9.** Q(pos 6).solve() calls `get_idx(M)` (Q's second edge).
```
push M
Stack: [S, P, Q, A, S, P, Q, M]
       0  1  2  3  4  5  6  7
pos_of: {S:[0,4], P:[1,5], Q:[2,6], A:[3], M:[7]}
```
`pre_calculate_state(M)`: M is NOT in SCC #1. Returns **NotInScc**.
`propose_calculation()`: M has never been calculated. Returns **Calculatable**.
Action: Calculate. M.solve() begins (M is computed as a fresh, non-SCC node).

**Step 10.** M.solve() calls `get_idx(R)`.
```
push R
Stack: [S, P, Q, A, S, P, Q, M, R]
       0  1  2  3  4  5  6  7  8
pos_of: {S:[0,4], P:[1,5], Q:[2,6], A:[3], M:[7], R:[8]}
```
R is not in any SCC, never calculated. Calculatable. Calculate. R.solve() begins.

**Step 11.** R.solve() calls `get_idx(S)`.
```
push S
Stack: [S, P, Q, A, S, P, Q, M, R, S]
       0  1  2  3  4  5  6  7  8  9
pos_of: {S:[0,4,9], P:[1,5], Q:[2,6], A:[3], M:[7], R:[8]}
```
`pre_calculate_state(S)`: S is in SCC #1, state = Fresh -> InProgress. **Participant**.
segment_size += 1.
`propose_calculation()`: S is Calculating. CycleDetected. Calculate.

**Step 12.** S(pos 9).solve() calls `get_idx(P)`.
```
push P
Stack: [S, P, Q, A, S, P, Q, M, R, S, P]
       0  1  2  3  4  5  6  7  8  9  10
pos_of: {S:[0,4,9], P:[1,5,10], Q:[2,6], A:[3], M:[7], R:[8]}
```
`pre_calculate_state(P)`: P is in SCC #1, state = InProgress. Returns **RevisitingInProgress**.
`propose_calculation()`: CycleDetected.

**`current_cycle()`**:
- P has positions [1, 5, 10]
- cycle_start = positions[len-2] = positions[1] = **5** (second-to-last)
- cycle_entries = stack[6..] reversed = [P, S, R, M, Q]

```
raw = [P, S, R, M, Q]
```

**`on_scc_detected(raw)`**:
- detected_at = P
- break_at = min(P, S, R, M, Q) = **M**
- New sub-cycle: members = {P, S, R, M, Q}, break_at = {M}
- Check overlap with SCC #1: SCC #1 has anchor_pos=0, segment extends to cover
  stack positions 0 through top. The new cycle starts at pos 5. Overlap detected.
- **Merge**: SCC #1 break_at {A} union new break_at {M} = **{A, M}**

```
Merged SCC: members={S, A, Q, P, M, R}, break_at={A, M}

*** CRITICAL: M entered break_at because it was the minimum of an
*** independent sub-cycle {P, S, R, M, Q} that did not contain A.
```

The rest of the computation continues (unwinding, completing nodes, batch commit).

**Scenario 1 final break_at: {A, M}**

---

## Scenario 2: Full Trace (Enter at M)

### Phase 1: Original DFS and Initial Cycle Detection

**Step 1.** External code calls `get_idx(M)`.
```
push M
Stack: [M]
       pos 0
pos_of: {M:[0]}
Action: NotInScc, Calculatable -> Calculate
```
M.solve() begins.

**Step 2.** M.solve() calls `get_idx(R)`.
```
push R
Stack: [M, R]
       0  1
pos_of: {M:[0], R:[1]}
Action: NotInScc, Calculatable -> Calculate
```
R.solve() begins.

**Step 3.** R.solve() calls `get_idx(S)`.
```
push S
Stack: [M, R, S]
       0  1  2
pos_of: {M:[0], R:[1], S:[2]}
Action: NotInScc, Calculatable -> Calculate
```
S.solve() begins.

**Step 4.** S.solve() calls `get_idx(P)`.
```
push P
Stack: [M, R, S, P]
       0  1  2  3
pos_of: {M:[0], R:[1], S:[2], P:[3]}
Action: NotInScc, Calculatable -> Calculate
```
P.solve() begins.

**Step 5.** P.solve() calls `get_idx(Q)`.
```
push Q
Stack: [M, R, S, P, Q]
       0  1  2  3  4
pos_of: {M:[0], R:[1], S:[2], P:[3], Q:[4]}
Action: NotInScc, Calculatable -> Calculate
```
Q.solve() begins.

**Step 6.** Q.solve() calls `get_idx(A)` (Q's first edge).
```
push A
Stack: [M, R, S, P, Q, A]
       0  1  2  3  4  5
pos_of: {M:[0], R:[1], S:[2], P:[3], Q:[4], A:[5]}
Action: NotInScc, Calculatable -> Calculate
```
A.solve() begins.

**Step 7.** A.solve() calls `get_idx(S)`.
```
push S
Stack: [M, R, S, P, Q, A, S]
       0  1  2  3  4  5  6
pos_of: {M:[0], R:[1], S:[2,6], P:[3], Q:[4], A:[5]}
```
**Back-edge detected!** S has positions [2, 6].

`pre_calculate_state(S)`: No SCC exists. NotInScc.
`propose_calculation()`: S is Calculating (from Step 3). CycleDetected.

`current_cycle()`:
- cycle_start = pos_of[S][0] = 2 (second-to-last position)
- cycle_entries = stack[3..] reversed = [S, A, Q, P]
- raw = [S, A, Q, P]

`on_scc_detected(raw)`:
- detected_at = S
- break_at = min(S, A, Q, P) = **A**
- SCC created: members = {S, A, Q, P}, break_at = {A}
- break_at.contains(S)? No -> **Continue**

```
SCC #1: members={S, A, Q, P}, break_at={A}, detected_at=S, anchor_pos=2
```

Note: this is the SAME initial SCC as Scenario 1. The first 4-node cycle
{S, A, Q, P} = C_A is always discovered first because Q's first edge is A.
The difference will emerge in Phase 2.

Action: Calculate. `calculate_and_record_answer(S)` at pos 6 begins.

### Phase 2: Re-solve of SCC (S at pos 6)

**Step 8.** S(pos 6).solve() calls `get_idx(P)`.
```
push P
Stack: [M, R, S, P, Q, A, S, P]
       0  1  2  3  4  5  6  7
pos_of: {M:[0], R:[1], S:[2,6], P:[3,7], Q:[4], A:[5]}
```
`pre_calculate_state(P)`: P in SCC #1, Fresh -> InProgress. **Participant**. CycleDetected. Calculate.

**Step 9.** P(pos 7).solve() calls `get_idx(Q)`.
```
push Q
Stack: [M, R, S, P, Q, A, S, P, Q]
       0  1  2  3  4  5  6  7  8
pos_of: {M:[0], R:[1], S:[2,6], P:[3,7], Q:[4,8], A:[5]}
```
Q in SCC #1, Fresh -> InProgress. **Participant**. CycleDetected. Calculate.

**Step 10.** Q(pos 8).solve() calls `get_idx(A)` (Q's first edge).
```
push A
Stack: [M, R, S, P, Q, A, S, P, Q, A]
       0  1  2  3  4  5  6  7  8  9
pos_of: {M:[0], R:[1], S:[2,6], P:[3,7], Q:[4,8], A:[5,9]}
```
`pre_calculate_state(A)`: A is in break_at of SCC #1. State = Fresh. Returns **BreakAt**.
Action: Unwind. Placeholder created for A.
```
pop A
Stack: [M, R, S, P, Q, A, S, P, Q]
       0  1  2  3  4  5  6  7  8
```

**Step 11.** Q(pos 8).solve() calls `get_idx(M)` (Q's second edge).
```
push M
Stack: [M, R, S, P, Q, A, S, P, Q, M]
       0  1  2  3  4  5  6  7  8  9
pos_of: {M:[0,9], R:[1], S:[2,6], P:[3,7], Q:[4,8], A:[5]}
```
**Back-edge detected!** M has positions [0, 9].

`pre_calculate_state(M)`: M is NOT in SCC #1. Returns **NotInScc**.
`propose_calculation()`: M is Calculating (from Step 1, M's original frame
hasn't returned). Returns **CycleDetected**.

**`current_cycle()`**:
- M has positions [0, 9]
- cycle_start = pos_of[M][0] = **0** (the ONLY previous position, from original entry)
- cycle_entries = stack[1..] reversed = [M, Q, P, S, A, Q, P, S, R]

```
raw = [M, Q, P, S, A, Q, P, S, R]
```

The raw cycle contains these **unique** members: **{M, Q, P, S, A, R}** -- ALL 6 nodes.

```
*** CRITICAL: A is in this cycle because A is on the stack at position 5,
*** which is BETWEEN M's position 0 and the current top (position 9).
*** A is there because the DFS entered at M (pos 0), went through R, S,
*** P, Q, A on the original path, and A's frame hasn't returned yet.
```

**`on_scc_detected(raw)`**:
- detected_at = M
- break_at = min(M, Q, P, S, A, Q, P, S, R) = **A**
- New sub-cycle: members = {A, M, P, Q, R, S}, break_at = {A}
- Check overlap with SCC #1 {S,A,Q,P}: overlap detected.
- **Merge**: SCC #1 break_at {A} union new break_at {A} = **{A}**

```
Merged SCC: members={A, M, P, Q, R, S}, break_at={A}

*** M is NOT in break_at because it was part of a sub-cycle that
*** ALSO contained A (since A < M, A was the minimum, shadowing M).
```

**Scenario 2 final break_at: {A}**

---

## Side-by-Side Comparison

| Aspect | Scenario 1 (enter at S) | Scenario 2 (enter at M) |
|--------|------------------------|------------------------|
| Entry node | S (an Aux node in the SCC) | M (the contested Def node) |
| Initial cycle found | C_A = {S,A,Q,P}, break_at={A} | C_A = {S,A,Q,P}, break_at={A} |
| M on CalcStack when Q explores M? | No (M never pushed) | Yes (M at pos 0, still Calculating) |
| What happens at Q -> M | M pushed fresh (Calculatable) | M's push triggers CycleDetected |
| M's sub-cycle | {P, S, R, M, Q}, independent, min = M | {A, M, P, Q, R, S}, includes A, min = A |
| Sub-cycle's break_at | {M} | {A} |
| After merge | {A} union {M} = **{A, M}** | {A} union {A} = **{A}** |
| **M in final break_at?** | **YES** | **NO** |

## The Nondeterminism Mechanism

### Why the entry point matters

The DFS entry point determines which nodes are on the CalcStack as "ancestors"
-- i.e., nodes whose `get_idx` frames have not yet returned. When a later push
of the same CalcId is detected, `current_cycle()` extracts the stack segment
from the node's first occurrence to the top. Everything between those two
positions becomes part of the sub-cycle.

### The critical moment

In both scenarios, Q's second edge leads to M. The difference:

**Scenario 1 (enter at S):**
- M has never been pushed. It is not on the CalcStack.
- `push(M)` succeeds as a fresh node: NotInScc, Calculatable.
- M.solve() runs, calling get_idx(R), then R calls get_idx(S).
- S is already on the stack (SCC member, InProgress), creating a back-edge.
- The sub-cycle from this back-edge goes from P's re-solve position (pos 5) to
  the current top. This segment is [Q, M, R, S, P] -- does NOT include A
  (A was already processed and popped from the stack at this point).
- Sub-cycle minimum = M. M enters break_at.

**Scenario 2 (enter at M):**
- M is on the CalcStack at position 0 (the original entry point). M is still
  Calculating because the DFS went M -> R -> S -> ... and is now deep inside
  SCC re-solve.
- `push(M)` detects M at positions [0, 9]. CycleDetected.
- `current_cycle()` uses cycle_start = 0 (M's first position).
- The sub-cycle goes from position 0 to position 9 -- the ENTIRE CalcStack.
  This includes A (at position 5), which is between M's two occurrences.
- Sub-cycle minimum = A (since A < M). A shadows M. M does NOT enter break_at.

### The general pattern

```
Same graph + same edge ordering + different entry point
    -> different CalcStack contents when Q explores M
    -> different cycle membership (A included or excluded)
    -> different per-sub-cycle minimum
    -> different break_at
```

This is nondeterministic in practice because module processing order (which
determines which external code calls `get_idx` first) varies between runs due
to parallelism in the module solver.

## Mapping to the Real-World Example

| Minimal example | Real codebase (steam library, 76-member SCC) |
|-----------------|---------------------------------------------|
| Def(A) | ClanT(chat) -- CalcId at position 19:27-32 |
| Def(M) | MemberT -- CalcId at position 46:1-8 |
| Q (branch point with two edges) | KeyTParams(6) -- has edges to multiple type params |
| M being on/off the ancestor stack | KeyTParams(8) being on/off the ancestor stack |
| Small sub-cycle without A | 16-node sub-cycle with MemberT as minimum |
| Large sub-cycle including A | Larger sub-cycle including ClanT(chat), where ClanT < MemberT |
| Scenario 1: break_at = {A, M} | Run 1: break_at includes MemberT |
| Scenario 2: break_at = {A} | Run 7: break_at excludes MemberT (ClanT shadows it) |

The real codebase has 76 nodes and many more overlapping cycles, but the
fundamental mechanism is identical: whether a node is on the ancestor CalcStack
when a second push of it occurs determines the sub-cycle membership, which
determines the per-sub-cycle minimum, which determines break_at.
