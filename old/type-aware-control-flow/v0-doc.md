# Unified Type-Aware Control Flow in Pyrefly

This document provides a comprehensive view of type-aware control flow analysis in Pyrefly,
synthesizing three previously separate design efforts:

1. **Type-Aware If Branch Termination** - Handling `Never`/`NoReturn` for control flow
2. **Type-Aware Initialization** - Correct uninitialized variable checking with type info
3. **Exhaustive Match** - Proving pattern matches cover all cases

These three capabilities share a fundamental architectural challenge and together enable
sophisticated control flow analysis that rivals or exceeds other Python type checkers.

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Core Concepts](#2-core-concepts)
   - 2.1 [Types of Type-Aware Control Flow](#21-types-of-type-aware-control-flow)
   - 2.2 [Downstream Impact Areas](#22-downstream-impact-areas)
   - 2.3 [The Binding vs Solving Time Gap](#23-the-binding-vs-solving-time-gap)
3. [Architecture](#3-architecture)
   - 3.1 [Key Data Structures](#31-key-data-structures)
   - 3.2 [The General Pattern](#32-the-general-pattern)
   - 3.3 [Phi Node Type Joining](#33-phi-node-type-joining)
4. [Exhaustive Match (Implemented)](#4-exhaustive-match-implemented)
   - 4.1 [Overview](#41-overview)
   - 4.2 [Implementation Architecture](#42-implementation-architecture)
   - 4.3 [Type Coverage](#43-type-coverage)
   - 4.4 [Connection to Return Analysis](#44-connection-to-return-analysis)
   - 4.5 [Extended Features](#45-extended-features)
5. [Never/NoReturn Branch Termination (Implemented)](#5-nevernoreturn-branch-termination-implemented)
   - 5.1 [Problem Statement](#51-problem-statement)
   - 5.2 [Implementation](#52-implementation)
   - 5.3 [Key Invariants](#53-key-invariants)
6. [Type-Aware Initialization (Partially Implemented)](#6-type-aware-initialization-partially-implemented)
   - 6.1 [Problem Statement](#61-problem-statement)
   - 6.2 [Implementation](#62-implementation)
   - 6.3 [Key Design Decisions](#63-key-design-decisions)
   - 6.4 [Known Gaps](#64-known-gaps)
7. [If/Elif Exhaustiveness (Future Design)](#7-ifelif-exhaustiveness-future-design)
   - 7.1 [Motivation](#71-motivation)
   - 7.2 [Design Considerations](#72-design-considerations)
   - 7.3 [Proposed Approach](#73-proposed-approach)
8. [Implementation Status & Roadmap](#8-implementation-status--roadmap)
   - 8.1 [What's Implemented](#81-whats-implemented)
   - 8.2 [Known Gaps](#82-known-gaps)
   - 8.3 [Non-Goals: Unreachable Code Skipping](#83-non-goals-unreachable-code-skipping)
   - 8.4 [Prioritized Roadmap](#84-prioritized-roadmap)
9. [Other Control Flow Constructs](#9-other-control-flow-constructs)
   - 9.1 [Try/Except/Finally](#91-tryexceptfinally)
   - 9.2 [Context Managers (with)](#92-context-managers-with)
   - 9.3 [Assert Statements](#93-assert-statements)
   - 9.4 [Loop Control Flow](#94-loop-control-flow)
10. [Examples & Test Cases](#10-examples--test-cases)
11. [Design Decisions & Rationale](#11-design-decisions--rationale)
12. [Integration Points](#12-integration-points)
13. [Key Files Reference](#13-key-files-reference)

---

## 1. Executive Summary

### Problem Statement

Python's type system includes features that require understanding control flow at the type
level, not just the syntactic level. Consider:

```python
from typing import NoReturn

def raises() -> NoReturn:
    raise Exception()

def process(x: str | int | None) -> str:
    if x is None:
        raises()  # Type says this never returns
    if isinstance(x, int):
        return str(x)
    return x  # x is str here
```

A naive type checker might:
- Warn that `x` could still be `None` after the first `if` (missing that `raises()` terminates)
- Require an explicit `else` clause even when the `if` conditions are exhaustive

Type-aware control flow analysis solves these problems by using type information to
understand:
1. **When branches terminate** (Never/NoReturn)
2. **When all cases are covered** (exhaustiveness)
3. **Which variables are guaranteed to be defined** (initialization)

### The Three Key Capabilities

| Capability | Description | Status |
|------------|-------------|--------|
| **Exhaustiveness** | Detect when pattern matching covers all possible values | ✅ Implemented (match) |
| **Termination** | Detect when branches end with Never/NoReturn | ✅ Implemented |
| **Initialization** | Correctly track which variables are defined after control flow | ⚠️ Partial |

### How They Interact

These capabilities feed into three downstream analyses:

```
                    ┌────────────────────┐
                    │   Type-Aware       │
                    │   Control Flow     │
                    └─────────┬──────────┘
                              │
        ┌─────────────────────┼─────────────────────┐
        │                     │                     │
        ▼                     ▼                     ▼
┌───────────────┐    ┌───────────────┐    ┌───────────────┐
│ Initialization│    │  Phi Node     │    │ Return Type   │
│   Tracking    │    │  Type Joins   │    │  Inference    │
└───────────────┘    └───────────────┘    └───────────────┘
        │                     │                     │
        ▼                     ▼                     ▼
   "x may be           "x: int | str"        "No implicit
   uninitialized"      (only live           None needed"
                        branches)
```

---

## 2. Core Concepts

### 2.1 Types of Type-Aware Control Flow

#### Exhaustiveness

Exhaustiveness analysis determines when a set of patterns or conditions covers all
possible values of a type.

**Match Statement Exhaustiveness:**
```python
from enum import Enum

class Color(Enum):
    RED = 1
    BLUE = 2

def describe(c: Color) -> str:
    match c:
        case Color.RED: return "red"
        case Color.BLUE: return "blue"
    # No implicit return needed - match is exhaustive
```

**If/Elif Exhaustiveness (Future):**
```python
def process(x: bool) -> str:
    if x is True:
        return "yes"
    elif x is False:
        return "no"
    # No implicit return needed - bool exhausted
```

#### Never/NoReturn Termination

When a function is annotated with `NoReturn` (or `Never`), calling it terminates
the current control flow path. Subsequent code in that branch is unreachable.

```python
from typing import NoReturn

def fail() -> NoReturn:
    raise Exception()

def process(x: int | None) -> int:
    if x is None:
        fail()  # This branch terminates
    return x  # x is int here, not int | None
```

#### Type Narrowing

Type narrowing refines the type of a variable based on control flow guards.
While not the focus of this document, narrowing is the foundation that enables
exhaustiveness and termination analysis.

```python
def process(x: int | str) -> None:
    if isinstance(x, int):
        # x is int here (narrowed)
        print(x + 1)
    else:
        # x is str here (narrowed by elimination)
        print(x.upper())
```

### 2.2 Downstream Impact Areas

Each type of control flow analysis affects three key downstream areas:

#### Impact Matrix

| Control Flow Type | Initialization | Phi Node Joins | Return Analysis |
|-------------------|----------------|----------------|-----------------|
| **Exhaustiveness** | All branches must define OR be covered | Only include live branches | No implicit return if exhaustive+returning |
| **Termination** | Terminated branches don't require definition | Exclude terminated branches from join | No implicit return if all paths terminate |
| **Narrowing** | N/A | Each branch contributes narrowed type | N/A |

#### Example: All Three Impacts

```python
from typing import Literal, NoReturn

def fail() -> NoReturn:
    raise Exception()

def example(x: Literal[1, 2, 3]) -> int:
    match x:
        case 1:
            y = 100
        case 2:
            y = 200
        case 3:
            fail()  # Terminated branch

    # Initialization: y IS defined (branch 3 terminates, doesn't count)
    # Phi node: y = 100 | 200 (branch 3 excluded)
    # Return: Exhaustive match, all non-terminating branches return implicitly
    return y
```

### 2.3 The Binding vs Solving Time Gap

The fundamental architectural challenge in Pyrefly is that control flow decisions
are made at **binding time**, but type information is only available at **solving time**.

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           BINDING TIME                                  │
│                                                                         │
│  - Parse AST, create bindings                                          │
│  - Determine control flow structure (branches, loops, merges)           │
│  - Track which statements could be the "last" in a branch               │
│  - NO type information available                                        │
│  - Cannot know if a function returns Never                              │
│  - Cannot know if patterns are exhaustive                               │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                           SOLVING TIME                                  │
│                                                                         │
│  - Resolve types for all bindings                                       │
│  - Type information fully available                                     │
│  - Can check if expression is Never                                     │
│  - Can compute remaining type after narrowing                           │
│  - Must emit errors, compute final types                                │
└─────────────────────────────────────────────────────────────────────────┘
```

**Solution Pattern**: At binding time, record references (keys) to expressions and
bindings that *might* affect control flow. At solving time, resolve these keys to
determine actual behavior.

---

## 3. Architecture

### 3.1 Key Data Structures

#### Flow Struct (scope.rs:430-446)

The `Flow` struct tracks per-branch state during binding:

```rust
pub struct Flow {
    /// Flow-sensitive type information for each name
    info: SmallMap<Name, FlowInfo>,

    /// Has syntactic termination occurred (return, raise, etc.)?
    has_terminated: bool,

    /// Conservative flag for error reporting
    is_definitely_unreachable: bool,

    /// Key for the last StmtExpr in this flow
    /// Used for type-based termination (NoReturn/Never) at solve time
    last_stmt_expr: Option<Idx<Key>>,
}
```

The `last_stmt_expr` field is the key innovation that enables deferred termination
checking. It stores a reference to the last expression-statement, which at solve
time can be checked for a `Never` return type.

#### BranchInfo Struct (binding.rs:1533-1541)

When merging branches in a `Phi` binding, each branch carries its termination info:

```rust
#[derive(Clone, Debug)]
pub struct BranchInfo {
    /// The type key from this branch.
    pub value_key: Idx<Key>,
    /// The last `Binding::StmtExpr` in this branch, if any.
    /// Used to check for type-based termination (NoReturn/Never) at solve time.
    pub termination_key: Option<Idx<Key>>,
}
```

The Phi binding then uses a vector of `BranchInfo`:

```rust
Phi(JoinStyle<Idx<Key>>, Vec<BranchInfo>),
```

This allows solve-time code to:
1. Check which branches terminate (have a `Never`-typed last expression)
2. Exclude those branches from the type join

#### LastStmt Enum (binding.rs:1461-1471)

For return type analysis, we track what kind of statement ends each code path:

```rust
pub enum LastStmt {
    /// The last statement is an expression
    Expr,

    /// The last statement is a `with` block
    With(IsAsync),

    /// The last statement is a match that may be type-exhaustive.
    /// Contains the match statement range to look up exhaustiveness at solve time.
    Match(TextRange),
}
```

The `Match` variant connects exhaustiveness checking to return analysis via the
match statement's text range.

#### MatchExhaustive Binding (binding.rs:1737-1744)

For match statement exhaustiveness, a special binding is created:

```rust
Binding::MatchExhaustive {
    subject_idx: Idx<Key>,
    subject_range: TextRange,
    /// When None, narrowing info couldn't be determined, so we conservatively
    /// assume the match is not exhaustive.
    exhaustiveness_info: Option<(NarrowingSubject, (Box<NarrowOp>, TextRange))>,
}
```

At solve time, this binding:
1. Applies the negated narrow op to the subject type
2. If remaining type is `Never`, match is exhaustive
3. Otherwise, emits a warning with missing cases

### 3.2 The General Pattern

All three capabilities follow the same pattern:

```
BINDING TIME:
1. Identify potential type-aware control flow point
2. Create a key/binding that captures necessary info
3. Record the key in control flow structures

SOLVING TIME:
1. Resolve the key to get type information
2. Make decision based on resolved types
3. Adjust downstream behavior (errors, type joins, etc.)
```

### 3.3 Phi Node Type Joining

Phi nodes represent the merge of multiple control flow paths. The type at a phi
node is the union of types from all live branches.

```python
if cond:
    x = 1      # Branch A: x = Literal[1]
else:
    x = "hi"   # Branch B: x = Literal["hi"]
# Phi: x = Literal[1] | Literal["hi"]
```

**With Termination Filtering:**

```python
if cond:
    x = 1      # Branch A: x = Literal[1]
else:
    fail()     # Branch B: terminates (Never)
# Phi: x = Literal[1] (Branch B excluded)
```

The `TypeInfo::join` function handles this, with termination info enabling
branch exclusion at solve time.

---

## 4. Exhaustive Match (Implemented)

### 4.1 Overview

Exhaustive match checking was implemented in a 14-commit stack that delivered:

- Detection of non-exhaustive matches with clear error messages
- Recognition that exhaustive matches don't need implicit returns
- Support for enums, literals, bool, None, final classes, unions
- Redundant case detection
- TypedDict discriminated union support
- Attribute-based exhaustiveness for @final classes

### 4.2 Implementation Architecture

The implementation follows the binding/solving split pattern:

**At Binding Time (`pattern.rs`, `stmt.rs`):**

```rust
// Create MatchExhaustive binding
let exhaustive_binding = Binding::MatchExhaustive {
    subject_key,
    subject_range: match_stmt.subject.range(),
    negated_ops: accumulated_negated_patterns,
};

// Track for return analysis
let last_stmt = LastStmt::Match(Some(exhaustive_key));
```

**At Solving Time (`narrow.rs`, `solve.rs`):**

```rust
// In narrow.rs
fn check_match_exhaustiveness(&self, ...) {
    // Apply negated narrow ops to subject type
    let remaining = self.apply_narrow_ops(subject_type, negated_ops);

    if !remaining.is_never() {
        // Match is not exhaustive
        let missing = self.format_missing_cases(&remaining);
        self.warn(NonExhaustiveMatch, missing);
    }
}

// In solve.rs for ReturnImplicit
fn solve_return_implicit(&self, ...) {
    // Check if match was exhaustive
    if let LastStmt::Match(Some(key)) = last_stmt {
        let binding = self.get_binding(key);
        if self.is_match_exhaustive(binding) {
            // Don't require implicit return
            return Type::never();
        }
    }
}
```

### 4.3 Type Coverage

Exhaustiveness is checked for these types:

| Type | Exhaustible? | Notes |
|------|--------------|-------|
| Enum (non-Flag) | ✅ Yes | All members known at compile time |
| `Literal[...]` | ✅ Yes | Finite set of values |
| `bool` | ✅ Yes | Effectively `Literal[True, False]` |
| `None` | ✅ Yes | Singleton type |
| `@final` class | ✅ Yes | No subclasses possible |
| Union | ✅ Yes* | *If all members exhaustible |
| Abstract class | ❌ No | Unknown subclasses may exist |
| `object`, `Any` | ❌ No | Open types |
| `tuple[int, ...]` | ❌ No | Unbounded length |

### 4.4 Connection to Return Analysis

The key innovation is the `LastStmt::Match` variant that connects exhaustiveness
to return type inference:

```python
from enum import Enum

class Color(Enum):
    RED = 1
    BLUE = 2

def describe(c: Color) -> str:
    match c:
        case Color.RED: return "red"
        case Color.BLUE: return "blue"
    # No warning about missing return!
```

**How it works:**

1. Binding time records `LastStmt::Match` with key to `MatchExhaustive` binding
2. Solving time checks if `MatchExhaustive` resolves to `Never` (exhaustive)
3. If exhaustive AND all branches return, no implicit `None` is added

### 4.5 Extended Features

#### Redundant Case Detection

```python
match x:
    case Color.RED: ...
    case Color.RED: ...  # W: Redundant case
```

#### Duplicate Pattern Detection

```python
match x:
    case 1: ...
    case 1: ...  # W: Duplicate pattern
```

#### TypedDict Discriminated Unions

```python
from typing import TypedDict, Literal

class DogEvent(TypedDict):
    type: Literal["dog"]
    bark_volume: int

class CatEvent(TypedDict):
    type: Literal["cat"]
    purr_intensity: int

def handle(event: DogEvent | CatEvent) -> str:
    match event:
        case {"type": "dog"}: return "woof"
        case {"type": "cat"}: return "meow"
    # Exhaustive - type field covers all variants
```

#### Attribute-Based Exhaustiveness

For `@final` classes with exhaustible attributes:

```python
from typing import final

@final
class Toggle:
    enabled: bool

def describe(t: Toggle) -> str:
    match t:
        case Toggle(enabled=True): return "on"
        case Toggle(enabled=False): return "off"
    # Exhaustive - bool attribute fully covered
```

This uses a "positive ops" approach to work around the `Placeholder` limitation
for class patterns with arguments.

---

## 5. Never/NoReturn Branch Termination (Implemented)

### 5.1 Problem Statement

Python's `Never` (aliased as `NoReturn`) type indicates a function never returns
normally. Calling such a function should be recognized as terminating control flow:

```python
from typing import NoReturn

def fail() -> NoReturn:
    raise Exception()

def process(x: int | None) -> int:
    if x is None:
        fail()  # Should terminate this branch
    return x  # x should be int, not int | None
```

### 5.2 Implementation

Never/NoReturn branch termination is fully implemented. The implementation follows
the binding/solving split pattern:

**Binding Time (stmt.rs:1085-1097):**

When processing expression statements, we track the last one as a potential
termination point:

```rust
Stmt::Expr(mut x) => {
    let mut current = self.declare_current_idx(Key::StmtExpr(x.value.range()));
    self.ensure_expr(&mut x.value, current.usage());
    let special_export = if let Expr::Call(ExprCall { func, .. }) = &*x.value {
        self.as_special_export(func)
    } else {
        None
    };
    let key = self
        .insert_binding_current(current, Binding::StmtExpr(*x.value, special_export));
    // Track this StmtExpr as the trailing statement for type-based termination
    self.scopes.set_last_stmt_expr(Some(key));
}
```

**Threading Through Phi (scope.rs:2954-2986):**

Termination keys are collected from all flows and threaded into `BranchInfo`:

```rust
// Collect all termination keys from flows
let all_termination_keys: Vec<Option<Idx<Key>>> =
    flows.iter().map(|f| f.last_stmt_expr).collect();

// Thread into MergeBranchEntry for each name
let branches: Vec<MergeBranchEntry> = flow_infos
    .iter()
    .enumerate()
    .map(|(i, flow_info_map)| MergeBranchEntry {
        flow_info: flow_info_map.get(&name).cloned(),
        termination_key: all_termination_keys[i],
    })
    .collect();
```

**Solving Time (solve.rs:3375-3434):**

The Phi solving logic filters out terminated branches:

```rust
fn binding_to_type_info_phi(
    &self,
    join_style: &JoinStyle<Idx<Key>>,
    branches: &[BranchInfo],
) -> TypeInfo {
    // Filter branches based on type-based termination (Never/NoReturn)
    let live_value_keys: Vec<Idx<Key>> = branches
        .iter()
        .filter_map(|branch| {
            match branch.termination_key {
                None => Some(branch.value_key),  // No terminal, branch is live
                Some(term_key) => {
                    let term_type = self.get_idx(term_key);
                    if term_type.ty().is_never() {
                        None  // Branch terminated with Never/NoReturn
                    } else {
                        Some(branch.value_key)  // Branch is live
                    }
                }
            }
        })
        .collect();

    // If all branches terminated, use all value keys (consistent with binding-time)
    let keys_to_use = if live_value_keys.is_empty() {
        branches.iter().map(|b| b.value_key).collect()
    } else {
        live_value_keys
    };

    // Join types from live branches only
    let type_infos = keys_to_use.iter().filter_map(|k| {
        let t: Arc<TypeInfo> = self.get_idx(*k);
        // ... filtering logic ...
    }).collect();

    TypeInfo::join(type_infos, ...)
}
```

### 5.3 Key Invariants

1. **`last_stmt_expr` is only meaningful if `!has_terminated`**: Syntactically
   terminated branches (explicit return, raise) are already filtered at binding
   time. The `last_stmt_expr` mechanism handles type-based termination.

2. **All branches Never → use all**: If every branch terminates with Never, we
   include all value keys in the join. This is consistent with how syntactic
   termination works at binding time.

3. **Clearing on non-StmtExpr**: The `last_stmt_expr` field is cleared when
   processing non-expression statements, ensuring it only tracks trailing
   expression statements that could be NoReturn calls.

---

## 6. Type-Aware Initialization (Partially Implemented)

### 6.1 Problem Statement

Pyrefly's initialization checking needs to account for branches that terminate
with Never/NoReturn. Consider:

```python
from typing import Literal, NoReturn

def never() -> NoReturn:
    raise Exception()

def test(x: Literal[1, 2, 3]) -> str:
    match x:  # NOT exhaustive - missing case 3
        case 1:
            y = "one"
        case 2:
            never()  # y not initialized, but branch terminates
    return y  # Should warn: case 3 doesn't initialize y
```

The challenge is determining at binding time whether the branch with `never()`
actually terminates, since we don't have type information yet.

### 6.2 Implementation

Type-aware initialization uses a deferred checking mechanism via `BindingExpect`.

**InitializedInFlow Enum (bindings.rs:132-158):**

```rust
pub enum InitializedInFlow {
    Yes,
    Conditionally,
    No,
    /// Initialization depends on whether these termination keys have Never type.
    /// If ALL termination keys are Never, the variable is initialized;
    /// otherwise it may be uninitialized.
    DeferredCheck(Vec<Idx<Key>>),
}
```

**UninitializedCheck Expectation (binding.rs:750-762):**

Rather than a separate `Binding` variant, the implementation uses `BindingExpect`
for deferred initialization checks:

```rust
BindingExpect::UninitializedCheck {
    /// The variable name (for error messages).
    name: Name,
    /// The range of the variable usage (for error location).
    range: TextRange,
    /// Termination keys from branches that don't define the variable.
    /// At solve time, we check if ALL of these have Never type.
    termination_keys: Vec<Idx<Key>>,
},
```

**At Solve Time:**

The expectation is checked after types are resolved:

```rust
BindingExpect::UninitializedCheck { name, range, termination_keys } => {
    let all_terminate = termination_keys.iter()
        .all(|k| self.get_idx(*k).ty().is_never());

    if !all_terminate {
        self.error(range, "`{}` may be uninitialized", name);
    }
}
```

### 6.3 Key Design Decisions

1. **Expectation vs Binding**: Uses `BindingExpect::UninitializedCheck` rather
   than a new `Binding` variant. This leverages the existing expectation system
   for solve-time checks without modifying the core binding types.

2. **Flat Termination Key Collection**: Uses `Vec<Idx<Key>>` to collect all
   termination keys that must resolve to Never for the variable to be initialized.

3. **Error Emission Split**: Binding time emits errors for definite cases
   (`Yes`, `Conditionally`, `No`); solve time emits errors only for
   `DeferredCheck` cases after resolving termination keys.

4. **Scope Limitation**: Focuses on branch/match merges; loops have additional
   complexity (`MergeStyle::Loop`) that requires different handling.

### 6.4 Known Gaps

The current implementation handles the common cases but has some gaps:

1. **Walrus operator in boolean expressions**: Disabled for now due to complexity
   (see GitHub issue #1251)

2. **Loop initialization**: `MergeStyle::Loop` has different semantics that are
   not yet fully integrated with type-aware initialization

---

## 7. If/Elif Exhaustiveness (Future Design)

### 7.1 Motivation

Currently, only `match` statements are checked for exhaustiveness. However,
`if/elif` chains with type guards can also be exhaustive:

```python
from enum import Enum

class Color(Enum):
    RED = 1
    BLUE = 2
    GREEN = 3

def describe(c: Color) -> str:
    if c is Color.RED:
        return "red"
    elif c is Color.BLUE:
        return "blue"
    elif c is Color.GREEN:
        return "green"
    # This is exhaustive! No else needed.
```

Currently, Pyrefly would warn about a missing return here.

### 7.2 Design Considerations

**Similarities to Match:**
- Same narrowing infrastructure applies
- Same exhaustibility criteria (enums, literals, bool, etc.)
- Same downstream impacts (return analysis, initialization)

**Differences from Match:**
- No explicit "subject" expression
- Guards can be arbitrary, not just patterns
- Mixed conditions (some type guards, some not)
- Early returns in branches

**Edge Cases:**
1. Mixed guards: `if isinstance(x, int): ... elif x > 0: ...` - the second
   condition doesn't narrow the type
2. Non-narrowing conditions: `if random(): ...` - can't contribute to exhaustiveness
3. Early returns: If each branch returns, exhaustiveness may not matter

### 7.3 Proposed Approach

**Step 1: Detect Exhaustive If/Elif Chains**

At binding time, when finishing a non-exhaustive fork:
- Check if all branches are `if`/`elif` with narrowing conditions
- Create a binding similar to `MatchExhaustive` that captures the negated ops

**Step 2: Leverage Existing Infrastructure**

The narrowing infrastructure already tracks `negated_prev_ops` for elif chains.
The key is to:
1. Thread this to a new `IfExhaustive` binding
2. At solve time, check if remaining type is `Never`

**Step 3: Integration with Return Analysis**

Add `LastStmt::If(Option<Idx<KeyExpect>>)` variant similar to `LastStmt::Match`.

**Proposed Changes:**

```rust
// New binding
Binding::IfExhaustive {
    subject_key: Idx<Key>,  // The narrowed variable
    negated_ops: NarrowOps,
}

// Extended LastStmt
enum LastStmt {
    Expr,
    With(IsAsync),
    Match(Option<Idx<KeyExpect>>),
    If(Option<Idx<KeyExpect>>),  // NEW
}
```

**Limitation:** This only works when the if/elif chain narrows a single subject.
More complex conditions (multiple variables, non-narrowing checks) would not
benefit from this analysis.

---

## 8. Implementation Status & Roadmap

### 8.1 What's Implemented

| Feature | Status | Completeness | Key Files |
|---------|--------|--------------|-----------|
| **Match Exhaustiveness** | ✅ Complete | 95% | 14-commit stack |
| Basic enum/literal | ✅ | 100% | `narrow.rs` |
| Bool, None, unions | ✅ | 100% | `narrow.rs` |
| @final classes | ✅ | 100% | `narrow.rs` |
| Return analysis integration | ✅ | 100% | `solve.rs`, `function.rs` |
| Redundant case detection | ✅ | 100% | `narrow.rs` |
| TypedDict discriminated unions | ✅ | 100% | `narrow.rs` |
| Attribute exhaustiveness | ✅ | 90% | Limited to 1024 combinations |
| **Never/NoReturn Termination** | ✅ Complete | 95% | |
| Basic return type handling | ✅ | 100% | `solve.rs:3131-3165` |
| `last_stmt_expr` field | ✅ | 100% | `scope.rs:443-446` |
| Setting in Stmt::Expr | ✅ | 100% | `stmt.rs:1085-1097` |
| BranchInfo with termination_key | ✅ | 100% | `binding.rs:1533-1541` |
| Phi termination filtering | ✅ | 100% | `solve.rs:3375-3434` |
| **Type-Aware Initialization** | ⚠️ Partial | 75% | |
| DeferredCheck variant | ✅ | 100% | `bindings.rs:132-158` |
| UninitializedCheck expectation | ✅ | 100% | `binding.rs:750-762` |
| Solve-time error emission | ✅ | 100% | `solve.rs` |
| Loop initialization | ❌ | 0% | Different semantics needed |
| Walrus in bool ops | ❌ | 0% | Disabled, see #1251 |
| **If/Elif Exhaustiveness** | ❌ Not started | 0% | |
| **Type Narrowing** | ✅ Complete | 95% | |
| 35+ atomic operations | ✅ | 100% | `narrow.rs` |
| Facet-aware narrowing | ✅ | 100% | `facet.rs` |
| **Phi Node Joining** | ✅ Complete | 95% | |
| TypeInfo join | ✅ | 100% | `type_info.rs` |
| Facet-aware joining | ✅ | 100% | `type_info.rs` |
| Termination filtering | ✅ | 100% | `solve.rs:3375-3434` |

### 8.2 Known Gaps

1. **If/Elif Exhaustiveness**
   - Not implemented at all
   - Would enable: `if x is True: ... elif x is False: ...` patterns
   - Uses only static evaluation currently, not type-based analysis

2. **Loop Initialization**
   - `MergeStyle::Loop` has different semantics
   - Loop body may not execute, variables may be modified across iterations
   - Not integrated with type-aware initialization

3. **Walrus Operator in Boolean Expressions**
   - Disabled due to complexity (GitHub issue #1251)
   - Affects initialization tracking in `x := value or default` patterns

4. **Class Patterns with Arguments**
   - Use `Placeholder` narrow ops that prevent exact negation
   - Workaround via positive ops only works for @final classes

### 8.3 Non-Goals: Unreachable Code Skipping

Some type checkers skip type-checking code that follows a `NoReturn` call. Pyrefly
intentionally does **not** do this for two reasons:

1. **Architectural constraints**: Bindings are created at binding time, but we don't
   know if an expression returns `Never` until solve time. Suppressing errors in
   "unreachable" code would require either threading unreachability through every
   error emission path or creating conditional bindings for every statement after
   a potential NoReturn call - both prohibitively invasive changes.

2. **Design philosophy**: The Pyrefly team believes all code should be type-checked,
   even if it's unreachable. Skipping unreachable code:
   - Would disable IDE features (hover, go-to-definition) for that code
   - Masks potential bugs that would surface if the code became reachable
   - Creates inconsistent behavior that's hard for users to understand

Pyrefly correctly handles the *type-level* implications of NoReturn (excluding
terminated branches from Phi joins, so narrowing works correctly). The tradeoff
is that syntactically unreachable code may produce type errors.

### 8.4 Prioritized Roadmap

| Priority | Feature | Dependencies | Effort | Impact |
|----------|---------|--------------|--------|--------|
| **P1** | If/elif exhaustiveness | None | Medium | Medium |
| **P1** | Loop initialization | Type-aware init | Medium | Medium |
| **P2** | Class patterns without Placeholder | Narrowing changes | Large | Medium |
| **P3** | Walrus in bool ops | Type-aware init | Medium | Low |

**Next Steps:**

1. **If/elif exhaustiveness** - The infrastructure from match exhaustiveness can
   be adapted. Need to:
   - Detect when if/elif chains narrow a single subject
   - Create `IfExhaustive` binding similar to `MatchExhaustive`
   - Add `LastStmt::If` variant for return analysis

2. **Loop initialization** - Requires understanding loop semantics:
   - `for i in non_empty_list:` guarantees at least one iteration
   - `while condition():` may not execute at all
   - Need `is_definitely_nonempty_iterable()` check

---

## 9. Other Control Flow Constructs

While the previous sections focused on the core type-aware control flow features,
Pyrefly also handles several other control flow constructs. This section documents
their behavior and interaction with type analysis.

### 9.1 Try/Except/Finally

Exception handling has significant control flow implications that affect type
analysis.

**Basic Try/Except:**

```python
try:
    x = risky_operation()
except SomeError:
    x = default_value
# x is defined in both branches
```

**Finally Block Semantics:**

The `finally` block always executes, and its effects override previous branches:

```python
try:
    x = 1
except:
    x = 2
finally:
    x = 3

assert_type(x, Literal[3])  # finally overwrites all previous bindings
```

**Implementation:** Try/except/finally is handled in `stmt.rs` with special fork/merge
logic. The `finally` block is processed after merging try and except branches, and
its bindings take precedence.

**Tests:** See `pyrefly/lib/test/flow_branching.rs:276-375`

### 9.2 Context Managers (with)

Context managers use `__enter__` and `__exit__` protocols with specific type
implications.

**Basic Usage:**

```python
with open("file.txt") as f:
    # f has type returned by __enter__
    content = f.read()
# f is still in scope but file is closed
```

**Async Context Managers:**

```python
async with aiofiles.open("file.txt") as f:
    # Uses __aenter__ and __aexit__
    content = await f.read()
```

**Return Analysis:**

The `LastStmt::With(IsAsync)` variant tracks when a function ends with a `with`
block for return type inference.

**Tests:** See `pyrefly/lib/test/with.rs` (200+ lines of tests)

### 9.3 Assert Statements

Assert statements can affect control flow when the condition is statically known.

**Assert False Terminates:**

```python
def process(x: int | str) -> int:
    if isinstance(x, str):
        assert False, "unexpected string"
    return x  # x is int here
```

When `assert False` is detected, `has_terminated` is set to `True` for that flow,
similar to explicit `raise` statements.

**Implementation:** In `stmt.rs:110-143`, the `assert()` method has special logic:

```rust
if let Some(false) = static_test {
    self.scopes.mark_flow_termination(true);
}
```

**Tests:** See `pyrefly/lib/test/flow_branching.rs:842-849`

### 9.4 Loop Control Flow

Loops have unique control flow semantics that interact with type analysis.

**Break and Continue:**

```python
for item in items:
    if condition:
        break  # Exits loop early
    if other:
        continue  # Skips to next iteration
    process(item)
```

**While True with Break:**

```python
while True:
    x = get_value()
    if x is not None:
        break
# x is guaranteed to be not None here (loop must have executed break)
```

**Loop Execution Guarantees:**

The binding phase uses `is_definitely_nonempty_iterable()` (stmt.rs:70-107) to
determine if a for loop is guaranteed to execute at least once:

```python
for i in [1, 2, 3]:  # Non-empty literal - guaranteed to execute
    y = i
# y is definitely initialized

for i in some_list:  # May be empty - not guaranteed
    z = i
# z may be uninitialized
```

**For/While Else Clauses:**

The else clause of a for/while loop executes when the loop completes without
breaking:

```python
for item in items:
    if matches(item):
        result = item
        break
else:
    result = None  # No match found
# result is defined in all paths
```

**Tests:** See `pyrefly/lib/test/flow_branching.rs:165-203`

---

## 10. Examples & Test Cases

### Match Exhaustiveness

**Basic Enum (pyrefly/lib/test/pattern_match.rs):**
```python
from enum import Enum

class Color(Enum):
    RED = 1
    BLUE = 2

def describe(c: Color) -> str:
    match c:
        case Color.RED: return "red"
        case Color.BLUE: return "blue"
    # OK - exhaustive, no missing return warning
```

**Non-Exhaustive Warning (pyrefly/lib/test/pattern_match.rs:64-73):**
```python
def foo(x: Literal['A'] | Literal['B']):
    match x:  # E: Match on `Literal['A', 'B']` is not exhaustive
        case 'A':
            raise ValueError()
    assert_type(x, Literal['B'])
```

**Class Pattern Narrowing (pyrefly/lib/test/pattern_match.rs:88-100):**
```python
def f0(x: int | str):
    match x:
        case int():
            pass
        case _:
            assert_type(x, str)  # Narrowed correctly
```

### Never/NoReturn Handling

**Return Type Inference (pyrefly/lib/test/returns.rs:91-105):**
```python
from typing import NoReturn

def fail() -> NoReturn:
    raise Exception()

def f(b: bool) -> int:
    if b:
        return 1
    else:
        fail()
    # OK - no missing return warning
```

**Inferred Never (pyrefly/lib/test/returns.rs:175-185):**
```python
from typing import assert_type, Never

def f():
    raise Exception()

assert_type(f(), Never)  # Function that only raises infers Never
```

### Initialization Checking

**May Be Uninitialized (pyrefly/lib/test/pattern_match.rs:10-19):**
```python
match 42:
    case x:  # E: name capture `x` makes remaining patterns unreachable
        pass
    case y:
        pass
print(y)  # E: `y` may be uninitialized
```

### Control Flow Merging

**Basic If/Else (pyrefly/lib/test/flow_branching.rs:16-29):**
```python
def b() -> bool:
    return True

if b():
    x = 100
else:
    x = "test"
y = x
assert_type(y, Literal['test', 100])  # Union of both branches
```

---

## 11. Design Decisions & Rationale

### Why Track `last_stmt_expr`?

**Decision:** Store an optional key to the last `StmtExpr` in each flow.

**Rationale:**
- `StmtExpr` is the most common location for `NoReturn` calls (e.g., `fail()`)
- Tracking only the *last* statement is sufficient for most real-world code
- Minimal memory overhead (single `Option<Idx<Key>>`)
- Enables deferred decision without changing binding structure

**Alternative Considered:** Track all function calls in the branch.
**Rejected Because:** Would significantly increase binding size; the last-statement
heuristic covers practical cases.

### Why Deferred Checks Instead of Optimistic/Pessimistic?

**Decision:** Defer initialization decisions to solve time for cases with termination keys.

**Rationale:**
- **Optimistic** (assume termination) causes false negatives (the current bug)
- **Pessimistic** (assume no termination) causes false positives
- **Deferred** gets correct answers by waiting for type information

### Why `BindingExpect::UninitializedCheck` Instead of a Binding Variant?

**Decision:** Use the existing expectation system rather than a new `Binding` variant.

**Rationale:**
- `Binding` has size constraints (`assert_words!(Binding, 11)`) that must be honored
- The expectation system is already designed for solve-time checks
- Most name lookups don't need deferred initialization checking
- Keeps the common `Binding::Forward` path simple and fast

### Why `Vec<Idx<Key>>` for Termination Keys?

**Decision:** Use a simple `Vec` to collect termination keys.

**Rationale:**
- Most cases have 1-3 termination keys
- `Vec` is simple and well-understood
- The overhead of `SmallVec` optimization is minimal for this use case
- Flat structure is easier to reason about than nested conditionals

### Why Limit Multi-Attribute Combinations to 1024?

**Decision:** Cap attribute exhaustiveness checking at 1024 combinations.

**Rationale:**
- Cartesian product grows exponentially with attributes
- 1024 = ~10 boolean attributes, which is already unusual
- Beyond this, fall back to independent attribute checking
- Prevents exponential blowup in pathological cases

---

## 12. Integration Points

### Narrowing Infrastructure

Type-aware control flow builds on Pyrefly's narrowing infrastructure:

**Key Files:**
- `pyrefly/lib/alt/narrow.rs` - Narrowing operations and exhaustiveness
- `pyrefly/lib/binding/narrow.rs` - `NarrowOps` algebra

**Integration Points:**
- `check_match_exhaustiveness()` uses `NarrowOps::apply()` to narrow types
- `should_check_exhaustiveness()` determines which types to check
- `format_missing_cases()` produces human-readable error messages

### Type Solver

**Key Files:**
- `pyrefly/lib/alt/solve.rs` - Main solving logic
- `crates/pyrefly_types/src/type_info.rs` - Type joins and facets

**Integration Points:**
- `solve_binding()` handles `MatchExhaustive`, `ReturnImplicit`, `Phi`
- `TypeInfo::join()` merges types from multiple branches
- `is_never()` checks for termination types

### Error Reporting

**Key Files:**
- `crates/pyrefly_config/src/error_kind.rs` - Error definitions
- `pyrefly/lib/error/` - Error collection and formatting

**Relevant Errors:**
- `NonExhaustiveMatch` - Warning for non-exhaustive match
- `RedundantMatchCase` - Warning for redundant cases
- `MissingReturn` - Error for missing return statements
- `UnboundName` - Error for uninitialized variables

---

## 13. Key Files Reference

### Documentation (to synthesize)

| File | Description |
|------|-------------|
| `pyrefly-docs/old/type-aware-if-branch-termination/project-plan-v0.md` | Never/NoReturn design |
| `pyrefly-docs/type-aware-initialization/v0-doc.md` | Initialization v0 design |
| `pyrefly-docs/type-aware-initialization/v1-doc.md` | Initialization v1 design |
| `pyrefly-docs/exhaustive-match/PLAN.md` | Match exhaustiveness plan |
| `pyrefly-docs/exhaustive-match/IMPLEMENTATION_AS_BUILT.md` | Match implementation summary |

### Implementation

| File | Description |
|------|-------------|
| `pyrefly/lib/binding/scope.rs` | Flow struct, termination tracking |
| `pyrefly/lib/binding/stmt.rs` | Statement processing, last_stmt_expr |
| `pyrefly/lib/binding/binding.rs` | Binding types, PhiTerminationInfo |
| `pyrefly/lib/binding/function.rs` | Return analysis, LastStmt |
| `pyrefly/lib/binding/pattern.rs` | Pattern binding, match exhaustiveness |
| `pyrefly/lib/alt/narrow.rs` | Narrowing, exhaustiveness checking |
| `pyrefly/lib/alt/solve.rs` | Solving, Phi handling, return analysis |
| `crates/pyrefly_types/src/type_info.rs` | TypeInfo, join, facets |

### Tests

| File | Description |
|------|-------------|
| `pyrefly/lib/test/returns.rs` | Return type inference tests |
| `pyrefly/lib/test/flow_branching.rs` | Control flow tests |
| `pyrefly/lib/test/pattern_match.rs` | Match exhaustiveness tests |
| `pyrefly/lib/test/narrow.rs` | Narrowing tests |

---

## Appendix A: Glossary

| Term | Definition |
|------|------------|
| **Binding** | A node in Pyrefly's IR representing a value or type |
| **Binding Time** | Phase when AST is processed and bindings are created |
| **Exhaustive** | A set of patterns/conditions that covers all possible values |
| **Facet** | A sub-property of a type (e.g., attribute, subscript) |
| **Flow** | The type state at a point in program execution |
| **Key** | An index into the bindings table (`Idx<Key>`) |
| **Narrow/Narrowing** | Refining a type based on control flow guards |
| **Never** | Type indicating a function/expression never returns normally |
| **Phi Node** | A binding representing the merge of multiple control flow paths |
| **Solving Time** | Phase when types are resolved and errors emitted |
| **Termination** | Control flow ending (return, raise, Never call) |

---

## Appendix B: Version History

| Version | Date | Changes |
|---------|------|---------|
| v0 | 2026-02-02 | Initial unified document |
| v0.1 | 2026-02-02 | Updated to reflect actual implementation status. Key changes: (1) Phi termination filtering is implemented, not 0%. (2) Section 3 data structures updated to match actual code (BranchInfo instead of PhiTerminationInfo, corrected LastStmt::Match and MatchExhaustive). (3) Section 5 marked as Implemented with actual code references. (4) Section 6 updated to reflect UninitializedCheck expectation instead of CheckedForward binding. (5) Added Section 9 covering try/except, context managers, assert, and loops. (6) Updated implementation percentages throughout. |
| v0.2 | 2026-02-02 | Added Section 8.3 documenting that unreachable code skipping is a non-goal due to architectural constraints (binding/solving split) and design philosophy (type-check all code, preserve IDE features). Removed from roadmap. |

---

*This document synthesizes the type-aware control flow efforts in Pyrefly, providing
a comprehensive reference for developers working on these features.*
