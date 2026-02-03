# Type-Aware Initialization Checking (Revised Plan v2)

## Problem Statement

Pyrefly's initialization checking currently happens at binding time, before type
information is available. This causes false negatives when branches have
termination keys (potential `Never`/`NoReturn` calls) that aren't yet known to
actually terminate.

See https://github.com/facebook/pyrefly/issues/2055 for the tracking issue.

### Example: False Negative

```python
from typing import Literal, NoReturn

def never() -> NoReturn:
    raise Exception()

def test_non_exhaustive(x: Literal[1, 2, 3]) -> str:
    match x:  # NOT exhaustive - missing case 3
        case 1:
            y = "one"
        case 2:
            never()  # y not initialized, but has termination_key
    return y  # BUG: Should flag "may be uninitialized" but doesn't
```

**Why it happens**: At binding time, the flow merger in `scope.rs:~1758`
counts branches with `termination_key` as "potentially terminating":

```rust
let this_name_always_defined = n_values == n_branches
    || n_missing_branches <= n_branches_with_termination_key;
```

This assumes any branch with a termination key will terminate, but we don't know
the actual return type until solve time.

### Additional Issue: Base Flow Termination Key Not Threaded

There's a related gap in the current implementation. In `finish_fork_impl`, the
base flow termination key (e.g., `MatchExhaustive`) is set on the current flow:

```rust
if let Some(term_key) = base_termination_key {
    self.scopes.current_mut().flow.last_stmt_expr = Some(term_key);
}
```

But then `merge_flow` is called with the **original** `fork.base`, and the current
flow is discarded. In `merged_flow_info`, the base is included in the Phi with
`termination_key: None`:

```rust
branch_infos.insert(0, BranchInfo {
    value_key: base_idx,
    termination_key: None,  // Base termination key is lost!
});
```

This means the `MatchExhaustive` key (which tracks whether unhandled cases exist)
is not used for initialization checking. The fix must address both issues.

### Contrast: Correct Behavior Without Termination Key

```python
def test_correct(x: Literal[1, 2, 3]) -> str:
    match x:
        case 1:
            y = "one"
        case 2:
            pass  # No termination key
    return y  # Correctly flags: "`y` may be uninitialized"
```

## Design Goals

1. **Fix the false negative**: When termination_key doesn't resolve to Never,
   correctly flag uninitialized variables
2. **Preserve current behavior**: No regressions for cases that work correctly
3. **Maintain coherent architecture**: Use patterns consistent with existing
   termination_key handling in Phi nodes
4. **Minimize scope**: Target the specific gap without overhauling initialization
5. **Respect size constraints**: The `Binding` enum has size assertions that must be honored

## Solution Overview

Instead of making a binding-time decision about whether a branch "counts" toward
initialization, we defer the decision to solve time by recording the dependency:

> "This variable is initialized **if** all relevant termination_keys return Never;
> otherwise, it may be uninitialized."

This mirrors how `Binding::Phi` already handles type merging with termination_key
in `solve.rs:~345-375`.

## Key Architectural Decisions

### Decision 1: New Binding Variant Instead of Modifying Forward

The original plan proposed extending `Binding::Forward`. However:

- `Binding::Forward(Idx<Key>)` is used pervasively (IDE features, pattern matching)
- The assertion `assert_words!(Binding, 11)` at `binding.rs:102` enforces size constraints
- Most Forward bindings don't need initialization tracking (they're definitely initialized)

**Solution**: Create a new `Binding::CheckedForward` variant for the uncommon case
where initialization depends on termination keys. Keep `Binding::Forward` simple.

### Decision 2: Flat Termination Key Collection

The original plan oscillated between nested and flat structures. After analysis:

- Nested `ConditionalOnTermination { key, fallback }` is more elegant but adds complexity
- Flat `SmallVec<[Idx<Key>; 2]>` is simpler and sufficient

**Semantics**: "The variable is initialized if ALL of these termination keys return Never.
If ANY key does NOT return Never, we have an uninitialized path."

This works because:
- Branches without termination keys that don't initialize → result is immediately `Conditionally`
- Only branches with termination keys get deferred → we check all at solve time

### Decision 3: Emit Errors at Both Binding and Solve Time

- **Binding time**: Emit errors for `Yes`, `Conditionally`, `No` (existing behavior)
- **Solve time**: Emit errors only for `CheckedForward` bindings after resolution

This minimizes changes and maintains backward compatibility.

## Implementation Plan

### Phase 1: Extend InitializedInFlow

