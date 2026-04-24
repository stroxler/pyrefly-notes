# Callable Residual v1 Plan 1a

## Status
This is a replacement implementation plan intended to produce a clean v1 stack while folding in:
1. bugs that were fixed later in-stack (so we do not reintroduce them),
2. final-design deltas from `design-v1.md`, especially expand/read-time gating,
3. new inserted commits where the prototype stack does not cover the final design.

## Planning stance
1. Preserve the successful prototype ordering as much as possible.
2. Avoid churn-heavy solver rewrites that diverge from the proven stack.
3. Make each work chunk bisectable and test-first.
4. Keep sanitization non-semantic: correctness comes from read/expand gating.

## Standalone execution rules
1. This document is self-sufficient. Commit hashes are historical anchors only.
2. If prototype behavior conflicts with `design-v1.md`, follow `design-v1.md`.
3. Do not implement residual semantics through mutable solver-global or thread-local scope stacks.
4. Thread call-context/witness/query-var information explicitly through relevant APIs.

## Core design deltas to apply
1. Residual target visibility is stored on residual answers at creation time.
2. Generic target set: all call-scoped vars that appear in the matched callable pattern.
3. Overload target set: exact branch-projection var only.
4. `expand_var(query_var)` gating is semantic: if `query_var` is not in target set, flatten.
5. Nested solved-var reads reached through `Answer(t)` continue using the original root `query_var`.
6. UF aliasing must not grant visibility to non-target vars.
7. Residual-producing comparisons carry witness context keyed by `(call_site_id, witness_id)` with `origin_vars`, `relevant_target_vars`, and `deferred_vars`.
8. Residual creation/materialization must enforce witness-specific eligibility; broad call-scope membership is insufficient.
9. Keep fallback channels distinct: `non-target visibility fallback` is separate from `zero-viable-overload quantified-default fallback`.

## Plan 1a Work Chunks

### Callable Residual Test Baseline and Scaffolding
Prototype references (optional):
- Keep: `a39d1504dba9`, `85dc3967a719`, `2a7227710296`, `badc9df835d0`, `9e2f46bbce87`
- Keep concept: `ef87630c57f2`

Insert commit after scaffolding (residual-answer representation plumbing):
- Add `Variable::ResidualAnswer { target_vars, ty }` plumbing early.
- Add residual identity metadata required for safe target-set merges.
- Add no behavior change yet; compile-only + debug/display paths.

Tests-first:
- Maintain all moved callable residual suite tests from baseline.
- Add compile-time/inert-path assertions where needed.

### Generic Capture and Deferred Finishing
Prototype references (optional):
- Keep concept: `0af1213e6d78`, `a30e554a5d64`, `9e17e6735e84`, `e2d9397f0218`
- Fold-in bugfix behavior immediately; do not stage regressions first.

Implementation requirements:
1. Capture generic residual candidates during `Forall` subset in polarity-aware flow.
2. During witness construction, define `relevant_target_vars` exactly as:
   all call-scoped vars appearing in the matched callable pattern for that witness.
3. Defer value-side `Forall` finishing in the same slice.
4. Active and inactive `Forall` paths must share precise witness-scoped eligibility rules.
5. Marker writes are allowed only for `origin_vars | deferred_vars`.
6. At residual creation/capture time (not later materialization), write
   `ResidualAnswer.target_vars` from that witness `relevant_target_vars` only.
   This is target metadata attachment for later solved-var materialization, not early solved-answer commit.
7. Marker timing is success-scoped (post-success or rollback/snapshot).
8. Generic materialization gate requires all of:
   unresolved var, exactly one candidate, eligible kind (`TypeVar` baseline),
   candidate+target set tied to one witness identity, and var eligibility in that witness.
9. Materialization re-checks scope/origin metadata before commit.
10. Required-concrete non-callable positions use quantified default policy, not overload fallback.
11. `finish_quantified` fallback precedence is fixed now:
   `solve bounds -> residual materialization gate -> quantified gradual fallback`.

Do not repeat prototype mistakes:
- Never land generic materialization with immediate finish still active.
- Never use broad placeholder/want-side marking when inactive.

Tests-first (must land before behavior):
- value-side deferred finish regression,
- inactive-context no over-marking regression,
- failed comparison rollback/no marker residue regression,
- hint-path deferred finishing regression,
- finish_quantified fallback-order regression:
  `solve bounds -> residual gate -> quantified gradual fallback`,
  independent of first-use mode.

