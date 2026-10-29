---- MODULE pyrefly_stack ----

\* Step 3b': Separate global state from SCC-local state.
\*
\* Global state (modeling Calculation cells): Fresh / InProgress / Done.
\* SCC-local state (modeling Scc.node_state): SccInProgress / SccDone.
\* This separation mirrors the implementation: global state lives in
\* Answers/Calculation, SCC state lives in thread-local Scc structs.
\* Merging only touches SCC records, not global state.

EXTENDS Sequences, FiniteSets, Naturals

CONSTANT Nodes, MaxDeps

VARIABLES state, graph, stack, scc_stack

vars == <<state, graph, stack, scc_stack>>

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
\* Returns 0 if n is not in any SCC. (0 is never a valid index
\* since sequences are 1-indexed.)
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

\* ---------------------------------------------------------------
\* Type invariant
\* ---------------------------------------------------------------

\* Global states model Calculation cell status.
GlobalStates == {"Fresh", "InProgress", "Done"}

\* SCC-local states model Scc.node_state.
\* SccInProgress: being computed (not yet encountered as a back-edge dep)
\* SccHasPlaceholder: a placeholder (Type::Var) was created for this node
\*   because another SCC member needed its answer during phase 0.
\*   Models the HasPlaceholder state in the implementation.
\* SccDone: has a preliminary answer (may contain placeholders).
SccNodeStates == {"SccInProgress", "SccHasPlaceholder", "SccDone"}

TypeOk ==
    /\ state \in [Nodes -> GlobalStates]
    /\ graph \in [Nodes -> SUBSET Nodes]
    /\ stack \in Seq(Nodes)
    \* We check scc_stack structure in SccWellFormed instead,
    \* since TLC can't express dependent record types here.

\* Each SCC record has valid members, anchor_pos, and a node_state
\* function whose domain matches members.
SccWellFormed ==
    \A i \in 1..Len(scc_stack) :
        /\ scc_stack[i].members \subseteq Nodes
        /\ scc_stack[i].members /= {}
        /\ scc_stack[i].anchor_pos \in Nat
        /\ DOMAIN scc_stack[i].node_state = scc_stack[i].members
        /\ \A n \in scc_stack[i].members :
               scc_stack[i].node_state[n] \in SccNodeStates

\* ---------------------------------------------------------------
\* Initial state
\* ---------------------------------------------------------------

Init ==
    /\ state = [n \in Nodes |-> "Fresh"]
    /\ graph \in [Nodes -> SUBSET Nodes]
    /\ \A n \in Nodes : Cardinality(graph[n]) <= MaxDeps
    /\ stack = <<>>
    /\ scc_stack = <<>>

\* ---------------------------------------------------------------
\* Actions
\* ---------------------------------------------------------------

\* Start a new DFS root: pick any Fresh node when the stack is empty.
StartRoot(n) ==
    /\ stack = <<>>
    /\ state[n] = "Fresh"
    /\ state' = [state EXCEPT ![n] = "InProgress"]
    /\ stack' = <<n>>
    /\ UNCHANGED <<graph, scc_stack>>

\* The top of the stack has a Fresh dependency: push it.
Descend(dep) ==
    /\ stack /= <<>>
    /\ LET top == Head(stack)
       IN  /\ dep \in graph[top]
           /\ state[dep] = "Fresh"
           /\ state' = [state EXCEPT ![dep] = "InProgress"]
           /\ stack' = <<dep>> \o stack
           /\ UNCHANGED <<graph, scc_stack>>

\* Remove entries at indices in `remove` from sequence `seq`.
\* Preserves the relative order of kept entries.
FilterSeq(seq, remove) ==
    LET F[i \in 0..Len(seq)] ==
        IF i = 0 THEN <<>>
        ELSE IF i \in remove THEN F[i-1]
        ELSE Append(F[i-1], seq[i])
    IN F[Len(seq)]

\* Indices of existing SCCs that overlap with a set of nodes.
OverlappingSccs(nodes) ==
    {i \in 1..Len(scc_stack) :
        scc_stack[i].members \intersect nodes /= {}}

\* Merge node_states from overlapping SCCs with new cycle members.
\* Existing SCC members keep their current state; new members get
\* SccInProgress.
MergedNodeState(all_members, overlapping) ==
    [n \in all_members |->
        IF \E i \in overlapping : n \in scc_stack[i].members
        THEN LET i == CHOOSE i \in overlapping :
                           n \in scc_stack[i].members
             IN scc_stack[i].node_state[n]
        ELSE "SccInProgress"]

