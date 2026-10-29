---- MODULE PyreflyFixpoint ----

\* Planning, documentation, and auditing of SCC answer availability.
\* A Calc frame requests visible dependencies; a Driver frame revisits members.
\* Only the top control frame acts. Thus a nested driver suspends its caller.
\* Inferred types, convergence equality, threads, and memory lifetimes are not
\* modeled. Fixed passes exercise the admitted visibility schedule, not Python
\* convergence. DynamicGraph advances the schedule on actual calculation starts.

EXTENDS Sequences, FiniteSets, Naturals, DynamicGraph

\* last_read, committed_sccs, and *_seen are audit-only history. They do not
\* enable or disable protocol actions; read_deps tracks actual consumed edges.
VARIABLES state, work, scc_stack, solve_count, read_deps, last_read,
          committed_sccs, late_merge_seen, warm_merge_seen, retained_read_seen
vars == <<state, work, scc_stack, solve_count, read_deps, last_read,
          committed_sccs, late_merge_seen, warm_merge_seen, retained_read_seen>>

\* ---------------------------------------------------------------
\* Input contract: these are assumptions about graph cases, not solver results.
\* Initial cycles must expose every cyclic participant, but may split a full
\* component into smaller cycles. Every full edge appears during the period.
\* Noncyclic nodes are solved only once, so their initial dependencies are full.
\* None of these conditions refers to this protocol's completion or SCC records.
\* ---------------------------------------------------------------
ASSUME IsFiniteSet(Nodes) /\ Nodes /= {}
ASSUME StepCount \in Nat /\ StepCount > 0
ASSUME FullGraph \in [Nodes -> SUBSET Nodes]
ASSUME DynamicSteps \in Seq([Nodes -> SUBSET Nodes]) /\ Len(DynamicSteps) = StepCount
ASSUME \A k \in 1..StepCount :
    \A n \in Nodes : DynamicSteps[k][n] \subseteq FullGraph[n]

ReachableIn(graph, n) ==
    LET iter[i \in 0..Cardinality(Nodes)] ==
            IF i = 0 THEN graph[n]
            ELSE iter[i-1] \union UNION {graph[m] : m \in iter[i-1]}
    IN iter[Cardinality(Nodes)]
CycleNodes(graph) == {n \in Nodes : n \in ReachableIn(graph, n)}
ASSUME CycleNodes(DynamicSteps[1]) = CycleNodes(FullGraph)
ASSUME \A n \in Nodes :
    UNION {DynamicSteps[k][n] : k \in 1..StepCount} = FullGraph[n]
ASSUME \A n \in Nodes \ CycleNodes(FullGraph) : DynamicSteps[1][n] = FullGraph[n]

TrueScc(n) ==
    IF n \in CycleNodes(FullGraph)
    THEN {m \in Nodes : n \in ReachableIn(FullGraph, m)
                         /\ m \in ReachableIn(FullGraph, n)}
    ELSE {}
TrueSccSets == {TrueScc(n) : n \in Nodes} \ {{}}

\* Phase 0 is discovery or caller handoff; phase 1 is cold, phases 2+ warm.
\* These are the code's conceptual iteration labels, not a literal simulation
\* of its MAX_ITERATIONS, convergence check, or per-driver demotion cap.
\* Every member completes a whole input period after each cold restart. At
\* least two passes are required for a one-step static input: cold, then warm.
PhaseLimit == IF StepCount < 2 THEN 2 ELSE StepCount
GlobalStates == {"Fresh", "InProgress", "Done"}
SccNodeStates == {"SccFresh", "SccInProgress", "SccHasPlaceholder", "SccDone"}
Calc(n) == [kind |-> "Calc", node |-> n]
Driver(n) == [kind |-> "Driver", node |-> n]
Top == work[Len(work)]
CalcNodes == {work[i].node : i \in {p \in 1..Len(work) : work[p].kind = "Calc"}}
FramePos(frame) ==
    IF \E i \in 1..Len(work) : work[i] = frame
    THEN CHOOSE i \in 1..Len(work) : work[i] = frame
    ELSE 0
SccOf(n) ==
    IF \E i \in 1..Len(scc_stack) : n \in scc_stack[i].members
    THEN CHOOSE i \in 1..Len(scc_stack) : n \in scc_stack[i].members
    ELSE 0
OwnerScc(frame) ==
    IF \E i \in 1..Len(scc_stack) : scc_stack[i].owner = frame
    THEN CHOOSE i \in 1..Len(scc_stack) : scc_stack[i].owner = frame
    ELSE 0
