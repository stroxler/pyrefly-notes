# `IntVar` Inference Fixpoint Plan

This note sketches a concrete implementation plan for inferring the `IntVar` kind for ambiguous unbounded PEP 695 type parameters. It builds on the design argument in `symvar-fixpoint-cost.md`: symbolic integer type parameters should be represented as a real `QuantifiedKind`, and inferred `IntVar` vs ordinary `TypeVar` should be resolved through Pyrefly's binding fixpoint rather than through deferred validation.

## Goals

The inference pass should be a classifier, not a validator.

Its job is to decide whether an ambiguous unbounded PEP 695 parameter is better treated as an ordinary `TypeVar` or as a symbolic integer `IntVar`. It should not collect all uses and diagnose inconsistency. Once the fixpoint chooses a kind, existing type-form validation should report ordinary kind errors at the invalid use sites.

The core invariants are:

- Stored function signatures and class fields contain only kind-valid types after fixpoint convergence.
- Explicit `N: IntVar` remains the primary representation for symbolic integer type parameters.
- Inference is a convenience layer that can be disabled or warned on without changing the internal representation.
- Ordinary generic code stays cheap, even when shape support is available in the environment.

## Scope

Inference should apply only to ambiguous unbounded PEP 695 `TypeVar`-shaped parameters:

```python
def f[N](...) -> ...: ...
class C[N]: ...
```

It should not apply to:

- explicit symbolic parameters such as `N: IntVar`
- any non-`IntVar` bound
- constraints
- defaults, at least initially
- type aliases, in the first implementation
- legacy declarations such as `N = TypeVar("N")`

The legacy declaration surface can continue to require `N = IntVar("N")`.

## Binding Shape

Add a dedicated inferred-kind binding keyed by the actual ambiguous parameter identity:

```text
KeyInferredQuantifiedKind(owner, quantified_identity) -> QuantifiedKind
```

This should be one binding per ambiguous owner/parameter pair, not a name lookup and not a map-level binding for all parameters owned by a function or class. Per-parameter bindings keep cycles small and allow each parameter to short-circuit independently.

The binding payload needs enough owner metadata to inspect the relevant API surface:

```text
BindingInferredQuantifiedKind {
  owner,
  quantified_identity,
  name,
}
```

The exact owner representation should use stable binding keys, not transient solved values. For the first implementation:

- class owners should use the class binding key, likely the existing `KeyClass` / class definition key shape
- function owners should use the canonical function syntax owner
- overload owners should represent the overload family, not only one overload item
- type alias owners are excluded from phase 1

Function owners need a stable binding key, not a transient function value. If decorators, overloads, or nested functions have separate binding objects, the inferred-kind owner should point at the canonical syntax owner whose annotation surface is scanned and invalidated.

The recursive answer for this binding must be conservative:

```text
recursive KeyInferredQuantifiedKind(...) = TypeVar
```

This is both the safe cycle breaker and the fast path. It means the first recursive pass may temporarily under-infer symbolicness, but persistent API types are rebuilt after the final inferred kind is available.

## Quantified Construction

PEP 695 binding already records type parameter names, bounds, defaults, and `QuantifiedIdentity`. During binding:

- explicit `N: IntVar` should be recorded as final `QuantifiedKind::IntVar`
- bounded/constrained/defaulted `TypeVar` parameters should remain final ordinary `TypeVar` parameters for the initial implementation
- unbounded plain `N` should be marked as inferable and associated with a `KeyInferredQuantifiedKind`

Do not represent ambiguity as a real `QuantifiedKind` that can leak into `Quantified`. Use an explicit marker on the binding-time type parameter record, such as:

```text
TypeParameterKind::Explicit(QuantifiedKind)
TypeParameterKind::Infer { fallback: TypeVar, inferred_kind_key: KeyInferredQuantifiedKind }
```

or an equivalent `is_ambiguous` / `inferred_kind_key` field. The important invariant is that `Quantified` is constructed only with a final effective kind: `TypeVar`, `IntVar`, `ParamSpec`, or `TypeVarTuple`.

During solving, `Quantified` construction should use an effective kind:

```text
explicit/final kind -> use directly
ambiguous unbounded kind -> read KeyInferredQuantifiedKind
```

This is what creates the intended dependency cycle:

```text
surface type construction
  -> effective quantified kind
  -> inferred-kind binding
  -> owner surface evidence
  -> surface type construction
```

The cycle is acceptable because the recursive inferred-kind answer is `TypeVar`.

## Evidence Model

The inference binding returns either `TypeVar` or `IntVar`. It does not need `Unknown` or `Conflict`.

Evidence categories:

- ordinary type-position evidence: a use that requires an ordinary type parameter, such as `x: N` or `list[N]`
- symbolic-integer-position evidence: a use in `Int[N]`, symbolic integer arithmetic, tensor shape slots, or equivalent shape-expression contexts
- no evidence: owner surfaces that do not mention the parameter

The inference rule is:

```text
if inference is disabled:
  TypeVar
else if shape support is unavailable for the module:
  TypeVar
else if any ordinary type-position evidence is found:
  TypeVar
else if symbolic-integer-position evidence is found:
  IntVar
else:
  TypeVar
```

`TypeVar` wins intentionally. The reason is not only compatibility with today's semantics; it is also the main performance property. Ordinary generic code should short-circuit as soon as the first ordinary use of the parameter is found. The inference binding should not continue scanning just to find mixed symbolic uses, because downstream kind validation will catch those after the final kind is chosen.

Symbolic evidence is provisional. If the scanner sees symbolic evidence first, it should remember that fact and continue scanning the relevant owner surface until either ordinary evidence is found or the surface is exhausted. If ordinary evidence appears later, the result is still `TypeVar`. This keeps the result independent of traversal order while preserving the common-case early exit for ordinary generic code.

## Evidence Collection Strategy

Prefer a binding-level syntactic evidence scan for the first implementation. The scanner should inspect raw binding data and annotation syntax that already exists in the owner surface, classify occurrences of the exact ambiguous parameter identity, and return an evidence summary to `KeyInferredQuantifiedKind`.

The scanner should avoid solved annotation, function, and class-field answers. Calling solved keys can re-enter the same surface construction cycle and may force return inference or class-field value inference that the plan is explicitly trying to avoid.

The scanner needs a precise symbolic-position predicate. For the first implementation, recognize symbolic-integer position only when the raw binding surface can identify one of:

- the canonical `shape_extensions.Int` form, including imported or qualified uses that existing binding flow can resolve without solving annotation answers
- tensor shape slots and shape-list syntax that Pyrefly already treats as symbolic integer context
- symbolic integer arithmetic inside those recognized shape contexts

For example, `from shape_extensions import Int; def f[N](x: Int[N]) -> None: ...` can be recognized from binding-time import flow and annotation syntax without solving the annotation type. Similarly, `import shape_extensions as se; x: se.Int[N]` can be recognized if the alias binding is available syntactically. A local class or variable named `Int` should not be treated as symbolic without resolving to the shape extension binding.

Ordinary type-position evidence includes bare use of the parameter in ordinary annotations and ordinary type arguments, such as `x: N`, `Foo[N]`, `tuple[N, ...]`, and `list[N]`. Nested symbolic forms like `list[Int[N]]` should count as symbolic evidence for `N` because the occurrence is inside a recognized symbolic integer context, while the outer `list[...]` is ordinary only for its own type argument shape.

Shadowing and aliases must be handled conservatively. Evidence attaches only to the exact ambiguous quantified identity being classified, not to a textual name. If a method, nested definition, nested class, type alias, or local PEP 695 binder introduces another `N`, uses of that inner `N` are not evidence for the outer owner. If a `Int`-looking name is shadowed or cannot be resolved syntactically to the shape extension surface, treat it as ordinary or no evidence according to the surrounding annotation rather than guessing symbolicness.

If syntactic evidence scanning proves insufficient, a second option is to add transient provenance for the case where a gradual symbolic integer type was introduced because a bare ambiguous type parameter appeared in symbolic-integer position while the recursive answer still classified it as an ordinary `TypeVar`.

This provenance can live inside `Type::Int` for example:

```rust
enum GradualIntSource {
    Normal,
    BareAmbiguousTypeParam { /* compact identity */ },
}
```

This in-type provenance is high risk and should not be the default MVP if the binding-level scanner can provide the needed evidence. If provenance is added, the exact shape should follow the eventual `Int` representation, and the invariant should be documented directly on the datatype:

- the provenance exists only for kind inference
- display must ignore it
- it must not create user-visible semantic differences
- it should not be used for any behavior other than inferred-kind classification

The provenance lifecycle must be explicit before implementation. `SizeExpr`-like types participate in equality, hashing, ordering, canonicalization, union deduplication, and heap interning. Ignoring provenance in some of those operations but not others can lose evidence or make caches inconsistent. If in-type provenance is used, the plan needs one of:

- a side-channel extraction step that consumes provenance before canonicalization/intering can erase it
- semantic equality/hash/order implementations that consistently ignore provenance and a separate non-semantic evidence path that cannot be deduplicated away
- a clearly documented stripping boundary before final exposed API types and caches rely on the type

The implementation should also handle multi-parameter symbolic expressions such as `Tensor[[N + M]]`; the evidence result should be able to record that both `N` and `M` appeared in symbolic-integer position.

## Untype Phase Model

If evidence is produced through `untype` rather than a purely syntactic scanner, the plan must distinguish three behaviors:

- recursive/in-progress inference: an ambiguous parameter may be treated as ordinary `TypeVar`, but symbolic-position use should produce evidence rather than a final user-facing diagnostic
- converged `IntVar`: ordinary type-position use of the parameter is an ordinary kind error
- converged `TypeVar`: symbolic-integer-position use of the parameter is an ordinary kind error

The first implementation should avoid adding phase-sensitive behavior to `untype` unless the syntactic scanner cannot cover the needed evidence. If phase-sensitive `untype` behavior is required, add tests that prove evidence-only behavior cannot leak into final stored API types.

## Convergence Model

The inferred-kind binding should be monotonic within an owner solve. The recursive answer starts as `TypeVar`; a normal answer can remain `TypeVar` or promote to `IntVar`; once ordinary evidence is found, the answer is definitively `TypeVar` for that solve.

There should be no `IntVar -> TypeVar -> IntVar` oscillation caused by stored API types. The classifier reads owner syntax/evidence, not previously stored finalized type surfaces, and the canonical tparam-producing binding rebuilds the `Quantified` with the effective kind after the inferred-kind binding converges. If an implementation path uses `untype`-produced evidence instead of syntax, it must preserve this monotonic property explicitly and test it.

`QuantifiedIdentity` identifies the binder, but the effective kind is part of the rebuilt `Quantified` data. A recursive pass may temporarily construct the same identity as `TypeVar`, and a later converged pass may construct it as `IntVar`. That temporary value must not be cached as the final persistent API type. Any cache keyed only by identity needs to be audited so it cannot return the recursive ordinary-kind `Quantified` after promotion.

Do not change `Quantified` equality or hashing as part of the first inference implementation unless a separate audit shows it is necessary. Treat kind promotion as rebuilding the owner surface with a different effective `Quantified` after the inferred-kind binding converges. The canonical tparam-producing binding must read the effective kind and be invalidated by inferred-kind changes; caches that assume `QuantifiedIdentity` alone determines a complete `Quantified` must be avoided or explicitly invalidated.

Variance inference should run over the converged effective `Quantified` data. If `IntVar` is variance-neutral or treated like `TypeVar` in the current implementation, document that in the variance code path; do not let variance inference observe a recursive `TypeVar` placeholder as final class metadata.

## Function Surface Scan

For a function owner, inference should scan declared signature surfaces only:

- parameter annotations
- explicit return annotation
- overload signature annotations, if the owner represents an overload family

It should not inspect:

- body-local annotations
- inferred return types
- body return expressions
- decorator expression types

This keeps inference close to the binder's declared API surface and avoids turning the feature into return-type or body inference.

For overloads, the owner identity and aggregation rule need to be explicit. The inferred-kind binding for a parameter owned by an overload family should aggregate all declared overload signatures that share the binder. Ordinary evidence in any overload signature wins and short-circuits to `TypeVar`; otherwise symbolic evidence in one or more overload signatures can promote to `IntVar`.

Implementation should walk the overload predecessor chain or equivalent raw binding structure for the overload family. It should not classify one overload item in isolation if the public function surface is the aggregate overload set.

## Class Surface Scan

Class inference should avoid the solved `ClassField` path. Calling `solve_class_field` / `calculate_class_field` can force value inference, method solving, decorators, descriptor/property transforms, inherited fields, dataclass and attrs handling, synthesized fields, and unannotated return inference.

