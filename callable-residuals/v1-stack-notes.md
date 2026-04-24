# Callable Residual v1 Stack Notes

## Purpose
Track problems or ambiguities discovered while executing `plan-v1.md` so they
can be reviewed and resolved deliberately.

## Entries

### 2026-04-20: Tooling constraint
- Requested Claude-assisted review/discussion workflow is not currently wired as
  an available local skill in this environment. For now, use delegated
  subagent review as the alternate second perspective and keep this item open.

### 2026-04-20: Phase 0 plan drift vs current behavior
- Two listed Phase 0 gaps appear already correct on current trunk in
  `callable_residuals` tests:
  1. Inactive call context did not produce residual carryover in the exercised
     scenario.
  2. Failed subset comparison did not leave externally visible marker residue in
     the exercised scenario.
- Kept both as regression coverage but without `bug` markers. Recommend
  explicitly marking these plan bullets as "verify-only unless repro found" to
  avoid implementation churn on already-fixed behavior.
### 2026-04-20: Repo structure clarification
- `pyrefly` source control and implementation stack must be driven via Sapling
  (`sl`) at the fbsource root.
- `pyrefly-docs` is a separate git-ignored notes repo; keep stack notes there,
  but do not treat it as source-of-truth for source-control operations in
  `pyrefly`.

### 2026-04-20: Generic-v1 baseline mismatch risk
- Explorer review found no current in-tree `Type::CallableResidual` or
  `Bounds.residuals` implementation surface in source.
- This means Phase 1 is not pure wiring on this checkout; it introduces new
  model surface and potentially broad match fallout.
- Execution policy: keep Phase 1 minimal/mechanical and defer semantics to later
  phases to avoid cross-cutting churn.

### 2026-04-20: Phase 0 test strength correction
- First-round review flagged two weak tests:
  1. non-target alias flattening test was tautological,
  2. coalesced-target test did not force meaningful behavior.
- Tests were strengthened to include target-constraining assignments plus
  unannotated reads.
- Current observed behavior still shows coalesced alias reveals as `Unknown`
  under target pressure; retained as `bug`-tracked regression signal.

### 2026-04-20: Generic residual gate landed without read-side gating surface
- This slice added call-scoped write gating, success-scoped marker writes, and
  stricter materialization gates in solver flow.
- The checkout still has no `Type::CallableResidual` representation and no
  read-time target flattening path, so `ResidualAnswer.target_vars` is not yet a
  full user-visible visibility boundary.
- Follow-up is still required to implement read-side gating semantics and
  non-target flattening behavior.

### 2026-04-20: Blockers found in call-scope write/materialization patch review
- Independent review found three blocking issues before landing:
  1. residual materialization branch was effectively unreachable in
     `finish_quantified` due solve-order,
  2. residual var-merge introduced solved-state unification side effects and
     direction-sensitive behavior,
  3. read paths still ignored `target_vars`, so any reachable residual answer
     would leak specialization through non-target reads.
- Action: hold commit, patch these blockers, and re-review before landing.

### 2026-04-20: Landing review on call-scoped residual gating changes
- Blockers fixed before landing:
  1. residual materialization reachability in `finish_quantified`,
  2. solved-var residual comparison no longer performs destructive UF rewrites,
  3. `ResidualAnswer` read paths now apply `target_vars` visibility gating.
- Remaining non-blocking risks (tracked for follow-up):
  1. residual scope membership currently checks across the active per-thread
     scope stack,
  2. residual-vs-answer var comparisons do not currently promote metadata onto
     the answer side,
  3. mixed residual and non-residual evidence needs broader stress testing.

### 2026-04-20: Subset memoization safety landing notes
- Implemented cache-safety guards for residual-producing/speculative comparisons:
  - bypass persistent subset-cache when side effects are possible,
  - use in-progress recursion tracking to preserve coinductive safety,
  - rollback memoized entries created during failed/non-OK speculative checks.
- Non-blocking tradeoff: cache bypass predicate is intentionally conservative and
  may increase recomputation in recursive-heavy paths.

### 2026-04-20: Witness-specific refinement blocker cycle
- Post-implementation review found two blocking regressions in the first
  witness-specific patch:
  1. var-vs-var residual comparisons bypassed visibility gating and compared
     raw residual payloads, allowing non-target constraints to observe hidden
     specialization,
  2. callable bounds inside witness scope could be captured as residual
     candidates and skipped from normal bounds even when residual finalization
     later fell back.
- Follow-up direction for this slice:
  1. restore visibility-boundary behavior for solver-internal var comparisons
     without reintroducing cross-witness target-set union leakage,
  2. ensure residual capture does not drop callable bounds when witness target
     evidence is insufficient for finalization.