VisibleGraph(n) == DynamicDeps(solve_count, n)
PickNode(S) == CHOOSE n \in S : TRUE
Min(S) == CHOOSE x \in S : \A y \in S : x <= y
Max(S) == CHOOSE x \in S : \A y \in S : x >= y
Pop(seq) == SubSeq(seq, 1, Len(seq)-1)
FilterSeq(seq, remove) ==
    LET kept[i \in 0..Len(seq)] ==
            IF i = 0 THEN <<>>
            ELSE IF i \in remove THEN kept[i-1]
            ELSE Append(kept[i-1], seq[i])
    IN kept[Len(seq)]
CalcSuffix(pos) ==
    {work[i].node : i \in {p \in pos..Len(work) : work[p].kind = "Calc"}}
FreshMembers(i) ==
    {n \in scc_stack[i].members : scc_stack[i].node_state[n] = "SccFresh"}
MembersDone(i) ==
    \A n \in scc_stack[i].members : scc_stack[i].node_state[n] = "SccDone"
MembersOffStack(i) == scc_stack[i].members \intersect CalcNodes = {}
CalcReady == work /= <<>> /\ Top.kind = "Calc"
DriverReady(i) ==
    /\ work /= <<>> /\ Top.kind = "Driver"
    /\ i \in 1..Len(scc_stack) /\ scc_stack[i].owner = Top
Unread(dep) == dep \in VisibleGraph(Top.node) \ read_deps[Top.node]

Init ==
    /\ state = [n \in Nodes |-> "Fresh"]
    /\ work = <<>> /\ scc_stack = <<>>
    /\ solve_count = PushCountInit
    /\ read_deps = [n \in Nodes |-> {}]
    /\ last_read = [reader |-> PickNode(Nodes), dependency |-> PickNode(Nodes),
                    members |-> {}, kind |-> "None"]
    /\ committed_sccs = {}
    /\ late_merge_seen = FALSE /\ warm_merge_seen = FALSE
    /\ retained_read_seen = FALSE

StartRoot(n) ==
    /\ work = <<>> /\ scc_stack = <<>> /\ state[n] = "Fresh"
    /\ state' = [state EXCEPT ![n] = "InProgress"]
    /\ work' = <<Calc(n)>>
    /\ solve_count' = RecordPush(solve_count, n)
    /\ read_deps' = [read_deps EXCEPT ![n] = {}]
    /\ UNCHANGED <<scc_stack, last_read, committed_sccs,
                   late_merge_seen, warm_merge_seen, retained_read_seen>>

Descend(dep) ==
    /\ CalcReady /\ Unread(dep) /\ state[dep] = "Fresh"
    /\ state' = [state EXCEPT ![dep] = "InProgress"]
    /\ work' = Append(work, Calc(dep))
    /\ solve_count' = RecordPush(solve_count, dep)
    /\ read_deps' = [read_deps EXCEPT ![dep] = {}]
    /\ UNCHANGED <<scc_stack, last_read, committed_sccs,
                   late_merge_seen, warm_merge_seen, retained_read_seen>>

\* A known fresh member can be needed by an active caller even while a merge
\* is awaiting restart. Fresh is a work state, not restricted to a phase number.
DescendIntoSccMember(dep) ==
    /\ CalcReady /\ Unread(dep)
    /\ LET i == SccOf(Top.node)
       IN /\ i /= 0 /\ SccOf(dep) = i
          /\ scc_stack[i].node_state[dep] = "SccFresh"
          /\ dep \notin CalcNodes
          /\ scc_stack' = [scc_stack EXCEPT ![i].node_state[dep] = "SccInProgress"]
    /\ work' = Append(work, Calc(dep))
    /\ solve_count' = RecordPush(solve_count, dep)
    /\ read_deps' = [read_deps EXCEPT ![dep] = {}]
    /\ UNCHANGED <<state, last_read, committed_sccs,
                   late_merge_seen, warm_merge_seen, retained_read_seen>>

\* Membership re-entry must merge before a nonmember consumes a local answer.
\* The live owner frame is an anchor, never an incrementally maintained bound.
\* Enclose all newer components and absorb every intervening Calc frame.
MergeStart(dep) ==
    LET i == SccOf(dep)
        target == IF i = 0 THEN FramePos(Calc(dep))
                  ELSE FramePos(scc_stack[i].owner)
        sharing == {j \in 1..Len(scc_stack) :
                       scc_stack[j].members \intersect CalcSuffix(target) /= {}}
    IN Min({target} \union {FramePos(scc_stack[j].owner) : j \in sharing})