**File**: `pyrefly/lib/binding/bindings.rs`

```rust
use pyrefly_graph::index::Idx;
use smallvec::SmallVec;

use crate::binding::binding::Key;

/// Represents whether a name is initialized at a given point in the flow.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum InitializedInFlow {
    /// Definitely initialized
    Yes,
    /// May or may not be initialized (from branch merging)
    Conditionally,
    /// Definitely not initialized
    No,
    /// Initialized only if ALL of these termination keys return Never at solve time.
    /// If any termination key does NOT return Never, the variable may be uninitialized.
    ///
    /// This variant is used when we can't determine initialization at binding time
    /// because it depends on type-based termination (NoReturn/Never).
    DeferredCheck(SmallVec<[Idx<Key>; 2]>),
}

impl InitializedInFlow {
    /// Returns an error message if this state indicates an uninitialized variable.
    ///
    /// Panics if called on `DeferredCheck` - that variant must be resolved at solve time.
    pub fn as_error_message(&self, name: &Name) -> Option<String> {
        match self {
            InitializedInFlow::Yes => None,
            InitializedInFlow::Conditionally => {
                Some(format!("`{name}` may be uninitialized"))
            }
            InitializedInFlow::No => {
                Some(format!("`{name}` is uninitialized"))
            }
            InitializedInFlow::DeferredCheck(_) => {
                panic!("DeferredCheck must be resolved at solve time before calling as_error_message")
            }
        }
    }

    /// Returns true if this state requires solve-time resolution.
    pub fn needs_solve_time_check(&self) -> bool {
        matches!(self, InitializedInFlow::DeferredCheck(_))
    }
}
```

### Phase 2: Add CheckedForward Binding Variant

**File**: `pyrefly/lib/binding/binding.rs`

Add a new variant after `Forward`:

```rust
pub enum Binding {
    // ... existing variants ...

    /// A forward reference to another binding (simple case, definitely initialized or
    /// initialization already checked at binding time).
    Forward(Idx<Key>),

    /// A forward reference where initialization depends on termination keys.
    /// The error is emitted at solve time after checking if all termination keys return Never.
    CheckedForward {
        target: Idx<Key>,
        /// Termination keys that must all return Never for the variable to be initialized
        termination_keys: SmallVec<[Idx<Key>; 2]>,
        /// Name for error message
        name: Name,
        /// Range for error location
        range: TextRange,
    },

    // ... rest of variants ...
}
```

**Note**: To respect size constraints, we may need to box the payload:

```rust
CheckedForward(Box<CheckedForwardData>),

// where:
pub struct CheckedForwardData {
    pub target: Idx<Key>,
    pub termination_keys: SmallVec<[Idx<Key>; 2]>,
    pub name: Name,
    pub range: TextRange,
}
```

### Phase 3: Update Flow Merging

**File**: `pyrefly/lib/binding/scope.rs`

Modify `merged_flow_info` to produce `DeferredCheck` instead of optimistically
assuming termination keys will terminate.

#### Current Logic (around line 1758)

```rust
let n_missing_branches = n_total_branches - n_values;
let this_name_always_defined = match merge_style {
    MergeStyle::LoopDefinitelyRuns => {
        base_has_value
            || n_values == n_branches
            || n_missing_branches <= n_branches_with_termination_key
    }
    _ => n_values == n_branches || n_missing_branches <= n_branches_with_termination_key,
};
```

#### New Logic

```rust
/// Compute the initialization state for a name after merging branches.
///
/// Returns (is_definitely_initialized, deferred_termination_keys)
fn compute_initialization_state(
    n_values: usize,
    n_branches: usize,
    merge_branches: &[MergeBranch],
    base_has_value: bool,
    base_termination_key: Option<Idx<Key>>,
    merge_style: MergeStyle,
) -> InitializedInFlow {
    // If all branches have a value, definitely initialized
    let n_total_branches = if base_termination_key.is_some() || !base_has_value {
        n_branches + 1
    } else {
        n_branches
    };

    if n_values == n_total_branches {
        return InitializedInFlow::Yes;
    }

    // Collect termination keys from branches that don't have a value
    let mut termination_keys: SmallVec<[Idx<Key>; 2]> = SmallVec::new();
    let mut has_uninitialized_without_termination = false;

    // Check base flow
    if !base_has_value {
        if let Some(term_key) = base_termination_key {
            termination_keys.push(term_key);
        } else {
            has_uninitialized_without_termination = true;
        }
    }

    // Check each branch
    for branch in merge_branches {
        let has_value = branch.flow_info.value.is_some();
        if !has_value {
            if let Some(term_key) = branch.termination_key {
                termination_keys.push(term_key);
            } else {
                has_uninitialized_without_termination = true;
            }
        }
    }

    // If any branch is uninitialized without a termination key, it's definitely conditional
    if has_uninitialized_without_termination {
        return InitializedInFlow::Conditionally;
    }

    // If we have termination keys to check, defer to solve time
    if !termination_keys.is_empty() {
        return InitializedInFlow::DeferredCheck(termination_keys);
    }

    // All branches have values
    InitializedInFlow::Yes
}
```

