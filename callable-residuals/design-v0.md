# Callable Residual Design (v0, draft)

## Goal
Allow delayed resolution of call-scoped type-variable identities when those
variables come from callable pattern components in parameter position.

The core problem is correlation:
- A callable value can impose correlated constraints across multiple pattern
  vars.
- The motivating shape is `Callable[P, T]`, where `P` and `T` may be coupled by
  the argument callable via either overload structure or value-side generic
  (`Forall`) structure.
- Similar correlations appear in non-`ParamSpec` callable patterns too (for
  example repeated type vars across params/return).

If we resolve too early, we commit to an overspecialized or incoherent answer.

## Glossary (v0 working terms)
- **Call-scoped var**: fresh quantified var created for one call solve and owned
  by that call's `QuantifiedHandle`.
- **Potential residual**: solver metadata in `Bounds.residuals` indicating a var
  may require deferred callable interpretation.
- **Materialized residual**: `Type::CallableResidual(...)` produced during
  finishing for unresolved call-scoped vars that satisfy residual materialization
  criteria.
- **Bounds-solving pass**: finish-phase sub-pass that commits concrete/equivalent
  answers from non-residual bounds.
- **Residual-solving pass**: finish-phase sub-pass that handles overload/generic
  residual candidates after bounds-solving stabilizes.
- **Quantified defaulting**: the existing unresolved-var defaulting policy used
  by quantified finishing when no concrete answer is available (respect type-var
  default/constraint when present; otherwise gradual fallback by var kind).
- **Overload projection**: shared `OverloadProjections<TProj>` branch map object
  captured from overload analysis and consumed during residual-solving/finalize
  behavior.
- **Projection identity**: the identity of one shared overload projection object;
  pruning/concretization operates at this unit.
- **Finalize phase**: post-finishing substitution finalization over already
  substituted return/member types, where residual elimination/transform happens.
- **Sanitize phase**: call-end leak scrub over the call mutation frontier for
  out-of-scope vars.
- **Call mutation frontier**: vars reachable from callee/args (after UF
  canonicalization), plus call-scoped vars and optional touched-vars widening
  used for snapshot/sanitization safety.

## Core idea: two residual layers
Introduce two related internal notions:

1. **Potential residual (solver metadata)** in per-var bounds state:

```text
Bounds.residuals: Vec<ResidualKind>
```

This marks that the var may need deferred callable interpretation.

2. **Materialized residual (type-level artifact)**:

```text
Type::CallableResidual(...)
```

`CallableResidual` is a nonfinalized solve result representing unresolved
call-scoped callable-variable identity that must be interpreted later.

High-level intent:
- keep enough correlation information to transform callable outputs correctly
- avoid forcing immediate concrete answers in solver recursion
- defer interpretation until substitution finalization points

## Creation point
Potential residual metadata (`Bounds.residuals`) is created during callable
pattern/value analysis (subset comparison) when matching overload or `Forall`
value structure against a callable pattern.

`Type::CallableResidual` comes into existence only at the existing
call-quantified finalization pipeline (`finish_quantified`): when finishing
quantified vars scoped to a call, including recursive finishing of overload
branch-local projection state after pruning.

This is the same point where current code can produce `PartialQuantified` when
unsolved.

Important sequencing:
- `finish_quantified` only decides/commits var answers and may materialize
  `Type::CallableResidual` (including recursive branch-local materialization)
- `finish_quantified` does not perform callable structural transforms
- callable transform vs fallback requires downstream substitution finalization,
  where the enclosing return/class-field type is available

Callable-shape normalization contract:
- residual creation/evaluation must run on a canonical callable view that has
  already applied existing callable extraction/normalization rules (including
  value-side `__call__` unwrapping for callback-protocol/class values and
  bound-method normalization)
- this prevents path-dependent mismatches where callable residual logic sees a
  non-callable raw shape in one path but callable-normalized shape in another
- bound-method policy in this design:
  - preserve existing bound-call semantics (`self_obj` handling and first-param
    binding/stripping behavior)
  - residual creation and finalization must operate on the bound-normalized
    callable signature, not raw unbound-method inner function shape
  - fallback/defaulting/finalization must not reintroduce an explicit bound
    receiver parameter artifact

Planned direction:
- for specific unsolved call-scoped vars where callable correlation must be
  preserved, and where no non-residual bounds produce a concrete answer,
  materialize `CallableResidual` instead of `PartialQuantified`
- preserve current behavior for unsolved vars that do not require callable
  correlation machinery

Selection rule (v0):
- after bounds-solving and residual-candidate normalization, a call-scoped var
  materializes `Type::CallableResidual` iff:
  - non-residual bounds do not yield a concrete/equivalent answer, and
  - exactly one distinct residual candidate remains for that var
- if non-residual bounds do yield a concrete/equivalent answer, commit that
  answer (no residual materialization)
- if multiple distinct residual candidates remain, do not materialize residual;
  use `fallback_for_residuals(...)`

## Boundary invariant
`Type::CallableResidual` must be eliminated by substitution finalization,
except that it may remain internally in class `TArgs` (parameterized class type
arguments) until the same finalization policy is applied at lookup/export
boundaries.

Finalization boundaries:
1. call return type construction
2. class member lookup result
3. serialization/export
4. binding boundary (`Binding`-level types consumed by production code)

Enforcement contract:
- at (1) and (2): no `Type::CallableResidual` may exist in the produced type
  except in class `TArgs`; finalization must run as the last substitution step
- at (3): no `Type::CallableResidual` may exist anywhere, including inside
  `TArgs`; apply fallback flattening before serialization/export
- at (4): same as (1)/(2) for production behavior (no residual outside `TArgs`)
- violation handling at (4):
  - debug mode: panic/assert (hard invariant failure)
  - production mode: emit internal type error and flatten residual to fallback
    before returning/consuming the `Binding` type

Rationale note:
- in principle, panicking in production on invariant breach would be cleaner
- in practice, solver mutation behavior is difficult to reason about globally
  (including risks from uncontrolled cross-scope/cross-thread mutation paths)
