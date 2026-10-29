---- MODULE PyreflyFixpoint ----

\* Iterative fixpoint SCC solver.
\*
\* This models Pyrefly's SCC solving algorithm. The solver runs a fixed
\* number of iterations (MaxPhase) rather than checking for convergence.
\*
\* Convergence detection is omitted intentionally: in Pyrefly, the
\* iteration count is bounded (e.g., max 5). Convergence is just an
\* optimization that allows early exit when answers stabilize. Since
\* some SCCs genuinely don't converge, the algorithm must be correct
\* without it. This model verifies correctness properties under the
\* fixed-iteration protocol.
\*
\* NOTE: In the real Pyrefly, the dependency graph is dynamic — edges
\* are discovered during solving, so different phases may traverse
\* different subsets of the true graph. This model uses a static graph
\* for simplicity. Modeling dynamic edge visibility is left for a
\* future iteration (the subtleties of per-phase edge sets are better
\* explored with a separate graph-generation tool or model).
\*
\* See DESIGN.md for the full design rationale.

EXTENDS Sequences, FiniteSets, Naturals

CONSTANTS
    Nodes,      \* set of node identifiers
    MaxDeps,    \* max outgoing edges per node (for tractability)
    MaxPhase    \* number of phases: 0 = discovery, 1..MaxPhase = iterations

\* graph is the dependency graph, chosen once at Init and then frozen.
\*
\* scc_anchors_read tracks, for each node, which SCC anchor_pos
\* values it has read preliminary answers from. Used to verify
\* invariant (a): no cross-SCC preliminary answer leakage.
VARIABLES state, stack, scc_stack, graph, scc_anchors_read

vars == <<state, stack, scc_stack, graph, scc_anchors_read>>

\* ---------------------------------------------------------------
\* Assumptions on constants
\* ---------------------------------------------------------------

ASSUME MaxPhase \in Nat

\* ---------------------------------------------------------------
\* Helpers
\* ---------------------------------------------------------------

\* The set of all nodes currently on the stack.
StackSet == {stack[i] : i \in 1..Len(stack)}

\* Find the position of node n in the stack (1-indexed from top).
\* Returns 0 if not found.
StackPos(n) ==
    IF \E i \in 1..Len(stack) : stack[i] = n
    THEN CHOOSE i \in 1..Len(stack) : stack[i] = n
    ELSE 0

\* The set of nodes on the stack from position 1 (top) through pos.
StackSlice(pos) ==
    {stack[i] : i \in 1..pos}

\* Which SCC (by index in scc_stack) does node n belong to?
\* Returns 0 if n is not in any SCC.
SccOf(n) ==
    IF \E i \in 1..Len(scc_stack) : n \in scc_stack[i].members
    THEN CHOOSE i \in 1..Len(scc_stack) : n \in scc_stack[i].members
    ELSE 0

\* Is node n in any SCC?
InAnyScc(n) ==
    \E i \in 1..Len(scc_stack) : n \in scc_stack[i].members

\* Look up a node's SCC-local state.
\* Returns "NoScc" if the node is not in any SCC.
SccState(n) ==
    LET i == SccOf(n)
    IN  IF i = 0 THEN "NoScc"
        ELSE scc_stack[i].node_state[n]

\* The phase of the SCC containing node n, or 0 if not in any SCC.
SccPhase(n) ==
    LET i == SccOf(n)
    IN  IF i = 0 THEN 0
        ELSE scc_stack[i].phase

\* The dependency edges visible to node n.
\* With a static graph, this is always graph[n].
\* In the real Pyrefly code, this would be phase-dependent
\* (some edges are only discovered in later phases).
VisibleGraph(n) == graph[n]

\* Minimum / Maximum of a nonempty set of naturals.
MinOfSet(S) == CHOOSE x \in S : \A y \in S : x <= y
MaxOfSet(S) == CHOOSE x \in S : \A y \in S : x >= y

\* Deterministic choice from a nonempty set of nodes.
\* In the real code this is min(CalcId); here we use CHOOSE which
\* is deterministic in TLC (always picks the same element for the
\* same set). The specific choice doesn't matter for correctness —
\* what matters is that it's deterministic and that invariant (c)
\* verifies all members get driven.
PickNode(S) == CHOOSE x \in S : TRUE

