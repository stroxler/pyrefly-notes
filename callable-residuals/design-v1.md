# Callable Residual Design (v1)

## Status
This document is the normative v1 design for callable residual behavior.

It supersedes v0 details for generic residual implementation strategy,
especially around residual visibility, leak control, marker scope/timing,
and subset-cache interaction.

## Purpose
Callable residuals preserve higher-order callable correlations long enough to
produce coherent substituted output types for generic and overload callables.

The v1 shift is architectural: correctness is enforced at read boundaries via
variable-gated residual visibility, not by broad call-end scrub passes.

## Core model
v1 keeps the v0 two-layer model:
1. Potential residual metadata in solver variable state (residual candidates on
   `Variable::Quantified`).
2. Materialized residual type artifacts (`Type::CallableResidual(...)`) produced
   during quantified finishing.
3. Residual visibility targets (`SmallSet<Var>`) are captured at subset-check
   time, stored in residual candidates on `Variable::Quantified`, and threaded into
   `Variable::ResidualAnswer.target_vars` during finishing so expand-time
   sanitization has the right query-var gate.

v1 changes visibility and leak policy:
1. Residual observability is gated by the queried variable identity.
2. Flattening happens at explicit boundaries.
3. Broad frontier sanitization is not a correctness mechanism.
4. Generic residual fallback metadata lives on the residual type artifact itself
   (in `Type::CallableResidual`), because not all flattening happens in
   `expand_var` where solver state is available.

## v1 deltas from v0

### 1) Variable-read-gated residual visibility replaces sanitization-first safety
Use a dedicated solved-variable state for residual answers:
- `Variable::ResidualAnswer { target_vars: SmallSet<Var>, ty: Type::CallableResidual(...) }`
- `target_vars` must be threaded from residual capture (quantified residual
  candidates) into
  `ResidualAnswer` materialization. This is mandatory because expand-time
  visibility checks run from solved answers, not from subset-check state.
- Generic residual metadata stores the source `Quantified` on the residual
  artifact (`CallableResidualKind::Generic { quantified }`). Fallback for
  non-target reads is derived as `quantified.as_gradual_type()`, and
  substitution-finalization re-promotion also uses this same `Quantified`.

Variable read behavior (for all solver var-read paths, not only `expand_var`):
- Read of root `Answer(t)` behaves as today.
- Read of root `ResidualAnswer { target_vars, ty }`:
  - if `query_var in target_vars`, expose residual payload `ty`.
  - otherwise expose flattened fallback.
- If reading `Answer(t)` recursively touches nested solved vars, those reads
  still use the original `query_var` from the root read request, not the nested
  var identity.

This policy applies uniformly to all variable-read entry points that can observe
solved vars (for example, expand-time reads plus other direct solved-var reads
such as recursive forcing paths).

Merge behavior:
- Legitimate coalesced residual targets must preserve visibility for all
  participating target vars.
- If multiple residual identities survive on a merged quantified var, retain all
  candidates and let finishing decline residual materialization (falls back to
  normal quantified defaulting/gradualization).

### 2) Prototype structure is retained; leak strategy is replaced
Retain working creation/materialization/finalization structure from the generic
prototype stack:
- residual candidates are captured during subset solving,
- materialization happens in `finish_quantified`,
- transform/elimination happens in substitution finalization.

Only leak-control strategy changes: sanitize-first -> gated visibility.

### 3) Prototype ambiguities are made normative
v1 makes the following mandatory:
- argument-side-aware residual capture in recursive subset flows,
- write-scope and timing rules for residual markers,
- deterministic quantified merge semantics matching implementation,
- subset-cache bypass for residual-side-effectful comparisons.
- constructor-callable normalization that preserves scoped generics.

## Residual elimination boundaries

1. Variable-read boundary for unrelated vars
- Non-target readers of residual answers flatten immediately.

2. Return substitution finalization
- Call-scoped residuals are transformed/eliminated when substituted return types
  are finalized.
- Callable-slot finalization is recursive: residuals must be eliminated
  throughout callable structure (params/return), including nested wrappers such
  as `Awaitable[T]`.
- Exception: residuals inside class `TArgs` may temporarily remain deferred
  until class-field lookup boundaries.

3. Class-field substitution finalization
- Deferred residuals that survive in class `TArgs` must be finalized/eliminated
  at class-field substitution boundaries (after substitution + var expansion).

No other ad hoc leak-scrub mechanism is semantic in v1.

## Normative rules

### Call context and argument side
Residual-enabled call solving carries:
- argument side for current recursive subset frame. The state is tri-valued:
  `Got`, `Want`, or `NotAnalyzingACall` (for generic `is_subset_eq` uses that
  are not part of callable subtyping),
- a witness-specific relevance context for each residual-producing comparison
  site (`Forall` now, `Overload` later), keyed by
  `(call_site_id, witness_id)`.

Argument-side initialization and recursion rules in the current implementation:
- call argument-vs-parameter subset entry seeds side according to top-level call
  direction (`Got` for argument side),
- parameter recursion flips side and return recursion preserves side,
- non-call subset checks remain `NotAnalyzingACall`.