### Expand/Read-Time Gating Replaces Sanitize-First
Prototype references (optional):
- Replace behavior from `8d90dabc3b32`
- Replace sanitize-focused tests from `b2509c37a265`

Insert commit before/at this stage (read-path gating core):
- Implement semantic read-path gating in `expand_var` and equivalent solved-var read paths.
- Thread `root_query_var` explicitly through expansion helpers.
- Visibility check uses original root query var for full recursive expansion.
- Visibility checks must ignore UF/root aliasing and use only
  `root_query_var in ResidualAnswer.target_vars`.
- Non-target reads flatten immediately.

Insert commit in same stage (nested-read root-query-var propagation):
- Ensure nested residual reads inside solved `Answer(t)` still use root query var.
- Explicitly prevent reader var identity switching on nested recursion.

Sanitize handling:
- keep sanitize only as debug backstop or extra boundary hygiene,
- sanitize must not be correctness-critical.

Tests-first:
- non-target alias flatten despite UF unification,
- nested-read root-query-var propagation,
- solved call-scoped param containing nested residual remains gated by root query var.

### Export and Finalization Boundary Routing
Prototype reference (optional):
- Keep concept: `618a551a6f99`

Implementation requirements:
1. Route export/protocol/report conversion through shared residual finalizer.
2. Preserve recursive callable-legal finalization through wrappers.
3. Ensure no user-visible `CallableResidual` leaks at reveal/export boundaries.
4. Return-substitution finalization eliminates/transforms call-scoped residuals.
5. Class `TArgs` may temporarily carry deferred residual form.
6. Class-field substitution finalization must eliminate deferred residuals from class `TArgs`.

Rule:
- leak safety for non-target readers is already enforced by expand/read-time gating.
- this chunk is still semantic for substitution outputs:
  return-substitution and class-field substitution finalization must produce
  callable-coherent, non-residualized external forms.
- do not defer this chunk as hygiene-only work.

Tests-first:
- reveal/export boundary leak regression (no user-visible `CallableResidual`),
- return-substitution finalization regression,
- class `TArgs` deferred form allowed pre-field-substitution but eliminated at class-field boundary.

### Deterministic Merge and Metadata Stability
Prototype references (optional):
- Keep concept: `514fd815a4f4`, `be8734e13b35`

Implementation requirements:
1. Deterministic quantified merge semantics for residual metadata.
2. No unique-id-sensitive tie-break behavior.
3. Union target sets only for same residual identity.
4. Incompatible identity merge: assert/debug + release flatten/diagnostic.

Sequencing note:
- Deterministic merge and metadata stability is a prerequisite for both generic and overload residual materialization paths.

### Overload Capture Foundation (Ambiguity-Safe)
Prototype references (optional):
- Keep concept: `7118bb542225`, `8b6c8ad46b2f`, `ccd733f29fea`
- Fold-in ambiguity-safe capture prerequisites from `0b8b8721eb55` immediately.

Implementation requirements:
1. Overload residual representation supports grouped/ambiguous candidates.
2. Capture is polarity-aware and symmetric across both subset-entry directions.
3. Capture all live-valid branches, not first-success branch.
4. Persist only replay-valid capture outcomes.
5. Replay-validity is strict: persisting a candidate must introduce no new specialization/instantiation diagnostics on live replay.
6. Target set for overload residual candidate is exact branch-projection var.
7. With active residual context, `got=Overload, want=Callable` must not use existential early-commit semantics.
8. Candidate payload stores per-var branch materialization data.
9. This chunk is capture-only; no overload residual materialization into solved vars.
10. Both subset-entry directions must use the same replay/error-gated persistence policy;
    no direction-specific acceptance criteria.
11. Arbitration in this chunk is capture-stage only (preserve ambiguity; no branch commitment).
12. Global generic-vs-overload arbitration is implemented only in
    Overload Materialization and Slot-Coherent Finalization.

Do not repeat prototype mistakes:
- no first-branch early commit,
- no ambiguity collapse in capture stage.

Tests-first:
- first-success branch collapse regression,
- replay-invalid candidate drop regression,
- symmetric polarity capture regression.

