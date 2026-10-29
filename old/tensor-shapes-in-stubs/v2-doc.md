# Tensor Shape Functions in Stubs (V2)

## Overview

This document proposes moving tensor shape logic from an embedded Rust DSL
string to Python stub files (`.pyi`), enabling library extensibility and code
navigation while preserving Pyrefly's lazy evaluation architecture.

The key architectural principles are:

1. **Lazy, not eager.** No upfront stub scanning or global registry construction.
   Shape functions are discovered through normal import resolution during type
   checking.
2. **AST lowering, not string extraction.** IR functions are converted from
   already-parsed Python AST to `DslFnDef` via the existing `convert_fndef`,
   not by extracting source text and re-parsing.
3. **Explicit opt-in.** DSL functions are marked with an explicit
   `@shape_dsl_function` decorator defined in `shape_extensions.dsl`.
   No heuristic detection, no module-level mode switches.
4. **Type-level decorator integration, reusing `Type::Function`.** Shape IR
   functions are represented as ordinary `Type::Function` values distinguished
   by a new `FunctionKind::ShapeDsl` variant; the `DslFnDef` is carried on the
   `Function` itself. `@uses_shape_dsl` is evaluated as a real decorator that
   produces another `Type::Function` whose `FuncMetadata`/`FuncFlags` carries a
   reference to the corresponding shape transform definition. No new top-level
   `Type` variant is introduced.
5. **State lives in the type system, not in side registries.** All shape-
   related state lives on solver answers — there is no separate registry, no
   `OnceLock` statics, no parallel lookup table threaded alongside types. The
   shape transform reference is carried on `FuncFlags` the same way
   `dataclass_transform_metadata` and `deprecation` are. This makes cache
   invalidation under LSP automatic.

## Motivation

Pyrefly currently implements tensor shape inference using a ~460-line Python-
subset string constant (`DSL_SOURCE`) in `tensor_ops_registry.rs`. The
`TensorOpsRegistry` maps ~131 qualified names (like `"torch.matmul"`) to DSL
function names (like `"matmul_ir"`), all hardcoded in Rust.

**Problems:**
1. **Not extensible.** Adding shape logic for any operation requires modifying
   Pyrefly's Rust source.
2. **No code navigation.** The DSL lives inside a Rust string literal — no "Go
   to Definition", no "Find References".
3. **Tight coupling.** Shape logic for PyTorch is tangled with the registry
   mechanism in Rust code.

**Goals:**
1. Library authors can ship shape logic in their type stubs.
2. "Go to Definition" works from API function → shape implementation.
3. No startup-time cost — resolution is lazy, matching Pyrefly's architecture.
4. Easy to create new shape DSL stub packages (e.g. numpy, jax) beyond torch.

## Current Architecture (What We're Replacing)

### The DSL engine (`meta_shape_dsl.rs`)

The DSL infrastructure has three parts:

- **`convert_fndef`**: Takes a `&ruff_python_ast::StmtFunctionDef` and produces
  a `Result<DslFnDef, String>`. This is pure AST-to-IR lowering — it doesn't
  parse source text, it converts already-parsed AST nodes. It currently
  inspects only `func.parameters.args` (positional-only and positional-or-
  keyword parameters) — `*args`, `**kwargs`, and keyword-only parameters are
  silently ignored. This is acceptable for today's DSL but is a limitation
  that Phase 7 should address with a clearer diagnostic.

- **`DslFnDef`** and friends: Grammar-aligned types (`DslBody`, `DslExpr`,
  `DslParam`, etc.) representing shape functions in a form the interpreter can
  evaluate. `DslFnDef` has four fields: `name`, `params: Vec<DslParam>`,
  `return_type: Option<DslType>`, and `body: DslBody`.

- **`eval_dsl_body`**: Interprets a `DslFnDef` given variable bindings,
  producing a `Result<(Val, bool), ShapeError>`. The `bool` indicates whether
  the return expression is a list literal ending with `...` (the
  unbounded-tuple marker). The `Val` result gets converted back to a `Type`.

### The registry (`tensor_ops_registry.rs`)

`TensorOpsRegistry::new()` does this at construction:
1. Calls `parse_dsl(DSL_SOURCE)` — which calls `Ast::parse()`, then
   `convert_fndef` for each function, then `type_check_program` on the
   resulting `Vec<DslFnDef>` — producing `Vec<Arc<DslFnDef>>`.
2. Builds `fn_lookup: Arc<HashMap<String, Arc<DslFnDef>>>` for helper
   resolution (when IR functions call other IR functions like `normalize_dim`).
3. Registers ~131 qualified names via `register()`, `register_dual()`, and
   `register_init_forward()`.

There are two separate `OnceLock<TensorOpsRegistry>` statics — one in
`callable.rs` (for shape function lookup) and one in `call.rs` (for init
capture lookup). The registry is constructed independently in each.

### The solver integration

In `callable.rs`, `callable_infer_inner` does:
1. `lookup_meta_shape(callable_name)` — constructs a qualified name from the
   `FunctionKind` (using `module.class.name` or `module.name`) and looks it up
   in the registry.
2. Collects `bound_args: Option<HashMap<String, Type>>` during argument
   binding. The `Option` wrapper ensures no allocation occurs when no shape
   function applies — `bound_args` is `Some` only when `lookup_meta_shape`
   found a match.
3. `inject_module_attrs()` — for `NNModule` instances, injects captured
   `__init__` params into `bound_args`. Has a separate path for plain
   `ClassType` instances that unwraps `Dim[T]` to `T`.
4. `apply_meta_shape()` — calls `meta_shape_func.evaluate(bound_args, ret_type)`
   and uses the result (or emits a diagnostic on `ShapeError`).

In `call.rs`, `maybe_wrap_nn_module` checks `registry.get_init_capture` to
decide whether to wrap a class construction result as `Type::NNModule`.
`NNModuleType` holds a `ClassType` plus a `SmallMap<Name, Type>` of captured
init args. The lookup is by fully-qualified class name string — no MRO walk,
no inheritance.

### DSL builtins

Eight functions are recognized at parse time in `convert_fndef`'s
`convert_call` (via string matching) and mapped to `DslBuiltin` enum variants:
- `shape_extensions.prod`, `shape_extensions.sum`,
  `shape_extensions.parse_einsum_equation`
- `len`, `range`, `str`, `enumerate`, `zip`

They are not resolved through imports. This will remain unchanged; these
builtins are intrinsic to the DSL interpreter. (Originally named
`torch_shapes.*`, renamed to `shape_extensions.*` in Phase 1.)

### DSL helper function structure

The current `DSL_SOURCE` contains ~50 IR functions and 14 helper functions in
a single flat namespace. The helper dependency graph is a DAG with max depth 3
(e.g. `movedim_ir` → `move_dims` → `contains`/`scatter`/`broadcast_int`).
No IR function calls another IR function — the call graph is strictly
IR→helper and helper→helper. All functions are parsed, type-checked, and
placed into one shared `fn_lookup` HashMap together. `type_check_program`
requires all functions to be present at once (it builds a global signature map
from the full slice of `DslFnDef`s).

### The `MetaShapeFunction` trait

```rust
pub trait MetaShapeFunction: Debug + Send + Sync {
    fn name(&self) -> &str;
    fn evaluate(
        &self,
        bound_args: &HashMap<String, Type>,
        ret_type: &Type,
    ) -> Option<Result<Type, ShapeError>>;
    fn param_names(&self) -> Vec<&str> { vec![] }
}
```

The sole implementation is `DslMetaShapeFunction`, which holds an
`Arc<DslFnDef>` and an `Arc<HashMap<String, Arc<DslFnDef>>>` (the `fn_lookup`
for helper resolution). Its `evaluate` method calls `bind_dsl_params` to
convert `bound_args` into a `Val` environment, then `eval_dsl_body`, and
finally converts the result via `val_to_type`. `ShapeError::Unsupported`
returns `None` (fall back to the fixture return type).

### Hardcoded `shape_extensions` references

`shape_extensions` is referenced by qualified name in several places
outside the registry — in `expr.rs`, `display.rs`, `solve.rs`, and
`special.rs` — for `Dim` recognition, display logic, canonicalization, and
`TypeVar`/`TypeVarTuple` sourcing. (Originally `torch_shapes`, renamed in
Phase 1.)

## Proposed Design

### The `shape_extensions` package

The `shape_extensions` package provides the primitives that all shape DSL
packages import from. It is not torch-specific — any library (torch, numpy,
jax, etc.) uses the same primitives. The package is distributed alongside
library stubs (in test fixtures during development), not bundled with
Pyrefly.

The package has two modules:

**`shape_extensions` (public API)** — types and decorators that appear in
normal stubs and `.py` files. Conceptually:

```python
# shape_extensions/__init__.py (idealized)

class Tensor[*Shape]:
    shape: tuple[int, ...]

class Dim[T]:
    pass

# TypeVar and TypeVarTuple are re-exports that the type system treats
# as identical to typing.TypeVar / typing.TypeVarTuple. See the test
# fixture for the runtime mechanism (class with `__class__ =
# typing.TypeVar`, etc.) — the surface API is just "use these like
# typing.TypeVar but with arithmetic that returns self."
TypeVar = ...
TypeVarTuple = ...

def uses_shape_dsl(
    ir_fn: Callable,
    *,
    capture_init: list[str] | None = None,
) -> Callable: ...
```

In the current test fixture (`test/tensor_shapes/fixtures/
shape_extensions/__init__.py`), `Tensor` is not defined here at all —
torch's `Tensor` is monkey-patched to be subscriptable so that
`Tensor[B, T]` works at runtime. Long-term those patches move to a
torch-specific module and `Tensor` is defined in `shape_extensions`
proper (see follow-up #6). Don't take the snippet above as a
file-for-file description of today's fixture.

**`shape_extensions.dsl` (DSL internals)** — the decorator that marks a
function as a shape DSL function. Only used inside DSL definition files
(like `torch/_shapes.pyi`), not in normal stubs or user code:

```python
# shape_extensions/dsl.py

def shape_dsl_function(fn: Callable) -> Callable: ...
```

- **`shape_dsl_function`** — marks a function as a shape DSL function. The
  function body is converted to `DslFnDef` during binding. The function is
  exported normally. Whether it is an "IR function" (referenced by
  `@uses_shape_dsl`) or a "helper" (called only from other DSL functions via
  `fn_lookup`) is determined by usage, not by the decorator — the DSL engine
  makes no distinction between the two.
- **`uses_shape_dsl`** — a decorator applied to API functions in library stubs.
  At solve time, it produces a shape transforming callable type that
  references the specified DSL function.

### Stub file layout

```python
# torch/_shapes.pyi — torch-specific IR functions and helpers