- v0 therefore prioritizes user experience and robustness: production must not
  crash Pyrefly on this class of invariant uncertainty; emit internal type error
  + fallback flattening instead

Invariant uncertainty note:
- expected behavior is that residuals do not leak through fresh call-scoped vars
- however, union-find flattening might still route some unrelated var to a var
  finalized as `CallableResidual`, which could create an unexpected leak path
- if this leak is observed in practice, preferred mitigation is to harden
  `expand` so residuals are always flattened to boundary fallback types there,
  preventing user-visible propagation regardless of union-find shape

Leak-likelihood note:
- leaks are expected to be realistically possible in some higher-order shapes,
  not purely theoretical
- example risk shape:
  `def higher_order(f: Callable[[T], T], x: T) -> ...`
  with `f` receiving a generic/overload argument that drives residual creation
  while `x` is represented by a pinning-style var state (for example
  partial/unwrap-linked mutation path)
- this is why an explicit sanitization boundary is required, rather than relying
  only on "should never happen" assumptions

## Biggest unknown / risk
The single biggest unknown in this design is invariant reliability under solver
mutation. The solver mutates variable state aggressively enough that "obvious"
invariants can be hard to trust globally.

Most likely failure mode if core design logic is otherwise correct:
- internal invariant diagnostics indicating unexpected `CallableResidual` leak
  paths

Operational policy if this happens:
- loud failure signal, but avoid crashing production flows
- Plan A: investigate and tighten invariants directly (preferred)
- Plan B: enforce fallback flattening as a hard safety boundary, accepting
  reduced precision if solver-global invariants remain too difficult to
  guarantee

## Call-end leak sanitization boundary
At the end of a higher-order call solve, run a sanitization pass over the call
mutation frontier:
- collect vars reachable from callee + all arguments (after union-find
  canonicalization), plus vars touched during this call solve
- define allowed residual scope as vars in the call's fresh quantified handle
  (the vars intentionally finalized for substitution into return/member types)
- for any frontier var outside that allowed scope:
  - if its solved `Answer(Type)` contains `Type::CallableResidual`, flatten that
    answer immediately to fallback type
  - clear/flatten any `Bounds.residuals` entries on that var

Policy:
- this is an invariant-enforcement hygiene pass, not a precision feature
- record internal diagnostics/counters when sanitization rewrites leaked
  residuals
- do not crash production flows on this path
- sanitization targets out-of-scope frontier vars only; it does not recursively
  flatten residual payload internals that remain inside in-scope residuals

Reachability note:
- it is currently unclear whether some leak shapes are practically reachable
  after normal finalization paths (for example, union-find-linked `Unwrap` vars
  may already end up forced to concrete answers)
- v0 still applies sanitization defensively; if leaks are truly unreachable in a
  sub-path, this pass should be effectively a no-op there

Cost note:
- this is a hygiene backstop, not precision logic; conservative supersets of the
  true mutation frontier are acceptable
- implementations should prefer reusing already-available deterministic touched
  var bookkeeping where possible, and measure cost before adding heavier
  frontier recomputation
- expected baseline shape is `O(branches * frontier_vars)` snapshot/restore in
  overload probing; if frontier sizes are large in practice, prefer incremental
  or lazy frontier/snapshot strategies as follow-up optimization

Touched-vars source note:
- sanitize-phase processing may use a "vars touched during call solve" set to widen
  coverage beyond static reachability from callee/args
- in v0 this set should come from existing deterministic solver write-tracking
  where available; otherwise use only the statically computed frontier
  (call-scoped vars + callee/arg-reachable vars)
- this does not change overload probe snapshot policy: probe scope remains
  precomputed at branch entry with no in-probe dynamic growth

## Elimination behavior
Elimination of `CallableResidual` is structural and context-sensitive.

### Callable-legal elimination
If a residual appears in a callable-legal position (during callable return/member
substitution) and compatibility requirements hold, transform the enclosing
callable structure accordingly.

Target outcomes include:
- producing an `Overload(...)` shape
- producing a `Forall(...)` shape

Compatibility is evaluated by an abstract policy hook (so rules can evolve
without changing the outer algorithm).

v0 policy:
- generic residuals are always considered compatible for callable-legal
  expansion (origin identity does not gate well-formed output)
- overload residuals must be witness-coherent: all overload residuals used in
  one transform must come from the same overload witness/projections identity
- overload witness coherence is evaluated per callable layer during recursive
  finalization; nested callable layers perform independent coherence checks on
  their own residual occurrences
- mixed generic + overload residuals are allowed; only overload witness
  coherence is required
- if overload witness coherence fails, do not perform overload expansion and
  fallback instead

Potential follow-up (not v0): if multiple overload witnesses appear and exactly
one is ParamSpec-bearing, prefer that witness and discard incompatible overload
residuals from other witnesses.

ParamSpec callable-shape fallback (v0 explicit rule):
- when callable-shape fallback is required for a ParamSpec-bearing projection
  context (for example recovering `P.args`/`P.kwargs`-driven callable shape from
  an ambiguous overload witness), select the first declared overload branch
- this is intentionally aligned with current trunk behavior for overload-based
  ParamSpec fallback and is a temporary policy choice for v0
- this rule is scoped to callable-shape fallback for ParamSpec contexts only
  and does not change per-var residual-candidate arbitration
  (`fallback_for_residuals(...)`)
- trigger/precedence rule:
  1. first classify the occurrence as callable-legal vs required-concrete
  2. only callable-legal occurrences may enter ParamSpec callable-shape fallback
  3. required-concrete occurrences always use required-concrete elimination
     (fallback/default), not first-branch ParamSpec callable-shape fallback

Recursive substitution-finalization rule:
- callable substitution finalization is recursive, for the same compositional
  reason as quantified finishing
- after one callable-legal expansion step (for example expanding an overload
  residual), the resulting callable may still contain residuals (for example from
  generic residuals inside branch results)