### Overload Materialization and Slot-Coherent Finalization
Prototype references (optional):
- Keep concept: `f75393d8c999`, `db96f76535a0`, `0bb3c29bad30`, `83cd1c13aa63`, `0f030cf2cb9c`, `3dd15dab9687`, `ceea9ad00761`

Insert commit immediately after first overload materialization (residual-answer materialization form):
- Materialize as `ResidualAnswer { target_vars, ty }` (not plain `Answer`).
- Read gating policy identical to generic residual path.

Implementation requirements:
1. This is the first chunk allowed to materialize overload residuals into `ResidualAnswer`.
2. Residual arbitration policy is explicit and global:
   generic residual wins over overload residual for same var/context;
   overload materializes only when unambiguous or as grouped candidates for later callable expansion;
   never select a single overload branch from an ambiguous set during quantified finishing.
3. Separate callable finalization slots explicitly: `Return`, `ParamType(i)`, `ParamSpec`.
4. Support indexed `TypeParam(n)` projection in plain callable param slots.
5. Preserve grouped ambiguous overload candidates through quantified finishing.
6. Resolve ambiguity only at callable-level finalization.
7. Overload residual materialization is callable-level and branch-coherent:
   materialize grouped callable payload first; slot kinds are consumed during projection/finalization.
8. Branch pruning uses compatibility/subtyping checks, not structural `Type` equality.
9. Zero-viable branches policy:
   one delayed incompatibility per `(call_site_id, witness_id)`,
   deterministic ordering, full callable-argument range anchor,
   then quantified-default fallback for related residual vars.
10. Preserve callable-slot context through nested finalization recursion.
11. Re-promotion granularity is per callable-legal occurrence with fresh quantification each time; no shared/global quantifier reuse.

Do not repeat prototype mistakes:
- no slot conflation,
- no premature grouped-candidate fallback,
- no nested-context reset to non-callable.

Tests-first:
- generic-first arbitration under ambiguity regression,
- slot split regression (`ParamType(i)` vs `ParamSpec`) plus `TypeParam(n)` projection regression,
- grouped-candidate preservation-through-finish regression,
- nested callable-slot context preservation regression.

### Residual Side-Effect Cache Bypass

Implementation requirements:
1. Define `has_residual_side_effects(frame)` for capture/write-hook-capable comparisons.
2. If side-effectful, bypass subset-cache lookup and subset-cache write.
3. Preserve in-progress recursion/coinductive safety.
4. Keep non-side-effectful frames on normal cache path.
5. Add regressions proving side-effectful frames do not cache and non-side-effectful frames still cache.
6. Preserve rollback/replay safety: cache reuse must not suppress required marker side effects.

## Optional Prototype Mapping (for code lookup only)
1. Keep mostly as-is: `a39d1504dba9`, `85dc3967a719`, `2a7227710296`, `badc9df835d0`, `9e2f46bbce87`, `7118bb542225`.
2. Keep concept but integrate with new semantics: `ef87630c57f2`, `0af1213e6d78`, `a30e554a5d64`, `9e17e6735e84`, `e2d9397f0218`, `618a551a6f99`, `514fd815a4f4`, `be8734e13b35`, `8b6c8ad46b2f`, `f75393d8c999`, `0b8b8721eb55`, `db96f76535a0`, `0bb3c29bad30`, `ccd733f29fea`, `83cd1c13aa63`, `0f030cf2cb9c`, `3dd15dab9687`, `ceea9ad00761`.
3. Replace or de-emphasize: `8d90dabc3b32` and `b2509c37a265` sanitize-first behavior.
4. New inserted commits:
   residual-answer representation plumbing,
   read-path gating core,
   nested-read root-query-var propagation,
   residual-answer materialization form.

## Optional Prototype Reference Chain
Use this chain only when an implementation agent needs to inspect prior code details.
- Non-normative lookup aid only. Do not import sanitize-first behavior from
  referenced commits. When in doubt, follow this plan and `design-v1.md`.
`a39d1504dba9 -> ef87630c57f2 -> 0af1213e6d78 -> 8d90dabc3b32 -> 85dc3967a719 -> 2a7227710296 -> a30e554a5d64 -> 9e17e6735e84 -> badc9df835d0 -> 9e2f46bbce87 -> b2509c37a265 -> e2d9397f0218 -> 618a551a6f99 -> 3e71f91d7dad -> 514fd815a4f4 -> be8734e13b35 -> 7118bb542225 -> 8b6c8ad46b2f -> f75393d8c999 -> 0b8b8721eb55 -> db96f76535a0 -> 0bb3c29bad30 -> ccd733f29fea -> 83cd1c13aa63 -> 0f030cf2cb9c -> 3dd15dab9687 -> ceea9ad00761`.