Then update `FlowStyle::merged` to use this, and thread the `InitializedInFlow`
through to where names are read.

#### Threading Base Termination Key

The current code has a gap: `finish_fork_impl` sets the termination key on the
current flow, but `merge_flow` is called with the original `fork.base`. The fix
requires threading the base termination key through the call chain.

**Step 3a: Update `merge_flow` signature**

```rust
fn merge_flow(
    &mut self,
    base: Flow,
    branches: Vec<Flow>,
    range: TextRange,
    merge_style: MergeStyle,
    base_termination_key: Option<Idx<Key>>,  // NEW parameter
) {
    // ... existing setup ...

    // Count how many branches have a last_stmt_expr (potential type-based termination)
    let n_branches_with_termination_key =
        flows.iter().filter(|f| f.last_stmt_expr.is_some()).count()
        + if base_termination_key.is_some() { 1 } else { 0 };  // Include base

    // ... rest of existing code ...

    // Pass base_termination_key to merged_flow_info
    merged_flow_infos.insert_hashed(
        name,
        self.merged_flow_info(
            merge_item,
            phi_idx,
            merge_style,
            n_branches,
            n_branches_with_termination_key,
            base_termination_key,  // NEW parameter
        ),
    );
}
```

**Step 3b: Update `merged_flow_info` signature**

```rust
fn merged_flow_info(
    &mut self,
    merge_item: MergeItem,
    phi_idx: Idx<Key>,
    merge_style: MergeStyle,
    n_branches: usize,
    n_branches_with_termination_key: usize,
    base_termination_key: Option<Idx<Key>>,  // NEW parameter
) -> FlowInfo {
    // ... existing code ...

    // When adding base to branch_infos, include the termination key:
    if let Some(base_idx) = base_idx
        && base_idx != phi_idx
    {
        branch_idxs.insert(0, base_idx);
        branch_infos.insert(0, BranchInfo {
            value_key: base_idx,
            termination_key: base_termination_key,  // NOW INCLUDES TERM KEY
        });
    }
}
```

**Step 3c: Update `finish_fork_impl` to pass the key**

```rust
fn finish_fork_impl(
    &mut self,
    negated_prev_ops_if_nonexhaustive: Option<&NarrowOps>,
    is_bool_op: bool,
    base_termination_key: Option<Idx<Key>>,
) {
    // ... existing code ...

    if let Some(negated_prev_ops) = negated_prev_ops_if_nonexhaustive {
        self.scopes.current_mut().flow = fork.base.clone();
        if let Some(term_key) = base_termination_key {
            self.scopes.current_mut().flow.last_stmt_expr = Some(term_key);
        }
        self.bind_narrow_ops(...);
        // Pass base_termination_key to merge_flow
        self.merge_flow(
            fork.base,
            branches,
            fork.range,
            MergeStyle::Inclusive,
            base_termination_key,  // NEW argument
        );
    } else {
        self.merge_flow(
            fork.base,
            branches,
            fork.range,
            if is_bool_op { MergeStyle::BoolOp } else { MergeStyle::Exclusive },
            None,  // No base termination key for exhaustive forks
        );
    }
}
```

**Step 3d: Update all `merge_flow` call sites**

Add `None` as the last argument to existing `merge_flow` calls that don't have
a base termination key (loops, bool ops, etc.).

### Phase 4: Update Name Lookup

**File**: `pyrefly/lib/binding/expr.rs`

Update the name lookup handling (around line 333-350):

