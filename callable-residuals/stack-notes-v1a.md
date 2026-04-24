# Callable Residual Stack Notes (v1a)

## 2026-04-20

- We pulled subset-cache bypass for residual-side-effectful frames earlier than its planned
  chunk in `plan-1a.md`.
  Reason: once generic `Forall` capture writes/defer side effects in subset, cache hits can
  bypass those effects and produce incorrect behavior.
  Change made: `Subset::is_subset_eq_impl` now bypasses recursive subset-cache lookup/write
  whenever a call residual context is active.
  Design impact: no semantic divergence from `design-v1.md`; this is a sequencing change to
  preserve correctness of side-effectful comparisons.

## 2026-04-21

- Divergence consult on generic residual marker write-scope hardening:
  attempted UF-root write guards in `mark_generic_residual_candidate` regressed
  `test_paramspec_identity_generic_specializes_call_results`.
- Decision for this slice: land deterministic residual metadata merge and
  fallback gate tightening without UF-root write-scope hardening.
- Follow-up required in next slice: move generic residual candidate recording
  into call-context-owned metadata keyed by original witness vars, and consult
  that metadata during finishing instead of mutating solver UF roots.
- Risk accepted temporarily: generic candidate metadata is still stored on UF
  roots, so witness write-scope hardening remains incomplete until follow-up.
- Follow-up attempts to harden generic fallback against UF-root cross-batch leakage (finish-batch guard and call-scope-root guard)
  both regressed `test_paramspec_identity_generic_specializes_call_results` by eliminating expected fallback-to-Unknown behavior.
- Decision: keep commit `aebe5c4fadde` behavior as current baseline (passes callable_residuals), and defer full UF-root leakage hardening
  to a larger refactor that can preserve ParamSpec identity behavior while enforcing witness/origin scoping.