from shape_extensions import Tensor, Dim
from shape_extensions.dsl import shape_dsl_function

@shape_dsl_function
def normalize_dim(rank: int, dim: int) -> int:
    if dim < 0:
        return dim + rank
    return dim

@shape_dsl_function
def broadcast(a: list, b: list) -> list:
    ...

@shape_dsl_function
def reshape_ir(self: Tensor, shape: list[int | Dim]) -> Tensor:
    ...  # same logic currently in DSL_SOURCE

@shape_dsl_function
def matmul_ir(self: Tensor, other: Tensor) -> Tensor:
    ...
```

```python
# torch/__init__.pyi — API stubs with @uses_shape_dsl decorators

from shape_extensions import Tensor, uses_shape_dsl
from torch._shapes import reshape_ir, matmul_ir

@uses_shape_dsl(reshape_ir)
def reshape(input: Tensor, shape: tuple[int, ...]) -> Tensor: ...

@uses_shape_dsl(matmul_ir)
def matmul(input: Tensor, other: Tensor) -> Tensor: ...
```

```python
# nn.Module example
from shape_extensions import uses_shape_dsl
from torch._shapes import maxpool_forward_ir

class MaxPool2d:
    @uses_shape_dsl(maxpool_forward_ir,
                capture_init=["kernel_size", "stride", "padding", "dilation"])
    def forward(self, input: Tensor) -> Tensor: ...
```

**Stub bodies caveat.** The DSL functions in `torch/_shapes.pyi` carry real
function bodies, which is unusual for `.pyi` files (typically bodies are
`...`). The Pyrefly binder distinguishes stub-from-non-stub mostly by file
extension rather than by body content, so this should be fine — but Phase 5
should verify that no stub-specific logic (interface module overload handling,
re-export semantics, etc.) gets confused by real bodies.

### Third-party extensibility

Libraries create their own shape DSL modules importing from
`shape_extensions` and `shape_extensions.dsl`. DSL functions can call
other `@shape_dsl_function`s from any module (see "Cross-module DSL
function calls" below).

```python
# mylib/_shapes.pyi — third-party shape DSL module
from shape_extensions import Tensor, Dim
from shape_extensions.dsl import shape_dsl_function

@shape_dsl_function
def custom_ir(x: Tensor, dim: int) -> Tensor:
    return Tensor(shape=[d for i, d in enumerate(x.shape) if i != dim])
```

```python
# mylib/__init__.pyi
from shape_extensions import uses_shape_dsl
from torch._shapes import reshape_ir
from mylib._shapes import custom_ir

@uses_shape_dsl(reshape_ir)
def my_reshape(x: Tensor, shape: tuple[int, ...]) -> Tensor: ...

@uses_shape_dsl(custom_ir)
def custom_op(x: Tensor, dim: int) -> Tensor: ...
```

## Architecture: Integration with Pyrefly's Phases

### Phase overview

The design integrates with Pyrefly's existing parse → export → bind → solve
pipeline. No new phases are needed.

```
Parse: torch/_shapes.pyi parsed by ruff → AST available during binding
                                          ↓
Export: shape_dsl_function and uses_shape_dsl recognized as SpecialExport
                                          ↓
Bind:  @shape_dsl_function detected on function defs
       → convert_fndef on the body → Binding::ShapeFunction
       API functions with @uses_shape_dsl → ordinary Binding::Function
       @uses_shape_dsl(..., capture_init=[...]) on methods → capture_init
         extracted syntactically and stored on BindingClassMetadata
                                          ↓
Solve: Binding::ShapeFunction → Type::Function with
                                 FunctionKind::ShapeDsl(func_id, dsl_function)
       Binding::Function + @uses_shape_dsl → SpecialDecorator::UsesShapeDsl
         produces a Type::Function whose FuncFlags carries the
         shape transform reference
       Class metadata solving → propagates capture_init from
                                 BindingClassMetadata to ClassMetadata
                                          ↓
       Call to torch.reshape → callable_infer_inner inspects the
                               function's FuncFlags for a shape
                               transform reference, evaluates the DSL
                               against bound_args, refines the return
                               type
