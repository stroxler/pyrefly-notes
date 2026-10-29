# Tensor Shape Functions in Stubs (V1)

## Overview

This document proposes moving tensor shape logic from an embedded Rust DSL
string to Python stub files (`.pyi`), enabling library extensibility and code
navigation while preserving Pyrefly's lazy evaluation architecture.

This V1 plan revises the V0 proposal based on code review of the current
implementation. The key architectural shifts from V0 are:

1. **Lazy, not eager.** No upfront stub scanning or global registry construction.
   Shape functions are discovered through normal import resolution during type
   checking.
2. **AST lowering, not string extraction.** IR functions are converted from
   already-parsed Python AST to `DslFnDef` via the existing `convert_fndef`,
   not by extracting source text and re-parsing.
3. **Type-level decorator integration.** Shape IR functions get a new
   `Type` (the *shape transform definition*) backed by a new `Binding`
   variant. `@uses_shape` is evaluated as a real decorator that produces
   a *shape transforming callable* type — an ordinary callable type
   extended with a reference to the shape transform definition. Both
   types live in the Solver's per-binding answer system, so cache
   invalidation under LSP is automatic.

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

## Current Architecture (What We're Replacing)

Understanding the current pipeline is essential for planning the migration.

### The DSL engine (`meta_shape_dsl.rs`)

The DSL infrastructure has three parts:

- **`convert_fndef`** (line ~1376): Takes a
  `&ruff_python_ast::StmtFunctionDef` and produces a
  `Result<DslFnDef, String>`. This is pure AST-to-IR lowering — it doesn't
  parse source text, it converts already-parsed AST nodes.

- **`DslFnDef`** and friends: Grammar-aligned types (`DslBody`, `DslExpr`,
  `DslParam`, etc.) representing shape functions in a form the interpreter can
  evaluate. `DslFnDef` has four fields: `name`, `params: Vec<DslParam>`,
  `return_type: Option<DslType>`, and `body: DslBody`.

- **`eval_dsl_body`** (line ~2805): Interprets a `DslFnDef` given variable
  bindings, producing a `Result<(Val, bool), ShapeError>`. The `bool`
  indicates whether the return expression is a list literal ending with `...`
  (the unbounded-tuple marker). The `Val` result gets converted back to a
  `Type`.

### The registry (`tensor_ops_registry.rs`)

`TensorOpsRegistry::new()` does this at construction:
1. Calls `parse_dsl(DSL_SOURCE)` — which is `Ast::parse()`, then
   `convert_fndef` for each function, then `type_check_program` on the
   resulting `Vec<DslFnDef>` — producing `Vec<Arc<DslFnDef>>`.
2. Builds `fn_lookup: Arc<HashMap<String, Arc<DslFnDef>>>` for helper
   resolution (when IR functions call other IR functions like `normalize_dim`).
3. Registers ~131 qualified names via `register()`, `register_dual()` (15
   calls producing 30 entries), and `register_init_forward()` (15 calls).

**Important detail:** There are two separate `OnceLock<TensorOpsRegistry>`
statics — one in `callable.rs:1624` (for shape function lookup) and one in
`call.rs:1073` (for init capture lookup). The registry is constructed
independently in each.

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

In `call.rs`, `maybe_wrap_nn_module` (line ~1064) checks
`registry.get_init_capture` to decide whether to wrap a class construction
result as `Type::NNModule`. `NNModuleType` holds a `ClassType` plus a
`SmallMap<Name, Type>` of captured init args.

### DSL builtins

Eight functions are recognized at parse time in `convert_fndef`'s
`convert_call` (via string matching) and mapped to `DslBuiltin` enum variants:
- `torch_shapes.prod`, `torch_shapes.sum`, `torch_shapes.parse_einsum_equation`
- `len`, `range`, `str`, `enumerate`, `zip`

They are not resolved through imports. This will remain unchanged in V1; these
builtins are intrinsic to the DSL interpreter.

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

### Hardcoded `torch_shapes` references

`torch_shapes` is currently referenced by qualified name in several places
outside the registry:
- `expr.rs:2698`: `cls.has_toplevel_qname("torch_shapes", "Dim")` — recognizes
  `torch_shapes.Dim` as a symint class.
- `pyrefly_types/src/display.rs:491`: Special display logic for `torch_shapes.Dim`.
- `solve.rs:5565`: Canonicalizes bare `Dim` to `Type::Dim`.
- `special.rs:143`: Treats `torch_shapes` as a valid source for
  `TypeVar`/`TypeVarTuple`.