- finalization must therefore re-run elimination/transform logic until no more
  callable-legal residual expansions apply, then apply boundary fallback policy
  for any remaining non-callable-required-concrete positions
- this is a deterministic fixpoint process over the output type tree; one
  expansion can expose further nested residual opportunities (including nested
  overload or generic structures) that must be recursively processed before
  boundary output
- elimination/fallback is occurrence-sensitive in the substituted output tree:
  one occurrence of a residual-bearing var may expand in callable-legal
  position while another occurrence of the same var falls back in
  required-concrete position

Termination note:
- finalization does not create new potential-residual metadata; it only consumes
  residual artifacts already materialized by finishing
- each callable-legal expansion step eliminates at least one currently visited
  residual occurrence in the output type tree
- with finite input type trees and finite residual payloads, this yields
  termination; v0 still permits defensive depth/iteration guards

### Required-concrete elimination
If a residual appears in a non-callable-required-concrete position, eliminate to
fallback according to boundary policy (v0 compatibility rules remain allowed).

Degeneracy diagnostic rule:
- if callable transform/finalization removes all parameter evidence for a
  residual-relevant type variable (transform-induced non-inferable shape), emit
  a dedicated delayed degeneracy diagnostic at witness origin
- fallback/default result remains required for continuation, but degeneracy must
  not be silent

Boundary-specific note:
- export/serialization always uses fallback flattening for any remaining
  residuals, including those inside class `TArgs`
- user-facing display/reveal of a whole instance type is treated as a
  required-concrete boundary for display purposes; member lookup uses the
  callable/member finalization path and is allowed to apply callable-legal
  expansion first

Export-hook contract (v0 required):
- every export/serialization path must call a single shared
  `finalize_for_export(type, context)` hook immediately before encoding/emitting
  the type to external consumers
- `finalize_for_export` runs after call finish/finalize/sanitize, and is the
  last internal normalization step before export
- `finalize_for_export` must:
  1. eliminate both deferred forms (`Type::Projected` and
     `Type::CallableResidual`) to local fixed point
  2. enforce stricter export policy (no deferred forms anywhere, including class
     `TArgs`)
  3. emit internal diagnostic if defensive iteration/depth guard is hit, then
     flatten remaining deferred forms via fallback before returning
- no serializer/exporter may bypass this hook

## Shared abstraction, separate internals
This design intentionally separates:
- shared outer mechanism: `Type::CallableResidual` + boundary invariants +
  finalization contract
- payload-specific internals: overload-oriented and generic-oriented residual
  semantics

The document does not lock down internal payload details yet.

## Relationship to existing `Type::Projected`
v0 assumes `Type::Projected` and `Type::CallableResidual` may coexist during
migration.

Current intent:
- `CallableResidual` is the new mechanism for delayed callable-correlation
  handling in this design
- existing `Projected` flows may remain in place initially where already wired
- elimination/finalization code should keep behavior coherent when both appear
  in one type tree (do not assume only one mechanism exists)

Follow-up direction (not required for v0):
- evaluate whether `Projected` paths should migrate onto
  `CallableResidual`-based machinery and eventually unify

Finalization ordering contract during coexistence:
- at boundary finalization points, both deferred forms must be eliminated by the
  end of the pipeline (`Projected` collapse and `CallableResidual`
  elimination/flattening)
- implementation may choose exact internal ordering, but it must be fixed and
  deterministic, and must preserve boundary invariants (no residual leakage per
  boundary policy)
- if one elimination can introduce new opportunities for the other, rerun the
  pair to a deterministic local fixed point before emitting the boundary result
- include a defensive iteration/depth guard for this local fixed-point loop; if
  the guard is hit, emit an internal diagnostic rather than silently returning
  unresolved deferred forms

## Why this framing
It captures what both problem families share:
- delayed interpretation of call-scoped callable-variable identity
- same boundary invariants
- same substitution-finalization choke points

And it avoids overcommitting where behavior diverges:
- overload internals are disjunctive/correlation-heavy
- generic internals are likely promotion/re-quantification-heavy

## Open design/implementation tracks (intentionally unresolved)
1. Solver state model:
   - `CallContext` threading through subset recursion
   - exact polarity flip points per recursive subtype path
2. Overload internals:
   - exact branch-frontier construction/maintenance strategy for snapshot scope
   - residual-solving pruning/concretization performance characteristics
   - simplification and deterministic diagnostics ordering
3. Generic internals:
   - re-promotion mechanics for unresolved instantiation vars
4. Finalization evaluator:
   - one shared dispatcher with payload-specific elimination implementations

## Pre-work refactor: deterministic quantified-merge metadata policy
Before callable-residual implementation, apply a solver refactor that makes
quantified-var metadata retention deterministic under union-find merging.

Scope:
- this is solver hygiene and determinism hardening, independent of residual
  semantics
- apply to all quantified-quantified merges (not only residual-related call
  paths)

Policy:
- retain current compatibility checks for restricted quantified merges
  (including incompatible-bound rejection behavior)
- merge solver bounds (`Bounds.lower`/`Bounds.upper`) as today
- for quantified metadata payload selection, use deterministic winner policy:
  1. provenance priority: `ForallInstantiation` > `CallScoped` > `Other`
  2. if provenance ties, choose lexicographically smaller quantified name
  3. winner contributes full metadata payload (default/restriction/etc.);
     loser metadata is not field-wise merged in v0

Rationale:
- avoids orientation-sensitive metadata drift from destructive union-find merges
- gives stable default/restriction behavior and stable printed naming
- strongly favors decorator-relevant value-side `Forall` metadata when merged
  with call-scoped quantified vars

Implementation note:
- represent provenance via quantified metadata tagging (no requirement to add a
  new top-level `Variable` enum variant)
- treat this as a pre-work refactor and land before residual feature changes

## CallContext minimum (v0)
`CallContext` is required when solving call argument-vs-parameter comparisons.

Minimum required fields:
- call-scoped var set: all fresh vars scoped to the current call solve
- polarity/direction metadata indicating which side of the current
  `is_subset_eq(got, want)` comparison is the pattern side vs value side