```

### Step 1: Binding DSL functions

When the binder encounters a function decorated with `@shape_dsl_function`,
it converts the function body to DSL IR and stores it on the function's
binding so the solver can produce `FunctionKind::ShapeDsl`.

1. Detect the `@shape_dsl_function` decorator via `SpecialExport` before
   the decorator list is consumed by `decorators()`.
2. Call `convert_shape_dsl_function(&x)` (the Phase 2 wrapper API) to
   produce a `ShapeDslFunction`. This must be done *before* `function_body`
   consumes the body via `mem::take`.
3. Store the result as `shape_dsl_def: Option<Arc<ShapeDslFunction>>` on
   `BindingUndecoratedFunction`. The normal `Binding::Function` chain
   remains intact — the function still gets its ordinary name binding,
   decorator processing, and callable signature. The DSL definition is
   an additional payload that the solver uses to choose
   `FunctionKind::ShapeDsl` over `FunctionKind::Def`.
4. If `convert_shape_dsl_function` fails, panic. This matches the current
   behavior (the existing `parse_dsl` call site uses `.expect()`). Graceful
   error handling is deferred to Phase 7 (see below).

**Why binding, not solve:** `BindingUndecoratedFunction` does not store the
function body — the body is consumed during binding (via `mem::take`) and
then dropped. We *must* convert IR functions to `DslFnDef` during binding
before the body is discarded.

**Name binding interaction.** Because the DSL definition is stored on
`BindingUndecoratedFunction` (not as a separate binding variant), the
function's name resolves through the normal `Binding::Function` chain.
The solver produces a `Type::Function` with `FunctionKind::ShapeDsl`
when `shape_dsl_def` is `Some`, so imports like
`from torch._shapes import normalize_dim` resolve to the shape-DSL type
automatically.

**Same-module sibling discovery (for helper resolution).** Deferred until
Phase 5, when stubs with cross-function DSL calls actually exist. When
needed, a per-module index of shape-function bindings can be added to
avoid full bindings scans.

### Step 2: Decorator evaluation for API functions

Add `FunctionKind::UsesShapeDsl` (no payload) so that calling
`uses_shape_dsl(...)` produces `Type::KwCall`, making the decorator
identifiable at solve time. Add `UsesShapeDsl` to the `SpecialDecorator`
enum in `alt/types/decorated_function.rs`.

**Binding-time argument extraction.** When the binder processes a function
def, it inspects the decorator list. For each decorator whose callee resolves
(via `SpecialExport`) to `uses_shape_dsl`, the binder extracts the
IR-function identifier from the decorator call AST
(`@uses_shape_dsl(reshape_ir)` → identifier `reshape_ir` as a bare `Name`).
The argument is required to be a bare name; arbitrary expressions are not
supported in V1. The `Name` and its `ShortIdentifier` (carrying the
`TextRange` needed for `Key::BoundName` lookup) are stored as
`uses_shape_dsl_ir_name: Option<(Name, ShortIdentifier)>` on
`BindingUndecoratedFunction`.

The same binding-time pass extracts `capture_init` from the same decorator
call, using the precedent set by `pydantic_before_validator_fields`.

**Solve-time decorator handling.** At solve time, the `@uses_shape_dsl(...)`
decorator is recognized as a `KwCall` with `FunctionKind::UsesShapeDsl` in
`get_special_decorator`, and consumed by `set_flag_from_special_decorator`
(returns `true` to filter it out of the decorator list, preventing the
generic decorator pipeline from calling `Callable` on the function and
producing `Any`).

The actual `FuncFlags.shape_transform` is populated after the decorator
loop in `undecorated_function`, where `uses_shape_dsl_ir_name` is available.
The `ShortIdentifier` is resolved via `self.get(&Key::BoundName(...))`
to get the IR function's type, and the `ShapeDslFunction` is extracted from
its `FunctionKind::ShapeDsl(_, dsl_fn)` variant. If the name doesn't
resolve to a shape DSL function (user error), the code silently no-ops;
Phase 7 will add diagnostics.

The shape transform reference is carried on `FuncFlags`, alongside flags like
`dataclass_transform_metadata` and `deprecation`. This placement is what
makes overload merging work transparently (see "Overload handling" below).

**Why `FunctionKind::UsesShapeDsl` is needed.** Without a `FunctionKind`,
`uses_shape_dsl(reshape_ir)` returns `Callable` (per its stub signature),
and `Decorator.ty` becomes an unidentifiable `Callable`. The generic
decorator pipeline would then try to call `Callable` on the function,
producing `Any`. `FunctionKind::UsesShapeDsl` enables `KwCall` production,
which makes the decorator identifiable in `get_special_decorator`.

**Why `ShortIdentifier` rather than `Idx<Key>`.** Pyrefly's binding lookup
(`Key::BoundName`) is range-based via `ShortIdentifier`, not name-based. A
plain `Name` cannot be used to look up a binding at solve time. Resolving to
an `Idx<Key>` at binding time was considered but rejected because (a) name
resolution at binding time has side effects (marking imports as used), and
(b) `KwCall` doesn't store positional arguments. Storing the
`ShortIdentifier` defers actual resolution to solve time while providing the
range needed for the lookup.

### Overload handling

Today the registry is keyed by qualified name, so a single shape function
applies to all overloads. The DSL functions are written with union-typed
parameters that subsume every overload's parameter space and branch on
`isinstance`/`None` at evaluation time. The migration preserves this.

**Where to place `@uses_shape_dsl`:** On the *implementation* definition (the
non-`@overload` definition), not on individual overloads. This works because
`merge_overload_metadata_with_implementation` takes the implementation's
`FuncMetadata` as its base. With `shape_transform` living on `FuncFlags`,
the reference is carried through automatically — exactly like
`dataclass_transform_metadata` is today. In stub files that lack an
implementation definition (only `@overload` definitions), place `@uses_shape_dsl`
on the *first* overload; `merge_overload_metadata_no_implementation` takes
the first overload's metadata as its base.

`merge_overload_metadata_*` currently has explicit special-case handling for
`dataclass_transform_metadata` and `deprecation`. `shape_transform` is added
as an analogous field on `FuncFlags`. The merge functions already select the
correct base (implementation or first overload), and the decorator pipeline
runs on that base before merging — so the shape transform reference is
already baked into the `FuncFlags` that becomes the merged function's
metadata. No new logic is required in the merge functions themselves.

Per-overload shape dispatch (different IR functions per overload) is
explicitly **out of scope**. It could be added later by extending the merge
functions to also preserve per-branch `shape_transform` values when present.

### `capture_init` and `nn.Module` wrapping

For `nn.Module` subclasses, `capture_init` specifies which `__init__`
parameters to capture for shape inference on `forward`.

**Where `capture_init` is extracted:** At *binding time*, syntactically, using
the same pattern as `pydantic_before_validator_fields`. During
`class_def_inner`, scan the class body for a `def forward` whose decorator
list contains `@uses_shape_dsl(..., capture_init=[...])`. Extract the list of
string literals from the decorator call AST and store it as
`capture_init: Option<Vec<Name>>` on `BindingClassMetadata`.

This avoids the cross-cutting access that would otherwise be required — the
class-metadata solver does not have direct access to method-level decorator
ASTs (its `decorators` field carries *class*-level decorators). Doing the
extraction at binding time keeps the data flow clean: binder produces it,
solver consumes it, exactly as `pydantic_before_validator_fields` does.

**Storage on solved metadata:** Add `capture_init: Option<Vec<Name>>` to
`ClassMetadata` (the solved answer type) and propagate it from
`BindingClassMetadata` during `class_metadata_of`. Set a `None` default in
`ClassMetadata::recursive()` for cycle-breaking.

**Consumption:** `maybe_wrap_nn_module` reads `capture_init` from the
class's solved `ClassMetadata` instead of from
`TensorOpsRegistry::get_init_capture`. The `NNModule` wrapping and
`inject_module_attrs` logic is unchanged.

**Inheritance:** V1 preserves the existing no-MRO-walk behavior. Today's
registry is keyed by qualified class name, and a subclass like
`class MyMaxPool(MaxPool2d): pass` is not wrapped as `NNModule`. V1
preserves this: `capture_init` metadata is read only from the constructed
class itself. MRO traversal is a natural follow-up — once `capture_init`
lives on class metadata, walking the MRO becomes a small change — but is
deferred to keep the migration behavior-preserving.

### Cross-module DSL function calls

A DSL function in one module can call a `@shape_dsl_function` from another
module. For example, `mylib/_shapes.pyi` can import and call `normalize_dim`
from `torch/_shapes`. This is supported in V1 because Pyrefly's
binding-centric resolution makes it essentially free.

**`fn_lookup` is per-calling-function, built from the caller's local scope.**
The `DslFnDef` body uses `DslCallTarget::UserDefined(name)` where `name` is
the name as it appears in the source. When the solver builds `fn_lookup` for
a given DSL function, it resolves each `UserDefined(name)` against that
function's local scope using normal name resolution:

- If `name` resolves to a sibling `Binding::ShapeFunction` in the same module,
  the resolved `DslFnDef` is included under that local name.
- If `name` resolves to an imported `Binding::ShapeFunction` (in any other
  module, possibly through a re-export chain), the resolved `DslFnDef` is
  included under the local name that the import introduced.

Because `fn_lookup` is constructed per calling function from its local scope,
**bare-name collisions across modules are not possible** — two different
modules can both define `normalize_dim` without conflict, since neither
caller's `fn_lookup` ever contains both. Each caller's lookup is keyed by
the names visible to that caller.

**Validation:** `type_check_program` runs per-calling-function on the slice
`[self_dsl_def, ...transitively_resolved_callees]`. The signature map it
builds is derived from that same slice, so cross-module callees are validated
the same way as same-module ones.

**Cache invalidation works automatically.** Resolving each call target uses
solver answer lookups, which create dependency edges. If a helper changes
(in any module), every DSL function whose `fn_lookup` includes it is
automatically invalidated and recomputed.

**Circular DSL calls are unsupported.** If DSL function A calls B and B calls
A, the solver's existing cycle detection will produce a cycle error. Today's
`DSL_SOURCE` has a DAG with max depth 3 (no IR↔IR calls and no cycles among
helpers); we make no attempt to support cycles in V1.

**Initial migration shape.** The current `DSL_SOURCE` is a single flat
namespace (~50 IR functions and 14 helpers). The initial migration preserves
this by putting everything in one `torch/_shapes.pyi`, but the architecture
supports splitting into multiple modules from day one.

### Type representation

No new top-level `Type` variant is introduced. Both shape-related concepts
are represented as `Type::Function` values, distinguished by `FunctionKind`
and by an optional field on `FuncFlags`.

**Shape transform definition** — the type of a `@shape_dsl_function`-
decorated function (e.g. `reshape_ir` as defined in `torch/_shapes.pyi`).
This is analogous to a `TypeAlias` declaration: it declares a callable-shaped
type-level transformation whose return-type computation cannot be written in
closed-form Python type syntax.

Representation: a `Type::Function(Function { signature, metadata })` where
`metadata.kind` is `FunctionKind::ShapeDsl(Arc<FuncId>, Arc<ShapeDslFunction>)`:
- `signature: Callable` is the declared callable signature from the stub
  (useful for hover/IDE/assignability against `Callable[...]`).
- `FuncId` provides identity (module, class, name) for display and lookup,
  mirroring the existing `FunctionKind::Def(Arc<FuncId>)` pattern.
- `ShapeDslFunction` carries the parsed DSL IR (`DslFnDef`), opaquely.

The DSL definition is embedded in the `FunctionKind` variant rather than as
a separate `dsl_def: Option<Arc<DslFnDef>>` field on `Function`. This
enforces the invariant by construction (the DSL ref exists exactly when the
kind is `ShapeDsl`) and avoids adding a per-`Function` `Option<Arc<_>>`
field that would be `None` for every non-shape function — a design
refinement that emerged during implementation. `ShapeDslFunction` carries
custom pointer-identity `Hash`/`Eq`/`Ord` impls and no-op `Visit`/`TypeEq`
impls (DSL IR contains no `Type` values).

The `fn_lookup` (resolved helpers) is *not* embedded in the type — it is
computed by the solver when building the answer (see "Helper resolution")
and effectively re-derived from solver answers on demand. Cache invalidation
is handled by the solver's dependency tracking, not by embedding lookups in
the type tree.

**Shape transforming callable** — the type of a function decorated with
`@uses_shape_dsl(...)` (e.g. `torch.reshape` after decorator application).

Representation: a `Type::Function` whose `FuncFlags` carries
`shape_transform: Option<Arc<ShapeTransformRef>>` (a new field on
`FuncFlags`, alongside `dataclass_transform_metadata` and `deprecation`).
The `signature` is the API function's ordinary callable signature; the
`shape_transform` field is additive metadata indicating "when this function
is called, route the bound arguments to this shape transform definition for
return-type refinement".

`ShapeTransformRef` carries enough information to evaluate the DSL — a
direct reference (or pointer to the answer) for the shape-DSL `Function` it
refers to. The exact storage (raw `Arc<DslFnDef>` vs. answer pointer) is an
implementation detail.

**Why `FuncFlags` rather than a `Callable` field.** Three reasons:

1. **Overload merging works for free.** `merge_overload_metadata_*` operates
   on `FuncMetadata`, and the decorator pipeline runs on the selected base.
   Putting the reference on `FuncFlags` gets it through overload merging
   without changes to merge logic.
2. **No bloat on anonymous callables.** `Type::Callable` is the structural
   callable type used in many positions; adding a field to it would grow
   every callable's footprint. `Function` is named functions only.
3. **Follows existing precedent.** `dataclass_transform_metadata` and
   `deprecation` are already on `FuncFlags`, so this is the canonical place
   for "this function carries an extra type-system behavior".

**This is the recommended starting point, not a one-way door.** If during
implementation we discover that `FuncFlags` is the wrong placement — for
example because shape-transforming callable values need to flow through
positions that only carry `Callable` (not `Function`) — we can revisit and
switch to a wrapper type (`Type::ShapeTransformingCallable(Box<Type>,
ShapeTransformRef)`) without disturbing the rest of the architecture.

### Helper resolution

When the solver answers a `Binding::ShapeFunction` and needs to build the
DSL evaluator's `fn_lookup` for it, it does so eagerly but per-function.

**Procedure:**

1. Take the calling function's `DslFnDef.body` and collect the set of
   `DslCallTarget::UserDefined(name)` referenced anywhere within it.
2. For each `name`, resolve it through normal name resolution in the calling
   function's scope:
   - Same-module sibling: look it up via the per-module index of
     `Binding::ShapeFunction` entries built at binding time.
   - Imported / cross-module: resolve via the normal name binding, which
     yields a `Binding::ShapeFunction` (possibly in another module). Read
     that binding's answer to get the helper `DslFnDef`.
3. Recurse on the resolved helpers to gather transitive callees.
4. Build `fn_lookup: HashMap<String, Arc<DslFnDef>>` keyed by the local
   name each callee appears under in the body's source.
5. Run `type_check_program` on the slice
   `[self_dsl_def, ...transitively_resolved_callees]` to validate.
6. Store the resulting `fn_lookup` alongside the answer (it is what
   `DslMetaShapeFunction::evaluate` will need at call sites).

**Cache invalidation:** Each solver lookup in step 2 creates a dependency
edge. If `normalize_dim` changes, every DSL function whose `fn_lookup`
includes it is automatically re-solved by the answer system. This works
identically for same-module and cross-module helpers.

**Why eager rather than lazy:** A lazy approach (store unresolved string
references, resolve at call-site evaluation time) would do the lookups
outside the solver's dependency tracking. If `normalize_dim` changes but the
caller's `DslFnDef` is structurally unchanged, nothing would invalidate the
caller's answer — producing stale results. Eager per-function resolution
keeps the dependency explicit in the answer graph.

**Recursive structure note.** This procedure intentionally avoids a
"definition depends on the full closure of every other definition" structure.
Each `Binding::ShapeFunction` answer reads only its own transitive callees'
`DslFnDef`s, not their full `fn_lookup`s. Sibling functions in the same
module that the caller doesn't actually use are not pulled in, so editing
an unrelated DSL function in the same module does not invalidate this
caller.

### Solver consumption

By the time `callable_infer_inner` runs, the decorator pipeline has already
produced the function's type. If `@uses_shape_dsl` was applied, that type is a
`Type::Function` whose `FuncFlags.shape_transform` is `Some(_)`.

1. **Inspect `FuncFlags.shape_transform`.** If it is `Some(_)`, run normal
   argument binding against the callable signature, populating
   `bound_args: Option<HashMap<String, Type>>`. The `Option` wrapper is
   allocated only when a shape transform is present, preserving the current
   zero-cost path for non-shape calls. This replaces the qualified-name
   `lookup_meta_shape` call.

2. **Evaluate the DSL.** Build a `DslMetaShapeFunction` from the
   `ShapeTransformRef` (resolving the shape-DSL `Function`'s DSL definition
   from its `FunctionKind::ShapeDsl` variant plus its associated `fn_lookup`
   from the solver answer system) and call its
   `evaluate(bound_args, ret_type)` method, which routes through the
   unchanged `bind_dsl_params` → `eval_dsl_body` → `val_to_type` chain.

3. **`capture_init` handling.** `maybe_wrap_nn_module` reads `capture_init`
   from the class's solved `ClassMetadata` instead of from
   `TensorOpsRegistry::get_init_capture`. The `NNModule` wrapping and
   `inject_module_attrs` logic is unchanged.

### Error handling

**During initial migration (Phases 1–6):** Error handling preserves the
current panic behavior. `convert_fndef` failures, `type_check_program`
failures, and `eval_dsl_body` failures all panic, matching the existing
`.expect()` and `unreachable!()` call sites. This is acceptable because
the initial migration moves already-validated DSL code from `DSL_SOURCE`
into stubs — no new error paths are exercised.

**Phase 7 (graceful errors):** Once the happy path works, replace panics
with diagnostics. This covers four failure modes:

- `convert_fndef` failure (unsupported Python syntax in a
  `@shape_dsl_function` body) → emit a diagnostic at the function
  definition, produce `Type::Any` with error context.
- Invalid `@uses_shape_dsl` argument (decorator argument doesn't resolve to a
  shape-DSL `Function`) → emit a diagnostic at the decorator, fall back to
  the undecorated callable type.
- `type_check_program` / `eval_dsl_body` failures → emit diagnostics
  rather than panicking.
- DSL functions using parameter kinds not yet supported by `convert_fndef`
  (`*args`, `**kwargs`, keyword-only) → emit a clear diagnostic explaining
  the supported DSL parameter subset, instead of silently dropping them.

Error messages from `convert_fndef` are currently terse
`Result<_, String>` — Phase 7 should improve these to include `TextRange`
spans and explain the supported Python subset.

**Shape evaluation errors** (the user passes bad shapes at a call site)
are already handled gracefully and reported at the call site:

```
error[invalid-argument]: shape error: can only specify one unknown dimension as -1
  --> user_code.py:10:5
   |
