# Callable Residual v1 Implementation Plan (Draft)

## Scope
This plan targets v1 deltas relative to the generic-residual prototype ending
at `be8734e13b35`, with sanitization replaced by variable-gated residual
visibility.

Primary goals:
1. Keep working generic residual behavior.
2. Replace broad call-end sanitization with precise expansion-time gating.
3. Fix prototype-exposed semantic gaps before layering overload residual work.

## Non-goals (this plan)
- Full overload residual implementation.
- New fallback policy beyond current v1 baseline.
- Large solver architecture refactors unrelated to residual correctness.

## Guiding constraints
- Deterministic behavior and diagnostics.
- No reliance on broad frontier scrub for correctness.
- Minimal policy churn per commit (separate semantics from cleanup).

## Recommended commit sequence

1. Tests first: orientation + scope + marker timing
- Add passing tests first (use `bug = "..."` where behavior is known-wrong):
  - value-side `Forall` on `want` via contravariant recursion path
  - inactive-call-context `Forall` should not create residual candidates
  - failed subset comparison should not leave residual markers behind
  - nested-return wrapper regression: `test_paramspec_wrap_generic_return`
    (`Awaitable[Residual]` must finalize to `Awaitable[T]`, not
    `Awaitable[Unknown]`)
- Keep tests small and single-purpose.

2. Introduce residual-answer gating in `Variable`
- Add solved-state form for gated residual visibility:
  - `ResidualAnswer { target_vars, ty }` (name may vary)
- Wire display/debug formatting and any exhaustive matches.

3. Tighten materialization eligibility (write boundary)
- Ensure residual materialization at `finish_quantified` only applies to
  residual-eligible vars for the active call context.
- Carry origin/scope metadata in residual markers (or equivalent) and enforce
  in-scope-origin checks before materialization.
- Treat write-time eligibility enforcement as mandatory: residual markers must
  only be written for active residual-eligible scope vars.

4. Fix polarity/orientation handling + success-scoped marker timing together
- Replace one-sided `Type::Forall` interception with polarity-aware trigger
  behavior under recursive subset calls.
- Avoid over-broad writes: only record markers for active residual scope vars.
- Ensure marker writes are either:
  - post-success, or
  - protected by snapshot/rollback on failure.
- Add explicit tests for failed-compare cleanup behavior.

5. Make subset-cache behavior side-effect safe for residual paths
- Ensure cache use cannot suppress required residual side effects.
- v1 strategy: bypass `subset_cache` for residual-side-effectful comparisons
  (frames where residual capture/write hooks are enabled).
- keep cache behavior unchanged for non-side-effectful comparisons.
- Add regression test(s) demonstrating:
  - residual-side-effectful comparisons are not cache-short-circuited, and
  - non-side-effectful comparisons still benefit from cache behavior.

6. Apply gating at expansion/forcing boundaries
- Update `expand_with_limit` (and any equivalent var-expansion entrypoints) to:
  - expose residual payload only when queried var is in `target_vars`
  - otherwise return fallback-flattened form
- Ensure behavior is consistent across all residual read paths, including:
  - `expand_with_limit` / var expansion,
  - force/deep-force paths,
  - return-type substitution finalization,
  - class-field substitution finalization,
  - display/export reads (no user-visible residual leaks).

7. De-emphasize/remove broad sanitize path
- Convert `sanitize_call_end_residuals` to debug backstop or remove it.
- Ensure release correctness does not depend on sanitize execution.

8. Doc sync and cleanup
- Update `design-v1.md` and `design-v0.md` status notes to match landed code.
- Keep any temporary compatibility notes explicit (pending overload phase).

## Pitfalls to avoid (from prototype stack)

1. Broad-first marker propagation
- Avoid writing markers from `collect_maybe_placeholder_vars()` without call
  scope filtering; this caused follow-up unwind commits previously.

2. Manual push/pop scope lifecycle
- Introduce scope guards (RAII-style) in the same commit as scope stacks.

3. Mixed policy + plumbing mega-commits
- Separate:
  - residual representation/plumbing,
  - marker/finish semantics,
  - fallback policy tweaks.

4. “Deterministic” partial fixes
- Land semantic comparator tie-break behavior in one complete change, not split
  across follow-up fixes.

## Verification checklist
- All callable-residual tests pass.
- Added polarity regression passes (value-side `Forall` on both sides).
- Added failed-comparison marker-rollback test passes.
- Added cache-side-effect safety regression(s) for residual-producing comparisons.
- `test_paramspec_wrap_generic_return` stays passing with expected
  `[X](x: X) -> Awaitable[X]` result.