```rust
NameLookupResult::Found {
    idx: value,
    initialized,
} => {
    match &initialized {
        InitializedInFlow::DeferredCheck(termination_keys) => {
            // Defer error to solve time - create CheckedForward binding
            self.insert_binding(
                key,
                Binding::CheckedForward(Box::new(CheckedForwardData {
                    target: value,
                    termination_keys: termination_keys.clone(),
                    name: name.id.clone(),
                    range: name.range,
                })),
            )
        }
        _ => {
            // Existing behavior: emit error at binding time for definite cases
            if !used_in_static_type
                && !self.module_info.path().is_interface()
                && let Some(error_message) = initialized.as_error_message(&name.id)
            {
                self.error(
                    name.range,
                    ErrorInfo::Kind(ErrorKind::UnboundName),
                    error_message,
                );
            }
            self.insert_binding(key, Binding::Forward(value))
        }
    }
}
```

### Phase 5: Handle CheckedForward at Solve Time

**File**: `pyrefly/lib/alt/solve.rs`

Update `solve_binding` and `binding_to_type_info` to handle the new variant:

```rust
pub fn solve_binding(&self, binding: &Binding, errors: &ErrorCollector) -> Arc<TypeInfo> {
    // Special case for forward variants
    match binding {
        Binding::Forward(fwd) => return self.get_idx(*fwd),
        Binding::CheckedForward(data) => {
            // Check if all termination keys return Never
            let all_terminate = data.termination_keys.iter().all(|k| {
                self.get_idx(*k).ty().is_never()
            });

            // Emit error if not all termination keys terminate
            if !all_terminate && !self.module().path().is_interface() {
                self.error(
                    errors,
                    data.range,
                    ErrorInfo::Kind(ErrorKind::UnboundName),
                    format!("`{}` may be uninitialized", data.name),
                );
            }

            return self.get_idx(data.target);
        }
        _ => {}
    }

    // ... rest of existing solve_binding logic ...
}
```

Also update `binding_to_type_info`:

```rust
fn binding_to_type_info(&self, binding: &Binding, errors: &ErrorCollector) -> TypeInfo {
    match binding {
        Binding::Forward(k) => self.get_idx(*k).arc_clone(),
        Binding::CheckedForward(data) => {
            // Error already emitted in solve_binding, just forward the type
            self.get_idx(data.target).arc_clone()
        }
        // ... rest of cases ...
    }
}
```

And update `binding_to_type`:

```rust
fn binding_to_type(&self, binding: &Binding, errors: &ErrorCollector) -> Type {
    match binding {
        Binding::Forward(..)
        | Binding::CheckedForward(..)  // Add this
        | Binding::Phi(..)
        // ... rest of cases that delegate ...
```

### Phase 6: Update Pattern Matching Sites

Search for all places that match on `Binding::Forward` and add handling for
`Binding::CheckedForward`:

**Files to update**:
- `pyrefly/lib/binding/bindings.rs` - `get_original_binding`, `as_special_export_inner`
- `pyrefly/lib/state/ide.rs` - `key_to_definition_inner`, etc.
- `pyrefly/lib/alt/function.rs` - `step_pred`
- `pyrefly/lib/report/pysa/captured_variable.rs` - `get_definition_from_idx`

Most of these just need to treat `CheckedForward` like `Forward`:

```rust
Binding::Forward(k) | Binding::CheckedForward(box CheckedForwardData { target: k, .. }) => {
    // existing logic using k
}
```

## Testing Plan

### Test Case 1: Non-Exhaustive Match with Never (The Original Bug)

```python
# test_non_exhaustive_match_never.py
from typing import Literal, NoReturn

def never() -> NoReturn: ...

def test(x: Literal[1, 2, 3]) -> str:
    match x:
        case 1:
            y = "one"
        case 2:
            never()
    return y  # E: `y` may be uninitialized
```

### Test Case 2: Exhaustive Match with Never (Should Pass)

```python
# test_exhaustive_match_never.py
from typing import Literal, NoReturn

def never() -> NoReturn: ...

def test(x: Literal[1, 2]) -> str:
    match x:
        case 1:
            y = "one"
        case 2:
            never()
    return y  # OK - match is exhaustive, case 2 terminates
```

### Test Case 3: If-Else with Never (Should Pass)

```python
# test_if_else_never.py
from typing import NoReturn

def never() -> NoReturn: ...

def test(cond: bool) -> str:
    if cond:
        y = "value"
    else:
        never()
    return y  # OK - else branch terminates
```

### Test Case 4: Multiple Termination Keys, One Fails

```python
# test_multiple_termination_keys.py
from typing import Literal, NoReturn

def never() -> NoReturn: ...
def maybe_never(x: int) -> int: ...  # NOT NoReturn

def test(x: Literal[1, 2, 3]) -> str:
    match x:
        case 1:
            y = "one"
        case 2:
            never()  # Terminates
        case 3:
            maybe_never(0)  # Does NOT terminate
    return y  # E: `y` may be uninitialized
```