Residual hooks are currently enabled only for the `Got` side. This is a
deliberate defensive baseline to avoid accidental side effects in inverted or
non-call contexts while argument-side-sensitive behavior is still being
expanded.

Each witness relevance context contains:
- `origin_vars`: fresh vars introduced by that witness instantiation,
- `relevant_target_vars`: target vars captured at residual creation time,
- `deferred_vars`: value-side deferred vars created by that same witness.
- witness identity fields (`call_site_id`, `witness_id`) that tie captures,
  materialization, and merge checks to the same producing comparison site.

Residual creation must consult argument side; fixed `(got, want)` assumptions are
invalid.

### Residual marker scope
Residual marker writes are allowed only for:
- vars in the current witness `origin_vars` or `deferred_vars`.
- and only when residual hooks are enabled for the current argument side
  (currently `Got` only).

Residual visibility targets must be recorded only from that witness
`relevant_target_vars`, and they must be attached directly to the created
residual answer.

Target capture policy in v1:
- generic residuals: use the full set of call-scoped vars that appear in the
  matched callable pattern for that witness,
- overload residuals: use witness/pattern-derived call-scoped vars captured for
  that overload witness, not a single branch-projection key var.

Vars that are merely in call scope, or later unify with relevant vars, are
out-of-scope and must not be captured as residual targets.

Write-time scope checks are mandatory.

### Residual marker timing
Marker writes must be success-scoped:
- write post-success, or
- write under rollback/snapshot discipline.

Unconditional pre-success commits without rollback are forbidden.

### Generic residual materialization gate
Generic residual materialization remains narrow:
- var unresolved after normal bounds solving,
- exactly one generic residual candidate,
- quantified kind is eligible (TypeVar, ParamSpec, and TypeVarTuple),
- candidate and target set are tied to a single witness context
  `(call_site_id, witness_id)`,
- var is eligible in that witness context (`origin_vars`/`deferred_vars`), not
  just broadly call-scoped.

Safety for out-of-scope exposure is enforced at read/finalization boundaries:
- variable read-time gating via `ResidualAnswer.target_vars`,
- substitution-finalization sanitization/flattening rules.

Otherwise use normal quantified defaulting/fallback behavior.

Required-concrete non-callable positions use quantified default policy, not
overload branch fallback policy.

### Overload residual capture/materialization requirements
- Capture is argument-side-aware and symmetric across subset entry direction.
- Both directions share the same replay/error-gated persistence policy.
- With active residual context, `got=Overload, want=Callable` must not use
  existential early-commit semantics.
- If overload-vs-callable entry has no active witness context, synthesize one
  from the callable pattern vars before branch probing so capture/target policy
  is live in ordinary call checks.
- Candidate payload must preserve per-var branch materialization data.
  Recommended representation:
  - per witness, keep branch captures such as
    `Vec<{ branch_index, values: SmallMap<Var, Type> }>`
    where `values` maps residual-eligible vars to that branch's projected
    solved types.
  - optional slot/provenance metadata may be stored if needed for diagnostics
    or pruning explanations, but it is not the semantic core.
  - branch values may themselves contain generic residuals; capture must
    preserve that structure and must not flatten it.
- Ambiguity is preserved through `finish_quantified`; resolution is deferred to
  substitution finalization.
- Materialization is callable-level and branch-coherent, not slot-local.
- Branch pruning uses compatibility/subtyping checks, not structural `Type`
  equality. This is part of full project correctness and can be sequenced after
  initial end-to-end overload reconstruction.
- If viable branches become zero:
  - record delayed incompatibility,
  - dedupe by `(call_site_id, witness_id)`,
  - anchor range at full callable-argument expression,
  - apply quantified-default fallback for related residual vars.

Overload limitation retained for v1 baseline:
- argument-selected ParamSpec overload narrowing is deferred.

### Overload staged responsibilities
Overload residual logic is intentionally staged. Each stage has a distinct
payload shape and responsibility.

Sequencing note:
- It is valid to ship an MVP that wires capture -> finishing -> finalization
  before pruning is enabled, as long as behavior is documented as potentially
  admitting false negatives.
- Pruning remains required for full project completion and final diagnostics
  quality.

1. Capture stage (`Variable` payloads)
- Input: subset solving state under witness context.
- Output: branch captures with solve-time payloads, for example
  `Vec<{ branch_index, values: SmallMap<Var, Variable> }>`
  where `Var` keys are residual-eligible pattern call-scoped vars.
- Capture uses snapshot/rollback probing and must not force an existential
  branch commit for residual-enabled overload comparisons.
- If entry lacks an active witness context, capture first synthesizes an
  overload witness from callable-pattern vars.
- For generic overload branches, captured `Variable` payloads must preserve
  generic structure (including unresolved/residual-capable state) rather than
  flattening to fallback types.

2. Finishing stage (`Variable -> Type`)
- Input: captured branch payloads from stage 1.
- Output: branch payloads converted to recursively finished `Type` values.
- Finishing performs branch-set logic (including pruning/deferred-incompatible
  handling) and recursively finishes each captured value.
- MVP sequencing may temporarily keep all captured branches here (no pruning)
  while still performing recursive finishing; this preserves structure but may
  delay incompatibility detection and allow false negatives.