Why this is required:
- residual creation is pattern/value-orientation sensitive
- recursion can invert variance, so the pattern side is not always `want`

Recursion rule:
- polarity is tracked as swap-parity of recursive subset calls:
  - flip when a recursive check swaps argument order
    (`is_subset_eq(want, got)` relative to current frame)
  - preserve when recursive check keeps order
    (`is_subset_eq(got, want)`)
- concrete v0 cases:
  - callable parameter checks are contravariant and use swapped order -> flip
  - contravariant class type arguments use swapped order -> flip
  - covariant class type arguments keep order -> preserve
- invariant checks (`is_consistent`) are a special case: residual recording is
  disabled for that recursion, and behavior falls back to trunk subset logic
  with no residual side effects
- implementation requirement: codify the exact variance-transition flip table
  used by subset recursion and treat it as part of residual correctness

Implementation note:
- any residual creation trigger must consult `CallContext` polarity rather than
  assuming fixed `got`/`want` roles
- subset-cache safety: subset-result cache usage must not suppress required
  residual side effects in call-context solves
  - acceptable v0 strategies include cache partitioning by call-context mode,
    bypassing cache for residual-producing comparisons, or equivalent guarantees
    that side-effectful paths are not skipped by cache hits
- invariant-recursion safety: when in invariant checks, call-context residual
  writes are disabled (trunk behavior); cache behavior may follow normal subset
  rules there because no residual side effects are expected

## CallContext witness stack (optional)
`CallContext` may carry a witness stack to track currently active
residual-producing solve frames.

Working shape:
- `witness_stack: Vec<WitnessFrame>`
- `WitnessFrame` is one of:
  - overload frame (current overload witness/projections identity)
  - generic frame (current value-side `Forall` instantiation frame)

Push/pop rules:
- push overload frame when entering overload-branch analysis in pattern/value
  orientation
- push generic frame when entering value-side `Forall` instantiation analysis
- pop on exit from that analysis scope (stack discipline, no leakage)

Status note:
- this stack is not strictly required if all needed context is naturally
  available via the Rust call stack and local recursion state
- keep as an implementation convenience: useful for tracing/debug diagnostics,
  and available if recursive logic later needs explicit shared witness metadata

Nesting:
- witness frames may nest arbitrarily (for example, higher-order overload inside
  overload branch solving, or generic inside overload and vice versa)
- implementation must not assume a fixed maximum nesting depth
- residual creation and capture should use the top-of-stack frame(s) relevant to
  the current rule

Composition note:
- recursive finishing/finalization is expected to make nested residual payloads
  composable
- generic residuals captured within overload branch-local `Variable` state must
  remain representable and finalizable after pruning

## Overload residuals (working spec draft)
This section is a stronger draft than the generic track and is intended as the
first concrete implementation target.

### Creation trigger (overload path)
When `CallContext` is active and subset comparison is in pattern/value
orientation such that:
- pattern side contains callable pattern vars, and
- value side is `Overload(...)`,
construct overload **potential residual** state for that one match context.

Mechanism (explicit):
- run a visitor over the callable pattern and collect participating pattern vars
  for this overload match context
- for each relevant overload branch solve, snapshot solver state for the call
  mutation frontier (not only participating pattern vars):
  - call-scoped quantified vars for this call
  - vars reachable from callee + argument inputs (after union-find
    canonicalization)
  - this frontier is precomputed at branch-entry time and held fixed for that
    branch probe (no dynamic in-probe frontier growth in v0)
- run branch-local solving and record solved pattern-var states into
  `OverloadProjections`
- rollback snapped vars before trying the next branch

Probe-time branch admissibility rule:
- overload branch probing is a *filtering* stage, not a user-diagnostic stage
- if branch-local subset solving for one overload arm is unsatisfiable (the arm
  would produce a type error under normal non-probe solving), treat that arm as
  ineligible for this witness:
  - do not record a `BranchSolution` for that arm in `OverloadProjections`
  - do not emit immediate user-visible diagnostics from the probe itself
- rationale: probe-only unsatisfiable arms are expected in overload matching;
  they are branch elimination signal, not independent call errors
- delayed diagnostics remain tied to finishing-time projection inconsistency
  (`active_branches` becomes empty after concrete-constraint pruning)

Probe-empty witness rule:
- if all overload arms are ineligible at probe time (no admissible
  `BranchSolution` captured), treat this as an immediately inconsistent overload
  witness for this match context
- do not materialize overload residuals from this witness
- queue one delayed incompatibility diagnostic at witness origin (same diagnostic
  family/order policy as empty-after-pruning)
- force participating unresolved pattern vars through quantified defaulting at
  finish (type-var default/constraint when present; otherwise gradual fallback by
  var kind), rather than leaving them to `PartialQuantified`
- this path is semantically equivalent to an `active_branches = empty`
  projection discovered later in residual-solving; it just arises earlier

Capture contract:
- branch capture must be rollback-stable: `BranchSolution<Variable>` must not
  alias mutable global solver-arena entries that will later be
  restored/mutated
- recorded projection state is by-value snapshot data for that branch result
  (including `Variable`/`Bounds` fields needed for later branch finishing)
- if later branch finishing requires transitive var state not present in the
  captured projection values, that transitive closure must also be captured into
  branch-local owned data rather than read back from mutable global arena

Residual recording point (overload):
- overload residual metadata is recorded once per overload match context at
  overload-analysis completion, after all branch probes have been aggregated
  into the `OverloadProjections<Variable>` object
- concretely, at the final probe/restore boundary ("snapshot flip"), attach
  `ResidualKind::Overload { projections, target }` to each participating
  call-scoped pattern var
- this avoids per-probe duplicate wiring and ensures the residual points at the
  final shared aggregated projections object

Trunk-overload analogy:
- current overload call selection probes each overload under snapshot/restore and
  discards probe-side mutations
- once one overload is selected, trunk re-runs the selected overload in normal
  mode to commit real pinning/effects
- this supports the same policy here: probe mutations are disposable; only
  explicitly captured projection artifacts should survive branch probing

