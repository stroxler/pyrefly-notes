# Callable Witness Projection Design (v1, concise)

## Goal
Fix higher-order callable transforms (decorators/wrappers) so we preserve valid
overload and generic structure instead of collapsing too early. See the
"Examples" section for some specific cases of interest.

Primary bug shape (issue #2105):
- parameter expects `Callable[P, R]`
- argument is overloaded or generic
- solving commits to one branch too early
- transformed result is overspecialized and later calls fail incorrectly

### A note on existing support in decorators

Currently, decorator handling partially has some of the behaviors we are
trying to pursue here - decorator calls are special-cased to be modeled
separately for each component of an overload, and to automatically unwrap
and re-wrap generic functions.

The current proposal aims to move this logic into the normal type system
so that calling the same decorator as an `@decorator` versus a normal call
could behave the same (at the moment, the special casing only works when
the decorator is used as a syntactic decorator - normal calls to higher-order
functions that are exactly equivalent are modeled differently and behave badly
on overload and generic arguments).

In addition, decorators that return classes (typically classes with a
`__call__` method) cannot be modeled accurately against overloads and generic
function using the existing heuristics, whereas this proposal is intented to
make that possible - so that a decorator output class can have a `__call__`
that is an overload whenever the decorated function was and/or is generic
whenever the decorated function was.

## Non-goals
- No multi-witness intersection in this phase (when multiple arguments constrain
  the same type variable via different witnesses).
- No new external type form; `Projected` is internal only.

## Core model
Use a witness + projection representation during solve/substitute:

```text
Type::Projected {
  witness: Arc<Witness>,
  projection: ProjectionKind,   // Params, Return, TParam(i), etc.
}
```

Key properties:
- `Arc::ptr_eq` gives witness identity for coupling checks (`P` and `R` from
  the same callable match).
- Projections are allowed in preliminary types.
- Finalized types must not contain projections except class-instance TParams.

## Finalization boundaries (where projection must be resolved)
A type becomes finalized at:
1. call return type construction
2. class member lookup result
3. serialization/export boundary

Rules:
- callable positions: eliminate projections by structural transform
- class instance TParams: may stay projected internally
- other positions (tuple element, union arm, bare `T`, etc.): resolve now or fallback

Enforcement:
- add `debug_assert!` at finalization boundaries to verify projections appear
  only in class-instance TParams.

## Solve vs substitute
### Solve
- Collect constraints from callable pattern matching.
- If argument callable is overloaded/generic, bind matched pieces as
  `Type::Projected` rather than forcing early concrete collapse.
- Constraint polarity:
  - callable parameter-side projections contribute upper bounds
  - callable return-side projections contribute lower bounds
  - ParamSpec projections are directly pinned (no bound accumulation)
- A type variable may accumulate multiple projected bounds (from overload
  branches and/or multiple constraining arguments). Multi-witness overlap
  remains fallback in this phase.
- Mixed projected+concrete bounds use existing constraint reduction behavior in
  this phase (no new merge rule here). Projection pass-through is only for the
  projection-only shapes enabled by v1/v2.

### Substitute (witness substitution)
- Shared logic used by both return-type construction and class member lookup.
- Applies branchwise transform on the witness:
  - map over overload branches
  - transform instantiated callable bodies
  - re-quantify remaining unsolved instantiation vars
- Eliminates projections in callable output positions.

## Structural transform (minimal spec)
Given transform schema `F: forall a R. [a -> R] -> T[a, R]` and witness `K`:
- `Overload(K1..Kn)` -> `Overload(F(K1)..F(Kn))`
- `forall X. K` -> instantiate to `K[vX]`, transform body, then re-quantify
  remaining unsolved instantiation vars in original `X` order
- base callable branch -> `apply_branch_transform(F, branch)`

`apply_branch_transform` handles per-branch parameter matching (`ParamSpec`,
`Concatenate`, tuple variadics) and return reconstruction.

`Concatenate` branch failures are branch-local:
- if a branch cannot satisfy required prefix decomposition, drop that branch
- if all branches are dropped, trigger fallback and emit an unresolvable
  projection diagnostic
- if some branches are dropped but at least one survives, continue with
  surviving branches (no warning in this phase; optional quality-of-life
  diagnostic can be added later)

## BoundMethod policy
Bound methods are common witnesses. Reuse existing bound-method binding logic
(`bind_boundmethod`/shared bind path) instead of inventing a new eliminator.

Policy:
- keep witness as-is during normal solving/substitution
- if substitution would create nested `BoundMethod`, bind/eliminate inner one
  at that point

Elimination semantics (binding-aware, not shallow unwrap):
1. strip first parameter (`self`/`cls`) per branch
2. drop overload branches whose `self` annotation is incompatible with the
   bound object
3. substitute `typing.Self` with the actual bound instance type
4. preserve remaining callable/overload structure

Rationale: preserves fidelity until elimination is required and aligns with
existing callable binding semantics.

## Fallback policy
When a non-callable output position still needs a concrete type and witness is
ambiguous:
1. prefer a partial precise form if still representable
2. otherwise use union-of-branch returns for overloaded witnesses
3. use `Any` only when no better approximation is available

Definition of "fallback":
- fallback means existing Pyrefly behavior for that site (same approximation
  path as today)
- ParamSpec-specific v1 fallback: when a ParamSpec projection requires overload
  fallback, select the first overload branch (matching current behavior). This
  is intentionally provisional and may be revised in a later phase.
- multi-witness cases use this fallback in v0/v1/v2
- when fallback is required at a finalized required-concrete position, emit
  Diagnostic #3 ("unresolvable projection in required-concrete position")

## Forall well-formedness after transform
After `forall` push + transform:
- if quantified var appears in params: well-formed
- if appears only in return: emit degeneracy diagnostic
- if appears nowhere: normalize away the `forall`

Decision: normalize no-op `forall` immediately (return the body type
unwrapped). Definition-site non-inferable diagnostics are owned by
definition-site checking, not re-emitted here.

## Class instances as witness carriers
If constructor solving yields projections in class tparams, keep them in the
instance type:

```text
MyDecorator(some_callable) -> MyDecorator[Projected(w, P), Projected(w, T)]
```

Then resolve lazily at member lookup:
- callable member (`__call__`): structural transform
- non-callable member (`x: T`): resolve/fallback immediately

## External boundary
`Type::Projected` must not escape internal analysis. Flatten projections at
serialization/export boundaries so external clients receive concrete types.

Flattening uses the same fallback policy and ordering above.

`Arc::ptr_eq` caveat:
- pointer identity is valid only within one solver session
- serialization/deserialization cannot preserve pointer identity
- this is acceptable because export already flattens projections
- if projections ever need to survive serialization, add a stable witness ID

## Examples
### A. Overload preservation (issue #2105 shape)
```python
class Foo(Protocol):
    @overload
    def __call__(self, ignore_errors: bool, onerror: int | None) -> None: ...
    @overload
    def __call__(self, ignore_errors: bool = False) -> None: ...

def callback[**P, T](
    callback: Callable[P, T], /, *args: P.args, **kwds: P.kwargs
) -> Callable[P, T]: ...
```
Expected: passing an overloaded callable preserves valid overload structure
rather than committing to one branch.

### B. Quantified projection remains valid
```python
def wrap[**P, T](f: Callable[P, T]) -> Callable[P, Awaitable[T]]: ...
def identity[X](x: X) -> X: ...
```
Expected:
```text
wrap(identity): forall Y. [(Y) -> Awaitable[Y]]
```

### C. Degeneracy after `Concatenate` stripping
```python
def strip_first[**P, T](
    f: Callable[Concatenate[Any, P], T]
) -> Callable[P, T]: ...
```
Applied to `forall Y. [(Y, int) -> Y]`:
```text
forall Y. [(int) -> Y]
```
Expected: emit transform-induced degeneracy diagnostic (`Y` is no longer
inferable from parameters).

### D. Non-`ParamSpec` callable coupling
```python
def add_prefix[A, R](f: Callable[[A], R]) -> Callable[[int, A], R]: ...
def id[T](x: T) -> T: ...
```
Expected: `A` and `R` stay coupled through the same witness even without
`ParamSpec`.

### E. TypeVarTuple projection
```python
def unpack_first[T, *Ts](
    f: Callable[[T, *Ts], T]
) -> Callable[[*Ts], T]: ...

@overload
def parse(mode: str, raw: bytes) -> dict: ...
@overload
def parse(mode: str) -> list: ...
```
Expected:
```text
Overload(Callable[[bytes], dict], Callable[[], list])
```
(`T` resolves to `str` from the first parameter of both branches; `*Ts`
remains projected branchwise until substitution.)

### F. Multi-witness overlap (deferred in this phase)
```python
f = Overload(Callable[[int], int], Callable[[str], str])
g = Overload(Callable[[int], int], Callable[[bytes], bytes])
def h[**P, R](f: Callable[P, R], g: Callable[P, R]) -> R: ...
```
Expected in this phase: fallback (no witness intersection yet). Potential
follow-on: intersect witnesses to recover the shared `int -> int` branch.

### G. Pinned witness degeneracy (fresh-var instantiation still works)
```python
def takes_s(f: Callable[[S, int], S]) -> Callable[[S, int], S]: ...
def poly[T](x: T, y: T) -> T: ...
```
When checking `takes_s(poly)`, solver instantiates `poly` to a fresh-var body
`Callable[[vT, vT], vT]`, then matches against `Callable[[S, int], S]`.

Constraint solving pins `vT` to `int`. A projection such as
`Projected(witness=Callable[[vT, vT], vT], Return)` therefore becomes
effectively concrete in this call (`int` after expansion/fallback).

Expected result in this case: `Callable[[int, int], int]`.
This is acceptable: projection machinery may degenerate to concrete answers
when witness vars are fully pinned by constraints in the same solve.

## Core Representation Decision: Instantiate-First `Forall` + Re-Quantify
Projection in normal calls adopts the solver's existing instantiate-first model
for `Forall`:
- incoming `Forall` callables are represented as fresh-var instantiations
- witness/projection references point into that instantiated callable shape
- outputs that still contain unresolved instantiated vars are promoted back to
  quantified form and wrapped in `Forall` when appropriate

This is the key design choice (not just pinned-case degeneracy). It preserves
compatibility with existing solver mechanics and with existing behavior like:

```python
def f[T]() -> Callable[[T], T]: ...
g = f()  # reveals as a forall callable shape
```

Non-obvious but intentional: this differs from current syntactic decorator
special-casing, which treats decorator application more like direct quantified
unwrap/re-wrap. The goal of this project is to recover equivalent end behavior
for normal calls while staying in the standard solver pipeline.

## Mechanism Walkthrough: Fresh Vars, Witnesses, and Re-Quantification
The normal solver path compares `Forall` values by instantiating quantified
parameters with fresh vars. Projection support is designed to compose with that
behavior, not bypass it.

1. Instantiate `forall` body with fresh vars:
   `forall T. K[T]` -> `K[vT]`.
2. Solve constraints in the usual bound machinery, potentially adding projected
   bounds that reference the instantiated witness.
3. If witness vars are pinned during the same solve, projections can collapse
   to concrete types (Example G).
4. If witness vars remain unpinned, later transform/substitution may preserve
   generic structure (`forall`) rather than collapsing immediately.
5. For outputs that should remain generic, unresolved vars corresponding to the
   instantiated quantified set are reified back into quantified form and
   wrapped in `forall` as needed.

Promotion rule (explicit):
- re-quantify only unresolved vars in the allowed capture set:
  - vars from the current callable instantiation scope
  - vars reachable from surviving projection witnesses in the transformed result
- do not re-quantify vars that were solved to concrete answers
- do not re-quantify unresolved vars outside the allowed capture set

Required guardrails:
- provenance tagging: each fresh var created from `Forall` instantiation must
  carry origin scope (for example `forall_instantiation(witness_id)`), so
  capture/re-quantification cannot accidentally include unrelated vars
- strict capture set: re-quantification only considers vars in that
  allowed capture set (instantiation-origin vars plus witness-reachable vars)
- deterministic quantifier order: preserve original tparam declaration order
  among captured vars for stable diagnostics/tests
- finalization invariant: no instantiation-origin vars may escape in finalized
  output types; they must be either solved, re-quantified, or diagnosed+fallback

Compatibility note:
- v0/v1 may still fallback at finalization boundaries.
- v2 enables structural transform, but still allows pinned-witness degeneracy
  when constraints determine a concrete answer.

## Deferred interaction surface
- Class-instance operations that depend on fully resolved generic arguments
  (for example variance-sensitive assignability/type-guard paths) may force
  projection resolution at their existing required-concrete boundary.
- when such resolution is forced, use the same fallback policy/ordering
  defined above.
- projected-vs-projected comparisons across different witnesses do not get a
  special relation in this phase; cross-witness comparison forces resolution.

## Diagnostics (split by cause)
1. definition-site non-inferable type variable
2. transform-induced degeneracy (binding sites removed)
3. unresolvable projection in required-concrete position
4. mixed-position conflict (same variable works in callable/TParam but not
   standalone)

Recovery behavior: on transform/elimination failure, emit the diagnostic and
use the existing checker fallback/error type for that site.

## Phased rollout
- v0: add representation + collect projected bounds; reduce using old fallback
- v1: allow solved bindings to retain projections when bounds are purely
  projected; substitution plumbing present but still fallback-only
- v2: enable single-witness callable structural transform (`Arc::ptr_eq`)

Phase-to-example mapping (tests):

| Example | v0 | v1 | v2 | Follow-on |
|---------|----|----|----|-----------|
| A. Overload preservation | fallback | projection preserved | overload structure preserved | — |
| B. Quantified projection | fallback | projection preserved | quantified callable preserved | — |
| C. Concatenate degeneracy | fallback | fallback | degeneracy diagnosed | diagnostic quality |
| D. Non-ParamSpec coupling | fallback | projection preserved | coupled transform works | — |
| E. TypeVarTuple projection | fallback | projection preserved | branchwise overload transform works | — |
| F. Multi-witness overlap | fallback | fallback | fallback | multi-bound resolution |
| G. Pinned witness degeneracy | concrete via fallback | concrete via fallback | concrete when constrained | — |

## Explicit decisions (resolved)
1. Approximation boundary: only at finalization boundaries above.
2. No-op `forall`: normalize immediately.
3. Class projected-TParam policy: allow internally, resolve at member lookup,
   flatten at export.
4. Multi-witness constraints: fallback in this phase.
5. BoundMethod timing: defer elimination until nesting/required boundary.

## Remaining open question
- Do we want a later multi-witness intersection strategy, or keep fallback-only
  permanently based on observed frequency?
