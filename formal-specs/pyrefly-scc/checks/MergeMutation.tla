---- MODULE MergeMutation ----
EXTENDS PyreflyFixpoint

\* Deliberately wrong for a dynamic-membership solver: preserve the highest
\* iteration when a new cycle merges existing SCC fragments.
PreserveMergedPhase(overlapping) ==
    IF overlapping = {} THEN 0
    ELSE MaxOfSet({scc_stack[i].phase : i \in overlapping})
====
