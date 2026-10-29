---- MODULE MergeMutation ----
EXTENDS PyreflyFixpoint

\* Deliberately wrong for a dynamic-membership solver: preserve the highest
\* iteration when a new cycle merges existing SCC fragments.
\* The supplied static scope does not exercise positive-phase expansion, so
\* this mutation passes its configured properties. That is a coverage gap,
\* not a reason to retain invalid iteration state after a real expansion.
PreserveMergedPhase(overlapping) ==
    IF overlapping = {} THEN 0
    ELSE MaxOfSet({scc_stack[i].phase : i \in overlapping})
====