10 |     x.reshape(-1, -1)
   |     ^^^^^^^^^^^^^^^^^
```

Enhancement: attach a secondary diagnostic span pointing to the `raise` in
the DSL function definition, enabling "Go to Definition" on the error
condition.

## What Stays the Same

- **The DSL language itself.** The restricted Python subset — `DslFnDef`,
  `DslBody`, `DslExpr`, `Val`, etc. — is unchanged. IR functions written for
  `DSL_SOURCE` move verbatim into `torch/_shapes.pyi`.

- **The interpreter.** `eval_dsl_body`, `bind_dsl_params`, `val_to_result_type`
  — all unchanged.

- **DSL builtins.** `Len`, `Range`, `Prod`, `Sum`, `Str`,
  `ParseEinsumEquation`, `Enumerate`, and `Zip` remain as `DslBuiltin` enum
  variants recognized during `convert_fndef`. They are intrinsics, not
  import-resolved. (Originally named `torch_shapes.*`, renamed to
  `shape_extensions.*` in Phase 1.)

- **`NNModule` type wrapping.** The `Type::NNModule` representation (holding a
  `ClassType` plus `SmallMap<Name, Type>` of captured fields) and
  `inject_module_attrs` logic are unchanged. Only the *source* of the capture
  list changes.

- **The top-level `Type` enum.** No new top-level `Type` variant is added.
  Both shape concepts ride on `Type::Function`.

## What Changes

| Component | Before | After |
|-----------|--------|-------|
| Framework module | `torch_shapes` (torch-specific) | `shape_extensions` (library-agnostic) |
| IR function source | `DSL_SOURCE` string in Rust | `torch/_shapes.pyi` stub file |
| DSL function detection | Implicit (heuristic / registry) | Explicit (`@shape_dsl_function` decorator) |
| Op-to-IR mapping | Hardcoded `register*()` calls (~131 entries) | `@uses_shape_dsl` decorator on API stubs |
| AST-to-IR conversion | `parse_dsl` (parse text + convert + type-check) | `convert_fndef` during binding; `type_check_program` per-function when solver answers a `Binding::ShapeFunction` |
| IR storage | `OnceLock<TensorOpsRegistry>` (×2) | `Binding::ShapeFunction` → `Type::Function` with `FunctionKind::ShapeDsl(func_id, dsl_function)` |
| API registration | Hardcoded registry calls | `@uses_shape_dsl` → `Type::Function` with `FuncFlags.shape_transform: Some(_)` |
| Init captures | `TensorOpsRegistry::init_captures` | `capture_init` field on `BindingClassMetadata` → `ClassMetadata` |
| Detection trigger | Qualified name lookup via `FunctionKind` | `FuncFlags.shape_transform` on the function's `Type::Function` |
| Cache management | Two `OnceLock` statics | Implicit: state lives in the type system's per-binding answers |
| `Dim` source | `shape_extensions.Dim` (hardcoded, library-agnostic; originally `torch_shapes.Dim`) | unchanged |

## Migration Plan

**Standing rules** (apply to every commit in the migration stack, not just
to the final state):

1. **All tests green.** Not just `buck test pyrefly:pyrefly_library`, but
   the full set of tensor_shapes test targets — annotation runtime tests,
   model runtime tests, jaxtyping tests, and the type-checking integration
   tests. The end-to-end tests are the primary validation that each
   intermediate state is sensible. Run them before committing each
   commit, not just at the end of the stack.
2. **Clean lint.** `arc f` (formatter) and `arc lint -a` must run clean.
   This matters more than usual during the migration because intermediate
   states may have temporarily-unused symbols (Phase 4 introduces
   wrappers Phase 5 consumes, Phase 5 lands decorators Phase 6 cleans
   up, etc.). Catch dead-code warnings before they accumulate; either
   suppress them with a justified `#[allow(dead_code)]` plus comment, or
   restructure the commit boundary.
3. **Minimum-necessary visibility.** Prefer the most restrictive
   visibility that compiles. When an item only has callers within its
   own module, keep it private (no `pub`/`pub(crate)`). Only promote to
   `pub(crate)` if a sibling module in `pyrefly_types` (or elsewhere
   in-crate) actually needs to name the item. Only promote to `pub` for
   items that are part of the documented cross-crate public surface
   (e.g. the Phase 2 wrappers). Whenever a refactor removes the last
   cross-module caller of a `pub(crate)` item, reduce it back to
   private in the same commit.
4. **No `// ===...===` section-divider comments.** They visually
   resemble merge conflict markers (`<<<<<<<`, `=======`, `>>>>>>>`)
   and add friction during conflict resolution and merge tooling. Use
   ordinary doc comments / module-level rustdoc for grouping. This
   applies to all languages — Python `# ===...===` blocks too.
5. **Independent per-commit review.** Each commit in the stack gets
   reviewed by an independent subagent (different from the one that
   wrote the commit) before the next commit lands on top of it.
   Reviewers should check for: spec adherence, dead code, leakage of
   internal types into public surfaces, missing tests, and any premature
   complexity that anticipates later phases. Reviewers do NOT modify
   code — they report findings.

### Phase 1: `shape_extensions` package and `SpecialExport` plumbing (DONE)

**Goal:** Establish `shape_extensions` as the canonical framework module,
with the public API in `shape_extensions` and DSL internals in
`shape_extensions.dsl`. Register both decorators as `SpecialExport`
variants so later phases can detect them during binding.

This was a 5-commit substack:

1. **Rename `torch_shapes` → `shape_extensions`.** The name follows the
   established convention for typing extension modules
   (`typing_extensions`, `pyre_extensions`, `ty_extensions`). Pure
   mechanical rename: moved the fixture, updated ~87 test files, updated
   all Rust hardcoded references, website stubs/docs, and BUCK targets.
2. **Add `uses_shape_dsl` to `shape_extensions`.** Runtime no-op decorator
   with type annotations. Registered `UsesShapeDsl` as a `SpecialExport`
   variant with `defined_in` returning `shape_extensions`.
3. **Add `shape_extensions.dsl` submodule.** Created
   `shape_extensions/dsl.py` with the `shape_dsl_function` no-op
   decorator. Registered `ShapeDslFunction` as a `SpecialExport` variant
   with `defined_in` returning `shape_extensions.dsl`.
4. **Add DSL builtins to `shape_extensions.dsl`.** Added `prod`, `sum`,
   `parse_einsum_equation` stub definitions. Updated DSL builtin prefix
   from `shape_extensions.*` to `shape_extensions.dsl.*` in Rust string
   matching and `DSL_SOURCE`. Fixed `convert_call` to support multi-level
   dotted names.
5. **Add `import shape_extensions.dsl` to `DSL_SOURCE`.** Makes the DSL
   source look like a normal Python module; the import is silently skipped
   by `parse_dsl` but will be meaningful once the code moves to stubs.

Both `SpecialExport` variants (`UsesShapeDsl`, `ShapeDslFunction`) have
no consumer yet — this is intentional. Phases 3 and 4 will consume them.

### Phase 2: Public shape-DSL API in `pyrefly_types`

**Goal:** Make the DSL conversion/evaluation machinery callable from
`pyrefly/lib/binding` and `pyrefly/lib/alt` without exposing DSL internals
(`DslFnDef`, `DslBody`, etc.) as public surface.

**Commit shape:** One commit for the wrapper API. Optionally a second
commit that refactors `tensor_ops_registry::new()` to use the new wrappers
(dogfood — validates the API works end-to-end before Phase 3 depends on
it).

**Starting state** (verified):
- `pyrefly_types::meta_shape_dsl` is already `pub mod` in `lib.rs:35`, so
  cross-crate visibility work is item-level only.
- `convert_fndef` (line 1374), `type_check_program` (line 1908),
  `bind_dsl_params` (line 2032), `eval_dsl_body` (line 2806) are all
  private (no visibility modifier).
- `parse_dsl` (line 1925) is `pub(crate)` — its in-crate caller is
  `tensor_ops_registry.rs`.