\* Minimum / Maximum of a nonempty set of naturals.
MinOfSet(S) == CHOOSE x \in S : \A y \in S : x <= y
MaxOfSet(S) == CHOOSE x \in S : \A y \in S : x >= y

\* For a back-edge to dep, find the relevant stack position.
\* - If dep is directly on the stack (not in an SCC), use its position.
\* - If dep is in an SCC, use the deepest stack position of any
\*   member of that SCC. This reflects that the SCC is logically
\*   one unit on the stack — a back-edge to any member is a
\*   back-edge to the whole SCC.
\* - Returns 0 if no relevant position exists (this shouldn't occur
\*   in a legal trace)
BackEdgeTargetPos(dep) ==
    LET depSccIdx == SccOf(dep)
    IN  IF depSccIdx /= 0
        THEN LET positions == {StackPos(n) : n \in scc_stack[depSccIdx].members} \ {0}
             IN  IF positions = {} THEN 0
                 ELSE MaxOfSet(positions)
        ELSE StackPos(dep)

\* Resolve a detected cycle: merge overlapping SCCs, absorb
\* free-floating cycle members, or create a new SCC.
\* Returns the new scc_stack value.
\*
\* Cases:
\*   - All cycle_members already in one SCC -> no change (no-op)
\*   - No overlapping SCCs -> push a brand-new SCC
\*   - Overlapping SCCs -> merge them all + new members into one
\* No-op check: all cycle members are already in a single SCC.
\* By SccStackOrdered + SccMembersDisjoint, this can only be the
\* top SCC. The implementation uses this for an O(1) short-circuit
\* on back-edges within the current SCC.
CycleAlreadyContained(cycle_members) ==
    \E i \in 1..Len(scc_stack) :
        cycle_members \subseteq scc_stack[i].members

\* Nontrivial cycle resolution: merge all overlapping SCCs with
\* the new cycle members into a single SCC, and remove the old
\* SCCs from scc_stack.
MergeOrCreateScc(cycle_members, anchor) ==
    LET overlapping == OverlappingSccs(cycle_members)

        \* Union all members: existing SCC members + new cycle members.
        all_members == cycle_members \union
            UNION {scc_stack[i].members : i \in overlapping}

        \* Minimum anchor across all merged SCCs and the new cycle.
        all_anchors == {scc_stack[i].anchor_pos : i \in overlapping}
                       \union {anchor}
        min_anchor == MinOfSet(all_anchors)

        \* Build the merged SCC record.
        new_scc == [members |-> all_members,
                    anchor_pos |-> min_anchor,
                    node_state |-> MergedNodeState(all_members, overlapping)]

        \* Remove merged SCCs, prepend the new one.
        remaining == FilterSeq(scc_stack, overlapping)

    IN scc_stack' = <<new_scc>> \o remaining

ResolveCycle(cycle_members, anchor) ==
    IF CycleAlreadyContained(cycle_members)
    THEN UNCHANGED scc_stack
    ELSE MergeOrCreateScc(cycle_members, anchor)

\* The top of the stack has a dependency that is globally InProgress
\* and either on the stack or in an existing SCC: we've found a
\* back-edge. Resolve it by creating or merging SCCs.
\*
\* The cycle extends from the top of the stack down to the deepest
\* stack position associated with dep (or dep's SCC). All nodes in
\* that range, plus any SCCs they overlap with, get merged.
DetectCycle(dep) ==
    /\ stack /= <<>>
    /\ LET top == Head(stack)
       IN  /\ dep \in graph[top]
           /\ state[dep] = "InProgress"
           /\ dep \in StackSet \/ InAnyScc(dep)
           /\ LET target_pos == BackEdgeTargetPos(dep)
              IN  /\ target_pos /= 0
                  /\ LET cycle_members == StackSlice(target_pos)
                         anchor == Len(stack) - target_pos
                     IN  /\ ResolveCycle(cycle_members, anchor)
                         /\ UNCHANGED <<state, graph, stack>>

\* The top of the stack is in an SCC and has a dependency that is
\* SccInProgress in the same SCC. This models get_idx encountering
\* a back-edge within the SCC during phase 0: a placeholder
\* (Type::Var) is created so computation can proceed with a
\* temporary answer.
CreatePlaceholder(dep) ==
    /\ stack /= <<>>
    /\ scc_stack /= <<>>
    /\ LET top == Head(stack)
           topSccIdx == SccOf(top)
       IN  /\ topSccIdx /= 0
           /\ dep \in graph[top]
           /\ SccOf(dep) = topSccIdx
           /\ SccState(dep) = "SccInProgress"
           /\ scc_stack' = [scc_stack EXCEPT
                  ![topSccIdx].node_state[dep] = "SccHasPlaceholder"]
           /\ UNCHANGED <<state, graph, stack>>

