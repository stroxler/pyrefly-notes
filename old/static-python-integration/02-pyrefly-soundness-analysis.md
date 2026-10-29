# Pyrefly Soundness Analysis for Static Python Integration

## Executive Summary

This document catalogs Pyrefly's type inference rules and classifies each as
**SOUND**, **UNSOUND**, or **CONDITIONALLY SOUND** in the context of powering
a compiler (Static Python / Cinder). A compiler needs reliable type information
to generate correct machine code; unsound type inference can lead to segfaults,
memory corruption, or silent data corruption at runtime.

Key findings:

1. **`Any` is the largest source of unsoundness.** Pyrefly treats `Any` as both
   assignable-to and assignable-from everything, which is standard for gradual
   typing but fundamentally unsound for a compiler. There is no mechanism to
   distinguish "trusted" type annotations from "unverified" ones.

2. **Attribute narrowing on mutable objects is unsound in concurrent contexts.**
   Narrowing on `a.b`, `a.b.c`, and similar facet chains assumes the object is
   not mutated between the check and the use. This is correct for local
   variables but incorrect for shared mutable state.

3. **Descriptor handling is incomplete.** A non-final, non-descriptor class can
   be subclassed into a descriptor, changing attribute access behavior without
   Pyrefly's knowledge.

4. **Pyrefly has no existing soundness tracking mechanism.** There are no flags,
   modes, or annotations that distinguish sound from unsound inferences. The
   `AnyStyle` enum tracks the *origin* of `Any` but does not control its
   behavior.

5. **Intersection types are partially supported** with a fallback type, meaning
   some intersection operations degrade to imprecise results.

---

## Table of Contents

