---- MODULE ModelProbes ----
EXTENDS PyreflyFixpoint

\* Reachability probes: a successful invariant check means the named event
\* never occurs in this bounded model, not that the production code forbids it.
NoFinalAllDoneState ==
    ~\E i \in 1..Len(scc_stack) :
        /\ scc_stack[i].phase = MaxPhase
        /\ \A n \in scc_stack[i].members :
            scc_stack[i].node_state[n] = "SccDone"
        /\ \A n \in scc_stack[i].members : n \notin StackSet

NoPositivePhaseExpansion ==
    \A dep \in Nodes :
        IF DetectCycleExpands(dep)
        THEN \A i \in OverlappingSccs(StackSlice(BackEdgeTargetPos(dep))) :
            scc_stack[i].phase = 0
        ELSE TRUE
====
