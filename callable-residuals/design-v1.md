# Callable Residual Design (v1, pre-notes)

## Purpose
This document is an early v1 delta note against `design-v0.md`.

v1 keeps the same high-level residual architecture (potential residuals in
`Bounds`, materialized residuals at `finish_quantified`, elimination/transform
at substitution finalization), but changes how leak/sanitization safety is
enforced.

## v1 deltas from v0

### Delta 1 (primary): replace broad call-end sanitization with variable-gated residual visibility
v0 includes a call-end sanitization sweep over a frontier of reachable vars to
remove out-of-scope residual metadata/artifacts.

v1 direction:
- remove broad frontier sanitization as a primary correctness mechanism
- enforce residual visibility directly in `variables`/expansion behavior
- flattening happens at explicit, well-defined boundaries only

Proposed mechanism:
- introduce a dedicated solved-variable form, conceptually:
  - `Variable::ResidualAnswer { target_vars: SmallSet<Var>, ty: Type::CallableResidual(...) }`
- only vars in `target_vars` are allowed to observe the residual payload as a
  residual during expansion
- any other var that reaches the same union-find root must see fallback
  flattening instead of residual payload
- union-find merge rule for legitimate residual targets: if multiple
  residual-eligible vars for the same active call witness coalesce, residual
  visibility must remain available to all of those coalesced target vars (for
  example via a target-set representation or equivalent semantics). A merge must
  not arbitrarily flatten one legitimate target var while preserving another.

Operational rule at expansion:
- for `expand_var(x)` (or equivalent `Type::Var(x)` expansion path):
  - if root is plain `Answer(t)`: current behavior
  - if root is `ResidualAnswer { target_vars, ty }`:
    - if `x in target_vars`: expose `ty`
    - else: expose fallback-flattened form

This makes sanitization local, explicit, and deterministic at the point where
types are read from solver state, instead of depending on best-effort global
frontier rewrites.

### Delta 2: incorporate prototype lessons while keeping overall v0 structure
There is now a prototype stack implementing most of v0 generic residual
behavior. v1 should preserve successful structure from that work and apply
changes incrementally:
- keep residual creation points and finishing pipeline shape where they are
  already working
- keep substitution finalization as the transform/fallback boundary
- revise only the leak-control strategy (sanitization -> variable-gated
  flattening), then iterate based on test outcomes

### Delta 3: convert prototype-discovered ambiguities into explicit rules
The prototype exposed a few places where v0 wording was too permissive for
consistent implementation. v1 makes these explicit:
- residual creation/orientation must be polarity-aware in recursive subset
  checks (not hardcoded to one side of `is_subset_eq`)
- the polarity/orientation rule is shared infrastructure for both generic and
  overload residual capture (both `pattern <: value` and `value <: pattern`
  entry paths must be covered)
- residual-marker writes must be scoped and timing-defined
- deterministic quantified metadata merge policy must match implementation
  semantics
- subset-cache behavior must not skip required residual side effects

## Residual elimination boundaries in v1
v1 narrows and hardens where flattening/elimination is allowed:

1. Expansion boundary for unrelated vars:
- at var expansion, if a residual answer is being read through a var other than
  the recorded `target_vars` set, flatten immediately to fallback

2. Return-type substitution finalization for call-scoped vars:
- call-scoped vars may materialize/use residuals during finishing
- during return substitution finalization, residuals are transformed/eliminated
  per callable rules
- exception: internal class `TParams` flow may carry deferred form until class
  field substitution boundary

3. Class field substitution finalization for `TParams`:
- deferred residuals that survive in class targs are finalized/eliminated at
  class-field substitution time

No other boundary should perform ad hoc residual leak scrubbing.

## Normative rules added in v1

### Call context and polarity
- `CallContext` for residual-enabled call solving must include:
  - call-scoped var set
  - polarity state for current recursive subset frame (pattern side vs value side)
- residual creation triggers must consult polarity; implementations must not rely
  on a fixed `(got, want)` side assumption.

### Residual marker scope
- residual markers (`Bounds.residuals`) may be written only for vars in the
  current residual-eligible scope:
  - call-scoped vars for the active call solve
  - deferred vars created by value-side `Forall` instantiation in that same call
- vars outside this scope may participate in ordinary bounds solving, but are
  not residual candidates.
- write-time eligibility is mandatory in v1: residual marker writes must enforce
  active-scope membership at write time (not just at materialization time).
- residual metadata used for materialization must preserve enough origin/scope
  information to re-check in-scope eligibility before materialization.

### Residual marker timing
- marker writes must be success-scoped:
  - either record only after the relevant subset comparison succeeds, or
  - record under snapshot/rollback so failed comparisons do not commit markers.
- v1 does not require one specific mechanism, but forbids unconditional
  marker-commit-before-success without rollback.

### Generic residual materialization gate
- generic residual materialization remains narrow:
  - var is unresolved after normal bounds solving
  - residual candidate set is exactly one generic candidate
  - target quantified kind is eligible for generic residual materialization
    (currently TypeVar in prototype behavior)
- otherwise follow normal quantified defaulting/fallback behavior.

### Overload residual capture and materialization rules
- overload capture must be polarity-aware and symmetric with respect to subset
  entry direction; implementations must not rely on only one structural path.
- both directional capture paths must use the same success-scoped persistence
  rule (including replay/error gating), so one direction cannot commit residuals
  under weaker validity criteria.