Degenerate rule:
- if the pattern visitor finds no participating vars, do not create overload
  residual machinery for this match context; behavior must remain equivalent to
  trunk for this path

### OverloadProjections shape
Create one shared object:

```text
OverloadProjections<TProj> {
  branches: Vec<BranchSolution<TProj>>,
  active_branches: BitSet, // mutable reduction state
}

BranchSolution<TProj> = Map<PatternVar, TProj>
```

Phase instantiations:
- solve-time/pruning input: `OverloadProjections<Variable>`
- post-finish residual payload: `OverloadProjections<Type>`

`Variable` is intentionally solver-level (not limited to concrete `Type`): it
can carry an `Answer(Type)`, bounds, and nonfinalized artifacts.

`PatternVar` scope is explicit: only vars from the callable pattern being solved
for this call context are recorded. Value-side internal vars are not stored as
top-level keys; they may only appear transitively inside recorded `Variable`
state.

When materialized at finishing-time, `CallableResidual::Overload` stores:
- reference to one `OverloadProjections<Type>`
- one `PatternVar` target identity

Multiple materialized residual vars from one match must share the same
`OverloadProjections` reference.

### Storage and solver interaction
Working direction:
- extend per-var `Bounds` to track both:
  - existing concrete-solving information (`bounds` as primary path)
  - zero or more residual candidates (`residuals`) for deferred callable state
- residual candidates shape (draft):

```text
residuals: Vec<ResidualKind>

ResidualKind =
  | Overload { projections: Arc<OverloadProjections<Variable>>, target: PatternVar }
  | Generic // unary marker
```

Candidate normalization rule:
- `residuals` may accumulate duplicate entries during solving, but finalization
  decisions must operate on a deduplicated ordered view of **distinct**
  candidates
- dedup ordering rule: preserve first-seen order from deterministic traversal
  (stable keep-first semantics)
- `Generic` is unary: treat repeated `Generic` entries as one candidate
- `Overload` candidates are distinct by `(projections identity, target)`; exact
  duplicates of that pair are one candidate

- this is the single location where "potential residual-ability" is tracked for
  both
  overload and generic paths
- solve from `bounds` first
- consult `residuals` only when `bounds` cannot produce a concrete result

`CallContext` requirement:
- `CallContext` must track every fresh var scoped to the current call solve.
- overload snapshot scope must be the call mutation frontier for the active
  overload match context (call-scoped vars + argument/callee-reachable vars),
  not only pattern-participating vars
- participating pattern vars remain the projection-recording scope; snapshot
  scope is intentionally broader for rollback safety
- `CallContext` polarity must be maintained through recursion so overload
  creation only triggers when callable pattern vars are actually on pattern side
- if `CallContext` witness stack is enabled, maintain strict push/pop discipline
  so residual creation/capture uses the correct active frame identity

Canonical callable normalization requirement:
- before residual creation/recording, normalize callable-like values through one
  shared entry point:
  - extract `__call__` shape for callback-protocol/class-callable values
  - apply bound-method binding (`self`/`cls` handling) so stored witness
    signatures are post-bind forms
- residual recording/finalization must operate on this normalized callable view,
  not on ad-hoc per-site callable extraction

Snapshot-scope rationale:
- union-find mutations are root-based and transitive; branch probing can mutate
  non-participating vars through merges/rewrites
- bounds merge paths for quantified/unwrap-like vars can write into
  argument-linked var state during branch probing
- therefore, snapshotting only participating pattern vars is unsafe; rollback
  must cover the broader call mutation frontier

Discard-policy rationale:
- for branch probing in this design, restore-and-discard is preferred over
  trying to merge probe-side solver mutations back into global state
- if this loses a potentially pin-able result (for example every overload branch
  implied the same pin), worst-case outcome is reduced precision (extra
  `Unknown`) rather than unsound leakage
- this precision tradeoff is acceptable in v0 and aligns with existing fallback
  behavior in complex or ambiguous Python typing cases

Implementability note:
- snapshot scope must be computable before each probe begins
- v0 rule: use a precomputed frontier at branch entry; do not rely on
  "vars touched during this probe" because that is causally unavailable at
  snapshot time
- optional future enhancement: mutation-log-based widening that records first
  writes to out-of-frontier vars and snapshots/restores them explicitly

Residual metadata write-path requirement:
- residual population is context-sensitive and is driven from recursive
  pattern/value analysis where polarity + witness context are known
- v0 chooses explicit in-analysis writes, not a pure pre-seeding-only model
- overload recording uses the overload-completion point above; generic recording
  uses the generic population points in the generic section below
- no-participation rule: if an active callable comparison frame has zero
  participating pattern vars, do not record residual metadata/projections for
  that frame (behavior falls back to trunk solving for that frame)

### Branch filtering from concrete constraints
At `finish_quantified`, overload residual branches must be filtered against
solved concrete answers from the bounds-solving pass.

Evaluation mode:
- filtering is intentionally stateful/mutating on branch-local projection state
  (not a pure predicate over immutable snapshots)
- each solved var contributes a pinning constraint (`lower=upper=T_final`) that
  is accumulated into branch-local state
- branch survivability is evaluated under the cumulative constraint set from all
  bounds-solving solved vars
- deterministic iteration order for solved vars and active branches is required;
  this pass must not depend on nondeterministic container traversal
- implementation-order note: any deterministic processing order is acceptable;
  v0 does not require one canonical var/branch ordering policy
- side-effect boundary: this pass may mutate branch-local projection state, but
  must not commit unrelated global solver mutations for the enclosing call solve

Compatibility rule for one solved var `v` with finalized type `T_final`:
- if branch state for `v` is `Answer(T_branch)`, branch is compatible iff
  `T_final` and `T_branch` are mutually compatible under subtype checking
  (`is_subset_eq(T_final, T_branch)` and `is_subset_eq(T_branch, T_final)`)