\* Remove entries at indices in `remove` from sequence `seq`.
\* Preserves the relative order of kept entries.
FilterSeq(seq, remove) ==
    LET F[i \in 0..Len(seq)] ==
        IF i = 0 THEN <<>>
        ELSE IF i \in remove THEN F[i-1]
        ELSE Append(F[i-1], seq[i])
    IN F[Len(seq)]

\* ---------------------------------------------------------------
\* Reachability and ground-truth SCCs
\* ---------------------------------------------------------------

\* Transitive closure of graph: Reachable(n) is the set of
\* nodes reachable from n via one or more edges in graph.
\* Uses iterative fixpoint over the powerset.
Reachable(n) ==
    LET step(S) == S \union UNION {graph[m] : m \in S}
        \* Iterate |Nodes| times — sufficient for transitive closure.
        iter[i \in 0..Cardinality(Nodes)] ==
            IF i = 0 THEN graph[n]
            ELSE step(iter[i-1])
    IN iter[Cardinality(Nodes)]

\* The true SCC of node n: all nodes mutually reachable with n
\* (including n itself) via graph. Only nodes that form a
\* cycle are included — singleton nodes without self-loops are
\* not considered SCCs.
TrueScc(n) ==
    LET mutual == {m \in Nodes : n \in Reachable(m) /\ m \in Reachable(n)}
    IN  IF n \in Reachable(n) THEN mutual \union {n}
        ELSE {}

\* The set of all ground-truth SCCs (sets with >= 2 members, or
\* singletons with self-loops).
TrueSccSets == {TrueScc(n) : n \in Nodes} \ {{}}

\* ---------------------------------------------------------------
\* Type invariant
\* ---------------------------------------------------------------

\* Global states model Calculation cell status.
GlobalStates == {"Fresh", "InProgress", "Done"}

\* SCC-local node states.
\* SccFresh: waiting to be driven in this phase (phases 1+ only).
\* SccInProgress: being computed (on the calc stack).
\* SccHasPlaceholder: a back-edge to this node was resolved via
\*   placeholder (cold phases) or previous answer (warm phases).
\* SccDone: has a preliminary answer for the current phase.
SccNodeStates == {"SccFresh", "SccInProgress", "SccHasPlaceholder", "SccDone"}

TypeOk ==
    /\ state \in [Nodes -> GlobalStates]
    /\ stack \in Seq(Nodes)
    /\ scc_anchors_read \in [Nodes -> SUBSET Nat]
    \* scc_stack structure checked in SccWellFormed.

\* Each SCC record has valid members, anchor_pos, phase, node_state,
\* prev_answers, and curr_answers.
SccWellFormed ==
    \A i \in 1..Len(scc_stack) :
        /\ scc_stack[i].members \subseteq Nodes
        /\ scc_stack[i].members /= {}
        /\ scc_stack[i].anchor_pos \in Nat
        /\ scc_stack[i].phase \in 0..MaxPhase
        /\ DOMAIN scc_stack[i].node_state = scc_stack[i].members
        /\ \A n \in scc_stack[i].members :
               scc_stack[i].node_state[n] \in SccNodeStates
        /\ scc_stack[i].prev_answers \subseteq scc_stack[i].members
        /\ scc_stack[i].curr_answers \subseteq scc_stack[i].members

\* ---------------------------------------------------------------
\* Initial state
\* ---------------------------------------------------------------

Init ==
    /\ state = [n \in Nodes |-> "Fresh"]
    /\ stack = <<>>
    /\ scc_stack = <<>>
    /\ scc_anchors_read = [n \in Nodes |-> {}]
    \* Choose graph nondeterministically.
    /\ graph \in [Nodes -> SUBSET Nodes]
    /\ \A n \in Nodes : Cardinality(graph[n]) <= MaxDeps

\* ---------------------------------------------------------------
\* SCC merge helpers
\* ---------------------------------------------------------------

\* Indices of existing SCCs that overlap with a set of nodes.
OverlappingSccs(nodes) ==
    {i \in 1..Len(scc_stack) :
        scc_stack[i].members \intersect nodes /= {}}

