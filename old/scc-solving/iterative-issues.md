# Iterative SCC Solving: Open Issues

This document tracks two architectural problems discovered while rolling out
iterative SCC solving. The goal is to decide whether to fix in the current
stack (by adjusting the existing architecture) or to treat these as known
issues and address in a follow-up redesign.

## Context

Iterative fixpoint solving introduces a thread-local `active_iteration` that
stores SCC membership and iteration state. SCC discovery still uses the
CalcStack/Calculation cycle detection machinery.

## Issue 1: `active_iteration` Is Thread-Global, Not SCC-Scoped

**Observation:** `active_iteration` lives on `CalcStack` (thread state), so
there can only be one active iteration at a time in a thread. This prevents
safe nested iteration and means that any solve while `active_iteration` is set
implicitly participates in the active SCC’s iteration policy.

**Why this is a problem:**
1. Disjoint SCCs discovered during iteration either:
   - must be solved non-iteratively (current behavior), or
   - overwrite the active iteration state (incorrect).
2. The iteration policy leaks across SCC boundaries, making it hard to
   enforce clear invariants about which SCC is being iterated.

**Candidate fixes:**
- **Stacked iteration state:** make `active_iteration` a stack of SCC-scoped
  iteration states, with explicit push/pop on entry/exit.
- **Scoped iteration context:** move iteration state onto `Scc` itself and keep
  a pointer to the “current” SCC in the stack, avoiding cross-SCC leakage.
- **Status quo + forward fixes:** keep a single global iteration state but
  harden invariants (see Issue 2) so cross-SCC accesses are either forbidden
  or treated as back-edges.

## Issue 2: Accessing Active Members Without Back-Edge Detection

**Observation:** The current logic treats back-edges as “node appears on the
current CalcStack.” However, the *iteration* treats any access to a member of
the active SCC as special (placeholders/previous answers), even if that member
is not on the call stack.

**Bug:** A disjoint SCC (or any non-stack dependency) can read an active
iteration member’s provisional answer without triggering a back-edge. This
violates the intended invariant:

> Any read of an active-iteration member from outside the current SCC must be
> treated as a back-edge, causing merge+demotion or a restart.

**Candidate fixes:**
- Treat **any access** to an active-iteration member as a back-edge when the
  current stack is not already inside that SCC’s segment.
- Alternatively, forbid reading active-iteration answers from non-members:
  route such lookups through the legacy path and force recomputation only after
  the iteration completes.

## Decision Needed

We need to decide:
1. Do we update the current stack to enforce SCC-scoped iteration (Issue 1),
   or do we accept a thread-global iteration state and tighten the invariants?
2. If we keep the thread-global state, what is the minimal change to enforce
   the “any access to an active-iteration member is a back-edge” rule (Issue 2)?

## Next Steps

- Confirm invariants for disjoint SCCs discovered during an active iteration.
- Decide whether a structural change (iteration stack) is required or whether
  local fixes are sufficient.