- If a generic overload branch remains residualized after finishing, the
  finished branch payload may contain `Type::CallableResidual(...)`; this is
  expected and must be preserved for finalization.

3. Finalization stage (boundary semantics)
- Input: finished branch payloads from stage 2.
- Output: boundary-safe type result.
- At callable boundaries, reconstruct branch results by substituting the
  branch payloads, then recursively finalize each per-branch result.
  This recursive per-branch finalization is required so generic branches can be
  re-promoted to `Forall` when appropriate.
- At non-callable boundaries, apply flattening/fallback policy.
- For zero-viable branches, apply delayed-incompatibility + quantified-default
  fallback policy from this design.

### Recursive residual finalization
Finalization must recurse through wrappers and preserve callable-legal
transforms:
- `Awaitable[Residual]`, tuples, unions, etc. must be finalized recursively.
- Overload branch reconstruction must apply this same recursion to each
  projected branch value, so branch-local generic residuals are finalized
  correctly.
- Expansion/read paths must not recursively expand through freshly read
  callable-residual markers; marker interpretation is finalized at callable
  boundaries to avoid self-recursive collapse to fallback types.
- Nested residuals must not be flattened solely because they are non-root.
- Inside callable slots, recursive finalization must eliminate residual artifacts
  rather than preserving deferred form.

Concrete guarded regression:
- ParamSpec wrap of generic return must preserve `Awaitable[T]`, not
  `Awaitable[Unknown]`.

Re-promotion granularity:
- per callable-legal occurrence in substituted output,
- each occurrence gets fresh quantification,
- no global/shared quantifier across distinct occurrences.

### Constructor-callable normalization
Residual behavior for constructors depends on preserving binder scope when class
objects are compared as callables.

Normative requirements:
- `ClassDef -> Callable` subset checks must use constructor-callable conversion
  for non-TypedDict classes, rather than silent class promotion that erases
  constructor generic structure.
- Constructor binding (`__init__`/`__new__` conversion) may synthesize
  callable/function types containing bare `Type::Quantified` after stripping
  `self`; these must be wrapped as `Forall` so quantifieds are scoped binders,
  not free vars.
- TypedDict class objects retain their existing non-constructor path in this
  design phase.

### Deterministic quantified merge policy
Deterministic merge behavior follows semantic type/restriction comparison with
deterministic tie behavior.

Residual-candidate merge behavior for coalesced quantified vars:
- merge candidate lists by set-union (dedupe by residual identity),
- generic candidates: materialize only when exactly one generic candidate
  survives at finishing,
- overload candidates: coalesce compatible overload candidates by combining
  branch captures and unioning `target_vars` before materialization,
- if incompatible or multiple unresolved identities remain after coalescing, do
  not materialize; fall back to normal quantified defaulting/gradualization.

v0 provenance-priority wording is superseded unless explicitly reintroduced.

### Subset-cache side-effect safety
For residual-side-effectful comparisons (capture/write hooks enabled):
- include residual context identity in subset-cache keys:
  - default non-residual context uses the default cache key,
  - residual witness context uses `(witness_id, argument_side)` keying.

This prevents cache reuse from suppressing required marker side effects across
distinct witness/argument-side contexts, while preserving cycle detection and
memoization behavior within a single context.

Most subset comparisons run in the default context and continue to use existing
cache behavior.

## Invariants

1. Residual production eligibility is witness-specific: only vars in the
   producing witness `origin_vars`/`deferred_vars` are eligible, and visibility
   targets come only from that witness `relevant_target_vars`.
2. Residual observability is gated by `ResidualAnswer.target_vars`.
3. Accidental UF aliasing may happen; non-target alias reads flatten.
4. Read-time visibility checks use the original query var for the
   entire read path, including nested solved vars reached through `Answer(t)`.
5. Different residual identities (`call_site_id`, `witness_id`) must never
   silently coalesce into one observable residual answer.

## Diagnostics and failure policy
- Out-of-scope residual visibility is an invariant violation.
- debug builds: assert/panic.
- release builds: emit internal diagnostic and flatten to non-residual fallback.

Zero-viable-overload witness diagnostics:
- one delayed incompatibility per `(call_site_id, witness_id)`,
- deterministic ordering,
- full callable-argument range anchor.

Richer wording that contrasts reconstructed argument-callable vs substituted
parameter-callable remains follow-up work.

## Migration notes
1. Keep two fallback channels distinct:
- visibility fallback (non-target residual read) via residual fallback policy,
- zero-viable-overload fallback via quantified defaulting after delayed
  incompatibility.

2. Temporary sanitize code may remain as debug instrumentation/backstop during
migration, but must remain non-semantic.

3. Remove or strictly narrow sanitize once gating behavior and tests are stable.

## Open follow-up items (not required for v1 baseline)
1. Argument-selected ParamSpec overload narrowing.
2. Diagnostic wording improvements for zero-viable-overload witness errors.
3. Performance work beyond correctness-first subset-cache bypass.
4. Extend argument-side-sensitive residual behavior beyond the current
   `Got`-only hook baseline.
