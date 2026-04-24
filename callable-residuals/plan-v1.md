# Callable Residual v1 Implementation Plan

## Status
This is the active implementation plan for callable residual v1.

Baseline assumption: generic residual prototype behavior already exists and we
are hardening semantics to match `design-v1.md`.

## Scope
In scope:
1. Preserve working generic residual behavior.
2. Replace sanitize-first leak control with variable-gated residual visibility.
3. Close prototype semantic gaps (polarity, marker timing/scope, cache
   side-effect safety).
4. Land overload residual work on top of stable generic-v1 foundations.

Out of scope for this plan:
1. Argument-selected ParamSpec overload narrowing.
2. Broad solver refactors unrelated to residual correctness.
3. New fallback-policy redesigns beyond v1 decisions.

## Non-negotiable constraints
1. Deterministic final types and diagnostics.
2. No correctness dependence on broad frontier sanitization.
3. Tests-first discipline for each behavior change phase.
4. Small bisectable commits that separate plumbing from policy.

## Test-first rule
For each behavior phase:
1. Land tests first (use `bug = "..."` when behavior is known-wrong).
2. Land implementation in follow-up commit(s).
3. Remove/update `bug` markers only after behavior lands.

Never combine new behavior-changing logic with its first test coverage in one
commit.

## Phase plan

### Phase 0: tests for current known gaps (pre-implementation gate)
Add/adjust passing tests first:
1. value-side `Forall` capture under contravariant/polarity-flipped recursion.
2. inactive call context must not produce residual candidates.
3. failed subset comparison must not leave marker residue.
4. nested wrapper finalization regression:
   `test_paramspec_wrap_generic_return` preserves `Awaitable[T]`.
5. non-target alias read flattening.
6. coalesced legitimate targets preserve residual visibility.

Exit criteria:
1. Tests are deterministic and single-purpose.
2. Behavior gaps documented with `bug` markers where necessary.

### Phase 1: representation/plumbing
Implement mechanical representation support without semantic policy changes:
1. Add solved variable state:
   `ResidualAnswer { target_vars, ty }`.
2. Add/normalize residual metadata storage in bounds (`Bounds.residuals` +
   required origin/scope metadata).
3. Update exhaustive `Variable` matches, display/debug paths, serialization
   guards.

Exit criteria:
1. Tree compiles cleanly.
2. No behavior claim yet; strictly representation plumbing.

### Phase 2: write-side invariants (scope + timing + materialization gate)
1. Enforce witness-specific write-time eligibility for residual marker writes.
2. Ensure marker writes are success-scoped (post-success or rollback-safe).
3. Materialize residuals only for in-scope eligible vars with required candidate
   shape.
4. Record residual target sets at creation time and store them on each
   residual answer:
   - generic residuals use all call-scoped vars that appear in the matched
     callable pattern for that witness,
   - overload residuals use only the exact branch-projection var.
5. Keep unrelated vars excluded even if they later unify.
6. Preserve legitimate target-set visibility on UF merges.
7. Enforce invariant handling for incompatible residual identity merges.

Exit criteria:
1. Out-of-scope writes/materialization blocked.
2. Failed comparisons do not leak markers.
3. Legitimate target coalescing keeps all targets visible.

### Phase 3: polarity/orientation correctness + deferred finishing
1. Make residual triggers polarity-aware in recursive subset checks.
2. Ensure value-side `Forall` vars participating in residual solving are
   deferred-finish and call-local.
3. Validate marker propagation respects witness relevance sets rather than
   generic active scope membership.

Exit criteria:
1. Both subset-entry directions pass symmetry tests for generic paths.
2. Contravariant/polarity-flip tests pass.

### Phase 4: subset-cache side-effect safety
1. Detect residual-side-effectful frames.
2. Bypass subset-cache lookup and write for those frames.
3. Keep cache behavior unchanged for non-side-effectful frames.

Exit criteria:
1. Residual side effects cannot be skipped by cache hits.
2. Non-residual paths retain cache behavior/perf characteristics.

### Phase 5: read-side gating and finalization boundaries
1. Apply target-var gating in var expansion (`expand_with_limit` and equivalent
   read paths) using the original root query var.
2. Ensure read-side visibility checks consult the producing witness target set;
   unrelated vars, including later-unified vars, flatten.
3. Ensure nested solved-var reads reached through `Answer(t)` reuse the same
   original query var instead of switching to nested var identity.
4. Ensure forcing/finalization/read/export paths use same visibility rule.
5. Keep recursive callable-legal finalization through wrappers.
6. Ensure no user-visible `CallableResidual` leaks at reveal/export boundaries.

Exit criteria:
1. Non-target aliases flatten at read boundaries.
2. Callable re-promotion is per occurrence.
3. Reveal/export outputs are residual-free.

### Phase 6: sanitize de-emphasis/removal
1. Convert sanitize path to debug-only backstop or remove it.
2. Verify release correctness is independent from sanitize execution.

Exit criteria:
1. Test suite passes with sanitize disabled/non-semantic.

### Phase 7: overload residual layer (post generic-v1 stabilization)
1. Add tests-first for direction symmetry, ambiguity preservation, zero-branch
   delayed diagnostics, and witness-level dedupe.
2. Implement directional capture symmetry and replay/error-gated persistence.
3. Land payload shape that preserves per-var branch data for callable-level
   materialization.
4. Preserve grouped ambiguity through `finish_quantified`.
5. Implement callable-level branch-coherent expansion/finalization.
6. Conservative branch pruning using compatibility checks.
7. Delayed-diagnostic plumbing keyed by `(call_site_id, witness_id)`.

Exit criteria:
1. Directional symmetry tests pass both directions.
2. Ambiguity survives finish and resolves only at callable finalization.
3. Zero-branch path emits one delayed witness diagnostic and applies quantified
   default fallback.

## Implementation map (likely touch points)
1. Solver variable representation and UF merge logic.
2. Bounds metadata write/read paths.
3. Subset recursion/capture hooks and call context plumbing.
4. Quantified finishing (`finish_quantified`) and deferred-finish queues.
5. Expansion/force/finalization paths (return + class-field + export).
6. Subset-cache access wrappers.
7. Callable residual test suites (generic + overload).

## Anti-churn guardrails
1. Do not land slot-local overload materialization as an intermediate step.
2. Do not land one-direction overload capture fixes.
3. Do not split payload definition from first correct consumer when payload
   shape is insufficient.
4. Do not mix deterministic-ordering tweaks with semantic policy changes unless
   required for correctness of the same phase.

## Verification checklist
1. Callable-residual tests pass.
2. Polarity regression tests pass.
3. Failed-compare marker-rollback tests pass.
4. Cache side-effect safety regressions pass.
5. Cross-var regression passes: unrelated vars (for example `S`) that unify
   later with relevant residual vars (for example `T`) do not gain residual
   visibility and instead flatten/fallback.
6. `test_paramspec_wrap_generic_return` preserves
   `[X](x: X) -> Awaitable[X]`.
7. No user-visible `CallableResidual` leaks.
8. No correctness dependence on sanitize frontier sweep.
9. Formatting and linting pass with no new lint issues.

## Suggested landing slices
1. Slice A: Phase 0 + Phase 1.
2. Slice B: Phase 2 + Phase 3.
3. Slice C: Phase 4 + Phase 5.
4. Slice D: Phase 6.
5. Slice E: Phase 7.

Each slice should remain bisectable with direct tests for the changed invariant.