OverlappingSccs(pos) ==
    {i \in 1..Len(scc_stack) : FramePos(scc_stack[i].owner) >= pos}
MergedNodeState(members, overlap) ==
    [n \in members |->
        IF \E i \in overlap : n \in scc_stack[i].members
        THEN LET i == CHOOSE i \in overlap : n \in scc_stack[i].members
             IN scc_stack[i].node_state[n]
        ELSE "SccInProgress"]
DetectCycle(dep) ==
    /\ CalcReady /\ Unread(dep) /\ state[dep] = "InProgress"
    /\ IF SccOf(dep) = 0 THEN FramePos(Calc(dep)) /= 0
       ELSE SccOf(dep) /= SccOf(Top.node)
    /\ LET pos == MergeStart(dep)
           overlap == OverlappingSccs(pos)
           members == CalcSuffix(pos) \union UNION {scc_stack[i].members : i \in overlap}
           phase == Max({0} \union {scc_stack[i].phase : i \in overlap})
           merged == [members |-> members, owner |-> work[pos], phase |-> phase,
                      needs_restart |-> TRUE,
                      node_state |-> MergedNodeState(members, overlap),
                      prev_answers |-> UNION {scc_stack[i].prev_answers : i \in overlap},
                      curr_answers |-> UNION {scc_stack[i].curr_answers : i \in overlap},
                      placeholders |-> UNION {scc_stack[i].placeholders : i \in overlap},
                      start_count |-> [n \in members |-> solve_count[n]]]
       IN /\ scc_stack' = Append(FilterSeq(scc_stack, overlap), merged)
          /\ late_merge_seen' = (late_merge_seen \/ phase >= 1)
          /\ warm_merge_seen' = (warm_merge_seen \/ phase >= 2)
    /\ UNCHANGED <<state, work, solve_count, read_deps, last_read,
                   committed_sccs, retained_read_seen>>

RecordRead(dep, members, kind, retained) ==
    /\ read_deps' = [read_deps EXCEPT ![Top.node] = @ \union {dep}]
    /\ last_read' = [reader |-> Top.node, dependency |-> dep,
                     members |-> members, kind |-> kind]
    /\ retained_read_seen' = (retained_read_seen \/ retained)
ReadFinalAnswer(dep) ==
    /\ CalcReady /\ Unread(dep) /\ state[dep] = "Done"
    /\ RecordRead(dep, {}, "Final", FALSE)
    /\ UNCHANGED <<state, work, scc_stack, solve_count, committed_sccs,
                   late_merge_seen, warm_merge_seen>>
ReadCurrentAnswer(dep) ==
    /\ CalcReady /\ Unread(dep)
    /\ LET i == SccOf(dep)
       IN /\ i /= 0 /\ SccOf(Top.node) = i
          /\ scc_stack[i].node_state[dep] = "SccDone"
          /\ dep \in scc_stack[i].curr_answers
          /\ RecordRead(dep, scc_stack[i].members, "Current", FALSE)
    /\ UNCHANGED <<state, work, scc_stack, solve_count, committed_sccs,
                   late_merge_seen, warm_merge_seen>>
ReadPlaceholder(dep) ==
    /\ CalcReady /\ Unread(dep)
    /\ LET i == SccOf(dep)
       IN /\ i /= 0 /\ SccOf(Top.node) = i
          /\ scc_stack[i].node_state[dep] = "SccHasPlaceholder"
          /\ dep \in scc_stack[i].placeholders
          /\ RecordRead(dep, scc_stack[i].members, "Placeholder", FALSE)
    /\ UNCHANGED <<state, work, scc_stack, solve_count, committed_sccs,
                   late_merge_seen, warm_merge_seen>>
ReadPreviousAnswer(dep) ==
    /\ CalcReady /\ Unread(dep)
    /\ LET i == SccOf(dep)
       IN /\ i /= 0 /\ SccOf(Top.node) = i
          /\ scc_stack[i].node_state[dep] = "SccInProgress"
          /\ dep \in scc_stack[i].prev_answers
          /\ RecordRead(dep, scc_stack[i].members, "Previous", scc_stack[i].needs_restart)
    \* Reading a warm answer does not create a placeholder or finish its producer.
    /\ UNCHANGED <<state, work, scc_stack, solve_count, committed_sccs,
                   late_merge_seen, warm_merge_seen>>