1. [Type System Foundations](#1-type-system-foundations)
2. [Type Narrowing and Refinement](#2-type-narrowing-and-refinement)
3. [Attribute Resolution](#3-attribute-resolution)
4. [Assignability and Subtyping](#4-assignability-and-subtyping)
5. [Generic Types and Type Variables](#5-generic-types-and-type-variables)
6. [Union and Intersection Types](#6-union-and-intersection-types)
7. [Special Forms](#7-special-forms)
8. [Callable Types](#8-callable-types)
9. [Module-Level Inference](#9-module-level-inference)
10. [Expression Type Inference](#10-expression-type-inference)
11. [Existing Soundness Controls](#11-existing-soundness-controls)
12. [Recommendations for Compiler Integration](#12-recommendations-for-compiler-integration)

---

## 1. Type System Foundations

### 1.1 Type Representation

Pyrefly represents types via the `Type` enum in
`crates/pyrefly_types/src/types.rs`. Key variants:

| Type Variant | Description |
|---|---|
| `ClassType(ClassType)` | Instantiated class with type arguments |
| `ClassDef(Class)` | A class object (the class itself, not an instance) |
| `Union(Box<Union>)` | Union of types |
| `Intersect(Box<(Vec<Type>, Type)>)` | Partial intersection with fallback |
| `Literal(Box<Literal>)` | Literal types (int, str, bool, enum, bytes) |
| `Function(Box<Function>)` | A `def`-declared function |
| `Callable(Box<Callable>)` | `typing.Callable` |
| `Overload(Overload)` | Overloaded function |
| `BoundMethod(Box<BoundMethod>)` | Method bound to an instance |
| `Forall(Box<Forall<Forallable>>)` | Universally quantified type |
| `Var(Var)` | Unification variable (internal) |
| `Quantified(Box<Quantified>)` | Type variable in annotation context |
| `TypeGuard(Box<Type>)` | TypeGuard return type |
| `TypeIs(Box<Type>)` | TypeIs return type |
| `Any(AnyStyle)` | Any type with origin tracking |
| `Never(NeverStyle)` | Bottom type |
| `None` | NoneType |
| `Type(Box<Type>)` | `type[X]` form |
| `SelfType(ClassType)` | `typing.Self` |
| `Materialization` | All possible materializations of Any |
| `TypedDict(TypedDict)` | TypedDict instance |
| `Tuple(Tuple)` | Tuple types (concrete, unbounded, unpacked) |
| `Module(ModuleType)` | Module type |
| `SuperInstance(...)` | Result of `super()` call |

### 1.2 AnyStyle Tracking

**Classification: UNSOUND (by design, as is standard for gradual typing)**

Pyrefly tracks the origin of `Any` via `AnyStyle`:
- `Explicit`: The user wrote `Any` literally
- `Implicit`: No type annotation was provided, so `Any` was inferred
- `Error`: A type error occurred, so `Any` was used as a fallback

The `propagate()` method converts `Explicit` to `Implicit` when Any flows
through operations, and preserves `Implicit` and `Error`. This tracking is
used for the `ImplicitAny` error kind but does **not** change the runtime
behavior of `Any` in subset checks. All three styles of `Any` are equally
unsound for a compiler.

**Compiler impact:** `Any` allows any value to flow into any position without
error, which could cause a compiler to emit incorrect type specializations.

### 1.3 Materialization Type

**Classification: SOUND (for its intended purpose)**

`Type::Materialization` represents "all possible materializations of Any" and
behaves asymmetrically:
- `Materialization <: T` succeeds iff `object <: T`
- `T <: Materialization` succeeds iff `T <: Never`

This is used internally for checking whether code would be correct for any
possible concrete type that `Any` could represent. This is the only existing
mechanism that approaches soundness checking, but it is not exposed as a
user-facing feature.

---

## 2. Type Narrowing and Refinement

Narrowing is implemented across two phases:
- **Binding phase** (`pyrefly/lib/binding/narrow.rs`): Extracts narrowing
  operations from expressions and creates `NarrowOp` structures.
- **Solving phase** (`pyrefly/lib/alt/narrow.rs`): Applies narrowing operations
  to types, computing intersections and subtractions.

### 2.1 Narrowing Operations Catalog

The `AtomicNarrowOp` enum defines all narrowing operations:

#### 2.1.1 isinstance / issubclass checks

**Classification: CONDITIONALLY SOUND**

- `IsInstance(Expr, NarrowSource)` / `IsNotInstance(Expr, NarrowSource)`
- `IsSubclass(Expr)` / `IsNotSubclass(Expr)`

**Sound when:** The isinstance check is on a local variable that is not
reassigned between the check and the use. Pyrefly validates this by checking
that the variable is not redefined after the narrow operation range
(`op_is_still_valid`).

**Unsound when:**
- The narrowed value is an attribute of a mutable object (see Section 2.2)
- The class has been subclassed in ways that change its runtime identity (rare)
- `__class__` has been mutated (acknowledged in code comment: "Technically the
  `__class__` attribute can be mutated, but code that does that probably isn't
  statically analyzable anyway")

**Negative narrowing caveat:** For `not isinstance(x, C)`, Pyrefly only allows
negative narrowing when `C` is `Final`. For non-final classes, it conservatively
skips negative narrowing because `x` could be an instance of a subclass of `C`.
This is sound.

#### 2.1.2 Identity checks (is / is not)

**Classification: SOUND (for singleton types)**

- `Is(Expr)` / `IsNot(Expr)`

Pyrefly correctly limits identity narrowing to singletons: `None`,
`Literal[True]`, `Literal[False]`, and enum members. For other types, `is`
comparisons are not used for narrowing because identity is not the same as
equality for arbitrary objects.

#### 2.1.3 Equality checks (== / !=)

**Classification: CONDITIONALLY SOUND**

- `Eq(Expr)` / `NotEq(Expr)`

Only narrows when the comparand is a `Literal` or `None`. This is sound for
immutable literal types but technically unsound for objects that override
`__eq__` to return `True` for non-identical objects. In practice, this is a
reasonable approximation.

**Compiler impact:** Equality narrowing on mutable objects could be incorrect
if `__eq__` is overridden to break the expected contract.

#### 2.1.4 Truthiness checks

**Classification: SOUND (for local variables)**

- `IsTruthy` / `IsFalsy`

Narrows based on the truthiness of a type. The code comment in
`op_is_still_valid` notes: "The only objects that have different truthy and
falsy types (True vs. False, empty vs. non-empty tuple, etc.) are immutable."

For `IsFalsy`, Pyrefly narrows specific types:
- `bool` -> `Literal[False]`
- `int` -> `Literal[0]`
- `str` -> `Literal[""]`
- `bytes` -> `Literal[b""]`

#### 2.1.5 TypeGuard / TypeIs

**Classification: UNSOUND (TypeGuard) / CONDITIONALLY SOUND (TypeIs)**

- `TypeGuard(Type, Arguments)` / `NotTypeGuard(Type, Arguments)`
- `TypeIs(Type, Arguments)` / `NotTypeIs(Type, Arguments)`

`TypeGuard` is unsound by specification: the returned type completely replaces
the original type, so the guard function could lie about the type. `TypeIs` is
sound in the sense that it narrows to the intersection of the original type and
the guarded type, but it still trusts the user-provided predicate.

`NotTypeGuard` performs no narrowing at all (returns `ty.clone()`), which is
sound but imprecise.

#### 2.1.6 type() checks

**Classification: CONDITIONALLY SOUND**

- `TypeEq(Expr)` / `TypeNotEq(Expr)`

`TypeEq` narrows like `isinstance` (intersection), which is an
over-approximation: `type(x) == C` means `x` is exactly `C`, not a subclass.
The code comment acknowledges this: "If type(X) == Y then X can't be a subclass
of Y. We can't model that, so we narrow it exactly like isinstance(X, Y)."

`TypeNotEq` performs no narrowing because even if `type(X) != Y`, `X` can still
be a subclass of `Y`.

#### 2.1.7 Containment checks (in / not in)

**Classification: SOUND (for literal containers)**

- `In(Expr)` / `NotIn(Expr)` / `HasKey(Name)` / `NotHasKey(Name)`

For `in`, Pyrefly only narrows when the container is a literal list, tuple, or
set and all elements are literal types. This is sound because these are known
at compile time.

For TypedDicts, `in` narrows to the union of key literal types, which is sound.

#### 2.1.8 Length checks

**Classification: SOUND (for immutable types)**

- `LenEq/LenNotEq/LenGt/LenGte/LenLt/LenLte(Expr)`

The code comment in `op_is_still_valid` notes: "The len ops are only applied to
tuples, which are immutable." This is sound.

#### 2.1.9 Pattern matching narrows

**Classification: SOUND**

- `IsSequence` / `IsNotSequence` / `IsMapping` / `IsNotMapping`

Used for structural pattern matching. `IsNotSequence` and `IsNotMapping`
correctly preserve `Any` and classes extending `Any` rather than narrowing
them to `Never`.

#### 2.1.10 hasattr / getattr narrows

**Classification: UNSOUND**

- `HasAttr(Name)` / `NotHasAttr(Name)`
- `GetAttr(Name, Option<Box<Expr>>)` / `NotGetAttr(Name, Option<Box<Expr>>)`

`HasAttr` narrows the attribute type to `Any` (implicit) when the attribute
does not exist statically. This is unsound because it introduces a new `Any`
that the type system treats as valid for any use.

`GetAttr` narrows based on the truthiness of the attribute value, and falls back
to `Any` if the attribute does not exist. Same unsoundness concern.

### 2.2 Facet / Attribute Narrowing

**Classification: UNSOUND in multithreaded contexts**

Pyrefly supports narrowing on attribute chains like `x.y`, `x.y.z`, `x[0]`,
`x["key"]`, and even `x.get("key")`. This is implemented through the
`FacetSubject` / `FacetChain` / `NarrowingSubject` system.

**Key unsoundness:** When narrowing on `a.b` (e.g., `if a.b is not None`),
Pyrefly assumes that `a.b` retains its value between the check and the use.
This assumption is violated when:
1. Another thread modifies `a.b` between the check and use
2. A property getter returns different values on successive calls
3. A descriptor's `__get__` has side effects

The code in `op_is_still_valid` explicitly **rejects** facet-based narrows
for transitive narrowing (line 906: `NarrowOp::Atomic(Some(_), _) => false`),
meaning Pyrefly does not try to carry facet narrows across assignment
boundaries. However, within a single expression or a straight-line block of
code, the facet narrow is trusted.

**For a compiler:** This is a serious concern. The compiler would need to either:
- Reject facet narrows entirely, or
- Insert runtime checks to validate the narrowing assumption, or
- Only trust facet narrows in specific contexts (e.g., when the attribute is
  `Final` or the class is `frozen`).

### 2.3 Narrowing Composition

**Classification: SOUND (structurally)**

- `NarrowOp::And(Vec<NarrowOp>)`: Applies all narrows sequentially
- `NarrowOp::Or(Vec<NarrowOp>)`: Takes the union (join) of narrow results

The composition logic correctly applies De Morgan's laws for negation:
`And.negate() = Or(negated components)` and vice versa.

The `Placeholder` operation is used as an identity element when a name appears
in one branch of a compound narrow but not the other, ensuring that the
absence of information is not confused with positive narrowing.

---

## 3. Attribute Resolution

Attribute resolution is implemented in `pyrefly/lib/alt/attr.rs`.

### 3.1 Attribute Lookup

**Classification: SOUND (for nominal types)**

Pyrefly resolves attributes through MRO lookup, with the `AttributeBase` system
normalizing types for lookup. The key base types are:

- `ClassInstance(ClassType)`: Instance attribute lookup
- `ClassObject(ClassBase)`: Class-level attribute lookup
- `Module(ModuleType)`: Module attribute lookup
- `Any(AnyStyle)`: Returns `Any` for any attribute
- `Never`: Returns `Never` for any attribute
- `TypedDict(TypedDictInner)`: TypedDict attribute lookup
- `Property(PropertyAttr)`: Property-based attribute access
- `Descriptor(Descriptor, DescriptorBase)`: Descriptor protocol
- `Quantified(Quantified, ClassType)`: Type variable attribute lookup

### 3.2 Descriptor Handling

**Classification: UNSOUND (incomplete)**

Pyrefly tracks descriptors via the `Descriptor` struct which records:
- Whether `__get__` exists on the descriptor class
- Whether `__set__` exists on the descriptor class
- The descriptor's class type

Descriptors are handled through `call_descriptor_getter` and
`call_descriptor_setter` in `pyrefly/lib/alt/call.rs`, which synthesize calls
to `__get__` and `__set__` respectively.

**Known unsoundness:**
1. A non-final, non-descriptor class can be subclassed to become a descriptor.
   Pyrefly determines descriptor status at the definition site and does not
   re-check when the class is used as an attribute of another class. If class
   `C` has an attribute of type `D` where `D` is not a descriptor, but a
   subclass `E(D)` defines `__get__`, then assigning an instance of `E` to
   `C`'s attribute would cause descriptor behavior that Pyrefly does not
   model.

2. Read-only descriptor detection: Pyrefly tracks whether `__set__` exists
   and reports `SettingReadOnlyDescriptor` if it does not. However, this
   check happens statically based on the declared type of the attribute, not
   the runtime type.

### 3.3 Property Handling

**Classification: SOUND (for well-typed properties)**

Properties are a special case of descriptors. Pyrefly tracks:
- The getter return type
- The optional setter parameter type
- The optional deleter

Read-only properties (no setter) correctly produce a `SettingReadOnlyProperty`
error when an assignment is attempted.

### 3.4 __getattr__ / __getattribute__ Fallback

**Classification: UNSOUND (inherently)**

When an attribute is not found on a class but `__getattr__` or
`__getattribute__` is defined, Pyrefly falls back to calling those methods
and using their return types. The `Attribute::GetAttr` variant records this
fallback.

This is inherently imprecise because `__getattr__` can return anything based
on the attribute name string, and Pyrefly can only use the declared return
type of `__getattr__`, which is typically `Any`.

### 3.5 Attribute Override Checking

**Classification: SOUND**

Pyrefly checks attribute overrides via `AttrSubsetError`, enforcing:
- Covariance for read-only attributes and method return types
- Invariance for read-write attributes
- Contravariance for property setters

This matches the Liskov Substitution Principle and is sound.

---

## 4. Assignability and Subtyping

The core subset checking logic is in `pyrefly/lib/solver/subset.rs`.

### 4.1 Any Assignability

**Classification: UNSOUND (by design)**

```rust
(Type::Any(_), _) => Ok(()),  // Any is assignable to everything
(_, Type::Any(_)) => Ok(()),  // Everything is assignable to Any
```

This is the standard gradual typing rule. `Any` acts as both top and bottom
type simultaneously. This is the single largest source of unsoundness.

**Compiler impact:** A compiler cannot trust that a value typed as `int` is
actually an `int` if the type was inferred through an `Any` boundary. The
entire chain of type inference back to an `Any` boundary is potentially
invalid.

### 4.2 Never Assignability

**Classification: SOUND**

```rust
(Type::Never(_), _) => Ok(()),  // Never is assignable to everything
```

`Never` is the bottom type. A value of type `Never` means control flow does
not reach that point, so accepting it as any type is sound.

### 4.3 Object Assignability

**Classification: SOUND**

```rust
(_, Type::ClassType(want)) if want.is_builtin("object") => Ok(())
```

Everything is an instance of `object`, which is the top type in Python's
nominal hierarchy.

### 4.4 Union Assignability

**Classification: SOUND**

- `A | B <: C` requires both `A <: C` and `B <: C`
- `A <: C | D` requires `A <: C` or `A <: D`

This follows standard set-theoretic semantics.

### 4.5 Intersection Assignability

**Classification: SOUND**

- `A & B <: C` requires `A <: C` or `B <: C` (any member suffices)
- `A <: B & C` requires `A <: B` and `A <: C`

### 4.6 ClassType Assignability (Nominal Subtyping)

**Classification: SOUND**

Pyrefly checks nominal subtyping by looking up the MRO:
```rust
got_as_want = self.type_order.as_superclass(got_class, want_class.class_object())
```

If the got type can be promoted to the want type via inheritance, the check
succeeds. Type arguments are then compared according to variance.

### 4.7 Variance Enforcement

**Classification: SOUND**

```rust
match variances.get(param.name()) {
    Variance::Covariant => self.is_subset_eq(got_arg, want_arg)?,
    Variance::Contravariant => self.is_subset_eq(want_arg, got_arg)?,
    Variance::Invariant | Variance::Bivariant => self.is_equal(got_arg, want_arg)?,
}
```

Pyrefly supports variance inference and correctly applies:
- Covariant: `list[Cat] <: list[Animal]` (only if declared covariant)
- Contravariant: `Callable[[Animal], None] <: Callable[[Cat], None]`
- Invariant: Requires exact equality of type arguments
- Bivariant: Treated as invariant (conservative choice, noted in comment)

**Important note:** Pyrefly performs variance *inference* for classes that do
not explicitly declare variance. The inference algorithm is in
`pyrefly/lib/alt/class/variance_inference.rs`. This is generally sound but
could theoretically produce incorrect results for classes with complex
internal invariants.

### 4.8 Protocol (Structural) Subtyping

**Classification: SOUND**

Protocol checks verify that all protocol members exist on the got type with
compatible signatures, using `is_protocol_subset_at_attr`. This dispatches
to the attribute resolution system for each member.

### 4.9 Callable Assignability

**Classification: SOUND**

Function parameter checking follows the standard rule:
- Parameter types are contravariant (the `is_subset_eq(u, l)` direction)
- Return types are covariant

Pyrefly handles positional, keyword, `*args`, `**kwargs`, and unpacked
parameters correctly.

### 4.10 Recursive Type Handling

**Classification: SOUND**

Recursive checks (e.g., for recursive type aliases like `type X = int | list[X]`)
use an assumption set: if we encounter the same `(got, want)` pair during
recursion, we assume it is true. This is standard for coinductive reasoning
and is sound.

A gas/fuel mechanism (`INITIAL_GAS = 200`) prevents infinite recursion.

---

## 5. Generic Types and Type Variables

### 5.1 TypeVar Representation

**Classification: SOUND**

Type variables are represented as `Quantified` with restrictions:
- `Restriction::Bound(Type)`: Upper bound (e.g., `T: Comparable`)
- `Restriction::Constraints(Vec<Type>)`: Value constraints (e.g., `T: (int, str)`)
- `Restriction::Unrestricted`: No restriction (defaults to `object` bound)

### 5.2 Type Variable Solving

**Classification: CONDITIONALLY SOUND**

The solver (`pyrefly/lib/solver/solver.rs`) uses union-find for unification.
Variables are tracked as:

- `Quantified(Quantified)`: Generic instantiation variable
- `PartialQuantified(Quantified)`: Unsolved generic variable with default
- `PartialContained(TextRange)`: Empty container type variable
- `LoopRecursive(Type, LoopBound)`: Loop-dependent variable
- `Recursive`: General recursion variable

**Soundness concern with PartialContained:** When a container is created empty
(e.g., `x = []`), Pyrefly creates a `PartialContained` variable and attempts
to infer the type from the first use. If inference fails, the type becomes
`Any`. This means that code like `x = []; x.append(1); y: str = x[0]` might
not be caught if the `Any` fallback is used.

### 5.3 ParamSpec

**Classification: SOUND (with limitations)**

ParamSpec is handled through `Type::ParamSpec`, `Type::ParamSpecValue`,
`Type::Args`, `Type::Kwargs`, `Type::Concatenate` variants. The subset
check has a special case:
```rust
(Type::Quantified(q), Type::Ellipsis) | (Type::Ellipsis, Type::Quantified(q))
    if q.kind() == QuantifiedKind::ParamSpec => Ok(())
```

This allows `ParamSpec` to match `...` (the ellipsis parameter spec), which
is sound.

### 5.4 TypeVarTuple

**Classification: CONDITIONALLY SOUND**

TypeVarTuple is handled through `Type::TypeVarTuple` and
`Type::ElementOfTypeVarTuple`. In subset checks, TypeVarTuple is compared
against tuples using `is_equal` (invariant), which is sound. The implementation
may be incomplete for complex variadic patterns.

---

## 6. Union and Intersection Types

### 6.1 Union Types

**Classification: SOUND**

Unions are represented as `Type::Union(Box<Union>)` with a `members` field.
Union simplification is handled in `crates/pyrefly_types/src/simplify.rs`.

### 6.2 Intersection Types

**Classification: CONDITIONALLY SOUND (with fallback)**

Intersections are represented as `Type::Intersect(Box<(Vec<Type>, Type)>)`.
The comment in the Type enum says: "Our intersection support is partial, so we
store a fallback type that we use for operations that are not yet supported on
intersections."

The intersection implementation in `narrow.rs` (`intersect_impl`) is
sophisticated:
1. If `right <: left`, return `right`
2. If `left <: right`, return `left`
3. If either is a literal, the intersection is `Never` (since literals are
   exact types)
4. If either class is `Final`, the intersection is `Never` (no common subclass
   can exist)
5. If the "disjoint bases" of both types share a superclass relationship, the
   intersection is kept; otherwise it is `Never`

**Compiler impact:** The fallback type in intersections means that some
operations on intersection types will use an approximation rather than the
precise intersection. This could lead to imprecise type information.

---

## 7. Special Forms

### 7.1 Any

**Classification: UNSOUND** (see Section 4.1)

### 7.2 object

**Classification: SOUND**

`object` is the top of the nominal type hierarchy. All types are assignable
to `object`.

### 7.3 Never / NoReturn

**Classification: SOUND**

`Never` is the bottom type. `NoReturn` is treated identically. Both are
tracked via `NeverStyle` but behave the same in the type system.

### 7.4 Self

**Classification: SOUND**

`Type::SelfType(ClassType)` stores the class where `Self` appears. It
correctly participates in attribute lookup through `AttributeBase1::SelfType`.

### 7.5 Final

**Classification: SOUND**

Final is tracked through class metadata (`is_final()`). Final classes:
- Cannot be subclassed (enforced by error reporting)
- Enable sound negative narrowing for `isinstance` checks
- Enable intersection elimination (a Final class cannot have a common
  subclass with a disjoint class)

### 7.6 ClassVar

**Classification: SOUND**

ClassVar is tracked through `ReadOnlyReason` in attribute handling. Class
variables cannot be set on instances, producing `NoAccess` errors.

### 7.7 Protocol

**Classification: SOUND**

Protocols are identified via `is_protocol()` class metadata. Protocol
subtyping is structural (see Section 4.8).

### 7.8 TypedDict

**Classification: SOUND**

TypedDicts have a dedicated `Type::TypedDict(TypedDict)` variant and custom
attribute resolution logic. Key features:
- Required vs NotRequired fields (tracked via `TypedDictField`)
- Extra items support
- Partial TypedDict (`Type::PartialTypedDict`) for `update()` operations
- `HasKey` / `NotHasKey` narrowing for `in` checks

### 7.9 Enum

**Classification: SOUND**

Enum support includes:
- Literal enum member types
- Exhaustiveness checking for match statements (with `NARROW_ENUM_LIMIT = 100`)
- Flag enum exclusion from exhaustiveness (correctly excluded because flag
  members can be combined via bitwise ops)
- Enum member subtraction for `is not` / `!= ` narrowing

### 7.10 NewType

**Classification: SOUND**

NewType is tracked via `is_new_type()` class metadata.

---

## 8. Callable Types

### 8.1 Function Types

**Classification: SOUND**

Functions are represented by `Type::Function(Box<Function>)` with:
- Parameter list (`ParamList`)
- Return type
- Metadata (`FuncMetadata`) including function kind, decorators, etc.

Parameters support:
- `PosOnly`: Positional-only parameters
- `Pos`: Normal parameters (positional or keyword)
- `KwOnly`: Keyword-only parameters
- `VarArg`: `*args`
- `Kwargs`: `**kwargs`

### 8.2 Overloaded Functions

**Classification: SOUND**

Overloads are represented by `Type::Overload(Overload)` containing multiple
function signatures. Overload resolution attempts each signature in order
and uses the first matching one.

### 8.3 Bound Methods

**Classification: SOUND**

`Type::BoundMethod(Box<BoundMethod>)` represents a method bound to an
instance. The `self` parameter is consumed during binding.

### 8.4 Decorators

**Classification: CONDITIONALLY SOUND**

Decorators are processed in `pyrefly/lib/alt/types/decorated_function.rs`.
Standard decorators (`@staticmethod`, `@classmethod`, `@property`,
`@abstractmethod`, `@override`, `@final`) are handled specially.

Custom decorators are processed by type-checking the decorator call, which is
sound as long as the decorator has correct type annotations. Decorators with
`Any` return types would propagate unsoundness.

---

## 9. Module-Level Inference

### 9.1 Module Resolution

**Classification: SOUND (for import resolution)**

Module resolution is handled in `pyrefly/lib/module/` with support for:
- Absolute imports
- Relative imports
- Wildcard imports (`from x import *`)
- `__all__` handling
- Stub files (.pyi)
- Namespace packages

### 9.2 Export System

**Classification: SOUND**

The export system in `pyrefly/lib/export/` tracks:
- Which names are exported from each module
- Re-exports (via `ExportLocation::OtherModule`)
- Wildcard exports
- Special exports (isinstance, len, type, etc.)
- Deprecated exports

### 9.3 Circular Import Handling

**Classification: CONDITIONALLY SOUND**

Circular imports are handled through the graph-based computation system.
When a circular dependency is detected, variables are created and solved
through the normal unification mechanism. The `Variable::Recursive` variant
handles general recursion cases.

**Compiler impact:** Circular imports can lead to partially-typed values
during module initialization. The compiler would need to handle this either
by disallowing certain circular import patterns or by inserting runtime
checks.

---

## 10. Expression Type Inference

### 10.1 Literal Inference

**Classification: SOUND**

Pyrefly infers literal types for:
- Integer literals (`Literal[0]`, `Literal[1]`, etc.)
- String literals
- Boolean literals (`Literal[True]`, `Literal[False]`)
- Byte literals
- None (`None` type)

### 10.2 Binary / Unary Operations

**Classification: SOUND**

Operations dispatch to `__add__`, `__mul__`, etc. via dunder method lookup.
This is sound because it follows the actual Python runtime semantics.

### 10.3 Control Flow Analysis

**Classification: SOUND (for local variables)**

Pyrefly performs flow-sensitive analysis for:
- if/elif/else branches
- while loops (with `LoopRecursive` variable tracking)
- for loops
- try/except/finally
- with statements
- match statements

Loop handling uses `LoopRecursive(Type, LoopBound)` variables that track:
- The type before the loop (`prior`)
- Upper bounds accumulated during loop body analysis
- Whether the variable was "forced" (resolved to the prior type)

### 10.4 Variable Inference

**Classification: CONDITIONALLY SOUND**

For annotated variables, Pyrefly uses the annotation (sound).

For unannotated variables:
- The type is inferred from the assigned expression
- This is flow-sensitive: the type can change with each assignment
- The `UntypedDefBehavior` config controls how unannotated function
  parameters and returns are handled:
  - `CheckAndInferReturnType`: Check the body and infer the return (soundest)
  - `CheckAndInferReturnAny`: Check the body but return `Any`
  - `SkipAndInferReturnAny`: Skip checking and return `Any`

### 10.5 Empty Container Inference

**Classification: UNSOUND (falls back to Any)**

When a container is created empty (`[]`, `{}`, `set()`), Pyrefly creates a
`PartialContained` variable and tries to infer the type from the first use.
If this fails, the type becomes `Any`, which is unsound.

---

## 11. Existing Soundness Controls

### 11.1 Error Suppression Mechanisms

Pyrefly supports error suppression via:
- `# type: ignore` (standard)
- `# pyrefly: ignore`
- `# pyright: ignore` (for compatibility)
- `# pyre-ignore` / `# pyre-fixme` (for Pyre compatibility)
- `# pyrefly: ignore-errors` / `# type: ignore` at file level (suppress all errors)

Error suppression is an explicit escape hatch that is inherently unsound.

### 11.2 Error Kind System

Pyrefly has a comprehensive error kind system (`ErrorKind` enum with ~55 error
kinds). Error severities can be configured per-project:
- `Error`: Reported as errors
- `Warn`: Reported as warnings
- `Info`: Reported as informational
- `Ignore`: Suppressed entirely

### 11.3 UntypedDefBehavior

The `UntypedDefBehavior` config option controls how functions without type
annotations are handled. The `SkipAndInferReturnAny` mode is the most unsound,
while `CheckAndInferReturnType` is the soundest.

### 11.4 Missing Soundness Controls

Pyrefly currently has **no mechanism** for:
- Marking specific type inferences as "trusted" vs "untrusted"
- Tracking the chain of `Any` propagation
- Distinguishing between sound and unsound narrowing
- Enforcing that a type inference is suitable for compiler use
- Reporting when a type was derived through `Any` boundaries

---

## 12. Recommendations for Compiler Integration

### 12.1 Critical Unsoundness Issues

The following issues must be addressed before Pyrefly can power a compiler:

1. **Any propagation tracking.** The compiler needs to know which types were
   derived through `Any` boundaries. `AnyStyle` exists but only tracks the
   immediate origin, not the transitive chain. A "tainted" type concept is
   needed.

2. **Facet narrowing guards.** Narrowing on `a.b`, `a.b.c` etc. must either:
   - Be rejected for compiler use, or
   - Be validated at runtime, or
   - Be restricted to `Final` attributes / frozen objects

3. **Descriptor soundness.** The compiler needs to either:
   - Restrict descriptor usage to known-sound patterns, or
   - Insert runtime descriptor checks, or
   - Track whether a class type could potentially be a descriptor

4. **TypeGuard safety.** `TypeGuard` results should not be trusted by the
   compiler. `TypeIs` is safer but still trusts user code.

5. **Empty container inference.** The compiler should require explicit type
   annotations for empty containers rather than falling back to `Any`.

### 12.2 Areas That Are Already Sound

The following areas can be trusted by a compiler:

1. Nominal subtyping with variance enforcement
2. isinstance/issubclass narrowing on local variables
3. Literal type narrowing (is/==, enum members)
4. Protocol structural subtyping
5. Function signature checking (parameter contravariance, return covariance)
6. Final class handling
7. TypedDict key tracking
8. Tuple length narrowing
9. Match exhaustiveness checking

### 12.3 Proposed Soundness Tiers

For compiler integration, consider implementing a tiered system:

**Tier 1 (Compiler-Safe):**
- Explicit type annotations with no `Any` in the transitive dependency chain
- isinstance narrowing on local variables with Final guard types
- Literal equality narrowing
- Nominal subtype checks with correct variance

**Tier 2 (Compiler-Safe with Runtime Checks):**
- isinstance narrowing on non-final guard types (need runtime type check)
- Attribute narrowing (need runtime guard or reload)
- Protocol subtype checks (need runtime structural check)

**Tier 3 (Compiler-Unsafe, Require Annotation):**
- Any `Any`-derived type information
- TypeGuard results
- Empty container inference
- `__getattr__` / `__getattribute__` fallbacks
- Descriptor access on non-final types

---

## Appendix: Key Source Files

| File | Purpose |
|---|---|
| `crates/pyrefly_types/src/types.rs` | Type enum definition |
| `pyrefly/lib/alt/narrow.rs` | Narrowing implementation (solving phase) |
| `pyrefly/lib/binding/narrow.rs` | Narrowing extraction (binding phase) |
| `pyrefly/lib/alt/attr.rs` | Attribute resolution |
| `pyrefly/lib/alt/class/class_field.rs` | Class field / descriptor handling |
| `pyrefly/lib/solver/subset.rs` | Subset (assignability) checking |
| `pyrefly/lib/solver/solver.rs` | Variable solving, unification |
| `pyrefly/lib/alt/solve.rs` | Binding solving orchestration |
| `pyrefly/lib/alt/call.rs` | Call resolution, descriptor getter/setter |
| `pyrefly/lib/alt/expr.rs` | Expression type inference |
| `pyrefly/lib/alt/special_calls.rs` | Special built-in call handling |
| `pyrefly/lib/export/exports.rs` | Module export system |
| `crates/pyrefly_config/src/error_kind.rs` | Error kinds and severities |
| `crates/pyrefly_config/src/base.rs` | Configuration options |
| `crates/pyrefly_types/src/type_var.rs` | TypeVar, Variance, Restriction |
