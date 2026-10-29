---- MODULE DeadlockProbe ----
EXTENDS PyreflyFixpoint

WitnessGraph == [n \in Nodes |-> IF n = "a" THEN {"b", "c"} ELSE {"b"}]
WitnessInit == Init /\ graph = WitnessGraph
\* Finished states are deliberately terminal; permit stuttering there so TLC
\* distinguishes intended termination from an unfinished solver deadlock.
ProbeNext == Next \/ (Finished /\ UNCHANGED vars)
WitnessSpec == WitnessInit /\ [][ProbeNext]_vars /\ WF_vars(ProbeNext)
====