\* Is the SCC at index idx fully done and ready to commit?
\* All members must be SccDone and none can be on the calc stack.
\* (The node being popped in this step is excluded from the stack
\* check via the popping_node parameter.)
SccReadyToCommit(idx, popping_node) ==
    /\ \A n \in scc_stack[idx].members :
        \/ scc_stack[idx].node_state[n] = "SccDone"
        \/ n = popping_node  \* about to become SccDone
    /\ \A n \in scc_stack[idx].members :
        \/ n \notin StackSet
        \/ n = popping_node  \* about to be popped

\* Batch-commit an SCC: all members become globally Done,
\* the SCC is removed from scc_stack.
\* This models commit_final_answers / batch_commit_scc in the
\* implementation. In a multithreaded model the write-locking
\* would matter; here we just do the state transition atomically.
CommitSccState(idx) ==
    LET scc == scc_stack[idx]
    IN  /\ state' = [n \in Nodes |->
            IF n \in scc.members THEN "Done"
            ELSE state[n]]
        /\ scc_stack' = FilterSeq(scc_stack, {idx})

\* The top of the stack has all dependencies resolved: pop it.
\* A dependency is resolved if it is:
\*   - globally Done (outside any SCC), or
\*   - SccDone or SccHasPlaceholder in the same SCC.
\*
\* If not in an SCC: mark global state Done.
\* If in an SCC: mark SCC-local state SccDone. Then, if this was
\*   the last member to finish, batch-commit the entire SCC
\*   (all members become globally Done, SCC is removed).
\*   This mirrors on_calculation_finished in the implementation.
FinishCalculationAtTopOfStack ==
    /\ stack /= <<>>
    /\ LET top == Head(stack)
           topSccIdx == SccOf(top)
       IN  /\ \A dep \in graph[top] :
                \/ state[dep] = "Done"
                \/ /\ SccOf(dep) = topSccIdx
                   /\ SccState(dep) \in {"SccDone", "SccHasPlaceholder"}
           /\ IF topSccIdx = 0
              THEN \* Acyclic node: just mark Done.
                   /\ state' = [state EXCEPT ![top] = "Done"]
                   /\ UNCHANGED scc_stack
              ELSE IF SccReadyToCommit(topSccIdx, top)
              THEN \* Last SCC member to finish: batch-commit.
                   CommitSccState(topSccIdx)
              ELSE \* SCC member but others still in progress:
                   \* just update SCC-local state.
                   /\ scc_stack' = [scc_stack EXCEPT
                        ![topSccIdx].node_state[top] = "SccDone"]
                   /\ UNCHANGED state
           /\ stack' = Tail(stack)
           /\ UNCHANGED graph

Next ==
    \/ \E n \in Nodes : StartRoot(n)
    \/ \E dep \in Nodes : Descend(dep)
    \/ \E dep \in Nodes : DetectCycle(dep)
    \/ \E dep \in Nodes : CreatePlaceholder(dep)
    \/ FinishCalculationAtTopOfStack

Spec == Init /\ [][Next]_vars /\ WF_vars(Next)

\* ---------------------------------------------------------------
\* Invariants
\* ---------------------------------------------------------------

\* Everything on the stack is globally InProgress.
StackIsInProgress ==
    \A i \in 1..Len(stack) : state[stack[i]] = "InProgress"

\* A node that is globally Done has all deps globally Done.
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

\* Every SCC on the scc_stack has at least one member on the calc
\* stack. This is why SCC commit cannot cascade: when the top SCC
\* commits (its last member was just popped), every lower SCC still
\* has live members on the stack above its anchor.
SccHasLiveMember ==
    \A i \in 1..Len(scc_stack) :
        \E n \in scc_stack[i].members : n \in StackSet

\* SCCs are ordered on the scc_stack by anchor position: the top
\* of scc_stack (index 1) has the highest anchor_pos (shallowest
\* on the calc stack, i.e. most recently entered).
\* This is why the implementation can merge by popping from the
\* top of the scc_stack: any cycle detected from the top of the
\* calc stack will only overlap with a contiguous prefix of the
\* scc_stack.
SccStackOrdered ==
    \A i \in 1..Len(scc_stack) :
        \A j \in 1..Len(scc_stack) :
            i < j => scc_stack[i].anchor_pos >= scc_stack[j].anchor_pos

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