CreatePlaceholder(dep) ==
    /\ CalcReady /\ Unread(dep)
    /\ LET i == SccOf(dep)
       IN /\ i /= 0 /\ SccOf(Top.node) = i
          /\ scc_stack[i].node_state[dep] = "SccInProgress"
          \* A merged pass can contain a new cold member beside warm members.
          /\ dep \notin scc_stack[i].prev_answers
          /\ scc_stack' = [scc_stack EXCEPT
                 ![i].node_state[dep] = "SccHasPlaceholder",
                 ![i].placeholders = @ \union {dep}]
          /\ RecordRead(dep, scc_stack[i].members, "Placeholder", FALSE)
    /\ UNCHANGED <<state, work, solve_count, committed_sccs,
                   late_merge_seen, warm_merge_seen>>

FinishCalculation ==
    /\ CalcReady /\ VisibleGraph(Top.node) \subseteq read_deps[Top.node]
    /\ LET n == Top.node
           i == SccOf(n)
       IN IF i = 0
          THEN /\ state' = [state EXCEPT ![n] = "Done"]
               /\ work' = Pop(work)
               /\ UNCHANGED scc_stack
          ELSE /\ UNCHANGED state
               /\ IF scc_stack[i].owner = Top
                  THEN \* The discovery/absorbed caller has now unwound safely.
                       /\ work' = Append(Pop(work), Driver(n))
                       /\ scc_stack' = [scc_stack EXCEPT
                              ![i].node_state[n] = "SccDone",
                              ![i].curr_answers = @ \union {n},
                              ![i].owner = Driver(n),
                              ![i].phase = 0,
                              ![i].needs_restart = TRUE]
                  ELSE /\ work' = Pop(work)
                       /\ scc_stack' = [scc_stack EXCEPT
                              ![i].node_state[n] = "SccDone",
                              ![i].curr_answers = @ \union {n}]
    /\ UNCHANGED <<solve_count, read_deps, last_read, committed_sccs,
                   late_merge_seen, warm_merge_seen, retained_read_seen>>

\* A nested driver whose component merged into an older owner returns to that
\* owner's suspended continuation; it cannot pop or publish the merged record.
ReturnSupersededDriver ==
    /\ work /= <<>> /\ Top.kind = "Driver" /\ OwnerScc(Top) = 0
    /\ work' = Pop(work)
    /\ UNCHANGED <<state, scc_stack, solve_count, read_deps, last_read,
                   committed_sccs, late_merge_seen, warm_merge_seen, retained_read_seen>>
ColdRestart(i) ==
    /\ DriverReady(i) /\ MembersOffStack(i)
    /\ scc_stack[i].needs_restart
    /\ scc_stack[i].phase = 0 \/ MembersDone(i)
    /\ scc_stack' = [scc_stack EXCEPT
           ![i].phase = 1, ![i].needs_restart = FALSE,
           ![i].node_state = [n \in scc_stack[i].members |-> "SccFresh"],
           ![i].prev_answers = {}, ![i].curr_answers = {}, ![i].placeholders = {},
           ![i].start_count = [n \in scc_stack[i].members |-> solve_count[n]]]
    /\ UNCHANGED <<state, work, solve_count, read_deps, last_read,
                   committed_sccs, late_merge_seen, warm_merge_seen, retained_read_seen>>
\* Binding-index ordering is abstracted by any fresh-member choice. This
\* explores protocol bookkeeping across drive orders, not type-value equality.
StartNextMember(i) ==
    /\ DriverReady(i) /\ scc_stack[i].phase >= 1
    /\ \E n \in FreshMembers(i) :
           /\ scc_stack' = [scc_stack EXCEPT ![i].node_state[n] = "SccInProgress"]
           /\ work' = Append(work, Calc(n))
           /\ solve_count' = RecordPush(solve_count, n)
           /\ read_deps' = [read_deps EXCEPT ![n] = {}]
    /\ UNCHANGED <<state, last_read, committed_sccs,
                   late_merge_seen, warm_merge_seen, retained_read_seen>>