## Bugfix-to-prevention matrix
This matrix includes both direct bugfix commits and regression-prevention behavior folds.
1. `9e17e6735e84`, `e2d9397f0218`:
   active/inactive eligibility parity; no broad want-side marking.
   Enforced in Generic Capture and Deferred Finishing.
2. `3e71f91d7dad`:
   stable fallback precedence in `finish_quantified`.
   Enforced in Generic Capture and Deferred Finishing.
3. `514fd815a4f4`, `be8734e13b35`:
   deterministic merge; no unique-sensitive tie-break.
   Enforced in Deterministic Merge and Metadata Stability.
4. `0b8b8721eb55`:
   generic-first arbitration with ambiguity-safe overload handling.
   Enforced in Overload Materialization and Slot-Coherent Finalization.
5. `0bb3c29bad30`, `83cd1c13aa63`:
   explicit slot kinds plus `TypeParam(n)` param-slot support.
   Enforced in Overload Materialization and Slot-Coherent Finalization.
6. `0f030cf2cb9c`, `3dd15dab9687`:
   grouped candidate preservation through finish and callable-level resolution.
   Enforced in Overload Materialization and Slot-Coherent Finalization.
7. `ceea9ad00761`:
   preserve callable-slot context through nested finalization recursion.
   Enforced in Overload Materialization and Slot-Coherent Finalization.
8. `a30e554a5d64`:
   defer value-side `Forall` finishing in the same step as generic residual materialization.
   Enforced in Generic Capture and Deferred Finishing.
9. `618a551a6f99`:
   route export/protocol/report paths through shared finalizer; no boundary bypass.
   Enforced in Export and Finalization Boundary Routing.
10. `8b6c8ad46b2f`, `ccd733f29fea`:
    capture all live-valid branches and persist only replay-valid candidates; no first-success collapse.
    Enforced in Overload Capture Foundation (Ambiguity-Safe).
11. `db96f76535a0`:
    do not flatten callable slots after overload materialization; finalize in callable slots.
    Enforced in Overload Materialization and Slot-Coherent Finalization.
12. `8d90dabc3b32`, `b2509c37a265`:
    sanitize-first leak control and sanitize-boundary coverage are replaced by
    expand/read-time visibility gating.
    Enforced in Expand/Read-Time Gating Replaces Sanitize-First.

## Diagnostics and invariant policy
1. Out-of-scope residual visibility/materialization is an invariant violation.
2. Debug builds: assert/panic.
3. Release builds: emit internal diagnostic and flatten to non-residual fallback.
4. Incompatible residual identity merge follows the same failure policy.

## Verification gates per work chunk
1. Each work chunk lands with direct regression coverage for the invariant changed in that chunk.
2. No work chunk depends on a later bugfix commit for correctness.
3. `ResidualAnswer` visibility checks always use root query var across nested read paths.
4. No user-visible `CallableResidual` leak in reveal/export paths.
5. Deterministic outputs and diagnostics across repeated runs.
6. No silent residual coalescing across differing `(call_site_id, witness_id)`.
7. Coverage includes class-field `TArgs` deferred-finalization boundary behavior.
8. Coverage includes zero-viable-overload delayed incompatibility dedupe and range anchoring.
9. Residual context flow is parameterized (explicit call-site/witness/query-var threading);
   no solver-global/thread-local scope stack is introduced for residual semantics.

## Per-chunk done criteria
1. All tests-first tests for that chunk are present and passing before behavior changes land.
2. At least one regression asserts each listed do-not-repeat-prototype-mistakes bullet.
3. Invariant checks introduced in that chunk are exercised by tests in that same chunk.
4. No correctness dependency on a later chunk is introduced.

## Exit criteria
1. The implementation can be executed linearly with the prototype stack as reference.
2. Known in-stack regression cycles are eliminated by construction.
3. Expand/read-time gating, target-set-on-residual, and nested root-query-var behavior are first-class semantics, not follow-up cleanups.
4. Plan remains compatible with future overload narrowing work (out of scope here).
5. Argument-selected ParamSpec overload narrowing remains out of scope for this stack.