\* Merge node_states from overlapping SCCs with new cycle members.
\* Existing SCC members keep their current state; new members get
\* SccInProgress (they are on the stack, being computed).
MergedNodeState(all_members, overlapping) ==
    [n \in all_members |->
        IF \E i \in overlapping : n \in scc_stack[i].members
        THEN LET i == CHOOSE i \in overlapping :
                           n \in scc_stack[i].members
             IN scc_stack[i].node_state[n]
        ELSE "SccInProgress"]

\* Merging always resets to phase 0. MergeOrCreateScc only fires
\* when membership is expanding (CycleAlreadyContained was false),
\* so the SCC must redo discovery with the expanded membership.
\* This is the demotion logic: any merge during fixpoint iteration
\* forces a full restart.
MergedPhase(overlapping) == 0

\* Merged prev/curr answers: always cleared since phase resets to 0.
\* Answers from previous phases are invalid with expanded membership.
MergedPrevAnswers(overlapping, merged_phase) ==
    IF merged_phase = 0 THEN {}
    ELSE UNION {scc_stack[i].prev_answers : i \in overlapping}

MergedCurrAnswers(overlapping, merged_phase) ==
    IF merged_phase = 0 THEN {}
    ELSE UNION {scc_stack[i].curr_answers : i \in overlapping}

\* For a back-edge to dep, find the relevant stack position.
BackEdgeTargetPos(dep) ==
    LET depSccIdx == SccOf(dep)
    IN  IF depSccIdx /= 0
        THEN LET positions == {StackPos(n) : n \in scc_stack[depSccIdx].members} \ {0}
             IN  IF positions = {} THEN 0
                 ELSE MaxOfSet(positions)
        ELSE StackPos(dep)

\* No-op check: all cycle members are already in a single SCC.
CycleAlreadyContained(cycle_members) ==
    \E i \in 1..Len(scc_stack) :
        cycle_members \subseteq scc_stack[i].members

\* Nontrivial cycle resolution: merge all overlapping SCCs with
\* the new cycle members into a single SCC.
MergeOrCreateScc(cycle_members, anchor) ==
    LET overlapping == OverlappingSccs(cycle_members)
        all_members == cycle_members \union
            UNION {scc_stack[i].members : i \in overlapping}
        all_anchors == {scc_stack[i].anchor_pos : i \in overlapping}
                       \union {anchor}
        min_anchor == MinOfSet(all_anchors)
        merged_phase == MergedPhase(overlapping)
        new_scc == [members      |-> all_members,
                    anchor_pos   |-> min_anchor,
                    phase        |-> merged_phase,
                    node_state   |-> MergedNodeState(all_members, overlapping),
                    prev_answers |-> MergedPrevAnswers(overlapping, merged_phase),
                    curr_answers |-> MergedCurrAnswers(overlapping, merged_phase)]
        remaining == FilterSeq(scc_stack, overlapping)
    IN  /\ scc_stack' = <<new_scc>> \o remaining
        \* Clear anchor tracking for merged members — the anchor_pos
        \* changed, so old records are invalid. This is sound because
        \* the merge ensures all members are now in the same SCC.
        /\ scc_anchors_read' = [n \in Nodes |->
            IF n \in all_members THEN {}
            ELSE scc_anchors_read[n]]

ResolveCycle(cycle_members, anchor) ==
    IF CycleAlreadyContained(cycle_members)
    THEN UNCHANGED <<scc_stack, scc_anchors_read>>
    ELSE MergeOrCreateScc(cycle_members, anchor)

\* ---------------------------------------------------------------
\* Actions
\* ---------------------------------------------------------------

\* Start a new DFS root: pick any Fresh node when the stack is empty.
StartRoot(n) ==
    /\ stack = <<>>
    \* Don't start a new root while there are active SCCs.
    \* The real code finishes SCC processing before starting new roots.
    /\ scc_stack = <<>>
    /\ state[n] = "Fresh"
    /\ state' = [state EXCEPT ![n] = "InProgress"]
    /\ stack' = <<n>>
    /\ UNCHANGED <<scc_stack, graph, scc_anchors_read>>