- explicit ban: when residual context is active, `got=Overload, want=Callable`
  paths must not use existential early-commit semantics ("first live branch
  succeeds, commit and return"). They must follow the same capture/replay
  symmetry as the mirrored direction.
- branch candidate payload must preserve enough data to materialize per-var
  results at callable finalization (a lossy branch-only payload is
  insufficient).
- ambiguous overload candidates must not be collapsed/dropped at
  `finish_quantified`; keep grouped candidates and defer resolution to
  substitution finalization.
- overload materialization is callable-level, branch-coherent expansion. Do not
  finalize residuals slot-by-slot in isolation.
- during branch analysis, branches that fail the branch-local subset
  constraints are removed from the candidate set.
- branch pruning from sibling constraints must be conservative: prune only when
  concrete solved constraints prove incompatibility; do not over-prune
  unresolved/compatible branches.
- branch compatibility/pruning checks must use type compatibility
  (`is_subset_eq`/consistency-style checks as appropriate), not structural
  Rust-level equality on `Type`.
- if branch analysis or pruning yields zero viable branches for the witness,
  emit the delayed incompatibility diagnostic and resolve remaining related
  residual vars to quantified-default fallback.
- v1 delayed-diagnostic policy for the zero-viable-branch case:
  - anchor the diagnostic at the full argument expression range for the
    callable value being matched,
  - emit at most one delayed incompatibility diagnostic per
    `(call_site_id, witness_id)` pair (residual-var-local failures must dedupe
    to that single witness-level diagnostic),
  - `witness_id` must be deterministic within a call solve (for example via
    deterministic capture insertion order),
  - keep message ordering deterministic via existing deterministic witness/branch
    ordering.
- richer diagnostic wording that compares reconstructed argument-callable type vs
  substituted parameter-callable type is deferred follow-up work and not required
  for v1.
- callable-level overload expansion must preserve callable slot context while
  recursively finalizing projected values; implementations must not force
  `NonCallable` flattening on intermediate projected values that are still in a
  callable-legal path.

### Overload v1 limitation (deferred)
- argument-selected ParamSpec overload narrowing remains out of v1 baseline
  scope and is tracked as follow-up work.

### Recursive residual finalization requirement
- residual handling must be recursive over type structure, not top-level only.
- when residuals appear under wrappers (for example `Awaitable[Residual]`,
  `tuple[Residual, ...]`, `Union[..., Residual]`), finalization must continue
  into nested positions and preserve callable-legal transforms where applicable.
- implementations must not degrade nested residuals to fallback merely because
  they are not at the root node.
- concrete regression to guard: ParamSpec wrap of generic return must preserve
  `Awaitable[T]` shape through residual finalization rather than producing
  `Awaitable[Unknown]`.

### Deterministic quantified merge policy
- v1 aligns doc policy with semantic deterministic comparison used in code
  (semantic type/restriction comparison with deterministic tie behavior).
- provenance-priority wording from v0 should be treated as superseded unless
  explicitly reintroduced in code.

### Subset cache side-effect safety
- if a subset path may produce residual side effects, cache behavior must not
  suppress those writes.
- v1 policy: bypass `subset_cache` for residual-side-effectful comparisons.
- for v1, "residual-side-effectful" means a subset comparison frame where
  residual capture/write hooks are enabled (generic or overload), i.e. the
  frame can mutate residual marker state.
- keep existing cache behavior unchanged for non-side-effectful comparisons.
- this is intentionally narrow and correctness-first; cache partitioning or a
  tighter side-effect predicate can be follow-up optimization work once v1
  semantics are stable.

### Phase ordering note
- v1 cares about boundary invariants, not one fixed internal ordering of
  finish/finalize/sanitize steps.
- any implementation order is acceptable if it preserves:
  - residual visibility gating at expansion
  - boundary elimination guarantees
  - deterministic diagnostics and final answers

## Invariant framing (v1)
- residual production eligibility remains scoped to call-scoped vars plus
  deferred vars introduced by value-side forall instantiation for that call
- residual observability is additionally constrained by
  `ResidualAnswer.target_vars`
- accidental union-find aliasing may still happen, but non-target aliases must
  flatten on read
- hard merge invariant: residual payloads from different
  `(call_site_id, witness_id)` identities must never silently coalesce into one
  observable residual answer. If a merge encounters incompatible residual
  identities, implementation must not preserve mixed visibility; treat as an
  invariant break (debug assertion) and flatten to non-residual fallback for
  release safety.

This shifts correctness from "discover and scrub leaks later" to
"never expose a leak outside allowed read paths."

## Migration notes
- distinguish two fallback channels explicitly:
  - visibility fallback (non-target var reading a residual answer) uses
    `fallback_for_residuals(...)` policy.
  - zero-viable-overload-witness fallback uses quantified-defaulting for
    participating vars after delayed incompatibility is recorded.
- current prototype behavior may still commonly produce `Any` via
  `fallback_for_residuals(...)`; that does not change the separate
  quantified-default rule for the zero-branch overload case.
- existing `sanitize_call_end_residuals(...)` can remain temporarily as debug
  instrumentation/backstop while migrating, but must remain non-semantic in v1
- once expansion-gating is stable and test coverage is in place, remove or
  strictly narrow sanitize logic
- if temporary sanitize remains during migration, it must not be relied on for
  correctness of non-debug builds

## Open questions for next pass
1. Which existing prototype tests should be rewritten to assert boundary-based
flattening semantics directly?

Resolved v1 decision:
- out-of-scope residual materialization must be treated as invariant violation.
- debug builds: hard assert.
- release builds: emit internal diagnostic and flatten to non-residual fallback.
