# Static Python Type Inference: A Comprehensive Analysis

## Document Purpose

This document provides a thorough analysis of Static Python's (SP) type inference
system within the CinderX compiler. It is intended for engineers evaluating whether
Pyrefly could replace or augment SP's type inference capabilities. The analysis covers
type representation, inference scope, soundness model, narrowing, special cases, codegen
integration, and the error model.

## 1. Architecture Overview

### 1.1 Pipeline

Static Python's compilation pipeline consists of three sequential passes, implemented
in `fbcode/cinderx/PythonLib/cinderx/compiler/static/compiler.py`:

1. **Declaration Pass** (`DeclarationVisitor` in `declaration_visitor.py`): Walks the
   AST top-to-bottom to discover module-level and class-level declarations. It creates
   `Class`, `Function`, and `Slot` objects for all declared types, functions, and
   attributes. It also resolves imports to discover cross-module types.

2. **Type Binding Pass** (`TypeBinder` in `type_binder.py`): Walks the AST again,
   performing local type inference within function bodies. This is the core type
   inference phase. It tracks local variable types via `TypeState`, handles narrowing
   through `NarrowingEffect`, and produces typed AST nodes (stored in `module.types`).

3. **Code Generation Pass** (`StaticCodeGenBase` in `__init__.py`): Walks the typed
   AST and emits specialized bytecode. It queries the type information attached to
   AST nodes by the TypeBinder to decide which opcodes to emit (e.g., `LOAD_FIELD`
   vs. `LOAD_ATTR`, `PRIMITIVE_BINARY_OP` vs. `BINARY_OP`).

The entry point is `Compiler._bind()`, which runs the Declaration and TypeBinder
passes, followed by `Compiler.code_gen()` which adds the code generation pass.

### 1.2 Key Files

| File | Role |
|------|------|
| `compiler.py` | Entry point; orchestrates passes; initializes builtins/typing modules |
| `types.py` (~10,600 lines) | All type representations: `Value`, `Class`, `Object`, `Function`, `Slot`, `CInstance`, unions, generics, etc. |
| `type_binder.py` (~2,200 lines) | Local type inference; visits expressions, assignments, control flow |
| `declaration_visitor.py` (~350 lines) | Module/class-level declaration collection |
| `effects.py` (~160 lines) | Narrowing effect algebra (`NarrowingEffect`, `AndEffect`, `OrEffect`, etc.) |
| `module_table.py` | Module table: manages per-module symbols, annotations, imports |
| `visitor.py` | Base visitor with error handling and dependency tracking |

### 1.3 Initialization

When a `Compiler` is constructed, it pre-populates its module tables with intrinsic
knowledge of:
- **builtins**: All built-in types (`int`, `str`, `list`, `dict`, etc.), exceptions, and functions
- **typing**: `Union`, `Optional`, `Final`, `Literal`, `ClassVar`, `Protocol`, etc.
- **__static__**: Primitive types (`int8` through `uint64`, `double`, `cbool`, `char`),
  `CheckedDict`, `CheckedList`, `Array`, `ExcContextDecorator`, `box`/`unbox`, `cast`, etc.
- **dataclasses**: `dataclass`, `field`, `Field`, `InitVar`

## 2. Type Representation

### 2.1 Core Hierarchy

SP's type system is built around two fundamental concepts:

- **`Value`**: The base class for all compile-time tracked values. Every AST node is
  assigned a `Value` during the TypeBinder pass. A `Value` has a `klass` attribute
  pointing to its `Class`.

- **`Class`** (extends `Object["Class"]`): Represents a type/class at compile time.
  Every `Class` has an `instance` attribute (a `Value` representing what you get when
  you instantiate the class), `members` (a dict of attribute names to their `Value`s),
  `bases`, and an MRO.