These hardcoded references will persist regardless of this migration — they
concern `Dim` and type variable semantics, not shape function registration.

## Proposed Design

### Stub file layout

```python
# torch_shapes.pyi — IR functions and helpers

class Tensor[*Shape]:
    shape: tuple[int, ...]

class Dim:
    pass

def uses_shape(ir_fn: Callable) -> Callable: ...

# Helper functions
def normalize_dim(rank: int, dim: int) -> int:
    if dim < 0:
        return dim + rank
    return dim

def broadcast(a: list, b: list) -> list:
    ...

# IR functions
def reshape_ir(self: Tensor, shape: list[int | Dim]) -> Tensor:
    ...  # same logic currently in DSL_SOURCE

def matmul_ir(self: Tensor, other: Tensor) -> Tensor:
    ...
```

```python
# torch/__init__.pyi — API stubs with @uses_shape decorators

from torch_shapes import Tensor, uses_shape, reshape_ir, matmul_ir

@uses_shape(reshape_ir)
def reshape(input: Tensor, shape: tuple[int, ...]) -> Tensor: ...

@uses_shape(matmul_ir)
def matmul(input: Tensor, other: Tensor) -> Tensor: ...
```

```python
# nn.Module example
from torch_shapes import uses_shape, maxpool_forward_ir

class MaxPool2d:
    @uses_shape(maxpool_forward_ir,
                capture_init=["kernel_size", "stride", "padding", "dilation"])
    def forward(self, input: Tensor) -> Tensor: ...
```

### Third-party extensibility

Libraries can define their own IR functions or reuse built-in ones:

```python
# mylib/__init__.pyi
from torch_shapes import uses_shape, reshape_ir
from mylib._shapes import custom_ir

@uses_shape(reshape_ir)
def my_reshape(x: Tensor, shape: tuple[int, ...]) -> Tensor: ...

@uses_shape(custom_ir)
def custom_op(x: Tensor, dim: int) -> Tensor: ...
```

```python
# mylib/_shapes.pyi
from torch_shapes import Tensor, Dim

def custom_ir(x: Tensor, dim: int) -> Tensor:
    return Tensor(shape=[d for i, d in enumerate(x.shape) if i != dim])
```

## Architecture: Integration with Pyrefly's Phases

### Phase overview

The design integrates with Pyrefly's existing parse → export → bind → solve
pipeline. No new phases are needed.

```
Parse: torch_shapes.pyi parsed by ruff → AST available during binding
                                          ↓
Bind:  IR functions → Binding::ShapeFunction(Arc<DslFnDef>)
       API functions with @uses_shape → ordinary Binding::Function
       (decorator is consumed at solve time by SpecialExport handling)
                                          ↓
Solve: IR function binding → shape transform definition type
       API function binding → decorator application produces a shape
                              transforming callable type that references
                              the shape transform definition
                                          ↓
       Call to torch.reshape → callable_infer_inner sees the shape
                               transform reference on the callable's
                               type, evaluates the DSL against
                               bound_args, refines the return type
```

### Step 1: Binding IR functions (`torch_shapes.pyi`)

When the binder encounters a function definition with a non-`...` body
in *any* `.pyi` file, it attempts to convert that function to a DSL IR.
On success the function is stored as `Binding::ShapeFunction`; on
failure the binder falls back to ordinary `Binding::Function`
processing without emitting a diagnostic. The detection heuristic is
discussed in detail below.

1. Call `convert_fndef(&stmt_function_def)` from `meta_shape_dsl.rs`
   (exposed via the Phase 0 wrapper API) to attempt producing a
   `DslFnDef`.