TransitionPhase(i) ==
    /\ DriverReady(i) /\ MembersDone(i) /\ MembersOffStack(i)
    /\ ~scc_stack[i].needs_restart /\ scc_stack[i].phase < PhaseLimit
    /\ scc_stack' = [scc_stack EXCEPT
           ![i].phase = @ + 1,
           ![i].node_state = [n \in scc_stack[i].members |-> "SccFresh"],
           ![i].prev_answers = scc_stack[i].curr_answers,
           ![i].curr_answers = {}, ![i].placeholders = {}]
    /\ UNCHANGED <<state, work, solve_count, read_deps, last_read,
                   committed_sccs, late_merge_seen, warm_merge_seen, retained_read_seen>>

\* Publication uses only protocol readiness, not FullGraph or a truth oracle.
\* The audit record observes the actual answers and drives on this transition;
\* checking an off-stack record after removing it would be vacuous.
CommitScc(i) ==
    /\ DriverReady(i) /\ MembersDone(i) /\ MembersOffStack(i)
    /\ ~scc_stack[i].needs_restart /\ scc_stack[i].phase = PhaseLimit
    /\ LET scc == scc_stack[i]
       IN /\ state' = [n \in Nodes |-> IF n \in scc.members THEN "Done" ELSE state[n]]
          /\ committed_sccs' = committed_sccs \union
                 {[members |-> scc.members, answers |-> scc.curr_answers,
                   phase |-> scc.phase,
                   drives |-> [n \in scc.members |-> solve_count[n] - scc.start_count[n]] ]}
    /\ scc_stack' = FilterSeq(scc_stack, {i}) /\ work' = Pop(work)
    /\ UNCHANGED <<solve_count, read_deps, last_read,
                   late_merge_seen, warm_merge_seen, retained_read_seen>>

Finished == /\ \A n \in Nodes : state[n] = "Done"
            /\ work = <<>> /\ scc_stack = <<>>
Next ==
    \/ \E n \in Nodes : StartRoot(n)
    \/ \E dep \in Nodes : Descend(dep)
    \/ \E dep \in Nodes : DescendIntoSccMember(dep)
    \/ \E dep \in Nodes : DetectCycle(dep)
    \/ \E dep \in Nodes : ReadFinalAnswer(dep)
    \/ \E dep \in Nodes : ReadCurrentAnswer(dep)
    \/ \E dep \in Nodes : ReadPlaceholder(dep)
    \/ \E dep \in Nodes : ReadPreviousAnswer(dep)
    \/ \E dep \in Nodes : CreatePlaceholder(dep)
    \/ FinishCalculation
    \/ ReturnSupersededDriver
    \/ \E i \in 1..Len(scc_stack) : ColdRestart(i)
    \/ \E i \in 1..Len(scc_stack) : StartNextMember(i)
    \/ \E i \in 1..Len(scc_stack) : TransitionPhase(i)
    \/ \E i \in 1..Len(scc_stack) : CommitScc(i)
    \* Successful termination alone may stutter, so CHECK_DEADLOCK does not
    \* misreport completion. Every unfinished transition changes protocol state.
    \/ Finished /\ UNCHANGED vars
Spec == Init /\ [][Next]_vars /\ WF_vars(Next)
Liveness == <>Finished

\* ---------------------------------------------------------------
\* Auditing obligations. Truth is used here, never to enable solver actions.
\* ---------------------------------------------------------------
TypeOk ==
    /\ state \in [Nodes -> GlobalStates]
    /\ work \in Seq([kind : {"Calc", "Driver"}, node : Nodes])
    /\ solve_count \in [Nodes -> Nat]
    /\ read_deps \in [Nodes -> SUBSET Nodes]
    /\ last_read \in [reader : Nodes, dependency : Nodes, members : SUBSET Nodes,
                       kind : {"None", "Final", "Current", "Previous", "Placeholder"}]
    /\ \A event \in committed_sccs :
           /\ event.members \subseteq Nodes /\ event.members /= {}
           /\ event.answers \subseteq event.members
           /\ event.phase \in 1..PhaseLimit
           /\ event.drives \in [event.members -> Nat]
    /\ late_merge_seen \in BOOLEAN /\ warm_merge_seen \in BOOLEAN
    /\ retained_read_seen \in BOOLEAN
