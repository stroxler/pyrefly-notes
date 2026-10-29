---- MODULE DeadlockProbe ----
EXTENDS PyreflyFixpoint

\* The fixed graph has a -> {b,c}, b -> {b}, c -> {b}.
\* Witness: StartRoot(a), Descend(b), DetectCycle(b), CreatePlaceholder(b),
\* FinishCalculation, Descend(c), TransitionPhase(1). The caller continues
\* while b's child SCC still awaits driving. Now b is off-stack and Fresh,
\* c cannot resolve it, and StartNextMember's required anchor depth is wrong.
\* Rust drives the child SCC inside the lookup before the caller resumes.
\* This is therefore a model-only unfinished deadlock, not a Python repro.
WitnessGraph == [n \in Nodes |-> IF n = "a" THEN {"b", "c"} ELSE {"b"}]
WitnessInit == Init /\ graph = WitnessGraph
\* Finished states are deliberately terminal; permit stuttering there so TLC
\* distinguishes intended termination from an unfinished solver deadlock.
ProbeNext == Next \/ (Finished /\ UNCHANGED vars)
WitnessSpec == WitnessInit /\ [][ProbeNext]_vars /\ WF_vars(ProbeNext)
====