- `DslFnDef` (line 565) is `pub(crate) struct` with only `name` field
  `pub(crate)`; `params`, `return_type`, `body` are private.
- `DslMetaShapeFunction` (line 3052) is `pub(crate) struct`.
- `MetaShapeFunction` trait is already `pub`.
- External consumers today: `pyrefly/lib/alt/callable.rs` (imports
  `MetaShapeFunction`, `TensorOpsRegistry`) and `pyrefly/lib/alt/call.rs`
  (imports `TensorOpsRegistry`). Phase 2 does not touch these.

**Wrapper types (the public surface):**

```rust
// New public types in pyrefly_types::meta_shape_dsl

pub struct ShapeDslFunction {
    pub(crate) inner: Arc<DslFnDef>,
}

pub struct ShapeDslProgram {
    pub(crate) fns: Vec<Arc<DslFnDef>>,
}
```

`ShapeDslFunction` is a cheap (one `Arc`) opaque handle around a single
converted DSL function. `Arc<DslFnDef>` is not exposed publicly — it's
`pub(crate)` so the rest of `pyrefly_types` (notably `tensor_ops_registry`)
can still reach in.

**Constructors and factory:**

```rust
// Convert one function from AST. Used by the binder (Phase 3).
pub fn convert_shape_dsl_function(
    func: &ruff_python_ast::StmtFunctionDef,
) -> Result<ShapeDslFunction, String>;

// Validate a bundle of functions as a program. Panics today on
// type-check failure, matching parse_dsl's current behavior; Phase 7
// converts this to a Result.
pub fn build_shape_dsl_program(
    fns: impl IntoIterator<Item = ShapeDslFunction>,
) -> ShapeDslProgram;

// Factory: given a program plus the root function's name, construct
// a MetaShapeFunction that callable_infer_inner can invoke.
pub fn make_meta_shape_function(
    program: &ShapeDslProgram,
    root_name: &str,
) -> Option<Box<dyn MetaShapeFunction>>;
```

The factory taking a `ShapeDslProgram` (not raw pieces) ensures callers
cannot construct a `MetaShapeFunction` from un-type-checked DSL.

**Design notes:**

1. **Keep panics for now; don't anticipate Phase 7.** `type_check_program`
   panics today on type errors. The Phase 2 wrapper preserves this — the
   public function name is `build_shape_dsl_program` (no `Result`)
   matching today's `parse_dsl` semantics. Phase 7 redesigns error
   handling end-to-end; doing the `Result` conversion now would spread
   that work across phases.