The key insight: `Class` is itself an `Object`, meaning type objects can be treated
as values too (this models Python's `type` being an instance of itself).

### 2.2 Type Constructors

SP supports the following type constructors:

| Type Constructor | Class | Purpose |
|-----------------|-------|---------|
| Object types | `Class` | Standard Python classes |
| Exact types | `Class` (with `is_exact=True`) | Exact type matching (no subclasses) |
| Dynamic | `DynamicClass` | Gradual typing escape hatch |
| None | `NoneType` | The `None` singleton type |
| Union | `UnionType` (extends `GenericClass`) | `Union[A, B]` or `A \| B` |
| Optional | `OptionalType` (extends `UnionType`) | `Optional[T]` = `Union[T, None]` |
| Generic | `GenericClass` | Parameterized types like `List[int]` |
| Generic Parameter | `GenericParameter` | Unbound type variables (`T`) |
| Literal | `LiteralType` | `Literal[42]`, `Literal[True]` |
| Final | `FinalClass` (wraps a type) | `Final[int]` |
| ClassVar | `ClassVar` (wraps a type) | `ClassVar[int]` |
| InitVar | `InitVar` (wraps a type) | `InitVar[int]` for dataclasses |
| Annotated | `AnnotatedType` | `Annotated[int, ...]` |
| C primitive int | `CIntType` | `int8`, `int16`, ..., `uint64` |
| C double | `CDoubleType` | `double` floating point |
| Function | `Function` | A concrete function with typed parameters |
| Callable | `Callable` | Abstract callable with parameter/return types |
| Slot | `Slot` | A typed attribute on a class |
| Method | `MethodType` | A bound method |
| Module | `ModuleType`/`ModuleInstance` | Module as a type |
| Enum | `EnumType` | Enum subclasses |
| Dataclass | `Dataclass` | Dataclass-decorated classes |
| CheckedDict | `CheckedDict` (extends `GenericClass`) | Type-checked dictionary |
| CheckedList | `CheckedList` (extends `GenericClass`) | Type-checked list |
| Array | `ArrayClass` (extends `GenericClass`) | Static arrays |

### 2.3 Exact vs. Inexact Types

SP distinguishes between **exact** and **inexact** type instances:

- An **exact type** (`is_exact=True`) represents a value known to be precisely that
  class, not a subclass. For example, when you write `x = MyClass()`, SP knows `x`
  is exactly `MyClass`.

- An **inexact type** represents a value that could be the class or any subclass.
  When you annotate `x: MyClass`, SP treats it as inexact (could be a subclass).

This distinction is critical for optimization: exact types allow SP to emit direct
slot accesses and vtable calls, while inexact types may require more dynamic dispatch.

The `can_assign_from` method on `Class` enforces this:

```python
def can_assign_from(self, src: Class) -> bool:
    return src is self or (
        (not self.is_exact or src.instance.nonliteral() is self.instance)
        and not isinstance(src, CType)
        and src.instance.nonliteral().klass.is_subclass_of(self)
    )
```

### 2.4 The Dynamic Type

The `DynamicClass` is SP's escape hatch for gradual typing. When SP encounters an
expression it cannot type, it assigns `dynamic`. The dynamic type has these properties:

- It accepts assignment from any non-primitive type:
  `can_assign_from(src)` returns `True` unless `src` is a `CType`
- It is `inexact` and has `is_nominal_type = False`
- Its type descriptor maps to `("builtins", "object")` for runtime purposes

Dynamic is used extensively as a fallback: unannotated function parameters, unknown
imports, unresolvable decorators, and many typing constructs that SP does not fully
model (e.g., `TypeVar`, `Generic`, `Callable`, `Iterable`, `Iterator`, `Awaitable`,
`Coroutine`, `Collection`, `Type`).

### 2.5 Literal Types

SP tracks literal values for `int` and `bool`:

```python
def get_literal_type(self, non_literal: Value, literal_value: object) -> Value:
```

Literal types are used for:
- Constant folding during codegen
- Final variable tracking (e.g., `RAND_MAX` is a `NumClass` with `literal_value`)
- Boolean narrowing (knowing a condition is `True` or `False`)

The `nonliteral()` method on `Value` strips literal information, and
`KnownBoolean` tracks whether a boolean expression is known to be `True` or `False`.

## 3. Type Inference Scope

### 3.1 What SP Infers

**Locals in function bodies:**
- SP infers types for all local variables based on their assignments
- For annotated variables (`x: int = ...`), the annotation is the declared type
- For unannotated assignments (`x = expr`), SP infers the type from the RHS and
  declares the variable as `dynamic` (allowing later reassignment to any type),
  but tracks the narrowed type for the current scope

**Module-level variables:**
- At module scope, unannotated assignments are inferred but widened: the type is
  made `nonliteral().inexact()` to allow reassignment to subtypes

**Function parameters:**
- Annotated parameters get their annotation type
- Unannotated parameters get `dynamic` (with a perf warning)

**Return types:**
- Annotated return types are used as declared
- Unannotated returns default to `dynamic`

**Class attributes:**
- Annotated attributes become typed `Slot`s on the class
- Attributes assigned in `__init__` (via `self.x = ...`) are discovered by the
  `InitVisitor` during the declaration pass
- Unannotated `self.x = ...` assignments in `__init__` create `dynamic`-typed slots

**Expression types:**
- Every expression node is assigned a type during the TypeBinder pass
- Binary operations resolve via `bind_binop`/`bind_reverse_binop` methods
- Calls resolve via `bind_call` which maps arguments and infers return types
- Attribute access resolves via `resolve_attr` and the MRO chain
- Subscript operations resolve via `bind_subscr`

### 3.2 What SP Does NOT Infer

- **Generic type parameters on functions**: SP does not support generic methods.
  The comment in `GenericClass.bind_generics()` states: "We don't yet support
  generic methods, so all of the generic parameters are coming from the type
  definition."

- **Complex typing constructs**: Many constructs are treated as `dynamic`:
  - `TypeVar` -> `dynamic`
  - `Generic` -> `dynamic`
  - `Callable` (from typing) -> `dynamic`
  - `Awaitable`, `Coroutine`, `Iterable`, `Iterator` -> `dynamic`
  - `Collection` -> `dynamic`
  - `Type[X]` -> `dynamic`
  - `enumerate`, `zip`, `map`, `filter`, `reversed` -> `dynamic`

- **Protocols**: Classes inheriting from `Protocol` are treated as `dynamic` and
  compiled non-statically. The declaration visitor explicitly sets them to `dynamic`:
  ```python
  if base is self.type_env.protocol:
      klass = self.type_env.dynamic
      break
  ```

- **NamedTuple**: Similarly forced to `dynamic`

- **TypedDict**: Forced to `dynamic` with a TODO comment

- **Relative imports**: Raise `NotImplementedError`

- **Classes nested inside functions**: Forced to `dynamic`

- **Closures/cell variables**: Types of cell variables are not resolved for
  soundness reasons (nested functions could modify them)

- **Complex decorator stacking**: Unknown decorators result in
  `UnknownDecoratedMethod`, forcing dynamic dispatch

### 3.3 Inference for Built-in Functions

SP has special handling for many built-in functions:

- `isinstance()` -> `bool` with narrowing effects
- `issubclass()` -> `bool`
- `len()` -> specialized `LenFunction` (boxed for builtins, unboxed via `clen`)
- `min()`/`max()` -> `ExtremumFunction` with ternary optimization
- `sorted()` -> `SortedFunction`
- `reveal_type()` -> diagnostic function
- `box()`/`unbox()` -> primitive boxing/unboxing
- `cast()` -> type casting with runtime check
- `prod_assert()` -> production assertion

Many built-in functions are reflected from their actual Python implementations
via `reflect_builtin_function()`, which introspects the function's signature to
create typed `BuiltinFunction` objects.

## 4. Soundness Model

### 4.1 Static Checking

SP's type checker is **locally sound within its inference scope**: it will flag
type errors where it has type information. The `TypeBinder` calls
`check_can_assign_from()` at every assignment, function call, and return statement.

However, SP is **deliberately unsound at boundaries**:
- The `dynamic` type acts as a universal receiver (accepts anything non-primitive)
- Unannotated code silently falls back to `dynamic`
- Many typing constructs are modeled as `dynamic`

This is a gradual typing approach: annotated code is checked; unannotated code passes
through without static errors.

### 4.2 Runtime Enforcement

SP's key differentiator is that it generates **runtime type checks** in addition to
static analysis:

1. **Argument type checks**: When a function's graph is created, SP encodes argument
   type descriptors (`type_descr`) into the bytecode's extra constants. The runtime
   checks incoming arguments against these descriptors:
   ```python
   def _get_arg_types(self, func, args, graph):
       arg_checks = []
       for arg in args.args:
           t = self.get_type(arg)
           if self._is_type_checked(t.klass):
               arg_checks.append(self._calculate_idx(arg.arg, i, cellvars))
               arg_checks.append(t.klass.type_descr)
       return tuple(arg_checks)
   ```

2. **Return type checks**: The return type descriptor is embedded alongside argument
   checks in the function's extra constants.

3. **Field type checks**: `STORE_FIELD` opcodes perform runtime type checking on
   attribute assignments to typed slots.

4. **CheckedDict/CheckedList**: These are runtime-enforced generic containers.
   Unlike regular `dict`/`list`, they validate key/value types at insertion time.
   They are enabled per-module via `from __static__.compiler_flags import checked_dicts`.

5. **Final enforcement**: The runtime prevents reassignment to `Final` attributes.

6. **VTable dispatch**: The C runtime (`fbcode/cinderx/StaticPython/`) maintains
   vtables for statically-compiled classes, enabling direct method dispatch while
   still supporting monkey-patching (vtable entries become indirect pointers that
   track changes).

### 4.3 Type Descriptors

Every `Class` produces a `type_descr` tuple used by the runtime for type checking:

- Regular class: `("module", "ClassName")`
- Exact class: `("module", "ClassName", "!")`
- C primitive: `("__static__", "int64", "#")`
- Optional: `("module", "ClassName", "?")`
- Dynamic: Falls back to `("builtins", "object")`

The runtime (`classloader.c`) resolves these descriptors to actual `PyTypeObject*`
pointers and performs `isinstance`-style checks.

### 4.4 The Exact Type Boundary

A critical soundness decision: SP generates `LOAD_FIELD`/`STORE_FIELD` for
attribute access on typed slots, but only when:
1. The receiver type is known (not `dynamic`)
2. The slot exists in the class's member dict
3. The attribute name is not `__dict__`

For inexact types, the runtime must verify that the actual type has the expected
slot layout. For exact types, this is guaranteed.

## 5. Type Narrowing and Refinement

### 5.1 Narrowing Architecture

SP implements type narrowing through the `NarrowingEffect` algebra in `effects.py`.
The algebra consists of:

- `NoEffect` / `NO_EFFECT`: No narrowing (singleton)
- `NegationEffect`: Reverses the sense of an effect (for `not`, `else` branches)
- `AndEffect`: Conjunction of effects (for `and` expressions)
- `OrEffect`: Disjunction of effects (for `or` expressions)
- `IsInstanceEffect`: The primary narrowing effect from `isinstance()` checks

Each effect supports three operations:
- `apply(type_state)`: Narrow types (used when entering `if` body)
- `undo(type_state)`: Restore original types
- `reverse(type_state)`: Apply the opposite narrowing (used in `else` branches)

### 5.2 isinstance Narrowing

`IsInstanceEffect` is the core narrowing mechanism:

```python
class IsInstanceEffect(NarrowingEffect):
    def __init__(self, node, prev, inst, visitor):
        self.prev = prev           # original type
        self.inst = inst           # narrowed-to type
        # For unions, compute the reverse (what's left after removing inst)
        if isinstance(prev, UnionInstance):
            type_args = tuple(
                ta for ta in prev.klass.type_args
                if not inst.klass.can_assign_from(ta)
            )
            reverse = visitor.type_env.get_union(type_args).instance
        self.rev = reverse
```

This handles both positive narrowing (`isinstance(x, Foo)` -> `x` is `Foo`) and
negative narrowing (`not isinstance(x, Foo)` -> `x` is the union minus `Foo`).

### 5.3 None Narrowing (Truthy Refinement)

SP narrows `Optional[T]` to `T` in truthy contexts via `refine_truthy()`:

```python
def refine_truthy(self, node):
    type_ = self.get_type(node)
    if isinstance(type_, UnionInstance):
        effect = IsInstanceEffect(
            node, type_, self.type_env.none.instance, self,
        )
        return effect.not_()  # Truthy means NOT None
```

This works for:
- `if x:` where `x: Optional[T]` -> `x` is `T` in the body
- `if x is not None:` -> explicit None check
- `if x is None:` -> reverse narrowing

### 5.4 Control Flow Integration

The `TypeBinder` integrates narrowing with control flow:

- **if/else**: Effects from the test are applied in the if body and reversed in the
  else body. At join points, types are merged using `LocalsBranch.merge()`.

- **while loops**: Uses `iterate_to_fixed_point()` which repeatedly analyzes the loop
  body until local types converge (with a limit of 50 iterations).

- **and/or expressions**: Effects are chained using `AndEffect`/`OrEffect` and
  applied/undone as short-circuit evaluation dictates.

- **assert statements**: The effect of `assert isinstance(x, T)` narrows `x` to `T`
  for the remainder of the scope.

### 5.5 Field Refinement

SP supports refinement of object fields (e.g., `self.x`) through a separate mechanism:

```python
class TypeState:
    local_types: dict[str, Value]       # refined local variable types
    refined_fields: dict[str, RefinedFields]  # refined field types
```

Field refinements track:
- The refined type
- A temporary variable index (for codegen to hoist field reads)
- The set of AST nodes involved (to coordinate reads/writes)

Field refinement is only applied when:
- The base is a `Name` node (e.g., `self`)
- The attribute has a typed `Slot` on the class
- The access is not through `__dict__`

Importantly, field refinements are **cleared by default** after any statement that
is not explicitly marked as `PreserveRefinedFields`. This is a conservative safety
measure because arbitrary code execution (e.g., method calls) could invalidate
field types. The `PreserveRefinedFields` marker is set for:
- Constants, name accesses, pass statements
- assert statements (after the effect is applied)
- Simple assignments to refinable targets
- `is`/`is not` comparisons
- if/while/match statements

Additionally, if the test expression in a conditional is not a `bool`, field
refinements are cleared because `__bool__()` can execute arbitrary code:
```python
def clear_refinements_for_nonbool_test(self, test_node):
    if self.get_type(test_node).klass is not self.type_env.bool:
        self.type_state.refined_fields.clear()
```

### 5.6 Branch Merging

At control flow merge points, `LocalsBranch.merge()` joins types from both branches:

```python
def _join(self, *types):
    return self.type_env.get_union(
        tuple(t.klass.inexact_type() for t in types)
    ).instance
```

This creates a union of the types from each branch. If both branches agree on a type,
the type is preserved. If they disagree, a union is created. Variables that exist in
only one branch are removed (conservative: they might be uninitialized).

## 6. Special Cases

### 6.1 Descriptors

SP models Python's descriptor protocol through the `resolve_descr_get` and
`bind_descr_get` methods on `Value`. Key descriptor types:

- `GetSetDescriptor`: Wraps CPython `getset_descriptor` (C-level properties)
- `ClassGetSetDescriptor`: For `__class__` attribute
- `Slot`: The primary descriptor for typed class attributes; resolves to its
  declared type on instances, returns the `Slot` object itself on classes
- `PropertyMethod`: For `@property` decorated methods

When resolving `obj.attr`, SP walks the MRO and calls `resolve_descr_get` on each
matching member. For `Slot`s, this returns:
- On instance access: the slot's declared type (instance)
- On class access: the `Slot` object itself (unless it's a typed descriptor with
  a default value, in which case it returns the type)

### 6.2 Metaclasses

SP has **minimal metaclass support**. The comment in `_check_final_attribute_reassigned`
notes: "TODO this logic will be inadequate if we support metaclasses". Currently:

- The `type` metatype is hard-coded in `TypeEnvironment.__init__` with circular
  self-referencing (`self.type.klass = self.type`)
- There is no mechanism to define custom metaclasses
- Classes that inherit from `type` are not modeled specially

### 6.3 Decorators

SP has a sophisticated decorator resolution system:

1. **Known decorators**: `@staticmethod`, `@classmethod`, `@property`,
   `@typing.final`, `@__static__.inline`, `@__static__._donotcompile`,
   `@dataclass`, `@__static__.allow_weakrefs`, `@__static__.dynamic_return`,
   etc. Each has a dedicated class that implements `resolve_decorate_function()`.

2. **Identity decorators**: `@mutable`, `@strict_slots`, `@loose_slots`,
   `@freeze_type` are treated as identity decorators (they don't change the type).

3. **Unknown decorators**: If SP cannot resolve a decorator, it creates an
   `UnknownDecoratedMethod`, which forces the function to use dynamic dispatch.
   This is a conservative but correct fallback.

4. **`TransparentDecoratedMethod`**: For decorators like `@staticmethod` and
   `@classmethod` that are understood but don't change the function's type signature.

5. **`TransientDecoratedMethod`**: For decorators that temporarily wrap a function
   during class construction (like `@overload`).

### 6.4 *args/**kwargs

SP tracks whether a function has `*args` and `**kwargs`:

- `*args`: Typed as `tuple` (exact)
- `**kwargs`: Typed as `dict` (exact)

The individual element types within `*args` and `**kwargs` are **not** tracked.
This means that SP does not support `ParamSpec` or typed `*args` / `**kwargs`.

In the override validation (`validate_compat_signature`), SP checks that `*args`
and `**kwargs` presence matches between base and override methods.

### 6.5 Overloads

SP recognizes `@typing.overload` but does not implement full overload resolution.
The `overload` decorator results in a `TransientDecoratedMethod` during the
declaration pass, and `FunctionGroup` is used to group overloaded functions.
However, the actual dispatch based on argument types is not statically resolved;
overloaded functions are essentially treated as dynamic.

### 6.6 Generics

SP supports generics through `GenericClass` and `GenericParameter`:

- **Type parameter variance**: `GenericParameter` tracks `variance` (invariant,
  covariant, contravariant) which is used in `is_subclass_of` checks
- **Generic instantiation**: `make_generic_type()` creates concrete instantiations
  by substituting type parameters. E.g., `CheckedDict[str, int]` creates a new
  `CheckedDict` class with `type_args = (str, int)`.
- **Bounds**: `GenericParameter` supports `bound` (e.g., `TClass = TypeVar("TClass", bound=type)`)
- **No generic methods**: Only class-level generics are supported
- **Generic subtyping**: `GenericClass.is_subclass_of` checks variance-aware
  subtyping of type arguments

The `TypeEnvironment` caches generic instantiations to avoid creating duplicate
types for the same parameterization.

### 6.7 Enums

SP has dedicated `EnumType` support:
- Classes inheriting from `__static__.Enum`, `__static__.IntEnum`, or
  `__static__.StringEnum` are treated specially
- Enum values are bound via `bind_enum_value()` during the type binding pass
- The `EnumBindingScope` overrides `declare()` to track enum member assignments

### 6.8 Dataclasses

SP models dataclasses through:
- `DataclassDecorator`: Resolves `@dataclass` to create a `Dataclass` class
- `Dataclass` (extends `Class`): Handles field discovery, `__init__` synthesis,
  `InitVar` processing
- `DataclassField`: Represents individual dataclass fields with their types and
  default values

### 6.9 Async

- Async functions have their return type wrapped in `AwaitableTypeRef`
- `await` expressions resolve through `bind_await()` which unwraps the awaitable
- Async for loops treat the iterator type as `dynamic` (no `__aiter__` resolution)
- `async with` is handled similarly to regular `with` but without the
  exception-suppression analysis

## 7. Codegen Integration

### 7.1 How Types Drive Code Generation

The code generator (`StaticCodeGenBase`) queries type information from AST nodes
to emit specialized bytecode. The type-to-codegen integration follows a dispatch
pattern where each `Value` subclass defines `emit_*` methods:

**Attribute access:**
- Typed slots: `LOAD_FIELD` / `STORE_FIELD` (direct memory access)
- Dynamic attributes: `LOAD_ATTR` / `STORE_ATTR` (dictionary lookup)
- Typed descriptors with defaults: `emit_invoke_method` for getter/setter

**Method calls:**
- Static dispatch: `INVOKE_FUNCTION` with type descriptor path
- Virtual dispatch: `INVOKE_METHOD` with vtable slot
- Dynamic dispatch: Regular `CALL_FUNCTION`

**Primitive operations:**
- `PRIMITIVE_BINARY_OP` with operation codes for int/double arithmetic
- `LOAD_LOCAL` / `STORE_LOCAL` with type descriptors for primitives
- `PRIMITIVE_BOX` / `PRIMITIVE_UNBOX` for boxing/unboxing

**Type checks:**
- `CAST` opcode for type assertions
- `TP_ALLOC` for typed object allocation
- `CHECK_ARGS` for function entry type validation

### 7.2 Performance Warnings

The codegen emits performance warnings when it encounters patterns that prevent
optimization:

```python
def emit_load_attr_from(self, node, code_gen, klass):
    if klass is klass.type_env.dynamic:
        code_gen.perf_warning(
            "Define the object's class in a Static Python "
            "module for more efficient attribute load", node)
```

Similarly, the TypeBinder emits warnings for unannotated parameters:
```python
self.perf_warning(
    "Missing type annotation for argument '...' "
    "prevents type specialization in Static Python", arg)
```

### 7.3 Inline Optimization

SP supports function inlining through the `@__static__.inline` decorator:

- Only single-expression-body functions (one `return` statement) can be inlined
- Arguments are substituted directly into the expression via `InlineRewriter`
- Complex arguments are spilled to temporaries
- Inlining depth is limited to 20 levels
- Inlining is disabled when `enable_patching=True`

### 7.4 The CI_CO_STATICALLY_COMPILED Flag

Every function compiled by the static compiler gets the `CI_CO_STATICALLY_COMPILED`
flag set on its code object. The runtime uses this flag to:
- Enable vtable dispatch
- Apply argument type checks at function entry
- Apply return type checks at function exit
- Route through the static Python classloader

## 8. Error Model

### 8.1 Error Types

SP uses two primary error types:

1. **`TypedSyntaxError`**: Raised for type errors during analysis. Despite the name,
   these are type errors, not syntax errors. Examples:
   - "type mismatch: X cannot be assigned to Y"
   - "Cannot assign to a Final attribute"
   - "Cannot redefine local variable"
   - "cannot iterate over X"
   - "cannot call X"
   - "Name `X` is not defined"

2. **`StaticTypeError`**: A runtime error (extends `TypeError`) raised when runtime
   type checks fail. This is defined in the C extension and raised by `CAST`,
   `CHECK_ARGS`, and `STORE_FIELD` opcodes.

### 8.2 Error Sink

Errors flow through an `ErrorSink` abstraction:

- **`ErrorSink`** (default): Throws `TypedSyntaxError` immediately on the first error
- **`CollectingErrorSink`**: Collects all errors without throwing (used during
  fixed-point iteration for loops)

The compiler checks `error_sink.has_errors` after the binding pass and raises the
first error before proceeding to codegen:
```python
if self.error_sink.has_errors:
    raise self.error_sink.errors[0]
```

### 8.3 Error Context

Errors include file and line information through the `error_context` context manager:
```python
def error_context(self, node):
    return self.error_sink.error_context(self.filename, node)
```

### 8.4 Inference Failures

When SP cannot determine a type, it falls back to `dynamic` rather than reporting
an error. This is the fundamental design choice that enables gradual typing:

- Unknown imports -> `dynamic`
- Unannotated parameters -> `dynamic` (with perf warning)
- Unresolvable decorators -> `UnknownDecoratedMethod` (dynamic dispatch)
- Protocols, NamedTuples, TypedDicts -> `dynamic`
- Complex typing constructs -> `dynamic`
- Lambda return type -> `dynamic`
- Generator/yield type -> `dynamic`
- `async for` target -> `dynamic`
- `with` variable -> `dynamic`

## 9. Implications for Pyrefly Integration

### 9.1 What Pyrefly Could Replace

Pyrefly could potentially replace SP's type inference with richer analysis:

1. **Broader typing support**: Pyrefly handles `TypeVar`, `Generic`, `Protocol`,
   `TypedDict`, `ParamSpec`, `Concatenate`, and other advanced typing constructs
   that SP treats as `dynamic`.

2. **More complete narrowing**: Pyrefly likely has more sophisticated control flow
   analysis and supports narrowing patterns beyond `isinstance` and `is None`.

3. **Better error messages**: Pyrefly's error model is designed for IDE integration,
   while SP's errors are geared toward compilation.

4. **Cross-module analysis**: Pyrefly performs full cross-module type analysis,
   while SP relies on what it can discover through imports.

### 9.2 What Pyrefly Must Preserve

To replace SP's type inference, Pyrefly would need to:

1. **Produce type descriptors**: SP's codegen needs `type_descr` tuples for each
   type. Pyrefly would need to map its internal type representations to SP's
   descriptor format.

2. **Track exact vs. inexact types**: This distinction is critical for codegen
   optimization. Pyrefly would need to track whether a type is exact.

3. **Support primitive types**: SP's `CIntType` and `CDoubleType` are not standard
   Python types but SP-specific extensions. Pyrefly would need to understand these.

4. **Handle the `__static__` module**: All special types and functions from
   `__static__` would need to be modeled.

5. **Maintain soundness guarantees**: SP's runtime type checks depend on the static
   analysis being conservative (never claiming a type is narrower than it actually
   is). An incorrect inference could cause runtime crashes.

6. **Preserve dynamic fallback behavior**: SP's codegen must handle `dynamic` types
   gracefully; Pyrefly cannot upgrade `dynamic` to a specific type without ensuring
   the runtime can handle it.

### 9.3 Key Architectural Differences

| Aspect | Static Python | Pyrefly |
|--------|--------------|---------|
| Language | Python | Rust |
| Type representation | Class hierarchy in Python | Custom Rust types |
| Inference scope | Per-module, forward-only | Full project |
| Narrowing | `isinstance`, `is None`, truthy | Broader patterns |
| Generics | Class-level only, no generic methods | Full generic support |
| Protocols | Treated as dynamic | Structural subtyping |
| TypeVar | Treated as dynamic | Full solver |
| Error recovery | Fall back to dynamic | Continue with errors |
| Output | Typed AST nodes + type descriptors | Type information for IDE |

### 9.4 Migration Strategy Considerations

A practical migration could proceed in phases:

1. **Phase 1**: Pyrefly provides type information in parallel with SP, used for
   IDE features only. SP continues to drive codegen.

2. **Phase 2**: Pyrefly's type information is translated to SP's type descriptor
   format and used to augment SP's inference (filling in types where SP gives up).

3. **Phase 3**: Pyrefly fully replaces SP's type inference, producing the typed
   AST that SP's codegen consumes.

The critical challenge is Phase 3: Pyrefly would need to produce output in the
exact format that SP's codegen expects, including type descriptors, exact/inexact
distinctions, and primitive type information.

## Appendix A: Source File Index

| File Path | Description |
|-----------|-------------|
| `fbcode/cinderx/PythonLib/cinderx/compiler/static/compiler.py` | Main compiler entry point |
| `fbcode/cinderx/PythonLib/cinderx/compiler/static/types.py` | Type system (~10,600 lines) |
| `fbcode/cinderx/PythonLib/cinderx/compiler/static/type_binder.py` | Local type inference |
| `fbcode/cinderx/PythonLib/cinderx/compiler/static/declaration_visitor.py` | Declaration collection |
| `fbcode/cinderx/PythonLib/cinderx/compiler/static/effects.py` | Narrowing effect algebra |
| `fbcode/cinderx/PythonLib/cinderx/compiler/static/module_table.py` | Module symbol table |
| `fbcode/cinderx/PythonLib/cinderx/compiler/static/visitor.py` | Base visitor class |
| `fbcode/cinderx/PythonLib/cinderx/compiler/static/__init__.py` | Code generator |
| `fbcode/cinderx/PythonLib/cinderx/compiler/static/definite_assignment_checker.py` | Definite assignment analysis |
| `fbcode/cinderx/PythonLib/__static__/__init__.py` | Runtime `__static__` module |
| `fbcode/cinderx/PythonLib/__static__/type_code.py` | Type code constants |
| `fbcode/cinderx/PythonLib/__static__/enum.py` | Static Python enum support |
| `fbcode/cinderx/StaticPython/classloader.c` | Runtime class loader and vtable management |
| `fbcode/cinderx/StaticPython/type.c` | Runtime type extensions |
| `fbcode/cinderx/StaticPython/checked_dict.c` | Runtime checked dictionary |
| `fbcode/cinderx/StaticPython/checked_list.c` | Runtime checked list |
| `fbcode/cinderx/StaticPython/vtable.h` | VTable structures |
| `fbcode/cinderx/StaticPython/thunks.c` | Method dispatch thunks |