- No user-visible `CallableResidual` leak at reveal/export boundaries.
- No correctness dependence on sanitize frontier sweep.

## Suggested landing strategy
- Land steps 1-3 first as a coherence block (tests + write-side invariants).
- Land steps 4-6 next (polarity/timing + cache safety + read-side gating).
- Land step 7 only after tests demonstrate sanitize independence.
- Keep each commit bisectable with focused tests.

## Overload phase (next, after generic v1 stability)

### Scope for overload phase
- Add overload residual capture, persistence, and callable-level materialization
  on top of the generic-v1 baseline.
- Keep ParamSpec argument-selected narrowing as deferred follow-up.

### Required implementation ordering
1. Tests-first coverage for directional symmetry and ambiguity preservation
- Add paired tests for both capture directions (`pattern <: overload` and
  `overload <: pattern`) under equivalent callable-pattern scenarios.
- Add tests that require ambiguity to survive `finish_quantified` and only
  resolve at callable finalization.
- Add tests for zero-viable-branch outcome asserting delayed incompatibility
  diagnostic plus quantified-default fallback behavior.
- Add tests that assert delayed diagnostic anchoring/dedup policy:
  - diagnostic range is the full callable-argument expression range,
  - multiple residual-var failures for one witness emit one diagnostic.

2. Capture symmetry and success gating
- Implement capture in both subset directions with the same replay/error-gated
  persistence semantics.
- Do not land a path where one direction records residuals directly while the
  mirrored direction requires replay validation.
- Explicitly block existential early-commit behavior in
  `got=Overload, want=Callable` when residual context is active.

3. Candidate payload shape before materialization work
- Land payload shape that includes per-var branch value data needed for
  callable-level expansion.
- Do not land branch-projection-only payloads that require follow-up payload
  redesign to recover per-var materialization semantics.

4. Keep grouped ambiguity through `finish_quantified`
- Preserve grouped overload candidates in deterministic order.
- Do not introduce single-winner arbitration in `finish_quantified`, even if
  deterministic; defer branch choice to callable-level finalization.

5. Callable-level branch-coherent expansion
- Implement callable-level expansion first, then wire slot reads into it.
- Do not land slot-local “project one residual slot at a time” finalization as
  an intermediate behavior.
- Ensure recursive finalization of projected branch values keeps callable-slot
  context; do not force `NonCallable` on intermediate projected values.

6. Conservative pruning and compatibility semantics
- Prune branches only on concrete incompatibility proven by subtype/consistency
  checks.
- Do not use structural `Type` equality as pruning criterion.
- Keep deterministic branch ordering independent from pruning decisions.

7. Delayed-diagnostic plumbing for zero-branch witnesses
- Implement witness-level delayed incompatibility recording keyed by
  `(call_site_id, witness_id)` so residual-var-local failures dedupe correctly.
- `witness_id` must be deterministic within a call solve (for example, capture
  insertion order in deterministic traversal).
- Use full argument expression range as the v1 diagnostic anchor.
- Keep message emission deterministic by preserving deterministic witness order.
- Apply quantified-default fallback to remaining related residual vars after
  recording the delayed diagnostic.

### Overload-specific anti-churn guardrails
- Avoid introducing deterministic-but-wrong intermediate behavior that must be
  undone later (single-candidate arbitration, slot-local collapse).
- Avoid landing capture persistence without replay/error gating.
- Avoid single-direction fixes: capture symmetry must include
  `got=Overload, want=Callable` from the start.
- Avoid splitting payload-definition and first consumer across commits when the
  first consumer cannot be correct with the old payload.
- Treat direction symmetry and zero-branch diagnostics as same-commit invariants,
  not follow-up polish.

### Overload verification additions
- Directional symmetry tests pass for both subset entry directions.
- Ambiguity survives finish and is resolved only at callable finalization.
- Zero-branch path emits delayed incompatibility diagnostic and applies
  quantified-default fallback to related residual vars.
- Zero-branch diagnostic is anchored to full argument range and deduped
  witness-wide (not one error per residual var).
- Branch pruning tests confirm:
  - concrete sibling constraints can prune incompatible branches,
  - unresolved-compatible branches are retained,
  - compatible non-identical types are not pruned by structural mismatch.
- Nested projected values inside wrappers preserve callable-slot semantics during
  branch expansion/finalization.
- Target-set residual visibility semantics are covered:
  - coalesced legitimate targets retain residual visibility,
  - non-target aliases flatten to fallback.