2. **`fn_lookup` keys are caller-local names.** The `MetaShapeFunction`
   factory's internal `fn_lookup` is keyed by the *local* names the
   caller's DSL body uses (e.g. if the caller imports `normalize_dim as
   norm_dim`, the lookup key is `norm_dim`). Phase 3 will populate the
   program with `[self_dsl_fn, ...resolved_callees]` where each callee's
   `name` field has been rewritten (or annotated) to match its
   caller-local name. The Phase 2 API doesn't need to do this rewriting
   itself — it just needs to accept programs where this is already the
   case. Document that constraint in the public API.
3. **Don't leak `Arc<DslFnDef>` into the public signature.** Every public
   entry point takes/returns `ShapeDslFunction` or `ShapeDslProgram`,
   never `Arc<DslFnDef>` directly. Phase 3 (`Binding::ShapeFunction`)
   stores `Arc<ShapeDslFunction>`, not `Arc<DslFnDef>`.
4. **Visibility changes to existing items.** Promote only what is
   actually needed. Items that only have intra-module callers should
   stay private. If a sibling module in `pyrefly_types` needs to reach
   in, promote to `pub(crate)`. Do not pre-promote "just in case" —
   that creates dead visibility. (Standing rule #3 in the migration
   plan.)
5. **`tensor_ops_registry.rs` dogfood (recommended second commit).**
   Today `TensorOpsRegistry::new()` calls `parse_dsl(DSL_SOURCE)`
   internally. If we change it to use the new public API
   (`parse_dsl` → list of `ShapeDslFunction` → `build_shape_dsl_program`
   → `make_meta_shape_function` per registered name), we (a) prove the
   API works end-to-end before Phase 3 depends on it, and (b) shrink the
   number of code paths through the DSL engine. `parse_dsl` can either
   be deleted at that point or kept as a convenience that internally
   calls the new wrappers.

### Phase 3: Binding infrastructure

**Goal:** The binder recognizes `@shape_dsl_function` and produces
`Binding::ShapeFunction`; class binding extracts `capture_init`
syntactically.

**Commit shape:** Four commits, ordered for reviewability. Each commit
compiles and passes tests independently; none adds user-visible behavior
until Phase 4 wires up the solver consumption.

**Commit 3a: `capture_init` plumbing.** Independent of the other three
commits — pure data threading following the `pydantic_before_validator_fields`
precedent.

1. Add `capture_init: Option<Vec<Name>>` to `BindingClassMetadata`. In
   `class_def_inner`, scan the class body for `def forward` whose decorator
   list contains `@uses_shape_dsl(..., capture_init=[...])`, extract the string
   literals from the decorator call AST, and populate this field.
2. Add `capture_init: Option<Vec<Name>>` to `ClassMetadata` (the solved
   answer type), with `None` default in `ClassMetadata::recursive()`. In
   `class_metadata_of`, propagate `capture_init` from `BindingClassMetadata`
   to `ClassMetadata`.

**Commit 3b: Type representation.** Small, self-contained.

3. Add `FunctionKind::ShapeDsl(Arc<FuncId>, Arc<ShapeDslFunction>)` variant,
   mirroring `Def(Arc<FuncId>)` but also carrying the DSL definition. Add
   pointer-identity `Hash`/`Eq`/`Ord` and no-op `Visit`/`TypeEq` impls on
   `ShapeDslFunction`. Update `module_name()`, `function_name()`, `class()`,
   and `outer_funcs()` on `FunctionKind`.

**Commit 3c: Binder recognition + solver integration.** Detects
`@shape_dsl_function` at binding time and threads through to the solver.

Instead of adding a new `Binding::ShapeFunction` variant (which would
require updating ~6 files of exhaustive matches, new Key types, answer
maps, etc.), the implementation adds `shape_dsl_def:
Option<Arc<ShapeDslFunction>>` to `BindingUndecoratedFunction` and threads
it through the solver. The name resolves to a `Type::Function` with
`FunctionKind::ShapeDsl` — same end result, much less plumbing.

4. Add `shape_dsl_def: Option<Arc<ShapeDslFunction>>` field to
   `BindingUndecoratedFunction`. Update all construction sites (normal
   functions pass `None`).
5. In `function_def`, before `decorators()` takes the decorator list,
   check for `@shape_dsl_function` via `SpecialExport::ShapeDslFunction`.
   Before `function_body()` takes the body, call
   `convert_shape_dsl_function(&x)` to produce the DSL IR. Panic on
   conversion failure for now (Phase 7 replaces with diagnostics).
6. In the solver's `undecorated_function` method, when `shape_dsl_def` is
   `Some`, produce `FunctionKind::ShapeDsl(func_id, dsl_fn)` instead of
   calling `FunctionKind::from_name`.

Per-module indices for enumerating same-module DSL functions (needed for
`fn_lookup` building) are deferred until Phase 5, when stubs with
cross-function DSL calls actually exist.

**Commit 3d: `@uses_shape_dsl` binding-time extraction.** Depends on
commit 3c (needs `FunctionKind::ShapeDsl` to exist for resolver targets).

8. In `function_def`, before decorators are consumed, detect
   `@uses_shape_dsl(ir_fn)` (via `SpecialExport::UsesShapeDsl`). Extract
   the first positional argument as a `Name` and store it as
   `uses_shape_dsl_ir_name: Option<Name>` on `BindingUndecoratedFunction`.
   The name is stored rather than resolved to an `Idx<Key>` because name
   resolution at binding time has side effects (marking imports as used,
   etc.) and deferred resolution at solve time is cleaner. Phase 4 will
   resolve the name to a `Type::Function` with `FunctionKind::ShapeDsl`
   and extract the `ShapeDslFunction` from it. Silently ignores non-name
   arguments (Phase 7 will add a diagnostic).

### Phase 4: Decorator pipeline integration

**Goal:** `@uses_shape_dsl` decorators produce `Type::Function` values whose
`FuncFlags.shape_transform` is populated, and the solver consumes this field
at call sites (with fallback to the legacy registry for incremental migration).

**Commit shape:** Three commits (optionally four if 4c grows large).

**Commit 4a: Add `shape_transform` to `FuncFlags`.** Pure data plumbing.

1. Define `ShapeTransformRef` in `meta_shape_dsl.rs`. Carries
   `pub dsl_fn: Arc<ShapeDslFunction>` — the resolved DSL function, not a
   name or key. By the time 4b populates this field, the IR function name
   from Phase 3d has been resolved to a `Type::Function` with
   `FunctionKind::ShapeDsl(_, dsl_fn)`, so we store the extracted
   `ShapeDslFunction` directly. Trait impls follow the same pointer-identity
   pattern as `ShapeDslFunction` (`PartialEq/Eq/Hash/PartialOrd/Ord` delegate
   to inner, no-op `Visit/VisitMut`, `TypeEq` delegates to `PartialEq`).
   `Arc<ShapeTransformRef>` gets `Visit/VisitMut` impls (custom Pyrefly traits
   don't auto-derive through `Arc`).
2. Add `shape_transform: Option<Arc<ShapeTransformRef>>` to `FuncFlags`,
   placed after `dataclass_transform_metadata`. The `Default` derive gives
   `None` automatically — no construction site updates needed.

**Commit 4b: `UsesShapeDsl` decorator recognition + flag population.**

Design note: the plan originally said to follow the `DataclassTransformCall`
pattern, but that pattern requires two things `uses_shape_dsl` didn't have:
(1) a `FunctionKind` variant, and (2) `KwCall` production. Without these,
`uses_shape_dsl(reshape_ir)` returns `Callable` (per its stub signature),
and `Decorator.ty` becomes an unidentifiable `Callable`. The generic
decorator pipeline would then try to call `Callable` on the function,
producing `Any`. To fix this, 4b adds `FunctionKind::UsesShapeDsl`.

Additionally, `uses_shape_dsl_ir_name` was changed from `Option<Name>` to
`Option<(Name, ShortIdentifier)>` because Pyrefly's binding lookup
(`Key::BoundName`) is range-based via `ShortIdentifier`, not name-based.
A plain `Name` cannot be used to look up a binding at solve time.

3. Add `FunctionKind::UsesShapeDsl` variant (no payload). Wire into
   `from_name` for `("shape_extensions", None, "uses_shape_dsl")`. Update
   exhaustive matches: `module_name`, `function_name`, `class`.
4. Add `UsesShapeDsl` to `kw_metadata` check in `call.rs` so calling
   `uses_shape_dsl(...)` produces `Type::KwCall`.
5. Add `UsesShapeDsl` variant to `SpecialDecorator` enum.
6. Implement recognition in `get_special_decorator`: match `Type::KwCall`
   with `has_function_kind(FunctionKind::UsesShapeDsl)`.
7. Implement `set_flag_from_special_decorator` for `UsesShapeDsl`: returns
   `true` to consume the decorator (filtering it from the decorators list).
   The actual `shape_transform` flag is populated separately (see step 8).
8. In `undecorated_function`, after the decorator loop, resolve the
   `ShortIdentifier` from `uses_shape_dsl_ir_name` via
   `self.get(&Key::BoundName(ir_identifier))`. If it resolves to a
   `Type::Function` with `FunctionKind::ShapeDsl(_, dsl_fn)`, set
   `flags.shape_transform = Some(Arc::new(ShapeTransformRef { dsl_fn }))`.
   If it doesn't resolve to a shape DSL function (user error), silently
   no-ops — Phase 7 will add diagnostics.
9. Verify that `merge_overload_metadata_*` carries `shape_transform` through
   automatically. Confirmed: both merge functions operate on `FuncMetadata`
   which contains `FuncFlags`. The implementation's (or first overload's)
   metadata is the base, so `shape_transform` flows through via `clone()`.
   Per-overload shape dispatch (different IR functions per overload) remains
   explicitly out of scope.

**Commit 4c: Solver consumption with legacy fallback.**

7. Add `ShapeTransformRef::to_meta_shape_function()` in `meta_shape_dsl.rs`.
   Builds a `DslMetaShapeFunction` from the stored `ShapeDslFunction`,
   using an empty `fn_lookup` (cross-function DSL calls are Phase 5).
8. Update `callable_infer_inner` to prefer the decorator-based
   `shape_transform` over the legacy registry. If `shape_transform` is
   present, call `to_meta_shape_function()` and use the result; fall back
   to `lookup_meta_shape` only when `shape_transform` is `None`. The
   decorator path is intentionally not gated by the `tensor_shapes` flag —
   `@uses_shape_dsl` is itself the opt-in, unlike the registry which
   applies implicitly by qualified name and needs a feature gate.
9. Update `maybe_wrap_nn_module` to read `capture_init` from `ClassMetadata`
   first; fall back to `TensorOpsRegistry::get_init_capture` if `None`.
   Same incremental-migration rationale.

Implementation note: `convert_shape_dsl_function` must run *before*
`function_header` in the binder, because `function_header` consumes
`x.returns` via `mem::take`. The DSL converter needs the return type
annotation to produce `DslFnDef.return_type`. This ordering constraint
was discovered during 4c and the fix was folded into the 4c amend
(moving the call earlier in `function_def`).

**Commit 4d: Document `val_to_type` scalar branch semantics.**

The `DslType::Int` and `DslType::Bool` branches in `val_to_type` look
inconsistent with the other branches — they synthesize `Literal[n]` /
`Literal[bool]` from the DSL's traced runtime value, while Tensor/List/
Tuple/None/Str return `expected_return_type.clone()`. This asymmetry is
intentional and load-bearing:

- Functions like `dim_ir`, `numel_ir`, and `size_ir(dim=N)` trace exact
  integer results. Downstream consumers (assert_type, reshape validation,
  shape inference) rely on the literal precision — 16 existing tests in
  `tensor_shapes_all_test` assert `Literal[n]` results.
- The Tensor/List branches' `expected_return_type` already carries refined
  structure (e.g. `Tensor[B, C, H, W]` with shape injected). For scalars,
  the fixture return type is just `int` — the literal value comes solely
  from DSL evaluation.
- `DslType::SymInt` follows the same pattern via `val_to_scalar_type`,
  which returns `Literal[n]` for `Val::Int` and `Dim[X]` for `Val::Dim`.

This commit adds comments explaining the invariant so the asymmetry is
not mistaken for a bug. (An earlier version of this commit attempted to
"fix" the branches by returning `expected_return_type`, which caused 16
test regressions.)

### Phase 5: Torch stub migration

**Goal:** All shape functions move from `DSL_SOURCE` to stubs, with
fn_lookup infrastructure enabling helper resolution through the decorator
path.

**Commit shape:** Four commits, each keeping tests green.

**The fn_lookup problem.** Most IR functions call helpers (e.g.,
`reshape_ir` → `normalize_dim`, `movedim_ir` → `move_dims` →
`contains`/`scatter`/`broadcast_int`). Phase 4's `to_meta_shape_function`
uses an empty `fn_lookup`, which panics on any helper call. The registry
works because it builds fn_lookup from ALL functions in `DSL_SOURCE` at
once. Phase 5 must populate fn_lookup before the decorator path can replace
the registry for most functions.

**Key constraint:** fn_lookup must be built when solving `@shape_dsl_function`
(in the DSL module), not when solving `@uses_shape_dsl` (in the consumer
module). The consumer module imports only the IR function — helpers like
`normalize_dim` are private to the DSL module and can't be resolved from the
consumer's scope. The solver resolves names via `Key::BoundName(ShortIdentifier)`,
which requires being in the defining module's scope.

**Approach (Phase 5: all-siblings; replaced by Phase 7a with per-caller
resolution).** Add a per-module binding-time index of DSL function
definitions to `BindingsMetadata`. At `@shape_dsl_function` solve time,
query this index to collect **all** same-module siblings (every other
`@shape_dsl_function` in the same source file, regardless of whether the
current function actually calls them). Carry the sibling list through
`FunctionKind::ShapeDsl` so consumers in other modules can access it.
Build fn_lookup from self + siblings in `to_meta_shape_function`.

This was a deliberate shortcut for Phase 5. The architectural sections
("Helper resolution", "Cross-module DSL function calls") describe a
per-caller resolution scheme that walks each function's body for
`DslCallTarget::UserDefined` names, resolves them in the calling
function's scope, and stores only the transitive callees. Phase 7a
implements that design.

For Phase 5, fn_lookup includes ALL same-module DSL functions (matching the
registry's flat-namespace behavior).

**Commit 5a: Create `torch/_shapes.pyi`.** Pure file creation, no Rust
changes.

1. Create `test/tensor_shapes/fixtures/torch/_shapes.pyi` with all 86
   functions from `DSL_SOURCE`, verbatim. Add `@shape_dsl_function` decorator
   to each and the necessary imports (`from shape_extensions.dsl import
   shape_dsl_function`). The functions are:
   - 14 helpers: `normalize_dim`, `int_max`, `replace_dim`, `remove_dim`,
     `insert_dim`, `broadcast`, `broadcast_int`, `reduce_shape`, `contains`,
     `scatter`, `move_dims`, `conv_spatial_out`, `reduce_single`,
     `apply_einsum`
   - 72 IR functions: `reshape_ir`, `squeeze_ir`, ..., through
     `nn_reflectionpad2d_forward_ir`
2. No behavioral change — nothing references this file yet.

**Commit 5b: fn_lookup infrastructure.** The critical plumbing commit.

1. **`BindingsMetadata` (binding/metadata.rs):** Add a per-module list
   `shape_dsl_functions: Vec<(Name, Arc<ShapeDslFunction>)>` with a
   `push_shape_dsl(&mut self, name, dsl_fn)` method. This follows the
   existing `push_class` / `get_class` pattern. **Mark the field with a
   `TODO` comment pointing at Phase 7a** — in the per-caller design
   this index becomes one input to name resolution rather than the whole
   sibling snapshot.

2. **Binding-time population (binding/function.rs):** In `function_def`,
   when `is_shape_dsl` is true, push `(func_name, Arc::clone(&shape_dsl_def))`
   to the module's `BindingsMetadata`. This must happen after the
   `convert_shape_dsl_function` call (which produces `shape_dsl_def`).

3. **`FunctionKind::ShapeDsl` (types/function.rs):** Extend the variant to
   carry the siblings list, wrapped so it does not participate in derived
   identity comparisons:
   ```
   ShapeDsl(Arc<FuncId>, Arc<ShapeDslFunction>, Derived<Arc<Vec<Arc<ShapeDslFunction>>>>)
   ```
   Introduce a small `Derived<T>` wrapper in `pyrefly_types` whose
   `PartialEq`/`Eq`/`Hash`/`PartialOrd`/`Ord` impls are constants
   (`true` / `Ordering::Equal` / no-op hash) and whose `Visit`/`VisitMut`/
   `TypeEq` impls are no-ops. This keeps `FunctionKind`'s existing
   `#[derive(PartialEq, Eq, PartialOrd, Ord, Hash, Visit, VisitMut, TypeEq)]`
   intact: the derive machinery sees the wrapper, not the inner data, so
   no manual `FunctionKind` impls are needed and future variants don't pay
   a maintenance tax for this feature. Cache invalidation still works
   correctly: the solver's dependency-edge tracking re-solves dependents
   when a helper changes (it does not rely on the `Type`'s `Eq` reporting
   a difference). Update all exhaustive matches that destructure `ShapeDsl`.

4. **Solver wiring — DSL function side (alt/function.rs):** At
   `@shape_dsl_function` solve time (where `FunctionKind::ShapeDsl` is
   constructed), query `self.bindings().metadata.shape_dsl_functions` to
   collect all same-module siblings, wrap in `Derived<_>`, and store as the
   third element of `FunctionKind::ShapeDsl`. **Mark this site with a
   `TODO` comment pointing at Phase 7a** — it is one of the two
   places that will be replaced when we switch from all-siblings to
   transitive-callee resolution.

5. **`ShapeTransformRef` (meta_shape_dsl.rs):** Add
   `helpers: Derived<Arc<Vec<Arc<ShapeDslFunction>>>>` (using the same
   `Derived<T>` wrapper introduced in step 3). The wrapper preserves
   pointer-identity-style behavior automatically — equality and ordering
   delegate to `dsl_fn` only because the wrapper compares as
   `Ordering::Equal`. Matching `FunctionKind::ShapeDsl`, helpers are
   excluded from identity comparisons because they are derived data.
   **Mark the field with a `TODO` comment pointing at Phase 7a.** The
   field name `helpers` is also a misnomer that becomes accurate only
   after the follow-up replaces "all module siblings" with "resolved
   transitive callees"; the TODO should call this out.