- otherwise (branch state for `v` has no `Answer`), branch is compatible iff
  `T_final` is compatible with the branch-local bounds recorded in that
  `Variable` state (checked by adding `T_final` as both lower and upper bound
  and requiring the branch state remain satisfiable under normal bounds solving)

Strictness note:
- the `Answer` path intentionally uses equivalence-style compatibility
  (mutual-subset), not one-way subtyping
- rationale: branch projections are still `Variable`-level at this stage, not
  pre-finalized `Type` snapshots
- therefore, if branch state is already `Answer(T_branch)`, that answer reflects
  branch-local collapse that already happened during overload analysis; the
  finalized call answer must match it (equivalence), not merely overlap by
  one-way subtyping
- if branch state is not `Answer`, compatibility is intentionally checked via
  branch-local bounds satisfiability (pin both bounds to `T_final`) rather than
  weakening the `Answer` rule
- this pass selects coherent branch projections for one concrete finalized call
  answer, rather than building widened approximation unions
- relaxing this rule to variance-aware one-way checks is a possible follow-up if
  v0 proves too strict in practice

Branch removal is global to shared `OverloadProjections`, so solving one var can
prune branches for other vars in the same match context.

If pruning eliminates all active branches, emit delayed type error at witness
origin range.

Continuation rule on empty-branch projection:
- do not abort `finish_quantified` batch processing for other vars
- mark that projection identity as inconsistent for this call solve
- any unresolved var whose single residual candidate references that
  inconsistent projection must not materialize overload residual; finalize via
  normal quantified defaulting policy instead (type-var default/constraint, or
  gradual fallback such as `Any` / `...` / `tuple[Any, ...]` by var kind)

Probe-empty alignment note:
- the same continuation/defaulting rule applies when inconsistency is known
  earlier from probe-time empty witness capture (all arms ineligible)

Delayed-diagnostic ordering rule:
- queue delayed incompatibility diagnostics in deterministic witness order:
  `(witness_origin_range_start, witness_origin_range_end, projection_identity_creation_order)`
- for multiple diagnostics within one projection identity, emit in deterministic
  var order `(quantified_handle_order, var_creation_order)`
- implementations may batch diagnostics, but emitted user-visible order must be
  equivalent to this stable key ordering

This delayed validation is overload-specific: overload branch solves use
snapshot/rollback, so branch-local constraints are not retained as normal global
bounds and must be rechecked at `finish_quantified`.

Finishing-interaction note:
- this introduces subset compatibility checks into `finish_quantified`
  residual-solving
- this is an intentional escalation versus bounds-only finishing; implementations
  should treat these checks as branch-sandbox checks (or equivalent restricted
  mode) rather than a path for committing new global call-solve mutations

### Branch concretization (overload path)
After pruning in `finish_quantified` residual-solving pass, branch projections
are recursively finished in **batch per branch**, converting
`OverloadProjections<Variable>` into `OverloadProjections<Type>`.

Execution-model note:
- branch projections are owned snapshot data, not live solver-arena vars
- this path therefore cannot literally call arena-indexed `finish_quantified`
  over original var handles
- v0 adapter choice: use temporary arena rehydration + extract (reuse normal
  finishing machinery), not a separate owned-data finisher
- this preserves normal quantified finishing behavior for solve/default/error
  semantics with lower drift risk
- append-only temporary vars created for branch finishing may remain in the
  arena after extraction; this is acceptable in v0 as long as no references to
  those temp vars escape into retained solver state/payloads
- follow-up optimization may reduce temp-var accumulation if needed, but is not
  required for correctness

Working shape:
- each active branch contributes a set of participating pattern vars
- finish that whole var set together (same batch semantics as normal
  `finish_quantified`, but scoped to one branch projection state)
- read resulting per-var `Type` answers from the finished branch state

Per-var result interpretation in that finished branch state:
- if solved to `Answer(t)`, use `t`
- if still unresolved but branch-local residual remains, use branch-local
  `Type::CallableResidual(...)`
- if unresolved with no residual, use existing defaulting behavior for that var
  (type var default, constraint-derived fallback, otherwise `Any`)

Defaulting must reuse existing quantified-finalization policy so branch
concretization does not diverge from normal solver behavior.

Composition requirement:
- branch concretization must run full residual-aware finalization logic on branch
  projection `Variable` state
- this is how a generic branch-local state can concretize to
  `Type::CallableResidual(Generic)` when still unsolved
- this recursion must support arbitrary nesting depth of overload/generic
  residual structures (no fixed-depth assumption)
- materialized overload residuals must reference the converted
  `OverloadProjections<Type>` payload, never the pre-finish
  `OverloadProjections<Variable>` payload

Transitive capture requirement:
- finishing inputs must include transitive var state reachable from captured
  projection `Variable` data, including `Var` references nested inside `Type`
  values stored in bounds/answers
- branch finishing must not read rolled-back global arena state through dangling
  references
- with the v0 rehydration adapter, satisfy this by deterministic rehydration of
  an equivalent closed world before finishing
- an alternate full-capture strategy is conceptually valid but not the chosen
  v0 adapter path

### Finishing-time materialization and simplification
At `finish_quantified` for call-scoped vars (batch over the full
`QuantifiedHandle`, not per-var immediate commit):
- `Bounds` remains primary: if non-residual bounds yield a concrete/equivalent
  answer, commit that answer and do not materialize `Type::CallableResidual`
- for overload residuals, pruning/validation against solved concrete answers
  happens here
- if exactly one overload branch remains active after pruning, commit that
  branch's per-var finished `Type` answers directly for unresolved vars (no
  overload residual materialization for that var; nested generic residuals may
  still appear inside those types where applicable)
  - commit path invariant: use normal solver pin/compatibility machinery (same
    satisfiability/error behavior as ordinary answer commits), not raw variable
    overwrite
- if multiple overload branches remain active, materialize
  `Type::CallableResidual::Overload` for unresolved vars
- if zero overload branches remain active for a projection (inconsistent
  overload witness), do not materialize overload residual for dependent vars;
  finalize those vars through normal quantified defaulting policy after
  recording the delayed type error