\* The top of the stack has a Fresh (globally) dependency: push it.
\* Uses VisibleGraph — only edges visible in the current phase
\* can be traversed.
Descend(dep) ==
    /\ stack /= <<>>
    /\ LET top == Head(stack)
       IN  /\ dep \in VisibleGraph(top)
           /\ state[dep] = "Fresh"
           /\ state' = [state EXCEPT ![dep] = "InProgress"]
           /\ stack' = <<dep>> \o stack
           /\ UNCHANGED <<scc_stack, graph, scc_anchors_read>>

\* During fixpoint phases (>= 1), descend into an SCC member that
\* is SccFresh. This handles the case where member A depends on
\* member B and B hasn't been driven yet in this phase.
\* The node is globally InProgress (from phase 0) but SCC-locally Fresh.
DescendIntoSccMember(dep) ==
    /\ stack /= <<>>
    /\ LET top == Head(stack)
           topSccIdx == SccOf(top)
       IN  /\ topSccIdx /= 0
           /\ scc_stack[topSccIdx].phase >= 1
           /\ dep \in VisibleGraph(top)
           /\ SccOf(dep) = topSccIdx
           /\ scc_stack[topSccIdx].node_state[dep] = "SccFresh"
           /\ dep \notin StackSet
           /\ scc_stack' = [scc_stack EXCEPT
                  ![topSccIdx].node_state[dep] = "SccInProgress"]
           /\ stack' = <<dep>> \o stack
           /\ UNCHANGED <<state, graph, scc_anchors_read>>

\* The top of the stack has a dependency that is globally InProgress
\* and either on the stack or in an existing SCC: back-edge found.
\* Uses VisibleGraph for edge visibility.
DetectCycle(dep) ==
    /\ stack /= <<>>
    /\ LET top == Head(stack)
       IN  /\ dep \in VisibleGraph(top)
           /\ state[dep] = "InProgress"
           /\ dep \in StackSet \/ InAnyScc(dep)
           /\ LET target_pos == BackEdgeTargetPos(dep)
              IN  /\ target_pos /= 0
                  /\ LET cycle_members == StackSlice(target_pos)
                         anchor == Len(stack) - target_pos
                     IN  /\ ResolveCycle(cycle_members, anchor)
                         /\ UNCHANGED <<state, stack, graph>>

\* The top of the stack is in an SCC and has a dependency that is
\* SccInProgress in the same SCC. A placeholder is created so
\* computation can proceed with a temporary answer.
\* Only valid during cold phases (0 and 1): in these phases there
\* are no previous answers to use.
\* Records the SCC's anchor_pos in scc_anchors_read for cross-SCC
\* leakage detection.
CreatePlaceholder(dep) ==
    /\ stack /= <<>>
    /\ scc_stack /= <<>>
    /\ LET top == Head(stack)
           topSccIdx == SccOf(top)
       IN  /\ topSccIdx /= 0
           /\ scc_stack[topSccIdx].phase <= 1
           /\ dep \in VisibleGraph(top)
           /\ SccOf(dep) = topSccIdx
           /\ SccState(dep) = "SccInProgress"
           /\ scc_stack' = [scc_stack EXCEPT
                  ![topSccIdx].node_state[dep] = "SccHasPlaceholder"]
           /\ scc_anchors_read' = [scc_anchors_read EXCEPT
                  ![top] = scc_anchors_read[top] \union
                           {scc_stack[topSccIdx].anchor_pos}]
           /\ UNCHANGED <<state, stack, graph>>

\* The top of the stack is in an SCC (warm phase >= 2) and has a
\* dependency that is SccInProgress in the same SCC. Instead of a
\* placeholder, we use the previous iteration's answer.
\* Guard: dep must have a previous answer available.
\* Records the SCC's anchor_pos in scc_anchors_read for cross-SCC
\* leakage detection.
ReadPreviousAnswer(dep) ==
    /\ stack /= <<>>
    /\ scc_stack /= <<>>
    /\ LET top == Head(stack)
           topSccIdx == SccOf(top)
       IN  /\ topSccIdx /= 0
           /\ scc_stack[topSccIdx].phase >= 2
           /\ dep \in VisibleGraph(top)
           /\ SccOf(dep) = topSccIdx
           /\ SccState(dep) = "SccInProgress"
           /\ dep \in scc_stack[topSccIdx].prev_answers
           /\ scc_stack' = [scc_stack EXCEPT
                  ![topSccIdx].node_state[dep] = "SccHasPlaceholder"]
           /\ scc_anchors_read' = [scc_anchors_read EXCEPT
                  ![top] = scc_anchors_read[top] \union
                           {scc_stack[topSccIdx].anchor_pos}]
           /\ UNCHANGED <<state, stack, graph>>