6. **`to_meta_shape_function` (meta_shape_dsl.rs):** Update to build
   fn_lookup from `self.helpers` (which already includes self since it's
   all same-module siblings):
   ```
   fn_lookup = Arc::new(
       self.helpers.iter()
           .map(|h| (h.inner.name.clone(), h.inner.clone()))
           .collect()
   )
   ```

7. **Solver wiring — consumer side (alt/function.rs):** At `@uses_shape_dsl`
   resolve time (where `ShapeTransformRef` is constructed from the resolved
   IR function's type), extract helpers from `FunctionKind::ShapeDsl` and
   populate on `ShapeTransformRef`:
   ```
   if let FunctionKind::ShapeDsl(_, dsl_fn, helpers) = &func.metadata.kind {
       flags.shape_transform = Some(Arc::new(ShapeTransformRef {
           dsl_fn: dsl_fn.clone(),
           helpers: helpers.clone(),
       }));
   }
   ```

8. **Test:** Add a test in `shape_dsl.rs` where the IR function calls a
   helper, verifying fn_lookup works through the decorator path. Example:
   a `double_ir` function that calls a `times_two` helper.

**Commit 5c: Add `@uses_shape_dsl` to torch fixture stubs.** Decorator
wiring across all ~131 registered functions.

1. Add `from shape_extensions import uses_shape_dsl` and
   `from torch._shapes import <ir_fns>` to each fixture file.

2. **`torch/__init__.pyi`:** Module-level functions (`cat`, `reshape`,
   `stack`, `matmul`, `randn`, etc.) and `Tensor` methods (`reshape`,
   `view`, `squeeze`, `unsqueeze`, etc.). `register_dual` entries need
   `@uses_shape_dsl` on BOTH the module function and the `Tensor` method.

3. **`torch/nn/functional.pyi`:** Functional conv, pool, loss, pad,
   interpolate, cosine_similarity ops.

4. **`torch/fft.pyi`:** `rfft`, `irfft`, `hfft`, `ihfft`.

5. **`torch/linalg.pyi`:** `eig`, `eigvals`, `solve`, `slogdet`, etc.

**Verification:** Phase 4's `callable_infer_inner` prefers the decorator
path over the registry — the registry is NOT a fallback when
`shape_transform` is `Some`. This means any `@uses_shape_dsl` decorator
that fails (wrong IR function name, missing helper, etc.) shows up
immediately as a test failure, not a silent degradation. All existing
tensor_shapes tests validate correctness.

**Commit 5d: Add `@uses_shape_dsl(capture_init=[...])` to nn.Module
fixture stubs.**

`maybe_wrap_nn_module` already checks `ClassMetadata.capture_init()` first
with a `TensorOpsRegistry::get_init_capture` fallback — this was wired in
Phase 4c as part of the broader "decorator wins, registry as fallback"
plumbing. The remaining work is purely fixture-level: drop the
decorators on each `forward` method and the existing consumption path
picks them up.

1. Add `@uses_shape_dsl(ir_fn, capture_init=[...])` to the `forward` methods
   of all 15 nn.Module classes in `torch/nn/__init__.pyi`:
   - `MaxPool1d/2d/3d`: `capture_init=["kernel_size", "stride", "padding", "dilation"]`
   - `AvgPool1d/2d/3d`: `capture_init=["kernel_size", "stride", "padding"]`
   - `Flatten`: `capture_init=["start_dim", "end_dim"]`
   - `PixelShuffle`: `capture_init=["upscale_factor"]`
   - `GLU`: `capture_init=["dim"]`
   - `LSTM`: `capture_init=["input_size", "hidden_size", "num_layers", "bidirectional"]`
   - `Upsample`: `capture_init=["size", "scale_factor"]`
   - `GRU`: `capture_init=["input_size", "hidden_size", "num_layers", "bidirectional"]`
   - `LSTMCell`: `capture_init=["input_size", "hidden_size"]`
   - `ReflectionPad2d`: `capture_init=["padding"]`
   - `ReplicationPad2d`: `capture_init=["padding"]`

   The `capture_init` plumbing from binding (`extract_capture_init`)
   through `BindingClassMetadata` to `ClassMetadata`, and the consumption
   in `maybe_wrap_nn_module`, are both already in place (Phase 3a + Phase
   4c). This commit is purely fixture annotations — once added, the decorators
   override the registry path for each annotated class.

**Risk areas:**

- **Identity comparisons exclude the siblings list (by design):** The
  `Derived<T>` wrapper on `FunctionKind::ShapeDsl` and `ShapeTransformRef`
  makes the siblings list invisible to `Hash`/`Eq`/`Ord`. Two
  `ShapeTransformRef`s with the same `dsl_fn` but different helper bundles
  compare equal. This is intentional — helpers are derived data, and the
  solver invalidates dependents through its dependency-edge graph, not
  through answer-`Eq` differences. Implementers should NOT use these
  values as cache keys assuming behavioral equivalence implies `Eq`.

- **`type_check_program` skipped for stub path (deliberate Phase 5
  bypass):** Phase 2 (lines ~925) introduced the invariant that
  `MetaShapeFunction` construction must go through a type-checked
  `ShapeDslProgram`. Phase 5 intentionally bypasses this — `to_meta_shape_function`
  builds the lookup directly from `ShapeDslFunction.inner` values without
  re-running `type_check_program` — because the migrated functions are
  verbatim copies of already-validated `DSL_SOURCE` code, and re-running
  the program-level type checker on every call site would be expensive.
  This is a knowingly-temporary state. **The Phase 6 prerequisites list
  explicitly tracks restoring per-function `type_check_program`
  validation before registry deletion** — see Phase 6 prerequisites.

- **Solver dependency tracking granularity:** With the binding-time
  `BindingsMetadata` approach, if one DSL helper changes, the solver
  re-solves the whole module. This is coarser than per-function invalidation
  but acceptable for Phase 5 (all functions in one module). Cross-module
  helpers (Phase 6+) would need solver-level dependency edges.

- **86 real function bodies in `.pyi`:** Phase 4 confirmed that real bodies
  work in `.pyi` files, but the Phase 4 test had only 3 functions. 86
  functions with real bodies is a heavier load test. Monitor for any
  stub-specific logic that scales poorly or treats real bodies as ill-formed.

**Stub-body sanity check (carried from original plan):** Confirm during this
phase that nothing in Pyrefly's stub-specific logic (overload merging for
interface modules, re-export semantics, etc.) treats real bodies as
ill-formed.

### Phase 6: Cleanup (DONE)

**Goal:** Remove the old infrastructure. Validates Phase 5's completeness
— any missed decorator surfaces as a test failure.

**What was done (single commit):**

1. Deleted `tensor_ops_registry.rs` (1,022 lines): `DSL_SOURCE` string,
   `TensorOpsRegistry` struct, ~131 `register*()` calls, both `OnceLock`
   statics, `parse_dsl`, and the Phase 2 unit test.
2. Removed `lookup_meta_shape` in `callable.rs`.
3. Removed registry fallback in `callable_infer_inner` — decorator-only.
4. Removed registry fallback in `maybe_wrap_nn_module` — ClassMetadata-only.

**Result:** All tensor_shapes tests pass with zero registry code.
`tensor_shapes_all_test` validates that every previously-registered
function is covered by `@uses_shape_dsl` decorators.

**Remaining items (deferred, not prerequisites):**

- [ ] Per-function `type_check_program` validation in the stub path.
  Phase 5 bypasses this since functions are verbatim copies of
  already-validated `DSL_SOURCE` code. Phase 7a's per-caller resolution
  is the natural place to add this — `type_check_program` runs on the
  transitive-callee slice, not the full module.
- [ ] `FuncFlags`/`ClassMetadata` audit for `shape_transform`/`capture_init`
  preservation through cloning/merging/wrapping. Green e2e tests are
  strong evidence but not a formal audit.
- The `tensor_shapes` config flag remains — it gates non-registry behavior
  (Tensor subscript support, jaxtyping, operator overloads).
- Documentation for third-party library authors deferred to post-Phase 7.

### Phase 7a: Per-caller fn_lookup resolution

**Goal:** Replace the all-siblings fn_lookup shortcut from Phase 5 with
per-caller transitive-callee resolution. This determines the data
structures and traversal algorithms that Phase 7b's error handling builds
on top of.

**Problem.** Phase 5's fn_lookup includes ALL same-module DSL functions
in every `ShapeTransformRef`, regardless of whether the function actually
calls them. This has three costs:

1. **Memory / type-size bloat.** Every shape-DSL `Type::Function` and
   every `ShapeTransformRef` carries an `Arc<Vec<Arc<ShapeDslFunction>>>`
   pointing at the whole module roster. A leaf function like `randn_ir`
   (no helper calls) gets 85 siblings it never uses.
2. **Coarse cache invalidation.** Editing any DSL function in the module
   invalidates every consumer that touches *any* DSL function in that
   module, even unrelated ones.
3. **No alias support, no cross-module helpers.** The lookup is keyed by
   the declared name in the sibling list. `from foo import normalize_dim
   as nd; nd(...)` doesn't resolve.

**Approach.**

1. **Add `call_targets()` on `ShapeDslFunction`** — walks `DslBody` and
   `DslExpr` recursively, collecting every
   `DslCallTarget::UserDefined(name)` string into a `HashSet<String>`.
   This is a pure read-only traversal of the binding-time IR; the method
   lives in `pyrefly_types::meta_shape_dsl`.

2. **Resolve call targets at `@shape_dsl_function` solve time.** For each
   name returned by `call_targets()`, look it up in the per-module
   `BindingsMetadata.shape_dsl_functions` index (matching by `Name`).
   Same-module helpers resolve directly from the binding-time
   `Arc<ShapeDslFunction>` — no solver-level `Key::BoundName` lookup
   needed, since the binding-time object is the same one the solver would
   produce. (Cross-module resolution via the solver's normal name
   resolution is a natural extension but deferred until a concrete use
   case exists.)

3. **Compute the transitive closure.** Resolved helpers may themselves
   have call targets. Recurse until no new names appear. The DSL call
   graph is a DAG with max depth 3 (e.g., `movedim_ir` → `move_dims` →
   `contains`/`scatter`/`broadcast_int`), so the closure is small.