### Test Case 5: Branch Without Termination Key

```python
# test_branch_without_termination.py
from typing import Literal, NoReturn

def never() -> NoReturn: ...

def test(x: Literal[1, 2, 3]) -> str:
    match x:
        case 1:
            y = "one"
        case 2:
            never()
        case 3:
            pass  # No termination key, no value
    return y  # E: `y` may be uninitialized (case 3 doesn't initialize)
```

### Test Case 6: Nested Conditionals

```python
# test_nested_conditionals.py
from typing import Literal, NoReturn

def never() -> NoReturn: ...

def test(x: Literal[1, 2], flag: bool) -> str:
    if flag:
        match x:
            case 1:
                y = "one"
            case 2:
                never()
    else:
        y = "default"
    return y  # OK - all paths initialize y or terminate
```

### Test Case 7: Non-Exhaustive Match Without Never (Pure MatchExhaustive)

This tests the base flow termination key specifically, without any Never-returning
function calls. The `MatchExhaustive` binding tracks whether unhandled cases exist.

```python
# test_non_exhaustive_match_pure.py
from typing import Literal

def test(x: Literal[1, 2, 3]) -> str:
    match x:  # Not exhaustive (missing case 3)
        case 1:
            y = "one"
        case 2:
            y = "two"
    return y  # E: `y` may be uninitialized (case 3 not handled)
```

### Test Case 8: Exhaustive Match (Pure MatchExhaustive, No Never)

```python
# test_exhaustive_match_pure.py
from typing import Literal

def test(x: Literal[1, 2]) -> str:
    match x:  # Exhaustive
        case 1:
            y = "one"
        case 2:
            y = "two"
    return y  # OK - all cases initialize y
```

### Test Case 9: Existing Behavior Preserved

```python
# test_existing_behavior.py
def test_definitely_uninitialized() -> int:
    if True:
        pass
    return x  # E: Could not find name `x` (existing behavior)

def test_conditionally_uninitialized(cond: bool) -> int:
    if cond:
        x = 1
    return x  # E: `x` may be uninitialized (existing behavior)

def test_definitely_initialized(cond: bool) -> int:
    if cond:
        x = 1
    else:
        x = 2
    return x  # OK (existing behavior)
```

## Migration Strategy

### Step 0: Add Failing Test First

Per project guidelines, add a test case that demonstrates the bug before fixing it:

```rust
testcase!(
    bug = "Non-exhaustive match with Never-returning call incorrectly assumes initialization",
    test_non_exhaustive_match_with_never,
    r#"
from typing import Literal, NoReturn

def never() -> NoReturn: ...

def test(x: Literal[1, 2, 3]) -> str:
    match x:
        case 1:
            y = "one"
        case 2:
            never()
    return y  # Should error but doesn't
"#,
    [],  // Current behavior: no error (this is the bug)
);
```

The test should pass initially (showing the bug exists). After the fix, update it
to expect the error and remove the `bug` marker.

### Step 1: Add Data Structures (No Behavior Change)

1. Add `DeferredCheck` variant to `InitializedInFlow`
2. Add `CheckedForward` variant to `Binding`
3. Add `CheckedForwardData` struct
4. Update pattern matches to handle new variants (treat as Forward)
5. Run `./test.py --no-test --no-conformance` for formatting/linting
6. Run tests - expect no behavior changes

### Step 2: Wire Up Flow Merging

1. Implement `compute_initialization_state` helper
2. Update `merged_flow_info` to use it
3. Ensure base flow termination key is threaded through
4. Run tests - still expect no behavior changes (CheckedForward not created yet)

### Step 3: Create CheckedForward Bindings

1. Update `expr.rs` name lookup to create `CheckedForward` for `DeferredCheck` cases
2. Run tests - errors now deferred but not yet emitted at solve time

### Step 4: Add Solve-Time Error Emission

1. Update `solve_binding` to emit errors for `CheckedForward`
2. Run tests - expect the false negative test cases to now report errors

### Step 5: Final Testing and Cleanup

1. Run full test suite: `./test.py`
2. Verify no regressions in existing tests
3. Verify IDE features still work (go-to-definition, find-references)

## Risks and Mitigations

### Risk: Size Constraint Violation

**Issue**: `assert_words!(Binding, 11)` may fail with the new variant.