- generic residual behavior is unchanged: rely on normal bounds accumulation and
  materialize only when still unsolved at finishing

`finish_quantified` is intentionally not a transform phase: it does not inspect
enclosing callable return/member structure and does not expand residuals.

Residual-solving preparation (implementation shape):
- after bounds-solving stabilizes, build a normalized candidate view for
  residual-solving:
  - include only vars with no concrete/equivalent non-residual answer
  - normalize/dedup each var's `Bounds.residuals` view
  - if exactly one distinct residual candidate remains for that var, record
    `single_residual_by_var: Map<Var, ResidualKind>`
  - otherwise route through `fallback_for_residuals(...)` path (no residual
    materialization for that var)
- for overload residuals, also index distinct
  `OverloadProjections<Variable>` identities referenced by
  `single_residual_by_var`:
  - this projection identity is the pruning/concretization unit
  - vars are consumers/targets of a projection unit, not independent pruning
    units
  - track projection status (`active`, `inconsistent-empty`) so downstream
    var-finalization can route inconsistent projections directly to quantified
    defaulting

Bounds-solving completion rule:
- residual-solving must start only after bounds-solving reaches a stable point
  for the
  call-scoped quantified batch (no additional concrete/equivalent non-residual
  answers remain to commit under normal finish semantics)
- implementations may use eager commit internally during bounds-solving, but
  residual-solving pruning input is the post-bounds-solving stable solved-answer
  set
- this is a phase-boundary contract, not a prescriptive internal loop shape;
  implementations may choose different low-level scheduling as long as this
  boundary condition is preserved deterministically

### Multiple residual candidates for one var
If `finish_quantified` observes multiple **distinct** residual candidates for
one var (after candidate normalization) and no non-residual bounds resolve that
var:
- do **not** materialize `Type::CallableResidual`
- route candidates to a new fallback hook:
  `fallback_for_residuals(var, residual_candidates, context)`
- commit the fallback result as the var's finalized answer
- emit a delayed diagnostic if policy requires one

Notes:
- v0 behavior for `fallback_for_residuals` is to return `Any`
- precedence rule: concrete/equivalent non-residual bounds always win before
  residual-candidate arbitration; `fallback_for_residuals(...)` applies only
  when those bounds cannot produce an answer
- policy note: ParamSpec-specific first-overload fallback is a separate,
  explicitly scoped callable-shape fallback rule and does not override this
  per-var multi-candidate residual arbitration rule
- implementation note: add a `TODO` at this hook for future richer fallback
  policy (for example overload-aware union-like approximations)
- rationale for v0 `Any`: expected to be rare in practice (typically requires
  higher-order calls where multiple callable-valued inputs jointly constrain the
  same var, with residual-producing shapes such as overload/generic on more than
  one input)
- better fallback rules are intentionally left open (for example overload-aware
  fallback to union-like approximations where applicable)

## Generic residuals (working shape)
Generic residuals are marker-driven and do not use a branch witness or a
separate compatibility recheck pass.

Working shape:
- generic path uses the same per-var `Bounds.residuals` storage as overloads
- add `ResidualKind::Generic` to `Bounds.residuals` for vars that should be
  treated as generic residual candidates (not `PartialQuantified`) if still
  unsolved at finishing/finalization
- solved vars remain normal solved answers; generic marker becomes irrelevant
  once a concrete/equivalent solve is committed
- generic marker is a finishing-time mode switch only: if normal bounds solving
  still cannot produce a concrete/equivalent answer, use residual/fallback
  behavior instead of materializing `PartialQuantified`

Population rules (draft):
- when unwrapping value-side `Forall`, add all fresh instantiation vars to
  generic residual candidacy immediately (`Bounds.residuals.push(Generic)`)
- when `CallContext` is active and a call-scoped `Variable::Quantified` is seen
  during subset comparison while a **value-side-instantiated `Forall` frame** is
  live, add that var to generic residual candidacy as well (captures pattern vars like
  `S`, `T` that should promote rather than become partial)

Recording granularity note:
- generic recording is intentionally split across two concrete points:
  1. pattern-side call-scoped vars in the active match context
  2. fresh vars created when instantiating the value-side `Forall` body
- this dual marking is required for composition when generic structure appears
  inside overload branch analysis
- `Forall` frame definition (v0): the dynamic recursive extent that begins after
  value-side `Forall` instantiation creates fresh vars for the body, and ends
  when comparison of that instantiated body returns
- this does not include unrelated want-side `Forall` stripping paths that do not
  perform value-side instantiation

Operational note:
- this remains intentionally metadata-driven; no disjunctive generic witness
  object is required for v0/v1 if current variable/bounds state carries
  sufficient solve structure

Validation note:
- generic residuals generally do not require a separate delayed compatibility
  check against solved types
- rationale: generic path does not use branch snapshot/strip semantics for its
  core solve path, so constraints accumulate in normal bounds and are enforced
  by normal solving

Provenance note:
- `ResidualKind::Generic` is intentionally unary in v0; it is a mode marker, not
  full witness provenance
- downstream generic re-promotion/finalization is expected to rely on existing
  solved type structure plus call context
- if implementation evidence shows marker-only is insufficient, enriching
  generic residual metadata remains an explicit follow-up

Composition with overload:
- overload arm analysis may unwrap `Forall` inside each arm match
- the same generic population rules must run within arm-local analysis
- branch-local generic residual markers become part of arm-local solved state
  captured into `OverloadProjections`
- this ensures generic re-promotion behavior is preserved when `Forall` appears
  inside overload contexts
- operationally, this composes with overload snapshot/restore because the
  branch-local `Variable` snapshots captured into projections include those
  generic residual markers before branch rollback

## Unified residual algorithm (draft)
Shared skeleton (with overload-only branch pass):
1. solve match context using kind-specific solve mode:
   - overload path: isolate branch probes (snapshot/restore over call mutation
     frontier)
   - generic path: use normal solver flow (no extra branch-probe isolation)
