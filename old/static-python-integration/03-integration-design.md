# Integration Design: Pyrefly as Static Python's Type Inference Engine

## Executive Summary

This document presents a comprehensive design for replacing Static Python's (SP)
built-in type inference with Pyrefly. The design is based on detailed analysis of
both codebases: SP's type system, inference pipeline, and codegen requirements
(Document 01), and Pyrefly's type system, soundness characteristics, and
extensibility points (Document 02).

The central thesis is that Pyrefly can serve as SP's type inference engine, but it
requires: (a) new type constructs for SP-specific primitives, (b) a soundness
control mechanism to distinguish compiler-safe inferences from gradual-typing
approximations, (c) a well-defined output interface producing the type metadata
SP's codegen needs, and (d) a phased migration strategy that allows incremental
adoption with continuous validation.

**Key recommendation:** Build a "Pyrefly-SP" mode as a compile-time feature flag
within Pyrefly, rather than forking. This mode would add SP-specific types,
disable unsound inference rules, and expose a structured output format for
SP's codegen to consume via a PyO3 bridge.

---

## Table of Contents

1. [Type System Mapping](#1-type-system-mapping)
2. [Soundness Controls Design](#2-soundness-controls-design)
3. [What to Strip and Simplify](#3-what-to-strip-and-simplify)
4. [What to Add](#4-what-to-add)
5. [Interface Design](#5-interface-design)
6. [Migration Strategy](#6-migration-strategy)
7. [Risk Analysis](#7-risk-analysis)
8. [Appendix: File References](#appendix-file-references)

---

## 1. Type System Mapping

### 1.1 Mapping Table

The following table maps every SP type constructor to its Pyrefly equivalent. SP
types are defined in `fbcode/cinderx/PythonLib/cinderx/compiler/static/types.py`.
Pyrefly types are defined in `crates/pyrefly_types/src/types.rs`.

| SP Type Constructor | SP Class | Pyrefly Equivalent | Status |
|---|---|---|---|
| Object (instance) | `Class` -> `Object` | `Type::ClassType(ClassType)` | MAPPED (see 1.2) |
| Class object | `Class` | `Type::ClassDef(Class)` | MAPPED |
| Exact type | `Class(is_exact=True)` | -- | MISSING (see 4.2) |
| Dynamic | `DynamicClass` | `Type::Any(AnyStyle)` | MAPPED (semantic difference, see 1.3) |
| None | `NoneType` | `Type::None` | MAPPED |
| Union | `UnionType` | `Type::Union(Box<Union>)` | MAPPED |
| Optional | `OptionalType` | `Type::Union` (union with `Type::None`) | MAPPED |
| Generic class | `GenericClass` | `Type::ClassType` with `TArgs` | MAPPED |
| Generic parameter | `GenericParameter` | `Type::Quantified(Box<Quantified>)` | MAPPED |
| Literal | `LiteralType` | `Type::Literal(Box<Literal>)` | MAPPED (Pyrefly has richer literals) |
| Final | `FinalClass` | `Qualifier::Final` in `Annotation` | MAPPED (different representation) |
| ClassVar | `ClassVar` | `Qualifier::ClassVar` in `Annotation` | MAPPED |
| InitVar | `InitVar` | `Qualifier::InitVar` in `Annotation` | MAPPED |
| Annotated | `AnnotatedType` | `Qualifier::Annotated` | MAPPED |
| CIntType | `CIntType` (int8-uint64) | -- | MISSING (see 4.1) |
| CDoubleType | `CDoubleType` | -- | MISSING (see 4.1) |
| Function | `Function` | `Type::Function(Box<Function>)` | MAPPED |
| Callable | `Callable` | `Type::Callable(Box<Callable>)` | MAPPED |
| Slot | `Slot` | Class field system (`ClassFieldProperties`) | PARTIAL (see 1.4) |
| Method | `MethodType` | `Type::BoundMethod(Box<BoundMethod>)` | MAPPED |
| Module | `ModuleType`/`ModuleInstance` | `Type::Module(ModuleType)` | MAPPED |
| Enum | `EnumType` | `ClassMetadata::enum_metadata` + `Lit::Enum` | MAPPED |
| Dataclass | `Dataclass` | `ClassMetadata::dataclass_metadata` | MAPPED |
| CheckedDict | `CheckedDict` (GenericClass) | -- | MISSING (see 4.3) |
| CheckedList | `CheckedList` (GenericClass) | -- | MISSING (see 4.3) |
| Array | `ArrayClass` (GenericClass) | -- | MISSING (see 4.3) |
| TypedDict | (treated as dynamic) | `Type::TypedDict(TypedDict)` | Pyrefly BETTER |
| Protocol | (treated as dynamic) | `ClassMetadata::protocol_metadata` | Pyrefly BETTER |
| NamedTuple | (treated as dynamic) | `ClassMetadata::named_tuple_metadata` | Pyrefly BETTER |
| Overload | `FunctionGroup` (limited) | `Type::Overload(Overload)` | Pyrefly BETTER |
| TypeGuard | (not supported) | `Type::TypeGuard(Box<Type>)` | Pyrefly BETTER |
| TypeIs | (not supported) | `Type::TypeIs(Box<Type>)` | Pyrefly BETTER |
| ParamSpec | (not supported) | `Type::ParamSpec(ParamSpec)` | Pyrefly BETTER |
| TypeVarTuple | (not supported) | `Type::TypeVarTuple(TypeVarTuple)` | Pyrefly BETTER |
| Self | (not supported) | `Type::SelfType(ClassType)` | Pyrefly BETTER |

### 1.2 ClassType Mapping Details

SP's `Class` has a rich hierarchy (`Class -> Object -> Value`) with `instance`,
`members`, `bases`, MRO, and per-class metadata like `is_exact`, `is_final`,
`type_descr`.

Pyrefly's `ClassType` is a pair of `(Class, TArgs)` where:
- `Class` holds the qualified name (`QName`), definition index, precomputed
  type parameters, and field map
- `TArgs` holds the concrete type arguments

The mapping is structurally sound. Pyrefly's `Class` already tracks fields via
`SmallMap<Name, ClassFieldProperties>`, and class-level metadata (is_final,
is_protocol, enum, dataclass, etc.) is stored in
`ClassMetadata` (`pyrefly/lib/alt/types/class_metadata.rs`).

**Gap:** SP's `Class` tracks `is_exact`, `type_descr`, and has methods like
`can_assign_from` that encode exact-type semantics. Pyrefly has no equivalent
concept. See Section 4.2.

### 1.3 Dynamic vs Any

SP's `DynamicClass` and Pyrefly's `Type::Any(AnyStyle)` serve the same role
(gradual typing escape hatch) but with an important behavioral difference:

- SP's `dynamic` **accepts** any non-primitive type but **rejects** C primitives
  (`CType`). This prevents accidentally passing a raw `int64` where a Python
  object is expected.
- Pyrefly's `Any` accepts everything unconditionally.

For compiler integration, Pyrefly-SP mode would need to adopt SP's semantics
where `Any` rejects primitive types. This could be implemented by checking for
the new primitive type variants during subset checking.

### 1.4 Slot Mapping

SP's `Slot` is a rich descriptor type representing typed class attributes. It
tracks: the declared type, whether there is a default value, the slot's module
and class context, and generates `type_descr` tuples for runtime type checking.

Pyrefly represents class fields through `ClassFieldProperties` (annotated,
initialized-on-class, range) and resolves field types lazily through the
`solve_class_field` method in `AnswersSolver`. The actual field type resolution
and descriptor handling happens in `pyrefly/lib/alt/class/class_field.rs` and
`pyrefly/lib/alt/attr.rs`.

**Gap:** Pyrefly's field system does not produce `type_descr` tuples or track
whether a field should use `LOAD_FIELD` vs `LOAD_ATTR`. This metadata would
need to be added as output (see Section 5).

---

## 2. Soundness Controls Design

### 2.1 Problem Statement

Pyrefly currently has no mechanism to distinguish sound from unsound inferences.
The `AnyStyle` enum (`Explicit`, `Implicit`, `Error`) tracks the origin of `Any`
but does not control behavior -- all three styles are equally permissive in
subset checks.

For a compiler, unsound type information can cause incorrect code generation
leading to segfaults, memory corruption, or silent data corruption. SP addresses
this by falling back to `dynamic` (which forces conservative codegen) whenever
inference is uncertain.

### 2.2 Design Options Evaluated

**Option A: Per-Type Confidence Level**

Annotate every `Type` with a soundness tag:
```rust
enum Soundness {
    Sound,                    // Fully verified, compiler can trust
    ConditionallySoundWithRT, // Sound if runtime check is inserted
    Unsound,                  // Cannot be trusted, must use dynamic dispatch
}
```

- *Pros:* Fine-grained; each callsite can decide the right tradeoff.
- *Cons:* The `Type` enum is 4 words (`assert_words!(Type, 4)`); adding a field
  would increase size significantly and propagate through the entire codebase.
  Every type construction site would need to supply a soundness level. The
  performance impact on Pyrefly's core (used for IDE, not just compiler) would
  be unacceptable.

**Verdict: Rejected.** Too invasive, too costly for the IDE use case.

**Option B: Mode Flag Disabling Unsound Rules**

A `CompilerMode` config flag that changes specific inference behaviors:
- Attribute narrowing produces `Any` instead of the narrowed type
- TypeGuard produces `Any`
- hasattr/getattr narrowing produces `Any`
- Empty container inference produces an error instead of `Any` fallback

- *Pros:* Simple to implement; clear semantics; minimal performance impact.
- *Cons:* Binary (on/off); cannot distinguish "conditionally sound with runtime
  check" from "fully unsound". Loses useful information.

**Verdict: Good foundation but insufficient alone.**

**Option C: Any-Taint Tracking**

Track whether a type was derived through an `Any` boundary. Extend `AnyStyle`
or add a separate `Tainted` wrapper:
```rust
enum AnyStyle {
    Explicit,
    Implicit,
    Error,
    Tainted(Box<Type>), // A concrete type that flowed through Any
}
```

- *Pros:* Addresses the #1 unsoundness issue (Any propagation).
- *Cons:* Complex to implement (every operation that interacts with `Any` must
  propagate taint). Doesn't address structural unsoundness (facet narrowing,
  descriptors).

**Verdict: Valuable for later phases but too complex for initial integration.**

**Option D: Hybrid -- Mode Flag + Output Annotations (RECOMMENDED)**

Combine a mode flag with annotations on the *output*, not the internal type
representation:

1. **Compile-time feature flag** (`compiler_mode`): When enabled, Pyrefly
   disables known-unsound inference rules (see Section 3) and uses `Any`
   fallbacks consistently.

2. **Output-level soundness metadata**: When producing output for SP's codegen,
   each type result carries metadata indicating:
   - Whether the type was derived through `Any` boundaries
   - Whether attribute narrowing was involved
   - Whether a runtime check is recommended

   This metadata is produced *at output time* by inspecting the `AnyStyle` of
   the resolved type and the narrowing provenance, rather than carried through
   the entire internal computation.

3. **SP's codegen decides**: Given the type + metadata, SP's codegen can:
   - Trust Sound types and emit specialized bytecode
   - Insert runtime checks for ConditionallySoundWithRT types
   - Fall back to dynamic dispatch for Unsound types

### 2.3 Recommended Approach: Detailed Design

```rust
// In crates/pyrefly_config/src/base.rs
#[derive(Debug, PartialEq, Eq, Deserialize, Serialize, Clone, Copy, Default)]
#[serde(rename_all = "kebab-case")]
pub enum CompilerSafetyMode {
    #[default]
    Standard,         // Normal Pyrefly behavior (IDE use)
    CompilerSafe,     // Disable unsound rules, produce Any fallbacks
}

// In the output interface (new module)
pub struct TypeResult {
    pub ty: Type,
    pub soundness: TypeSoundness,
}

pub enum TypeSoundness {
    /// Type is derived from annotations and sound inference only.
    Sound,
    /// Type is sound if a runtime check is inserted.
    /// The `check_type` indicates what runtime check is needed.
    NeedsRuntimeCheck { check_type: RuntimeCheckKind },
    /// Type flowed through Any or an unsound inference path.
    /// Codegen should use dynamic dispatch.
    Unsound,
}

pub enum RuntimeCheckKind {
    IsInstance,    // isinstance check at the use site
    FieldReload,  // Reload field value after narrowing
    TypeDescr,    // Full type descriptor check
}
```

**Why this works:**
- The internal `Type` representation stays unchanged (4 words, fast)
- The `CompilerSafetyMode` flag is checked at ~5-10 narrowing/inference sites
- The output metadata is computed only when producing results for the compiler
- The approach is additive: it does not break Pyrefly's existing IDE functionality
- SP's codegen retains full control over the trust/check/fallback decision

### 2.4 Implementation Effort

- Config flag: ~20 lines in `crates/pyrefly_config/src/base.rs`
- Narrowing guards: ~5-10 `if compiler_safe_mode` checks in
  `pyrefly/lib/alt/narrow.rs` and `pyrefly/lib/binding/narrow.rs`
- Output metadata: New struct definitions (~50 lines) + annotation logic at
  output boundaries (~200 lines)
- Total: ~300-400 lines of Rust

---

## 3. What to Strip and Simplify

The following Pyrefly inference rules should be disabled or simplified when
`CompilerSafetyMode::CompilerSafe` is active.

### 3.1 Attribute / Facet Narrowing

**Current behavior:** Pyrefly narrows types based on attribute chains like
`x.y`, `x.y.z`, `x[0]`, `x["key"]`. This is implemented via `FacetSubject` /
`FacetChain` in `crates/pyrefly_types/src/facet.rs` and applied in
`pyrefly/lib/alt/narrow.rs`.

**Problem:** Unsound in multithreaded contexts. Another thread could modify
`x.y` between the isinstance check and the use. Properties and descriptors
could return different values on successive calls.

**Recommended action:** In `CompilerSafe` mode, skip all facet-based narrows.
The implementation point is in `NarrowOp::Atomic(Some(facet), op)` -- when
`facet` is `Some(...)` (indicating an attribute chain rather than a plain local
variable), return the original type unchanged.

**Implementation location:** `pyrefly/lib/alt/narrow.rs`, in the function that
applies `AtomicNarrowOp`. Check for `NarrowOp::Atomic(Some(_), _)` and skip.

**Fallback behavior:** The type stays as it was before the narrowing check.
SP's codegen would use dynamic dispatch for the attribute access.

### 3.2 TypeGuard Narrowing

**Current behavior:** `TypeGuard(Type)` completely replaces the original type
with the guard type. This is unsound by specification -- the guard function
could lie.

**Recommended action:** In `CompilerSafe` mode, `TypeGuard` results should
produce `Type::Any(AnyStyle::Implicit)`. `TypeIs` is safer (it intersects
rather than replaces) but should still be annotated as
`NeedsRuntimeCheck(IsInstance)` in the output.

**Implementation location:** `pyrefly/lib/alt/narrow.rs`, in the
`AtomicNarrowOp::TypeGuard` match arm.

### 3.3 hasattr / getattr Narrowing

**Current behavior:** `HasAttr(Name)` narrows the attribute type to
`Any(Implicit)` when the attribute does not exist statically. This introduces
unsound `Any` values.

**Recommended action:** In `CompilerSafe` mode, `HasAttr` and `GetAttr` should
not narrow at all (return the original type). If the attribute does not exist
statically, the compiler cannot make assumptions about it.

**Implementation location:** `pyrefly/lib/alt/narrow.rs`, in the
`AtomicNarrowOp::HasAttr` and `AtomicNarrowOp::GetAttr` match arms.

### 3.4 Empty Container Inference Fallback

**Current behavior:** When a container is created empty (`x = []`), Pyrefly
creates a `PartialContained` variable and tries to infer the type from first
use. If inference fails, it falls back to `Any`.

**Recommended action:** In `CompilerSafe` mode, empty containers without
explicit type annotations should:
- Produce a diagnostic (warning or error) asking for explicit annotation
- Fall back to `Any` (as now) but mark the output as `Unsound`

**Implementation location:** `pyrefly/lib/solver/solver.rs`, in the
`PartialContained` resolution logic.

### 3.5 Equality Narrowing on Mutable Objects

**Current behavior:** `Eq(Expr)` / `NotEq(Expr)` narrows when the comparand
is a `Literal` or `None`. This is sound for immutable literals but technically
unsound for objects that override `__eq__`.

**Recommended action:** No change needed. The current behavior already restricts
equality narrowing to literals and None, which is conservative enough for
compiler use. The Pyrefly implementation correctly limits this.

### 3.6 Summary of Compiler-Safe Mode Changes

| Inference Rule | Standard Mode | CompilerSafe Mode |
|---|---|---|
| isinstance on locals | Narrow | Narrow (sound) |
| isinstance on attributes | Narrow via facet | Skip (return original type) |
| is / is not (singletons) | Narrow | Narrow (sound) |
| Truthiness | Narrow | Narrow (sound) |
| TypeGuard | Replace type | Return Any |
| TypeIs | Intersect | Intersect (with runtime check annotation) |
| hasattr / getattr | Narrow to Any | Skip (return original type) |
| Empty container | Infer or Any | Infer or Any + diagnostic |
| Equality (literals) | Narrow | Narrow (sound) |
| Pattern matching | Narrow | Narrow (sound) |
| len checks | Narrow | Narrow (sound for tuples) |

---

## 4. What to Add

### 4.1 Primitive Types (CInt, CDouble)

SP defines primitive types via `CIntType` and `CDoubleType` in the `__static__`
module. These represent machine-level values, not Python objects:

- `int8`, `int16`, `int32`, `int64`
- `uint8`, `uint16`, `uint32`, `uint64`
- `double` (64-bit float)
- `cbool` (C boolean)
- `char` (single character)

**Design: New Type Variant**

Add a new variant to the `Type` enum in `crates/pyrefly_types/src/types.rs`:

```rust
/// A Static Python primitive type (not a Python object).
/// These types have value semantics and support specialized bytecode.
Primitive(PrimitiveType),
```

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
#[derive(Visit, VisitMut, TypeEq)]
pub enum PrimitiveType {
    Int8,
    Int16,
    Int32,
    Int64,
    UInt8,
    UInt16,
    UInt32,
    UInt64,
    Double,
    CBool,
    Char,
}
```

**Subset rules:**
- `Primitive(X)` is NOT a subset of `Any` (matching SP's behavior where dynamic
  rejects C primitives)
- `Primitive(X)` is a subset of `Primitive(X)` only (no implicit widening)
- Boxing: `Primitive(Int64)` can be explicitly boxed to `int` via `box()` call

**Operations:**
- Binary ops between primitive types produce primitive types
  (`Primitive(Int64) + Primitive(Int64) -> Primitive(Int64)`)
- This would need handling in `pyrefly/lib/alt/expr.rs` for binary/unary ops

**Implementation effort:** ~200 lines for the type definition, ~100 lines for
subset rules in `pyrefly/lib/solver/subset.rs`, ~200 lines for operation
handling.

### 4.2 Exact vs Inexact Type Distinction

SP distinguishes between exact and inexact types. This is critical for codegen:
- Exact types allow direct slot access (`LOAD_FIELD`) and vtable calls
  (`INVOKE_METHOD`)
- Inexact types may require more dynamic dispatch or runtime type checks

**Design: Flag on ClassType**

Add an `is_exact` flag to `ClassType` in `crates/pyrefly_types/src/class.rs`:

```rust
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
#[derive(Visit, VisitMut, TypeEq)]
pub struct ClassType(Class, TArgs, TypePrecision);

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
#[derive(Visit, VisitMut, TypeEq)]
pub enum TypePrecision {
    Exact,   // Known to be precisely this class (from constructor call)
    Inexact, // Could be this class or a subclass (from annotation)
}
```

**Inference rules:**
- `x = MyClass()` -> `ClassType(MyClass, [], Exact)` (constructor creates exact)
- `x: MyClass` -> `ClassType(MyClass, [], Inexact)` (annotation is inexact)
- `isinstance(x, MyClass)` -> `ClassType(MyClass, [], Inexact)` (could be subclass)
- `type(x) is MyClass` -> `ClassType(MyClass, [], Exact)` (identity check)

**Subset rules:**
- `Exact(C) <: Inexact(C)` (exact is more specific)
- `Inexact(C) <: Inexact(C)` (normal subtyping)
- `Exact(C) <: Exact(C)` only if same class (no subclass relationship)

**Concern:** This adds a word to `ClassType`, which is one of the most common
types. The `assert_words!(Type, 4)` constraint would need to be verified.
An alternative is to track exactness only in the output metadata (TypeResult)
rather than in the internal Type, deferring the computation to output time.

**Recommendation:** Start with output-level exactness tracking (cheaper to
implement, no internal Type changes). If codegen needs require it at the
inference level, upgrade to the internal flag in a later phase.

### 4.3 CheckedDict, CheckedList, and Array

These are runtime-enforced generic containers from `__static__`:
- `CheckedDict[K, V]`: Like `dict[K, V]` but validates key/value types at
  insertion time
- `CheckedList[T]`: Like `list[T]` but validates element types at insertion
- `Array[T]`: Fixed-size static array

**Design:** Model these as normal generic classes defined in a synthetic
`__static__` module stub. They can use the existing `ClassType` with `TArgs`
mechanism. No new `Type` variants are needed.

```python
# Synthetic __static__.pyi stub
class CheckedDict(dict[_KT, _VT]):
    """Runtime type-checked dictionary."""
    ...

class CheckedList(list[_T]):
    """Runtime type-checked list."""
    ...

class Array(Generic[_T]):
    """Fixed-size static array."""
    def __getitem__(self, index: int) -> _T: ...
    def __setitem__(self, index: int, value: _T) -> None: ...
    def __len__(self) -> int: ...
```

**Implementation:** Create a `.pyi` stub file for `__static__` and add it to
Pyrefly's module resolution search path. The existing generic class machinery
handles the type parameter tracking.

**Metadata output:** The output interface (Section 5) would need to indicate
that a `dict` type is actually a `CheckedDict` (so codegen can emit the right
constructor). This is tracked via the qualified name of the class.

### 4.4 The `__static__` Module

SP's `__static__` module provides:
- Primitive types (`int8`, ..., `uint64`, `double`, `cbool`, `char`)
- Container types (`CheckedDict`, `CheckedList`, `Array`)
- Utility functions (`box`, `unbox`, `cast`, `prod_assert`, `clen`)
- Decorators (`@inline`, `@_donotcompile`, `@allow_weakrefs`, `@dynamic_return`)
- Compiler flags (`checked_dicts`, etc.)
- Enum base classes (`Enum`, `IntEnum`, `StringEnum`)

**Design:** Create a synthetic `__static__.pyi` stub file with type
definitions for all of the above. For primitive types, map them to the new
`PrimitiveType` variants. For utility functions, provide special handling in
Pyrefly's `special_calls.rs`.

**Box/Unbox:** `box(x)` converts `Primitive(Int64)` to `int`, `unbox(x)`
converts `int` to `Primitive(Int64)`. These need special call handling in
`pyrefly/lib/alt/special_calls.rs` or `pyrefly/lib/alt/call.rs`.

**Cast:** `cast(T, x)` asserts `x` is of type `T` with a runtime check. In
Pyrefly, this would return `T` with a `NeedsRuntimeCheck(TypeDescr)` soundness
annotation.

### 4.5 Type Descriptors for Codegen

SP's codegen relies on `type_descr` tuples to generate runtime type checks:

| Type | Descriptor |
|---|---|
| Regular class | `("module", "ClassName")` |
| Exact class | `("module", "ClassName", "!")` |
| C primitive | `("__static__", "int64", "#")` |
| Optional | `("module", "ClassName", "?")` |
| Dynamic | `("builtins", "object")` |

**Design:** Add a `type_descr()` method to the output interface, not to the
internal `Type` representation. This method maps Pyrefly types to SP descriptor
tuples:

```rust
impl TypeResult {
    pub fn type_descr(&self) -> TypeDescriptor {
        match &self.ty {
            Type::ClassType(ct) => {
                let module = ct.class_object().module_name().as_str();
                let name = ct.class_object().name().as_str();
                if self.is_exact() {
                    TypeDescriptor::Exact(module, name)
                } else {
                    TypeDescriptor::Inexact(module, name)
                }
            }
            Type::Primitive(p) => TypeDescriptor::Primitive(p),
            Type::Any(_) => TypeDescriptor::Dynamic,
            Type::None => TypeDescriptor::Inexact("builtins", "None"),
            Type::Union(u) => {
                // Check for Optional pattern (T | None)
                if let Some(inner) = u.as_optional() {
                    TypeDescriptor::Optional(Box::new(inner.type_descr()))
                } else {
                    TypeDescriptor::Dynamic // Unions fall back to dynamic
                }
            }
            _ => TypeDescriptor::Dynamic,
        }
    }
}
```

---

## 5. Interface Design

### 5.1 Options Evaluated

**Option A: Pyrefly produces a typed AST that SP's codegen consumes**

SP's codegen walks the Python AST and queries type information per node. This
would require Pyrefly to produce a data structure mapping AST nodes to types.

- *Pros:* Cleanest integration; SP's codegen gets exactly what it needs.
- *Cons:* Pyrefly uses `ruff_python_ast` AST nodes while SP uses Python's `ast`
  module. The AST representations are fundamentally different (Rust vs Python).

**Option B: Pyrefly produces a serialized type map**

Pyrefly outputs a JSON or binary mapping from source locations to type
information. SP reads this and correlates with its own AST.

- *Pros:* Language-agnostic boundary; easy to debug (JSON).
- *Cons:* Serialization/deserialization overhead; fragile location-based
  matching between Rust and Python ASTs; large output for big files.

**Option C: Pyrefly integrated directly into SP's pipeline**

Replace SP's DeclarationVisitor and TypeBinder with Pyrefly, keeping SP's
CodeGenerator. Run Pyrefly in-process.

- *Pros:* Tightest integration; no serialization overhead.
- *Cons:* Requires a Rust-Python bridge (PyO3). SP's codegen currently queries
  type info from Python `Value` objects; it would need to query Rust types
  instead.

**Option D: PyO3 bridge with query API (RECOMMENDED)**

Expose Pyrefly as a Python module via PyO3. SP's codegen calls Pyrefly to get
type information for specific AST locations, expressions, and names.

- *Pros:* SP's codegen can be adapted incrementally; no need to change AST
  representation; PyO3 is battle-tested; types are queried on-demand rather
  than materialized all at once.
- *Cons:* Requires adding PyO3 as a dependency to Pyrefly; cross-language
  function call overhead per query (mitigated by batching).

### 5.2 Recommended Interface: PyO3 Query API

**Architecture:**

```
                     PyO3 boundary
                         |
SP's compiler.py         |    Pyrefly (Rust)
                         |
  1. Parse Python file   |
  2. Call pyrefly.check() -----> Pyrefly analyzes file, builds Answers
  3. For each AST node:  |
     query type info  ------->  Answers.get_type_at(offset) -> TypeResult
  4. Use TypeResult to   |
     emit bytecode       |
```

**PyO3 Module API:**

```python
# Exposed by the pyrefly_sp Python module (built via PyO3)
class PyreflyContext:
    """Manages Pyrefly state for a compilation session."""

    def __init__(self, search_paths: list[str], config: dict) -> None:
        """Initialize with module search paths and config."""

    def analyze_module(self, filename: str, source: str) -> ModuleTypes:
        """Analyze a single module and return type information."""

class ModuleTypes:
    """Type information for a single module."""

    def type_at(self, offset: int) -> TypeInfo:
        """Get the type at a byte offset in the source."""

    def function_type(self, name: str) -> FunctionTypeInfo:
        """Get type info for a module-level function."""

    def class_type(self, name: str) -> ClassTypeInfo:
        """Get type info for a module-level class."""

    def all_names(self) -> dict[str, TypeInfo]:
        """Get types for all module-level names."""

class TypeInfo:
    """Type information for a single expression or name."""

    @property
    def type_descr(self) -> tuple[str, ...]:
        """SP-compatible type descriptor tuple."""

    @property
    def is_exact(self) -> bool:
        """Whether this is an exact type."""

    @property
    def is_primitive(self) -> bool:
        """Whether this is a C primitive type."""

    @property
    def soundness(self) -> str:
        """'sound', 'needs_runtime_check', or 'unsound'."""

    @property
    def is_dynamic(self) -> bool:
        """Whether this resolved to dynamic/Any."""

    def slot_info(self, attr_name: str) -> SlotInfo | None:
        """Get slot info for an attribute (for LOAD_FIELD decisions)."""
```

**Key design principles:**
1. **Lazy evaluation:** Types are computed on first query, not materialized
   upfront for the entire file. Pyrefly's `Answers` system already supports
   this pattern.
2. **SP-compatible output:** The `type_descr` property produces tuples in
   exactly SP's format.
3. **Incremental adoption:** SP's codegen can start by querying Pyrefly for
   specific expressions while still using its own inference for the rest.
4. **Batched queries:** For performance, a `batch_types_at(offsets: list[int])`
   method could be added to amortize the per-query overhead.

### 5.3 Implementation Notes

Pyrefly does not currently use PyO3. The closest existing mechanism is the WASM
build (`pyrefly_wasm/`) and the playground API (`pyrefly/lib/playground.rs`),
which provide JSON-serializable type query interfaces.

The `query.rs` module (`pyrefly/lib/query.rs`) already has a comprehensive query
infrastructure for Pysa integration, including serialized class references and
type information. This can serve as a model for the SP integration.

The `Answers` struct (`pyrefly/lib/alt/answers.rs`) provides `get_type_at(idx)`
and `get_type_trace(range)` methods that return `Type` for a given binding key
or source range. The `AnswersSolver` wraps `Answers` with type operations.

Adding PyO3 requires:
1. A new crate (e.g., `crates/pyrefly_sp/`) with PyO3 dependency
2. Wrapper types that convert Pyrefly `Type` -> Python-visible `TypeInfo`
3. A `PyreflyContext` that manages `State` and `Transaction` objects

---

## 6. Migration Strategy

### Phase 0: Validation (Estimated: 2-4 weeks)

**Goal:** Run Pyrefly on SP codebases and compare its type inferences with SP's.

**Steps:**
1. Run Pyrefly on the SP test suite (`fbcode/cinderx/PythonLib/test_cinderx/test_compiler/`) and catalog differences
2. Build a comparison harness that runs both SP and Pyrefly on the same source files and reports:
   - Cases where SP infers a concrete type but Pyrefly infers `Any`
   - Cases where Pyrefly infers a different concrete type than SP
   - Cases where Pyrefly finds errors that SP does not (and vice versa)
3. Identify the set of SP-specific types (`CIntType`, `CheckedDict`, etc.) that Pyrefly does not understand
4. Measure Pyrefly's analysis time on SP codebases

**Deliverable:** A compatibility report quantifying the overlap and gaps.

**Risk mitigation:** This phase has no production impact. It is purely diagnostic.

### Phase 1: Parallel Mode (Estimated: 4-8 weeks)

**Goal:** Run Pyrefly alongside SP's type inference, using Pyrefly's results to
augment SP's inference where SP gives up (returns `dynamic`).

**Steps:**
1. Implement the `__static__` module stub (Section 4.4) so Pyrefly can parse SP source files
2. Build the PyO3 bridge (Section 5.2) with minimal API: `analyze_module` + `type_at`
3. Modify SP's `TypeBinder` to optionally query Pyrefly when it would return `dynamic`:
   ```python
   # In type_binder.py
   def visit_expression(self, node):
       sp_type = self._infer_type(node)
       if sp_type is self.type_env.dynamic and self._pyrefly_ctx:
           pyrefly_type = self._pyrefly_ctx.type_at(node.col_offset)
           if pyrefly_type and pyrefly_type.soundness == 'sound':
               return self._map_pyrefly_type(pyrefly_type)
       return sp_type
   ```
4. Gate this behind a flag (`--use-pyrefly-augmentation`)
5. Run the SP test suite with augmentation enabled and fix any regressions

**Deliverable:** SP compilation with optional Pyrefly augmentation for types
that SP currently treats as `dynamic` (e.g., `TypeVar`, `Protocol`, `TypedDict`).

**Key constraint:** Only use Pyrefly types that are marked `Sound`. Never use
Pyrefly to override an SP inference with a different type.

### Phase 2: Expanded Coverage (Estimated: 8-16 weeks)

**Goal:** Use Pyrefly for a majority of type inferences, falling back to SP only
for SP-specific constructs.

**Steps:**
1. Add `PrimitiveType` support to Pyrefly (Section 4.1)
2. Add exactness tracking (Section 4.2)
3. Implement `type_descr()` output (Section 4.5)
4. Implement `CompilerSafetyMode` (Section 2) and disable unsound rules (Section 3)
5. Replace SP's `DeclarationVisitor` with Pyrefly's export system for discovering
   module-level declarations
6. Replace SP's `TypeBinder` with Pyrefly's `AnswersSolver` for local type
   inference, keeping SP's codegen
7. Run the SP test suite continuously, fixing regressions

**Deliverable:** SP's codegen consuming Pyrefly types for all standard Python
typing constructs, with SP's own inference retained only for `__static__`-specific
constructs.

### Phase 3: Full Replacement (Estimated: 4-8 weeks after Phase 2)

**Goal:** Remove SP's type inference entirely. Pyrefly provides all type
information to SP's codegen.

**Steps:**
1. Move all `__static__`-specific inference into Pyrefly (primitive operations,
   box/unbox, cast)
2. Validate that Pyrefly produces correct type descriptors for all SP codegen
   needs
3. Remove `declaration_visitor.py`, `type_binder.py`, and `effects.py` from SP
4. Remove `types.py` except for the `type_descr` generation code (which becomes
   a thin mapping layer)
5. Run full production validation on Cinder workloads

**Deliverable:** SP's compilation pipeline uses Pyrefly for all type inference.
The codebase shrinks by ~13,000+ lines of Python.

### Phase Timeline

```
Phase 0: Validation          [Week 1-4]
  |
Phase 1: Parallel Mode       [Week 5-12]
  |
Phase 2: Expanded Coverage   [Week 13-28]
  |
Phase 3: Full Replacement    [Week 29-36]
```

---

## 7. Risk Analysis

### 7.1 High Risks

**R1: Soundness regression in production**

*What:* Pyrefly infers a type that is wrong, causing SP to emit specialized
bytecode that crashes at runtime.

*Likelihood:* Medium. Pyrefly's inference is generally sound for standard Python,
but the interaction between Pyrefly's type system and SP's runtime enforcement
is untested.

*Mitigation:*
- Phase 1's "augment only" approach limits blast radius
- The `CompilerSafetyMode` disables known-unsound rules
- SP's runtime checks (CHECK_ARGS, STORE_FIELD, CAST) catch many type mismatches
- A/B testing: run both inference engines and compare before trusting Pyrefly

**R2: Performance regression**

*What:* Pyrefly's analysis is slower than SP's, increasing compilation time.

*Likelihood:* Low for single-file analysis (Pyrefly is Rust, SP is Python).
However, Pyrefly performs whole-project analysis while SP works module-by-module.

*Mitigation:*
- Pyrefly can be configured for single-module analysis
- The PyO3 bridge adds constant overhead per call, not per-type
- Benchmark continuously during Phase 1

**R3: Type system mismatch causing silent behavioral changes**

*What:* Pyrefly and SP disagree on a type, and the Pyrefly type causes different
(but not crashing) codegen, changing program behavior.

*Likelihood:* Medium. The type systems have different coverage (Pyrefly handles
generics better, SP handles primitives).

*Mitigation:*
- Phase 0's comparison harness catches these before production
- Only use Pyrefly types where they are strictly more specific than SP's `dynamic`
- Never override a non-dynamic SP inference with a different Pyrefly inference

### 7.2 Medium Risks

**R4: PyO3 bridge complexity**

*What:* Building and maintaining the Rust-Python bridge becomes a significant
maintenance burden.

*Likelihood:* Low-Medium. PyO3 is mature but adds build complexity and version
pinning requirements.

*Mitigation:*
- Keep the bridge thin (10-15 functions)
- Use simple data types across the boundary (strings, tuples, ints)
- Consider JSON serialization as a fallback if PyO3 proves problematic

**R5: `__static__` module modeling is incomplete**

*What:* SP's `__static__` module has complex semantics (compiler flags, inline
decorators, specialized enums) that are hard to model accurately in stub files.

*Likelihood:* Medium. The `__static__` module is SP-specific and not documented
outside the SP codebase.

*Mitigation:*
- Build the stub file incrementally, starting with the most-used types
- Use SP's `__init__.py` and `type_code.py` as source of truth
- Keep SP's own handling of `__static__` as a fallback during Phase 1-2

**R6: Exactness tracking is harder than expected**

*What:* Tracking exact vs inexact types throughout Pyrefly's inference requires
pervasive changes.

*Likelihood:* Medium. SP's exactness tracking is deeply integrated into
`can_assign_from`.

*Mitigation:*
- Phase 2 recommendation: Start with output-level exactness (computed from
  constructor-call provenance) rather than internal tracking
- Defer full internal exactness to Phase 3 if needed

### 7.3 Low Risks

**R7: Cinder runtime incompatibility**

*What:* Pyrefly's type descriptors do not match what Cinder's `classloader.c`
expects.

*Likelihood:* Low. Type descriptors are simple tuples with well-defined formats.

*Mitigation:* Comprehensive testing of descriptor generation against SP's
existing descriptors.

**R8: Cross-module analysis differences**

*What:* Pyrefly analyzes the full project graph while SP works module-by-module,
leading to different results for cross-module dependencies.

*Likelihood:* Low. Pyrefly's cross-module analysis should be strictly better.

*Mitigation:* Compare cross-module inference results in Phase 0.

---

## Appendix: File References

### Static Python Source Files

| File | Purpose |
|---|---|
| `fbcode/cinderx/PythonLib/cinderx/compiler/static/types.py` | Type system (~10,600 lines) |
| `fbcode/cinderx/PythonLib/cinderx/compiler/static/type_binder.py` | Local type inference (~2,200 lines) |
| `fbcode/cinderx/PythonLib/cinderx/compiler/static/compiler.py` | Compilation entry point |
| `fbcode/cinderx/PythonLib/cinderx/compiler/static/declaration_visitor.py` | Declaration collection |
| `fbcode/cinderx/PythonLib/cinderx/compiler/static/effects.py` | Narrowing effect algebra |
| `fbcode/cinderx/PythonLib/cinderx/compiler/static/__init__.py` | Code generator |
| `fbcode/cinderx/PythonLib/__static__/__init__.py` | Runtime __static__ module |

### Pyrefly Source Files

| File | Purpose |
|---|---|
| `crates/pyrefly_types/src/types.rs` | Type enum definition (where PrimitiveType would be added) |
| `crates/pyrefly_types/src/class.rs` | ClassType struct (where exactness could be added) |
| `crates/pyrefly_types/src/facet.rs` | FacetSubject/FacetChain (attribute narrowing targets) |
| `crates/pyrefly_types/src/literal.rs` | Literal types |
| `crates/pyrefly_types/src/annotation.rs` | Annotation qualifiers (Final, ClassVar, etc.) |
| `pyrefly/lib/alt/narrow.rs` | Narrowing implementation (where CompilerSafe checks go) |
| `pyrefly/lib/binding/narrow.rs` | Narrowing extraction from expressions |
| `pyrefly/lib/alt/answers.rs` | Answers system (type query infrastructure) |
| `pyrefly/lib/alt/answers_solver.rs` | AnswersSolver (type operations + queries) |
| `pyrefly/lib/alt/solve.rs` | Binding solving orchestration |
| `pyrefly/lib/alt/attr.rs` | Attribute resolution |
| `pyrefly/lib/alt/call.rs` | Call resolution, descriptor handling |
| `pyrefly/lib/alt/expr.rs` | Expression type inference |
| `pyrefly/lib/alt/special_calls.rs` | Special built-in call handling |
| `pyrefly/lib/alt/types/class_metadata.rs` | Class metadata (is_final, is_protocol, etc.) |
| `pyrefly/lib/alt/class/class_field.rs` | Class field resolution |
| `pyrefly/lib/solver/subset.rs` | Subset (assignability) checking |
| `pyrefly/lib/solver/solver.rs` | Variable solving, unification |
| `pyrefly/lib/state/lsp.rs` | LSP state (hover, goto-def, completion) |
| `pyrefly/lib/query.rs` | Query interface (model for SP integration) |
| `pyrefly/lib/playground.rs` | Playground API (JSON serialization model) |
| `pyrefly/lib/commands/check.rs` | Check command entry point |
| `crates/pyrefly_config/src/base.rs` | Configuration options |