**Mitigation**: Box the `CheckedForwardData` payload to keep the variant small.
If still too large, consider using an index into a separate storage.

### Risk: Performance

**Issue**: `SmallVec` allocation and solve-time iteration.

**Mitigation**:
- `SmallVec<[Idx<Key>; 2]>` is stack-allocated for ≤2 keys (common case)
- Boxing keeps the common `Forward` path unaffected
- Solve-time check is O(n) where n is typically 1-3

### Risk: Missed Pattern Match Sites

**Issue**: Forgetting to handle `CheckedForward` somewhere.

**Mitigation**: Add `#[non_exhaustive]` consideration. Use `Binding::Forward(..) | Binding::CheckedForward(..)` pattern consistently. The compiler will catch most missing cases.

### Risk: Duplicate Errors

**Issue**: Both binding and solve time could emit errors.

**Mitigation**: `DeferredCheck` cases skip binding-time errors entirely. Only `CheckedForward` emits at solve time.

## File Changes Summary

| File | Changes |
|------|---------|
| `pyrefly/lib/binding/bindings.rs` | Add `DeferredCheck` variant to `InitializedInFlow` |
| `pyrefly/lib/binding/binding.rs` | Add `CheckedForward` variant, `CheckedForwardData` struct, and `DisplayWith` impl |
| `pyrefly/lib/binding/scope.rs` | Add `compute_initialization_state`, update `merge_flow` and `merged_flow_info` |
| `pyrefly/lib/binding/expr.rs` | Create `CheckedForward` for `DeferredCheck` cases |
| `pyrefly/lib/alt/solve.rs` | Handle `CheckedForward` in `solve_binding` and `binding_to_type_info` |
| `pyrefly/lib/state/ide.rs` | Add `CheckedForward` to pattern matches |
| `pyrefly/lib/alt/function.rs` | Add `CheckedForward` to pattern matches |
| `pyrefly/lib/report/pysa/captured_variable.rs` | Add `CheckedForward` to pattern matches |
| `pyrefly/lib/test/flow_branching.rs` | Add test cases |

## Scope Clarifications

### Loop Handling

This proposal **does not change** the behavior of `MergeStyle::Loop` or
`MergeStyle::LoopDefinitelyRuns`. Loop initialization has additional complexity
(e.g., the loop body may not execute, variables may be modified across iterations)
that is out of scope for this fix.

The fix applies to:
- `MergeStyle::Exclusive` (exhaustive if/match)
- `MergeStyle::Inclusive` (non-exhaustive if/match)
- `MergeStyle::BoolOp` (boolean short-circuit)

When passing `base_termination_key` to `merge_flow`, use `None` for loop merges.

### DeferredCheck and Incremental Analysis

`DeferredCheck` is resolved at solve time and does not need to be serializable.
It is not exported - the resolved `Yes` or `Conditionally` state is what matters
for downstream modules.

### Error Deduplication

This proposal preserves existing behavior: each read of an uninitialized variable
generates a separate error. This is consistent with how Pyrefly handles other errors
and is not a regression. Future work could add deduplication if desired.

## Implementation Notes

### DisplayWith Implementation for CheckedForwardData

Add a `DisplayWith<Bindings>` impl following existing patterns in `binding.rs`:

```rust
impl DisplayWith<Bindings> for CheckedForwardData {
    fn fmt(&self, f: &mut fmt::Formatter<'_>, ctx: &Bindings) -> fmt::Result {
        write!(
            f,
            "CheckedForward({}, {}, {:?})",
            ctx.display(self.target),
            self.name,
            self.termination_keys.iter().map(|k| ctx.display(*k)).collect::<Vec<_>>()
        )
    }
}
```

### Identifying Existing Tests

Before implementation, run:
```bash
buck test pyrefly:pyrefly_library -- flow
buck test pyrefly:pyrefly_library -- initialization
buck test pyrefly:pyrefly_library -- unbound
```

This helps identify existing tests that cover initialization checking and should
continue to pass after the changes.

## Future Work

- **LoopPhi handling**: Loop initialization has additional complexity with
  `MergeStyle::Loop` and `MergeStyle::LoopDefinitelyRuns`. This proposal
  focuses on branch/match cases.

- **Unify initialization checking at solve time**: This proposal keeps
  binding-time errors for the common case. A future refactor could move all
  initialization checking to solve time for consistency.

- **Error deduplication**: Currently, each read of an uninitialized variable
  generates an error. Could add deduplication to show only the first occurrence.