4. **Store only the closure** on `FunctionKind::ShapeDsl` and
   `ShapeTransformRef`, replacing the all-siblings snapshot. The
   `Derived<T>` wrapper stays.

5. **`to_meta_shape_function`** builds fn_lookup from helpers only
   (unchanged — helpers already includes self in the all-siblings case,
   and in per-caller case we include self explicitly in the closure).

**Expected results for torch/_shapes.pyi (86 functions):**

- `randn_ir`, `linspace_ir`, `eye_ir`, etc. (leaf functions): closure = `{self}` (1 entry)
- `reshape_ir`: closure = `{reshape_ir, normalize_dim}` (2 entries)
- `movedim_ir`: closure = `{movedim_ir, move_dims, contains, scatter, broadcast_int, normalize_dim}` (6 entries)
- Previous: every function carried all 86 entries

**Per-function `type_check_program` validation.** Once we have the
per-caller closure, run `type_check_program` on the closure slice at
solve time. This replaces the Phase 5 bypass and validates each DSL
function against its actual callees. Panics on failure for now (matching
current behavior); Phase 7b converts to diagnostics.

**Commit shape:** Two commits.

**Commit 7a-1: `call_targets()` + per-caller resolution.** Add the body
walker, change the solver wiring from all-siblings to transitive-closure,
update `to_meta_shape_function`. All existing tests must pass — the
behavioral result is identical, just with smaller fn_lookup maps.

**Commit 7a-2: Per-function `type_check_program`.** Add
`type_check_program` validation on the closure slice at solve time. This
is the deferred Phase 6 prerequisite. Panics on failure for now.

### Phase 7b: Graceful error handling

**Goal:** Replace panics with diagnostics so third-party stub authors get
useful errors instead of crashes.

**Design invariant:** The DSL type checker (`type_check_program`) is the
validation boundary. Any DSL program that passes type checking must
execute without error. Eval-time panics in `eval_dsl_body` and
`eval_dsl_expr` are correctness assertions — they stay as panics because
they should be unreachable for type-checked programs. Converting them to
diagnostics would mask real engine bugs.

**Commit shape:** Three commits, each with unit tests in `shape_dsl.rs`
that assert the expected diagnostic output.

**Commit 7b-1: Invalid `@uses_shape_dsl` diagnostic.** Trivial, high
user-visibility.

Currently, if `@uses_shape_dsl(ir_fn)` points to something that isn't
a `FunctionKind::ShapeDsl` function (e.g., a typo, a non-DSL function,
or an undefined name), the `if let` chain in `undecorated_function`
(`alt/function.rs:574-584`) silently falls through — `shape_transform`
stays `None` and the function gets no shape inference. No error is
reported.

1. Add an `else` branch to the `if let FunctionKind::ShapeDsl` match
   that emits `ErrorKind::InvalidArgument` at the decorator's
   `TextRange` with a message like ``"`ir_fn` does not resolve to a
   `@shape_dsl_function`"``. Keep `shape_transform = None` (the function
   falls back to its declared return type, matching current behavior).
2. **Test:** Add a testcase in `shape_dsl.rs` with a function decorated
   `@uses_shape_dsl(not_a_dsl_fn)` where `not_a_dsl_fn` is a plain
   function (not `@shape_dsl_function`). Assert the expected error
   diagnostic.

**Commit 7b-2: `convert_fndef` failure diagnostic.** Moderate — changes
the binding-time crash path.

Currently, `convert_shape_dsl_function(&x).expect(...)` in
`binding/function.rs:832` panics on any conversion error. The binder has
`self.error(range, kind, msg)` for emitting diagnostics.

1. Replace `.expect()` with a `match`. On `Err(msg)`, emit
   `ErrorKind::InvalidArgument` at the function definition's
   `TextRange` (available as `x.range`). Set `shape_dsl_def = None` so
   the function is treated as a normal function (no `FunctionKind::ShapeDsl`,
   no shape inference). The `Type` produced at solve time will be a
   normal `Type::Function` with `FunctionKind::Def`.
2. Add diagnostics for silently-dropped parameter kinds. Currently,
   `convert_fndef` iterates only `func.parameters.args` (positional
   and positional-or-keyword), silently ignoring `*args`, `**kwargs`,
   keyword-only, and positional-only parameters. Add a check: if any
   of these are present, emit a warning diagnostic at the parameter's
   `TextRange` explaining which parameter kinds the DSL subset
   supports. The conversion still proceeds (the unsupported params are
   dropped) — this is a warning, not an error.
3. **Test:** Add a testcase in `shape_dsl.rs` with a `@shape_dsl_function`
   whose body uses unsupported syntax (e.g., a `while` loop). Assert
   the expected error diagnostic and that the function is still callable
   (returns its declared type, no shape inference).
4. **Test:** Add a testcase with a `@shape_dsl_function` that has
   `**kwargs`. Assert the expected warning diagnostic.

**Commit 7b-3: `type_check_program` → `Result` conversion.** Significant
but self-contained within `meta_shape_dsl.rs`.

`type_check_program` currently panics on ~20 sites (undefined variables,
type mismatches, unknown function calls, arity errors). These are all
DSL author errors that should produce diagnostics, not crashes.

1. Change `type_check_program` to return `Result<(), Vec<String>>` (or
   a dedicated error type). Each panic site becomes an `Err` push.
2. Change `validate_shape_dsl_functions` to return `Result<(), Vec<String>>`
   (propagating from `type_check_program`).
3. At the call site in `alt/function.rs` (where `validate_shape_dsl_functions`
   is called at `@shape_dsl_function` solve time), on `Err`, emit each
   error as a diagnostic at the function definition's `TextRange` using
   `ErrorKind::InvalidArgument`. The function still gets
   `FunctionKind::ShapeDsl` (the IR was converted successfully) but
   consumers will see shape evaluation failures at call sites if the
   type errors are real.
4. **Test:** Add a testcase in `shape_dsl.rs` with a `@shape_dsl_function`
   that calls an undefined function. Assert the expected error
   diagnostic.
5. **Test:** Add a testcase with a type mismatch (e.g., passing a `str`
   where `int` is expected). Assert the expected diagnostic.

**What stays as panics (by design):**

- All `eval_dsl_body` / `eval_dsl_expr` panics (~24 sites, all labeled
  "DSL bug"). These are correctness assertions: if `type_check_program`
  validates the DSL correctly, none should fire. Making them graceful
  would hide bugs in the type checker.
- `val_to_type` panics (~5 sites). Same reasoning — the type checker
  ensures the return value matches the declared type.
- `bind_dsl_params` is already graceful (returns `Option`, falls back
  to fixture type on `None`).
- `ShapeError::ShapeComputation` and `ShapeError::Unsupported` returns
  in eval (~19 sites) are already graceful — they produce user-visible
  shape errors or silent fallbacks, not panics.

## Open Questions

1. **Stub-body interaction with stub-only overload handling.** Real function
   bodies in `torch/_shapes.pyi` must not confuse the stub-specific overload
   merging path (`merge_overload_metadata_no_implementation`). Validate
   during Phase 5; if there's a problem, either adjust the overload path or
   reconsider where the DSL functions live (e.g. a `.py` module instead of
   `.pyi`).

   *Phase 4 investigation (resolved):* Tested `@shape_dsl_function` in
   `.pyi` files — works correctly. The parser does not strip bodies from
   `.pyi` files, and stub detection is based on body content (ellipsis/pass),
   not file extension. A function with `return x` is classified as `Impl`
   regardless of extension. The only `.pyi`-specific behavior is in the
   solver (`skip_implementation` for overloads, `defined_in_stub_file` flag),
   which does not affect DSL function conversion. No blocker for Phase 5.

## Follow-up Work (Post-Migration)

1. **MRO traversal for `capture_init`.** Allow subclasses to inherit
   `capture_init` from their parent's `forward` decorator. Small change once
   `capture_init` lives on `ClassMetadata`.

2. **Per-overload shape dispatch.** Allow different `@uses_shape_dsl` IR functions
   on different overloads. Requires extending `merge_overload_metadata_*` to
   preserve per-branch `shape_transform` instead of collapsing to the base's.

3. **`.py` registration.** The decorator is the opt-in signal, not the file
   extension, so `@shape_dsl_function` and `@uses_shape_dsl` should work in `.py`
   files identically. The public `pyrefly_types` API (Phase 2) should not
   assume the source is always a stub.

4. **Revisit `FuncFlags` placement.** If implementation experience shows
   shape-transforming-callable values need to flow through positions that
   only carry `Type::Callable` (not `Type::Function`), switch to a wrapper
   type. Defer until concrete evidence appears.

5. **Runtime `shape_extensions` package distribution.** The test fixtures
   include a working `shape_extensions` package with runtime behavior
   (no-op decorators, subscriptable classes, etc.). For production use,
   this package needs to be published/distributed so that end-user code
   can `from shape_extensions import Dim, Tensor` at runtime. Out of
   scope for the current migration but important for adoption.

6. **Move torch monkey-patches out of `shape_extensions`.** The
   `shape_extensions/__init__.py` fixture currently contains torch-specific
   `__class_getitem__` patches (inherited from the old `torch_shapes`
   module). These make `Tensor[B, T]` and `nn.Linear[In, Out]` work at
   runtime but couple `shape_extensions` to torch. Long-term, these
   patches should live in a torch-specific module (e.g. a torch runtime
   setup module) so that `shape_extensions` remains library-agnostic.

7. **Runtime-testable DSL builtins.** The `shape_extensions.dsl` builtins
   (`prod`, `sum`, `parse_einsum_equation`) currently have `...` stub
   bodies. Implementing them as real Python functions would let DSL
   authors unit-test their shape functions in the Python interpreter
   without running Pyrefly.

8. **Trivial BE: replace pre-existing `// ===...===` banner comment
   blocks with `// ---...---` (or remove).** Several files outside this
   migration's scope still use `=====` banner blocks — e.g.
   `crates/pyrefly_types/src/dimension.rs`,
   `crates/pyrefly_types/src/tensor.rs`,
   `pyrefly/lib/test/tsp/tsp_interaction/notebook.rs`. These resemble
   merge conflict markers and add friction. A drive-by rewrite to
   dashes (or removal) is a small consistency win. Not part of this
   migration stack; spin off as a separate trivial BE diff.

9. ~~**Replace all-siblings fn_lookup with transitive-callee resolution.**~~
   Promoted to Phase 7a — no longer a follow-up.