Instead, the inferred-kind binding should inspect `BindingClassField.definition` directly and scan only retained declared annotations/signatures.

Traverse:

- class base expressions only for direct, syntactically recognized symbolic contexts
- `DeclaredByAnnotation { annotation, .. }`: scan the annotation.
- `AssignedInBody { annotation: Some(annotation), .. }`: scan only the annotation.
- `DefinedInMethod { annotation: Some(annotation), .. }`: scan only the `self.x: ...` or `cls.x: ...` annotation.
- `MethodLike { annotation, definition, has_return_annotation }`: scan `annotation` if present, then inspect the raw method signature through `definition`.

Ignore:

- `AssignedInBody.value`
- `DefinedInMethod.values`
- `DefinedWithoutAssign { definition }`
- `DeclaredWithoutAnnotation`
- `NestedClass { definition }` for the enclosing class's parameters; nested class parameters should be inferred by the nested class owner
- decorator expression types
- descriptor/property transformation
- inherited annotation lookup
- dataclass and attrs value analysis
- synthesized fields
- default-value inference
- all `ReturnTypeKind::ShouldInferType` body-return keys

For `MethodLike.definition`, read raw binding data rather than solved answers:

- `Binding::Function(...)` gives access to the function binding.
- The undecorated function binding exposes parameter annotations.
- `FunctionParameter::Annotated(Idx<KeyAnnotation>)` can be scanned directly.
- Explicit return annotation bindings can be scanned.
- Inferred return bindings must be ignored.

Do not call APIs such as `get_decorated_function`, solved `KeyDecoratedFunction`, solved `KeyReturnType`, or `get_class_fields` from the evidence walk if they can force full function/class solving.

Arbitrary generic base type arguments are not symbolic evidence in the MVP. For example, `class C[N](HasShape[N])` should not infer `N` as `IntVar` unless `HasShape` is an allowlisted shape surface or the implementation adds a safe dependency-tracked lookup of the base class's parameter kind. The conservative MVP behavior is to treat `N` in an ordinary generic base argument as ordinary evidence. Shape-generic base-parameter inference can be added later with explicit dependencies on the base class/type metadata.

When scanning method signatures, respect method-local binders and nested definitions. A method `def m[N](...)` inside `class C[N]` owns its own `N`; method-local uses must not affect the class parameter. Nested classes and nested functions should be handled the same way: their binders are classified by their own owners, not by the enclosing class scan.

One known omission is attrs `field(type=...)`, which may currently be converted into a direct annotation during class-field calculation rather than being retained as a `KeyAnnotation`. The first implementation should ignore this unless it is important enough to bind as an annotation explicitly.

Because this scanner deliberately duplicates only a small part of class-field logic, add debug assertions or code-structure guardrails where possible to make sure it remains a binding-level scan and does not accidentally call solved class/function/annotation APIs.

## Type Alias Surface

Type aliases should be explicitly excluded from the first implementation. They have the same conceptual rule as functions/classes, but they are not keyed exactly like function and class owners, and including them would expand the first dependency-graph change.

The first implementation should focus on functions and classes. Type aliases should be a follow-up with dedicated tests showing that excluded aliases retain current explicit-only behavior until alias owner support exists.

## Configuration And Policy

Do not use runtime feature flags. Pyrefly is open-source, and typechecking behavior should be reproducible from source and checked-in config.

Use a Pyrefly config enum rather than a boolean:

```text
symbolic-type-param-inference = "disabled" | "warn" | "enabled"
```

The Rust config field should use the normal snake_case field with serde kebab-case config spelling, for example:

```rust
symbolic_type_param_inference: SymbolicTypeParamInference
```

with a default of `disabled`.

Suggested behavior:

- `disabled`: ambiguous binders stay ordinary `TypeVar`; explicit `N: IntVar` still works when shape support is available.
- `warn`: inference runs, but a diagnostic is emitted whenever an implicit binder is actually promoted to `IntVar`.
- `enabled`: inference runs without migration diagnostics.

The first implementation should not add a source-level directive. Project and subconfig policy is enough for the initial rollout and avoids parser/config invalidation complexity.

A later implementation can support a source-level directive if a narrower opt-in is desired:

```python
# pyrefly: enable-symbolic-type-param-inference
```

The directive should be recognized only in the module prologue and should follow existing `# pyrefly: ...` directive style. Possible policy:

- in `disabled`, the directive opts a file into inference
- in `warn`, the directive suppresses migration warnings for that file
- in `enabled`, it is redundant

If a directive is added later, config precedence must be explicit. In particular, `disabled` may need to remain a hard-off mode for performance or emergency rollback. If the directive is allowed to override `disabled`, add a separate `forbidden` or `hard-disabled` mode before relying on `disabled` as an emergency stop.

The effective inference gate should combine:

```text
shape support is available for this module
  and config/directive policy permits inference
```

Pyrefly already has a per-module tensor-shape availability bit derived from whether `shape_extensions` is resolvable. The inferred-kind binding should use that kind of fast path and return `TypeVar` immediately when shape support is unavailable.

## Diagnostics

In `warn` mode, emit only when an ambiguous binder is actually promoted:

```text
Implicit symbolic integer type parameter `N` was inferred from symbolic integer use.
Add `N: IntVar` to make this explicit, or enable/suppress symbolic type parameter inference warnings for this module.
```

The warning should be reported once at the binder/type-parameter definition site where possible. If `TypeVar` wins because ordinary evidence was found, the inference binding should not emit a warning. The downstream symbolic-use error may be less localized, so consider including a secondary note in that later diagnostic once implementation support exists, but do not make the inference binding scan globally for better mixed-use diagnostics.

Avoid diagnostics for:

- explicit `N: IntVar`
- binders classified as ordinary `TypeVar`
- mixed-use conflicts inside the inference binding

Mixed-use conflicts should be reported by existing kind validation after fixpoint convergence. This avoids a global consistency scan and keeps the inference binding cheap.

## Performance Expectations

The plan makes narrow performance claims:

- If shape support is unavailable, the inferred-kind binding returns `TypeVar` without scanning.
- If config disables inference, the inferred-kind binding returns `TypeVar` without scanning.
- Ordinary generic code usually short-circuits on the first ordinary type-position use.
- Simple owner-local symbolic inference costs roughly three constructions of the affected surface:
  1. recursive pass classifies as `TypeVar`
  2. evidence promotes to `IntVar` and the surface is rebuilt
  3. the same `IntVar` answer is confirmed
- Persistent API types are rebuilt after convergence and do not store illegal symbolic forms.

Do not claim a global constant bound for recursive class graphs, inheritance, decorators, or return inference. The performance claim is locality and fast paths, not universal boundedness. Higher-arity generics may still scan the same owner surface for multiple ambiguous parameters; per-parameter bindings keep invalidation local, but they do not make shared surface scans free.

## Invalidation And Incrementality

The implementation should make the dependency boundaries explicit:

- owner surface edits must invalidate the relevant inferred-kind bindings
- raw annotation and method-signature bindings read by the evidence scanner must be registered as dependencies of the inferred-kind binding
- config changes must invalidate inferred-kind answers
- changes in per-module shape-support availability must invalidate inferred-kind answers
- changing a binder from ambiguous to explicit or bounded must remove or bypass the inferred-kind binding
- edits that flip an inferred kind from `TypeVar` to `IntVar`, or back, must rebuild dependent signatures and class surfaces

The existing per-module tensor-shape availability bit is a useful model: it is a find-only dependency on whether `shape_extensions` is resolvable, not a dependency on the contents of `shape_extensions`.

Raw binding scans should not silently bypass the dependency graph. If the scanner reads a `KeyAnnotation`, raw function signature binding, method-like binding, or class base binding, the inferred-kind binding must depend on that key or on an owner-level binding that is invalidated by changes to those syntactic surfaces. Cross-module base-class evidence should similarly depend on the imported/base surface needed to classify the local parameter use.

The implementation should prefer reading raw syntax through dependency-tracked binding APIs rather than directly indexing side tables in a way the fixpoint engine cannot see. If a required raw surface has no key today, add an owner-level key or explicitly document that the inferred-kind binding is invalidated whenever the owner binding changes.

## Implementation Phases

### Phase 1: No-Op Plumbing

- Add the key, binding, answer type, and `Solve` implementation.
- Return `TypeVar` unconditionally, including recursive answers.
- Thread config shape if convenient, but keep behavior identical.
- Add tests showing explicit `IntVar` still works and ambiguous binders remain ordinary.