2. solve constraints under that mode
3. record solved state only for pattern vars of that call context
4. during matching, populate per-var potential residual metadata in
   `Bounds.residuals`:
   - overload path: `Overload { projections, target }`
   - generic path: unary `Generic` marker
5. continue normal solving; bounds remain primary
6. at `finish_quantified` (batch):
   - bounds-solving pass: commit answers for vars with
     concrete/equivalent non-residual bounds
   - residual-solving pass (overload residuals only): for remaining vars,
     prune/validate overload residual branches against bounds-solving solved
     answers (emit delayed errors for inconsistencies)
   - residual-solving pass (overload residuals only): recursively finish each
     active branch as a batch over its participating vars after pruning; nested
     overload/generic residuals are handled by the same finishing rules
   - residual-solving pass (overload residuals only): convert pruned
     `OverloadProjections<Variable>` into `OverloadProjections<Type>`
   - residual-solving pass (overload residuals only): if one active overload
     branch remains,
     commit that branch's finished `Type` answers directly for unresolved vars
     (no overload residual materialization; nested generic residuals may still
     appear inside those finished types where applicable)
   - residual-solving pass (overload residuals only): if multiple active
     overload branches remain, materialize `Type::CallableResidual::Overload`
     for unresolved vars using the converted `OverloadProjections<Type>`
     payload
   - for generic residuals, materialize `Type::CallableResidual` only for
     still-unsolved vars whose `Bounds.residuals` is non-empty and whose
     non-residual bounds do not provide a concrete/equivalent answer
   - for generic residuals, do not run a separate compatibility check pass;
     normal bounds solving is authoritative
   - if multiple residual candidates exist for one var with no concrete answer,
     call `fallback_for_residuals(...)` and do not materialize residual type
7. downstream substitution finalization (return type and class-field
   substitution paths):
   - these types are already naively substituted through fresh vars at call
     setup; this phase finalizes/eliminates residual artifacts rather than
     performing a second substitution pass
   - for overload residuals, consume the branch maps (`Var -> Type`) produced by
     the `finish_quantified` residual-solving pass
   - inspect enclosing type structure and interpret materialized residuals
   - if callable-legal compatibility holds, perform callable structural
     transform (for example to `Overload` or `Forall`)
   - otherwise apply boundary fallback/diagnostic policy
8. run call-end leak sanitization over the call mutation frontier:
   - this is post-processing after finishing + substitution finalization, not
     interleaved with recursive finishing
   - allow residuals only on vars in this call's fresh quantified handle
   - for all other touched/reachable vars, flatten any leaked residuals to
     fallback type and record internal diagnostics

This is the intended common skeleton; witness payload semantics differ by kind.

`complete_call` phase summary:
- finish phase: finish call-scoped vars (`finish_quantified`, including recursive
  branch finishing for overload projections)
- finalize phase: finalize already-substituted return/member types (callable
  elimination/transform vs fallback)
- sanitize phase: sanitize out-of-scope vars in the call mutation frontier

Boundary distinction note:
- the `Binding` boundary is listed separately even though its residual policy
  mirrors return/member boundaries because it is an independent production
  consumption boundary and final invariant backstop

Complexity note:
- overload handling requires explicit branch probing/pruning machinery
- generic handling reuses preexisting solver behavior for core solving; main
  differences are finishing behavior and downstream substitution-time
  interpretation

## Remaining tactical decisions
These are important implementation choices but do not change the outer model:
- nested solve isolation strategy:
  - overload path: use solver snapshot/restore over the call mutation frontier
    (call-scoped vars + argument/callee-reachable vars) for the active match
    context
- fresh-vars branch probing is currently disfavored due to prior
  graph-growth/perf regressions
- exact merge/precedence between `bounds` and residual references
- post-v0 diagnostic text/wording quality in delayed-error scenarios (ordering is
  specified in v0)
- overload-only: whether residual-solving requires fixpoint iteration or a
  single post-pass over bounds-solving solved answers is sufficient
- overload-only: temp-var accumulation management for branch-finishing
  rehydration adapter (correctness is fixed; optimization policy remains open)
- post-v0 policy for `fallback_for_residuals(...)` (v0 is fixed to `Any`;
  richer overload/generic-aware fallback may be preferable later)
- exact provenance storage for generic delayed diagnostics (origin range/lifetime
  across nested or stacked call solves)
- richer non-`Any` policy for `fallback_for_residuals(...)` beyond v0 TODO path

## Determinism requirement
This implementation must not introduce nondeterministic iteration/ordering.

Requirement:
- do not use nondeterministic-order data structures in any residual creation,
  branch pruning, branch finalization, or delayed-diagnostic emission path
- preserve source/traversal order (call params, args, `Forall` params, overload
  branches) and deterministic container order end-to-end
- if an internal aggregation must use an unordered container temporarily, sort
  deterministically before any decision or emitted output that depends on order
- delayed diagnostics specifically must follow the stable ordering key defined
  in overload branch filtering (witness range + projection creation order + var
  order), independent of internal batching

v0 specification boundary:
- this design intentionally does not fully lock down one global canonical
  operation order for all pruning/finalization substeps; some sequencing details
  are deferred to implementation
- this does not permit nondeterminism: for any given implementation/config, the
  chosen order must be deterministic and yield stable diagnostics/results
- therefore, edge-case differences between two distinct deterministic
  implementations are acceptable in v0, but per-implementation run-to-run drift
  is not

## Non-goals (current phase)
- Defining full multi-witness intersection semantics.
- Finalizing every overload/generic corner case before landing an incremental
  path.
- Exposing `CallableResidual` externally.

## Immediate implementation direction
1. Establish `Type::CallableResidual` as the common nonfinalized boundary type.
2. Wire creation at call-quantified finishing points where unsolved vars are
   currently turned into `PartialQuantified`.
3. Enforce elimination at substitution finalization boundaries:
   - return/member/binding paths: no residual outside internal class `TArgs`
   - export/serialization path: no residual anywhere (including `TArgs`)
4. Incrementally add payload behavior (overload first or generic first) behind
   this shared boundary contract.