SccWellFormed ==
    \A i \in 1..Len(scc_stack) :
        /\ scc_stack[i].members \subseteq Nodes /\ scc_stack[i].members /= {}
        /\ scc_stack[i].owner \in [kind : {"Calc", "Driver"}, node : Nodes]
        /\ scc_stack[i].owner.node \in scc_stack[i].members
        /\ FramePos(scc_stack[i].owner) /= 0
        /\ scc_stack[i].phase \in 0..PhaseLimit
        /\ scc_stack[i].needs_restart \in BOOLEAN
        /\ scc_stack[i].node_state \in [scc_stack[i].members -> SccNodeStates]
        /\ scc_stack[i].start_count \in [scc_stack[i].members -> Nat]
        /\ scc_stack[i].prev_answers \subseteq scc_stack[i].members
        /\ scc_stack[i].curr_answers \subseteq scc_stack[i].members
        /\ scc_stack[i].placeholders \subseteq scc_stack[i].members
SccMembersDisjoint ==
    \A i,j \in 1..Len(scc_stack) : i /= j =>
        scc_stack[i].members \intersect scc_stack[j].members = {}
SccStackOrdered ==
    \A i,j \in 1..Len(scc_stack) : i < j =>
        FramePos(scc_stack[i].owner) < FramePos(scc_stack[j].owner)
StackIsInProgress == \A n \in CalcNodes : state[n] = "InProgress"
UniqueControlFrames ==
    \A i,j \in 1..Len(work) : work[i] = work[j] => i = j
OwnerEnclosesActiveMembers ==
    \A i \in 1..Len(scc_stack) :
        \A n \in scc_stack[i].members \intersect CalcNodes :
            FramePos(scc_stack[i].owner) <= FramePos(Calc(n))
SccMembersGloballyInProgress ==
    \A i \in 1..Len(scc_stack) : \A n \in scc_stack[i].members : state[n] = "InProgress"
SccNodeAvailability ==
    \A i \in 1..Len(scc_stack) : \A n \in scc_stack[i].members :
        /\ (scc_stack[i].node_state[n] = "SccDone" => n \in scc_stack[i].curr_answers)
        /\ (scc_stack[i].node_state[n] = "SccHasPlaceholder" => n \in scc_stack[i].placeholders)
        /\ (scc_stack[i].node_state[n] \in {"SccInProgress", "SccHasPlaceholder"} => n \in CalcNodes)
        /\ (scc_stack[i].node_state[n] = "SccFresh" => n \notin CalcNodes)
PrevAnswersComplete ==
    \A i \in 1..Len(scc_stack) :
        ~scc_stack[i].needs_restart /\ scc_stack[i].phase >= 2 =>
            scc_stack[i].prev_answers = scc_stack[i].members
DepsBeforeDone ==
    \A n \in Nodes : state[n] = "Done" => \A dep \in FullGraph[n] : state[dep] = "Done"
\* A tripwire for the explicit read guards: source membership must include
\* reader and dependency. This is not a complete answer-lifetime or type-value
\* leakage analysis, which is outside the availability model.
NoCrossSccLeakage ==
    last_read.kind \in {"None", "Final"} \/
        /\ last_read.reader \in last_read.members
        /\ last_read.dependency \in last_read.members
CommittedSccMatchesTruth == \A event \in committed_sccs : event.members \in TrueSccSets
AllAnswersAtCommit == \A event \in committed_sccs : event.answers = event.members
ScheduleCoveredAtCommit ==
    \A event \in committed_sccs :
        /\ event.phase = PhaseLimit
        /\ \A n \in event.members : event.drives[n] >= PhaseLimit

\* A merge invalidates publication, not availability to active callers.
MergePreservesAvailabilityAction ==
    \A dep \in Nodes : DetectCycle(dep) =>
        LET overlap == OverlappingSccs(MergeStart(dep))
            merged == scc_stack'[Len(scc_stack')]
        IN /\ merged.needs_restart
           /\ UNION {scc_stack[i].curr_answers : i \in overlap} \subseteq merged.curr_answers
           /\ UNION {scc_stack[i].prev_answers : i \in overlap} \subseteq merged.prev_answers
           /\ UNION {scc_stack[i].placeholders : i \in overlap} \subseteq merged.placeholders
RestartRequiresUnwindAction ==
    \A i \in 1..Len(scc_stack) : ColdRestart(i) =>
        /\ MembersOffStack(i) /\ DriverReady(i)
        /\ scc_stack'[i].phase = 1 /\ scc_stack'[i].prev_answers = {}
        /\ scc_stack'[i].curr_answers = {} /\ scc_stack'[i].placeholders = {}
MergePreservesAvailability == [][MergePreservesAvailabilityAction]_vars
RestartRequiresUnwind == [][RestartRequiresUnwindAction]_vars

====