\* Is the SCC at index idx fully done and ready to advance?
\* All members must be SccDone and none can be on the calc stack.
SccAllDone(idx, popping_node) ==
    /\ \A n \in scc_stack[idx].members :
        \/ scc_stack[idx].node_state[n] = "SccDone"
        \/ n = popping_node
    /\ \A n \in scc_stack[idx].members :
        \/ n \notin StackSet
        \/ n = popping_node

\* Batch-commit an SCC: all members become globally Done,
\* the SCC is removed from scc_stack.
\* Clears scc_anchors_read for committed members.
CommitSccState(idx) ==
    LET scc == scc_stack[idx]
    IN  /\ state' = [n \in Nodes |->
            IF n \in scc.members THEN "Done"
            ELSE state[n]]
        /\ scc_stack' = FilterSeq(scc_stack, {idx})
        /\ scc_anchors_read' = [n \in Nodes |->
            IF n \in scc.members THEN {}
            ELSE scc_anchors_read[n]]

\* The top of the stack has all dependencies resolved: pop it.
\* A dependency is resolved if it is:
\*   - globally Done, or
\*   - SccDone or SccHasPlaceholder in the same SCC.
\*
\* Uses VisibleGraph: only visible edges need to be resolved.
\*
\* If not in an SCC: mark global state Done.
\* If in an SCC at MaxPhase and all members done: batch-commit.
\* If in an SCC at phase < MaxPhase: just mark SccDone (TransitionPhase
\*   will advance to the next phase when all members are done).
FinishCalculation ==
    /\ stack /= <<>>
    /\ LET top == Head(stack)
           topSccIdx == SccOf(top)
       IN  /\ \A dep \in VisibleGraph(top) :
                \/ state[dep] = "Done"
                \/ /\ topSccIdx /= 0
                   /\ SccOf(dep) = topSccIdx
                   /\ SccState(dep) \in {"SccDone", "SccHasPlaceholder"}
           /\ IF topSccIdx = 0
              THEN \* Acyclic node: just mark Done.
                   /\ state' = [state EXCEPT ![top] = "Done"]
                   /\ UNCHANGED <<scc_stack, scc_anchors_read>>
              ELSE IF SccAllDone(topSccIdx, top)
                      /\ scc_stack[topSccIdx].phase = MaxPhase
              THEN \* Last SCC member at final phase: batch-commit.
                   CommitSccState(topSccIdx)
              ELSE \* SCC member: mark SccDone, add to curr_answers.
                   /\ scc_stack' = [scc_stack EXCEPT
                        ![topSccIdx].node_state[top] = "SccDone",
                        ![topSccIdx].curr_answers =
                            scc_stack[topSccIdx].curr_answers \union {top}]
                   /\ UNCHANGED <<state, scc_anchors_read>>
           /\ stack' = Tail(stack)
           /\ UNCHANGED graph

\* Transition an SCC to the next phase.
\* Fires when all members are SccDone, none are on the stack,
\* and phase < MaxPhase.
\* Moves curr_answers -> prev_answers, resets all members to SccFresh.
\* Clears scc_anchors_read for all members (answers from this phase
\* are now "prev_answers" — the tracking resets for the new phase).
TransitionPhase(idx) ==
    /\ idx \in 1..Len(scc_stack)
    /\ scc_stack[idx].phase < MaxPhase
    /\ \A n \in scc_stack[idx].members :
        scc_stack[idx].node_state[n] = "SccDone"
    /\ \A n \in scc_stack[idx].members :
        n \notin StackSet
    /\ LET scc == scc_stack[idx]
           new_phase == scc.phase + 1
       IN  /\ scc_stack' = [scc_stack EXCEPT
               ![idx].phase = new_phase,
               ![idx].node_state =
                   [n \in scc.members |-> "SccFresh"],
               ![idx].prev_answers = scc.curr_answers,
               ![idx].curr_answers = {}]
           /\ scc_anchors_read' = [n \in Nodes |->
               IF n \in scc.members THEN {}
               ELSE scc_anchors_read[n]]
    /\ UNCHANGED <<state, stack, graph>>