### Phase 2: Effective Kind Lookup

- Mark ambiguous unbounded PEP 695 binders during binding.
- Make `Quantified` construction read the inferred-kind binding only for ambiguous binders.
- Keep the inferred-kind binding returning `TypeVar`.
- Verify no behavioral change.

### Phase 3: Evidence Scanner

- Implement binding-level syntactic evidence scanning for symbolic-integer and ordinary type-position uses.
- Keep scans owner-local and avoid solved annotation/function/class-field answers.
- Add in-type provenance only if syntactic evidence is insufficient, and only after defining cache/equality/canonicalization behavior.
- Keep promotion behavior behind config defaulting to `disabled` until policy and diagnostics are implemented.

### Phase 4: Function Evidence

- Implement function signature evidence scanning.
- Short-circuit on ordinary evidence.
- Promote to `IntVar` only when symbolic evidence is found and no ordinary evidence was seen first.
- Add tests for symbolic parameter annotations, tensor shape slots, ordinary generics, and mixed uses.
- Keep behavioral promotion enabled only in tests or explicitly opted-in config until Phase 6.

### Phase 5: Class Evidence

- Implement declared class-surface evidence scanning over `BindingClassField.definition`.
- Include direct symbolic contexts in class base expressions.
- Treat arbitrary generic base type arguments as ordinary evidence unless a dependency-tracked base-parameter-kind lookup is added.
- Avoid solved `ClassField` and inferred return paths.
- Add tests for class fields, method signatures, `self.x: ...` annotations, ordinary class generics, and nested class ownership.
- Keep behavioral promotion enabled only in tests or explicitly opted-in config until Phase 6.

### Phase 6: Policy And Migration

- Add config enum behavior.
- Add warning mode.
- Add tests for disabled/warn/enabled modes and for shape-support-unavailable fast paths.

### Phase 7: Follow-Ups

- Type alias owner support.
- attrs `field(type=...)` if needed.
- Source directive support if project/subconfig policy is not granular enough.
- Better migration diagnostics or autofix suggestions.
- Potential default policy changes after real usage data.

## Test Plan

The implementation should include tests for:

- no-op plumbing preserving current behavior
- explicit `N: IntVar`
- ambiguous `N` remaining ordinary when inference is disabled
- shape-support-unavailable fast path
- `warn` mode emitting one diagnostic at the binder site
- warning deduplication
- ordinary evidence before symbolic evidence
- symbolic evidence before ordinary evidence, proving traversal-order independence
- symbolic-only function signatures
- direct symbolic contexts in class bases
- conservative ordinary treatment for arbitrary base generic arguments such as `class C[N](HasShape[N])`
- follow-up tests for cross-module base class shape-generic inference if that support is added
- class fields and method signatures
- `self.x: Int[N]` / `cls.x: Int[N]` annotations
- nested class ownership
- method-local PEP 695 shadowing, such as `class C[N]: def m[N](...) -> ...`
- nested function and nested class shadowing
- renamed, qualified, shadowed, and unsupported `Int` / `Size` spellings
- `list[Int[N]]`, `Foo[N]`, `tuple[N, ...]`, and bare return boundary cases
- symbolic-looking defaults being excluded from evidence
- body-only symbolic-looking usage staying `TypeVar`
- legacy `N = TypeVar("N")` staying explicit-only
- overload or multi-signature evidence merging
- multi-parameter symbolic expressions such as `Tensor[[N + M]]`
- recursive class graphs
- incremental edits that flip inferred kind in both directions
- incremental method-signature edits that flip inferred kind
- cache consistency when the same `QuantifiedIdentity` is first seen with the recursive `TypeVar` answer and later promoted
- config changes that disable inference
- deferred type-alias behavior

## Rollback Story

The rollback path should be a config change:

- explicit `N: IntVar` remains supported
- inferred binders stop promoting when inference is disabled
- warning mode can surface all inferred binders before disabling
- no representation rewrite is needed because `QuantifiedKind::IntVar` remains the explicit representation

This matters because the inferred syntax may turn out to be a poor language-design tradeoff. The implementation should make it easy to discourage, warn on, or remove inference while preserving explicit symbolic integer type parameters.