2. On success, store the result as a new binding variant:
   `Binding::ShapeFunction(Arc<ShapeDslFunction>)`. When the Solver
   resolves this binding, the resulting type is a *shape transform
   definition* (see Open Question #4 for the exact `Type` variant).
3. On failure, fall back to normal `Binding::Function` processing.
   Attach the conversion error lazily so it only surfaces if a
   `@uses_shape(...)` decorator actually references this function (see
   error-handling note below).

This means the AST-to-IR conversion happens exactly once, during
binding, and the resulting shape transform definition is available to
the solver through normal binding resolution.

**Important implementation detail:** `BindingUndecoratedFunction` does not
store the function body — the body is consumed during binding to produce return
type bindings and then dropped. This means we *must* convert IR functions to
`DslFnDef` during binding (before the body is discarded), which aligns
naturally with the `Binding::ShapeFunction` approach.

**Detection heuristic (V1 decision):** Any function in a `.pyi` file with a
non-`...` body is a candidate for `convert_fndef`. If conversion succeeds, the
binder emits `Binding::ShapeFunction`; if it fails, the binder falls back to
normal `Binding::Function` processing *without emitting a diagnostic* (the body
is dropped as it would be normally). This approach is necessary because the
third-party extensibility examples in this document — e.g. `mylib/_shapes.pyi`
below — neither define nor import `uses_shape`, so a "defines `uses_shape`"
heuristic would silently miss them. Because the DSL is a strict subset of
Python, the false-positive rate (normal stub functions that happen to parse as
valid DSL) is expected to be extremely low; we should still measure this
empirically (see Open Questions).

**Type checking the IR:** The current `parse_dsl` calls
`type_check_program` on the converted `DslFnDef` list. Under the new
design, DSL type checking runs when the shape transform definition's
*type* is computed by the Solver — at which point the same-module
helpers (OQ#1's restriction) are all available as
`Binding::ShapeFunction` entries in the same module. The type-check
result is cached as part of the type itself, so it runs once per
module per stub change and inherits the Solver's answer-invalidation
machinery (cf. OQ#7).

**Error handling:** Because we attempt `convert_fndef` on every non-`...`
function in any `.pyi` file (most of which are *not* shape functions),
conversion failures must not produce diagnostics on their own — that would
spam errors on ordinary stubs. Instead, store conversion failures lazily via a
`Binding::InvalidShapeFunction(ConversionError)` variant (or attach the error
to a regular `Binding::Function` as side metadata). The solver only emits the
diagnostic when a `@uses_shape(...)` decorator actually references that
function, at which point the error is clearly relevant. Error messages from
`convert_fndef` are currently terse `Result<_, String>` — these should be
improved to include `TextRange` information and explain what subset of Python
is supported.

**Helper resolution:** All functions in `torch_shapes.pyi` — both
top-level IR functions and helpers like `normalize_dim` — become
`Binding::ShapeFunction` entries and each get a shape transform
definition type. Helpers are resolved through the normal type system
when the DSL evaluator runs (or eagerly embedded at definition
construction time — see the OQ#4 sub-decision on helper resolution).
Under OQ#1's V1 same-module restriction, only same-module helpers
need to be resolvable.

### Step 2: Binding API functions (`torch/__init__.pyi`)

Add `UsesShape` to the `SpecialExport` enum (in `export/special.rs`)
with `defined_in` returning `torch_shapes`. The API function itself is
bound normally as `Binding::Function` — no special-casing at the
binding layer. The decorator's effect is realized at solve time, by
recognizing `uses_shape` as a `SpecialExport` and producing a *shape
transforming callable* type instead of the ordinary callable type that
the decorator would otherwise yield.

**Decorator evaluation:** When the solver applies the decorator stack
of an API function (the normal decorator pipeline in
`alt/types/decorated_function.rs`), `@uses_shape(reshape_ir)` is
intercepted via the `SpecialExport` mechanism:

1. Resolve `reshape_ir` through normal name resolution. It has a
   shape transform definition type (i.e. it resolves to a
   `Binding::ShapeFunction`).
2. Take the underlying function's callable type and produce a shape
   transforming callable type that references the resolved
   definition. Per OQ#4's leading direction, this is a variant of
   `Type::Callable` carrying an optional
   `shape_transform: Option<ShapeTransformDefinitionRef>` field.

The shape transform reference becomes part of the function's *type*,
which lives in the Solver's per-binding answer system. There is no
separate metadata sidecar to thread through
`FuncMetadata`/`FuncFlags`.

**`capture_init` argument:** When the decorator is called with a
`capture_init=[...]` keyword argument (e.g.
`@uses_shape(maxpool_forward_ir, capture_init=["kernel_size", ...])`),
the same `SpecialExport` evaluation captures this list and attaches it
to the shape transforming callable type. This replaces the current
`init_captures` HashMap in `TensorOpsRegistry`.

**Class-level capture metadata:** The current `maybe_wrap_nn_module`
runs during *class construction* and looks up captures by class name.
Reading `capture_init` off the `forward` method at construction time
is non-trivial: it requires resolving the (possibly inherited via
MRO) `forward` method, solving its decorator type, and avoiding
construction-time cycles. To side-step this, lift `capture_init` to
*class-level* metadata during class binding (derived from the
`forward` method's decorator if present), so that
`maybe_wrap_nn_module` can consult class metadata directly without
re-entering function solving. Per OQ#3 (resolved), V1 preserves the
existing no-MRO-walk behavior.

### Step 3: Solver consumption

By the time `callable_infer_inner` runs, the decorator pipeline has
already produced the function's type. If `@uses_shape` was applied,
that type is a shape transforming callable carrying a reference to a
shape transform definition.

1. **Inspect the callable's type.** If it carries a shape transform
   reference, take the *also-existing* underlying callable signature
   (which is just the `Callable` payload) and run normal argument
   binding against it, populating
   `bound_args: Option<HashMap<String, Type>>`. The `Option` wrapper
   is allocated only when a shape transform is present, preserving
   the current zero-cost path for non-shape calls. This replaces the
   existing `lookup_meta_shape` HashMap lookup.

2. **Evaluate the DSL.** Use the existing `eval_dsl_body` interpreter
   against `bound_args` — identical to how `DslMetaShapeFunction::evaluate`
   works today. The shape transform definition supplies the
   `Arc<DslFnDef>`; the helper `fn_lookup` is resolved per the OQ#4
   sub-decision (either pre-embedded in the definition's type, or
   looked up lazily through the type system at evaluation time).

3. **`capture_init` handling:** For `nn.Module` classes, if the
   resolved function's shape transforming callable carries a
   `capture_init` list, `maybe_wrap_nn_module` reads it from
   class-level metadata (lifted from the `forward` method's decorator
   at class binding time) instead of from
   `TensorOpsRegistry::get_init_capture`. The `NNModule` wrapping and
   `inject_module_attrs` logic (including the `ClassType` path with
   `Dim[T]` unwrapping) is unchanged.

Note: there is no per-module `fn_lookup` HashMap on the Solver. All
shape-related state lives inside the types themselves, which are
managed by Pyrefly's existing per-binding answer system.

### Error reporting

Shape errors are reported at the user's call site, exactly as today:

```
error[invalid-argument]: shape error: can only specify one unknown dimension as -1
  --> user_code.py:10:5
   |
10 |     x.reshape(-1, -1)
   |     ^^^^^^^^^^^^^^^^^
```

Enhancement: attach a secondary diagnostic span pointing to the `raise` in
`torch_shapes.pyi`, enabling "Go to Definition" on the error condition.

## What Stays the Same

- **The DSL language itself.** The restricted Python subset — `DslFnDef`,
  `DslBody`, `DslExpr`, `Val`, etc. — is unchanged. IR functions written for
  `DSL_SOURCE` move verbatim into `torch_shapes.pyi`.

- **The interpreter.** `eval_dsl_body`, `bind_dsl_params`, `val_to_result_type`
  — all unchanged.

- **DSL builtins.** `Len`, `Range`, `Prod` (`torch_shapes.prod`), `Sum`
  (`torch_shapes.sum`), `Str`, `ParseEinsumEquation`
  (`torch_shapes.parse_einsum_equation`), `Enumerate`, and `Zip` remain as
  `DslBuiltin` enum variants recognized during `convert_fndef`. They are
  intrinsics, not import-resolved.

- **The `MetaShapeFunction` trait.** `DslMetaShapeFunction` still wraps a
  `DslFnDef` and implements `evaluate`. The trait may eventually be simplified
  away (since all shape functions are now DSL-backed), but that's cleanup, not
  architecture.

- **`NNModule` type wrapping.** The `Type::NNModule` representation (holding a
  `ClassType` plus `SmallMap<Name, Type>` of captured fields) and
  `inject_module_attrs` logic are unchanged. Only the *source* of the capture
  list changes (from `TensorOpsRegistry::init_captures` to decorator metadata).

- **Hardcoded `torch_shapes` references.** The qualified name checks for
  `torch_shapes.Dim` in `expr.rs`, `display.rs`, `solve.rs`, and `special.rs`
  are orthogonal to shape function registration and remain unchanged.

## What Changes

| Component | Before | After |
|-----------|--------|-------|
| IR function source | `DSL_SOURCE` string in Rust | `torch_shapes.pyi` stub file |
| Op-to-IR mapping | Hardcoded `register*()` calls (~131 entries) | `@uses_shape` decorator on API stubs |
| AST-to-IR conversion | `parse_dsl` (parse text + convert + type-check) | `convert_fndef` called during binding; type-check at `fn_lookup` assembly |
| IR storage | `OnceLock<TensorOpsRegistry>` (×2) | `Binding::ShapeFunction` → shape transform definition type |
| API registration | Hardcoded registry calls | Shape transforming callable type produced by decorator application |
| Init captures | `TensorOpsRegistry::init_captures` (15 classes) | `capture_init` decorator arg on class-level metadata |
| Detection trigger | Qualified name lookup via `FunctionKind` | Shape transform reference on the function's callable type |
| Cache management | Two `OnceLock` statics | Implicit: state lives in the type system's per-binding answers |

## Migration Plan

(Note: phase-relative complexity ordering, not absolute time estimates. The
unresolved questions below will materially affect scope.)

### Phase 0: Public shape-DSL API in `pyrefly_types`

**Goal:** Make the DSL conversion/evaluation machinery callable from
`pyrefly/lib/binding` and `pyrefly/lib/alt`.

Currently `convert_fndef`, `type_check_program`, `bind_dsl_params`, and
`eval_dsl_body` are private `fn` in `meta_shape_dsl.rs`, and `DslFnDef` is
`pub(crate)` with mostly private fields. Two options:

- **Option A (minimal):** Promote the necessary functions and `DslFnDef` to
  `pub`. Easy but freezes DSL internals as a public API.
- **Option B (recommended):** Introduce opaque public wrapper types in
  `pyrefly_types` — e.g. `ShapeDslFunction`, `ShapeDslProgram` — with
  constructors `convert_shape_dsl_function(&StmtFunctionDef) -> Result<...>`
  and `build_shape_dsl_program(impl IntoIterator<...>) -> ShapeDslProgram`,
  plus a `MetaShapeFunction` factory. Keeps internals private.

### Phase 1: Binding infrastructure

**Goal:** The binder can recognize `@uses_shape` and produce shape-function
bindings.

1. Add `UsesShape` to `SpecialExport` enum, with `defined_in` returning
   `torch_shapes`.
2. Add `Binding::ShapeFunction(Arc<ShapeDslFunction>)` variant.
   `binding_to_type_info` resolves to the IR function's *declaration
   type* — i.e. a value whose type identifies it as a DSL-defined
   type-level transformation (analogous to how a `TypeAlias`
   assignment yields a value whose type marks it as a type alias).
   This is the **shape transform definition** in Open Question #4;
   the exact variant name and shape are settled there. Update all exhaustive match blocks —
   let the compiler drive the audit. Known sites: `DisplayWith` impl
   in binding.rs (~line 2252-2526), `symbol_kind()` (~line 2534-2611),
   plus many in `alt/expr.rs`, `alt/solve.rs`, `alt/call.rs`,
   `alt/callable.rs`.
3. Improve `convert_fndef` error reporting: change the return type from
   `Result<DslFnDef, String>` to a structured error with `TextRange`
   information and clear messages about which Python constructs are unsupported.
4. In `function_def`, for *every* non-`...` body in *any* `.pyi` file, attempt
   `convert_fndef`. On success, produce `Binding::ShapeFunction`. On failure,
   fall back to normal binding and attach the conversion error lazily (see
   error-handling note above). Bodies are dropped during binding anyway —
   confirmed by `mem::take(&mut x.body)` at `binding/function.rs:812` — so
   the conversion must happen here.
5. Register `UsesShape` in the decorator-evaluation path so that when
   `@uses_shape(reshape_ir, ...)` is applied during the solver's
   decorator pipeline (`alt/types/decorated_function.rs`), it produces
   a shape transforming callable type (a variant of `Type::Callable`
   per OQ#4) that references the resolved shape transform definition
   and carries any `capture_init=[...]` argument. The API function
   binding itself remains an ordinary `Binding::Function`; no
   metadata-threading through `FuncMetadata` is needed because the
   shape transform reference *is part of the function's type*.

**Test:** Write a minimal `torch_shapes.pyi` with one IR function and one
decorated API function. Verify the binder produces the correct binding
variants (unit test at the binding level).

### Phase 2: Solver integration

**Goal:** The solver evaluates shape transforms attached to function
types and produces correct refined return types.

1. In `callable_infer_inner`, add a path that inspects the callable's
   type for a shape transform reference (the new
   `Type::Callable`-variant field). When present, populate
   `bound_args: Option<HashMap<String, Type>>` as today, evaluate via
   `eval_dsl_body`, and use the result. The path coexists with the
   legacy `lookup_meta_shape` during migration; both feed into the
   same `apply_meta_shape` call. Preserve the `Option<HashMap>`
   wrapper so non-shape calls allocate nothing.
2. Implement the chosen helper-resolution strategy from OQ#4:
   - Option (a): when constructing a shape transform definition's
     type, eagerly resolve all same-module helpers and embed the
     resulting `fn_lookup` inside the definition. DSL type checking
     runs at this point.
   - Option (b): resolve helpers lazily through the type system at
     DSL evaluation time, keyed by helper name within the IR
     function's module.
   Either way there is no separate solver-level `fn_lookup` HashMap;
   per-module caching happens inside the type, which inherits the
   answer system's invalidation.
3. Handle `capture_init` from class-level metadata (lifted from
   `forward` at class binding time) in `maybe_wrap_nn_module`.

**Test:** Write end-to-end tests with a stub-defined shape function.
Verify shape inference produces the same results as the hardcoded
registry.

### Phase 3: Torch stub migration

**Goal:** All shape functions move from `DSL_SOURCE` to stubs.

1. Create `torch_shapes.pyi` in `crates/pyrefly_bundled/third_party/stubs/`.
   Move IR functions verbatim from `DSL_SOURCE`. (Currently no torch stubs
   exist in bundled stubs — only test fixtures at
   `test/tensor_shapes/fixtures/torch/`.)
2. Add `@uses_shape` decorators to the existing torch test fixture stubs
   (`test/tensor_shapes/fixtures/torch/__init__.pyi` etc.).
3. Migrate incrementally, verifying test parity after each batch. The
   hardcoded registry serves as fallback: if a function has both a registry
   entry and a `@uses_shape` decorator, prefer the decorator.
4. Update all 15 `nn.Module` registrations (`MaxPool1d/2d/3d`,
   `AvgPool1d/2d/3d`, `Flatten`, `PixelShuffle`, `GLU`, `LSTM`, `Upsample`,
   `GRU`, `LSTMCell`, `ReflectionPad2d`, `ReplicationPad2d`) to use
   `capture_init` in decorators.

### Phase 4: Cleanup

**Goal:** Remove the old infrastructure.

1. Delete `DSL_SOURCE` constant and `parse_dsl` function.
2. Delete `TensorOpsRegistry` struct, both `OnceLock` statics, and all
   `register*` methods.
3. Remove `lookup_meta_shape` — the decorator path is now the only path.
4. Simplify `MetaShapeFunction` trait if warranted (all impls are now
   `DslMetaShapeFunction`).
5. Write documentation for third-party library authors on how to use
   `@uses_shape`.

## Open Questions

1. **Cross-module helpers (follow-up, not V1).** V1 restricts each IR
   function to call only helpers defined in the *same* module. Helpers like
   `normalize_dim` must therefore live alongside the IR functions that use
   them, and the per-module `fn_lookup` does not need to span modules. This
   is a real limitation: common helpers shared across multiple DSL modules
   are not yet supported.

   A natural follow-up (post-V1) is to allow *direct* (non-transitive)
   imports of helpers from another shape module: an IR function may call a
   helper resolved through `from other_shapes import helper`, but not a
   helper that `other_shapes` itself imported from somewhere else.
   Implementing this requires resolving DSL call targets through import
   analysis during conversion and storing a `ModuleName`-qualified symbol
   identity instead of a bare string. Transitive resolution is explicitly
   out of scope — every shape module must import its helpers directly.

2. **`@uses_shape` overload semantics (resolved — preserve existing
   behavior).** Today the registry is keyed purely by qualified name
   (`module.cls.name`), so a single shape function applies to all
   overloads. The DSL functions are written with union-typed parameters
   (e.g. `normal_ir(mean, std, size)`) that subsume every overload's
   parameter space, and branch on `isinstance`/`None` at evaluation time.
   In effect the DSL *replaces* overload resolution for return-type
   inference rather than being driven by it.

   The migration preserves this:

   - `@uses_shape` may appear on any of an overloaded function's
     overloads. The binder/solver reads the decorator off the merged
     `FuncMetadata`. Since `merge_overload_metadata_*` already drops
     arbitrary per-overload decorator payloads (function.rs:1820-1856),
     the natural "first overload wins" semantics apply if multiple
     overloads carry the decorator; if they disagree, emit a lint.
   - DSL functions remain union-typed and continue to branch internally.
     Per-overload dispatch is explicitly **out of scope** for V1.
   - The DSL still runs once per overload candidate during
     `find_closest_overload`, and again on the winning overload during
     contextual typing (overload.rs:687-694) — unchanged.

   A follow-up could extend `merge_overload_metadata_*` to retain
   per-overload `@uses_shape` and add a dispatch mechanism in
   `lookup_meta_shape`, enabling per-overload IR selection. That is
   strictly additive and not needed for V1.

3. **`capture_init` and inheritance (resolved — preserve existing
   behavior).** Today's registry is keyed by qualified class name
   (`torch.nn.MaxPool2d`), and `maybe_wrap_nn_module` looks up the
   *constructed* class's qname only — no MRO walk. A subclass like
   `class MyMaxPool(MaxPool2d): pass` is not wrapped as `NNModule`
   today, because `MyMaxPool` is not in `init_captures`. V1 preserves
   this: class-level `capture_init` metadata is read only from the
   constructed class itself, with no inheritance traversal.

   **Follow-up concern (not part of migration):** MRO traversal during
   `maybe_wrap_nn_module` is probably the *right* semantics — users who
   subclass an `nn.Module` without overriding `forward` reasonably expect
   the parent's shape behavior to apply. The class-keyed registry made
   this hard to fix; once `capture_init` lives on class metadata derived
   from a decorator, walking the MRO becomes a small change. Defer
   intentionally to keep the migration behavior-preserving.

4. **`@uses_shape` as a type-level decorator (resolved — leading
   direction; sub-design open).** Rather than treating `@uses_shape`
   as sidecar metadata that the solver reads after the fact,
   *evaluate it as a real decorator* whose type-level effect is to
   produce a richer type carrying the shape transformation. Pyrefly
   recognizes `uses_shape` as a `SpecialExport`, intercepts decorator
   application, and emits a function type that references the IR
   function's type.

   **Two distinct types are at play.** These are closely related but
   serve different roles, and must be designed separately:

   - **Shape transform definition — the type of an IR function**
     (e.g. `reshape_ir` as defined in `torch_shapes.pyi`). This is
     analogous to a `TypeAlias` *declaration*: it declares a
     callable-shaped type-level transformation whose return-type
     computation cannot be written in closed-form Python type
     syntax. It carries the IR function's declared signature
     (useful for hover/IDE) plus the DSL body that refines its
     return type. Its identity is "I am a shape-DSL declaration."
     `Binding::ShapeFunction` resolves to a value of this type.

   - **Shape transforming callable — the type of a function
     decorated with `@uses_shape(...)`** (e.g. `torch.reshape` after
     decorator application). This is an ordinary callable type
     extended with a *reference* to a shape transform definition.
     The decorator's type-level effect is to read the IR argument
     (which has a shape-transform-definition type), extract the
     declaration reference, and attach it to the underlying
     callable's type.

   The relationship: the shape transform definition is what the
   shape transforming callable *references*; the shape transforming
   callable is how a definition gets *applied* at call sites.
   `uses_shape` itself has the signature
   `(ir: ShapeTransformDefinition) -> Callable[[F], F]` at a high
   level; concretely Pyrefly's special handling of the decorator
   threads the IR reference into the produced callable type.

   Why this design is the right shape:

   - **Cache invalidation is automatic.** Both types live in the
     Solver's per-binding answer system. When `torch_shapes.pyi`
     changes, each IR function's shape-transform-definition type
     recomputes, every decorated API function's
     shape-transforming-callable type recomputes, and consumers
     invalidate through the normal mechanism. This dissolves the
     original Open Question #7 about ad-hoc LSP cache invalidation.
   - **No side channels.** Shape behavior is reachable from the
     function's type, so hover/IDE can surface it; aligns with the
     OQ#9 rationale (explicit, navigable decorators over hidden
     side-channels).
   - **Composes with overloads, classmethod, etc.** Decorator
     pipelines already handle these transformations; we slot in.
   - **Works identically for `.py` and `.pyi`.** A runtime
     `@uses_shape` decorator produces a callable-with-shape value;
     the type checker mirrors that.

   **Sub-design decisions (settle during Phase 0 / Phase 1):**

   - **Representation of the shape transform definition.** A new
     `Type::ShapeTransformDefinition` variant carrying
     `Arc<DslFnDef>` plus the declared callable signature is the
     cleanest option. Alternative: reuse `Type::Callable` with a
     "this-is-a-declaration" marker. New variant is probably better
     because the identity of a definition is fundamentally different
     from an ordinary callable (you don't call a definition; the
     decorator *references* it).
   - **Representation of the shape transforming callable (leading
     direction).** Most likely a new *variant of `Type::Callable`*
     in the existing `Type` tree (rather than a separate top-level
     `Type` variant), carrying an additional reference field —
     conceptually `shape_transform: Option<ShapeTransformDefinitionRef>`
     attached to the callable. This keeps the type tree compact and
     lets every callable-handling site continue to work uniformly;
     sites that care about shape inference (`callable_infer_inner`)
     consult the new field when present. Not 100% settled — a
     dedicated top-level variant remains a fallback if extending
     `Callable` proves intrusive, but the working assumption is
     "Callable variant."
   - **Raw-stub signature preservation.** The shape transforming
     callable should keep the pre-decoration callable signature
     accessible. Under the leading direction (a `Callable` variant
     with an optional shape ref), this is automatic — the `Callable`
     payload *is* the raw stub signature, and the shape ref is
     additive refinement. No separate metadata needed.
   - **Helper resolution.** Each helper function in
     `torch_shapes.pyi` (e.g. `normalize_dim`) gets its own
     shape-transform-definition type. The DSL evaluator at the API
     call site needs `fn_lookup` to resolve helpers referenced from
     the IR body. Two options: (a) at definition-construction time,
     eagerly resolve all same-module helpers (under OQ#1's
     same-module restriction) and embed a self-contained DSL
     package in the definition; or (b) at call-site evaluation
     time, look up helpers' definition types through the normal
     type system. (a) is eager but side-effect-free; (b) is leaner
     and matches Pyrefly's laziness. Both are tractable; pick
     during Phase 0.

5. **DSL subset enforcement.** When IR functions live in `.pyi` files,
   developers may try to use full Python syntax. `convert_fndef` rejects
   unsupported constructs, but the error messages are currently terse
   strings. Phase 1 should improve these to include `TextRange` spans and
   list the supported subset. Consider whether a lint or diagnostic mode
   could validate shape modules without running the full type checker.

6. **False-positive rate of the broad detection heuristic.** Attempting
   `convert_fndef` on every non-`...` body in every `.pyi` is theoretically
   cheap (the DSL grammar is restrictive enough that most ordinary stub
   bodies will fail conversion immediately), but should be measured. Run a
   conversion pass over a corpus of real `.pyi` files and report (a) what
   fraction of non-trivial stub bodies successfully parse as DSL, and
   (b) the wall-clock cost of the failing attempts. Adjust the heuristic if
   either number is unacceptable.

7. **Cache invalidation under LSP (dissolved by OQ#4).** Under the
   type-level-decorator design (OQ#4), shape DSL functions and the
   transformations they induce live inside the type returned by the
   Solver's per-binding answer system. There is no separate
   `fn_lookup` cache to invalidate: when a shape stub changes, the
   normal answer-invalidation machinery recomputes the affected types
   and propagates to consumers automatically. No additional design
   work is required here beyond the OQ#4 resolution.

8. **Bundled-stub discovery.** Phase 3 proposes placing `torch_shapes.pyi`
   in `crates/pyrefly_bundled/third_party/stubs/`, but currently no torch
   stubs live there (only test fixtures). Verify the bundled-stub loading
   path makes `import torch_shapes` resolve correctly, and decide whether a
   user-provided `torch_shapes.pyi` should override the bundled version.

9. **`register_dual` migration shape (resolved).** Each function in the
   stub carries its own explicit `@uses_shape(reshape_ir)` decorator — no
   `dual=True` sugar. The duplication is intentional: a primary goal of
   this migration is to support "Go to Definition" chains from API stubs
   to IR implementations, and a dual side-channel would hide that link
   from at least one of the two call sites. Being explicit is better.

10. **Eventual `.py` registration.** The design should not foreclose
    later allowing registration of shape logic from `.py` files, where
    the runtime value would be a real Python object with no
    type-relevant behavior. Specifically: the same `convert_fndef`
    -attempt heuristic could extend to `.py` files (producing a shape
    transform definition type for any conformant function body), and
    the public `pyrefly_types` API surfaces (per Phase 0) should not
    assume the source is always a stub. The shape transform definition
    type is the natural home for either source: it advertises a
    callable shape plus a DSL body regardless of how the value would
    behave at runtime.