\* Drive the next SCC member during fixpoint phases (>= 1).
\* Picks the minimum SccFresh member. Only fires when no SCC
\* member is currently on the calc stack (the previous DFS has
\* fully unwound).
StartNextMember(idx) ==
    /\ idx \in 1..Len(scc_stack)
    /\ scc_stack[idx].phase >= 1
    /\ \A n \in scc_stack[idx].members : n \notin StackSet
    \* Stack must have unwound to exactly the SCC's anchor position.
    /\ Len(stack) = scc_stack[idx].anchor_pos
    \* No SCC above this one on the scc_stack is in fixpoint mode.
    \* In the real code, only the innermost (topmost) active SCC
    \* drives members; outer SCCs wait.
    /\ \A j \in 1..Len(scc_stack) :
        j < idx => scc_stack[j].phase < 1
    /\ LET fresh_members == {n \in scc_stack[idx].members :
               scc_stack[idx].node_state[n] = "SccFresh"}
       IN  /\ fresh_members /= {}
           /\ LET n == PickNode(fresh_members)
              IN  /\ scc_stack' = [scc_stack EXCEPT
                       ![idx].node_state[n] = "SccInProgress"]
                  /\ stack' = <<n>> \o stack
    /\ UNCHANGED <<state, graph, scc_anchors_read>>

Next ==
    \/ \E n \in Nodes : StartRoot(n)
    \/ \E dep \in Nodes : Descend(dep)
    \/ \E dep \in Nodes : DescendIntoSccMember(dep)
    \/ \E dep \in Nodes : DetectCycle(dep)
    \/ \E dep \in Nodes : CreatePlaceholder(dep)
    \/ \E dep \in Nodes : ReadPreviousAnswer(dep)
    \/ FinishCalculation
    \/ \E idx \in 1..Len(scc_stack) : TransitionPhase(idx)
    \/ \E idx \in 1..Len(scc_stack) : StartNextMember(idx)

Spec == Init /\ [][Next]_vars /\ WF_vars(Next)

\* ---------------------------------------------------------------
\* Transition-level safety checks (explicit demotion semantics)
\* ---------------------------------------------------------------

\* State predicate: DetectCycle(dep) would perform a nontrivial merge
\* (i.e., membership expansion rather than a no-op contained cycle).
DetectCycleExpands(dep) ==
    /\ stack /= <<>>
    /\ LET top == Head(stack)
           target_pos == BackEdgeTargetPos(dep)
       IN  /\ dep \in VisibleGraph(top)
           /\ state[dep] = "InProgress"
           /\ dep \in StackSet \/ InAnyScc(dep)
           /\ target_pos /= 0
           /\ LET cycle_members == StackSlice(target_pos)
              IN ~CycleAlreadyContained(cycle_members)

\* Action formula: whenever DetectCycle runs and performs a membership
\* expansion, the merged SCC must restart at phase 0.
MergeExpansionResetsPhase0Action ==
    \A dep \in Nodes :
        /\ DetectCycle(dep)
        /\ DetectCycleExpands(dep)
        => scc_stack'[1].phase = 0

\* Temporal property wrapping the action formula.
MergeExpansionResetsPhase0 == [][MergeExpansionResetsPhase0Action]_vars

\* ---------------------------------------------------------------
\* Invariants (structural)
\* ---------------------------------------------------------------

\* Everything on the stack is globally InProgress.
StackIsInProgress ==
    \A i \in 1..Len(stack) : state[stack[i]] = "InProgress"

\* A node that is globally Done has all deps (in graph) Done.
\* Once committed, a node's answer must be valid against all
\* real dependencies.
DepsBeforeDone ==
    \A n \in Nodes :
        state[n] = "Done" =>
            \A dep \in graph[n] : state[dep] = "Done"

\* SCC members are globally InProgress (never Done while SCC exists).
SccMembersGloballyInProgress ==
    \A i \in 1..Len(scc_stack) :
        \A n \in scc_stack[i].members :
            state[n] = "InProgress"

\* No node appears in more than one SCC.
SccMembersDisjoint ==
    \A i \in 1..Len(scc_stack) :
        \A j \in 1..Len(scc_stack) :
            i /= j => scc_stack[i].members \intersect scc_stack[j].members = {}

\* Every SCC on the scc_stack either has a live member on the calc
\* stack, or has no actively-computing members (all are SccDone or
\* SccFresh, in a transient state between phases or between DFS
\* runs within a fixpoint phase).
SccHasLiveMember ==
    \A i \in 1..Len(scc_stack) :
        \/ \E n \in scc_stack[i].members : n \in StackSet
        \/ ~\E n \in scc_stack[i].members :
               scc_stack[i].node_state[n] \in {"SccInProgress", "SccHasPlaceholder"}

\* SCCs in phase 0 with live members on the stack are ordered by
\* anchor position. During fixpoint phases, members are re-driven
\* at different stack positions so the original anchor_pos no longer
\* reflects stack layout.
SccStackOrdered ==
    \A i \in 1..Len(scc_stack) :
        \A j \in 1..Len(scc_stack) :
            /\ i < j
            /\ scc_stack[i].phase = 0
            /\ scc_stack[j].phase = 0
            /\ \E n \in scc_stack[i].members : n \in StackSet
            /\ \E n \in scc_stack[j].members : n \in StackSet
            => scc_stack[i].anchor_pos >= scc_stack[j].anchor_pos

\* ---------------------------------------------------------------
\* Invariants (correctness properties)
\* ---------------------------------------------------------------

\* (a) No cross-SCC preliminary answer leakage.
\* If a node read preliminary answers (via placeholder or previous
\* answer), it must have read from exactly one SCC, and that SCC
\* must be the one the node belongs to.
\* A violation means a node consumed a preliminary answer from a
\* *different* SCC without being merged into it.
NoCrossSccLeakage ==
    \A n \in Nodes :
        LET anchors == scc_anchors_read[n]
            scc_idx == SccOf(n)
        IN  \/ anchors = {}
            \/ /\ Cardinality(anchors) = 1
               /\ scc_idx /= 0
               /\ scc_stack[scc_idx].anchor_pos \in anchors

\* (b) Committed SCCs match ground truth.
\* At commit time (phase = MaxPhase, all members done), the SCC's
\* members should be exactly one of the ground-truth SCCs.
CommittedSccMatchesTruth ==
    \A i \in 1..Len(scc_stack) :
        scc_stack[i].phase = MaxPhase =>
            scc_stack[i].members \in TrueSccSets

\* (c) All answers available at commit.
\* When an SCC reaches MaxPhase and all members are SccDone with
\* none on the stack, every member must have a current answer.
AllAnswersAtCommit ==
    \A i \in 1..Len(scc_stack) :
        /\ scc_stack[i].phase = MaxPhase
        /\ \A n \in scc_stack[i].members :
            scc_stack[i].node_state[n] = "SccDone"
        /\ \A n \in scc_stack[i].members :
            n \notin StackSet
        => scc_stack[i].curr_answers = scc_stack[i].members

\* (d) Demotion correctness: if an SCC reached phase >= 2, it must
\* have successfully completed phase 1, meaning all members produced
\* answers that became prev_answers. If a merge expanded membership
\* without resetting, prev_answers would be a strict subset of members.
PrevAnswersComplete ==
    \A i \in 1..Len(scc_stack) :
        scc_stack[i].phase >= 2 =>
            scc_stack[i].prev_answers = scc_stack[i].members

\* ---------------------------------------------------------------
\* Properties
\* ---------------------------------------------------------------

Finished ==
    \A n \in Nodes : state[n] = "Done"

Liveness == <>Finished

\* ---------------------------------------------------------------
\* Probes
\* ---------------------------------------------------------------

\* "Can a cycle be detected?"
ProbeSccFormed == Len(scc_stack) = 0

====
