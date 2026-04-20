# Callable Residual Examples (v1)

Purpose: executable v1 example set for implementation and tests.

All examples are intended to map directly to unit tests (with `bug = "..."` markers where behavior is not yet fixed).

## 1) Generic Implementation + Shared Residual Handling (no overload dependency)

### 1.1 Generic re-promotion through callable return
Intended test name: `test_v1_generic_repromotion_callable_return`

```python
from typing import Callable, reveal_type

def ho[A, R](f: Callable[[A], R]) -> Callable[[A], R]: ...
def id[T](x: T) -> T: ...

r = ho(id)
reveal_type(r)
```

Expected direction:
- preserve callable polymorphism
- do not degrade to `(Unknown) -> Unknown`

### 1.2 ParamSpec wrap generic return (recursive finalization)
Intended test name: `test_v1_paramspec_wrap_generic_return_recursive_finalization`

```python
from typing import Callable, Awaitable, reveal_type

def wrap[**P, T](f: Callable[P, T]) -> Callable[P, Awaitable[T]]: ...
def identity_fn[X](x: X) -> X: ...

result = wrap(identity_fn)
reveal_type(result)
```

Expected direction:
- preserve `Awaitable[T]` shape
- do not degrade nested residuals to `Awaitable[Unknown]`

### 1.3 Callable vs non-callable split behavior
Intended test name: `test_v1_callable_vs_noncallable_split_behavior`

```python
from typing import Callable, Optional, reveal_type

def ho[T](f: Callable[[T], T]) -> tuple[Callable[[T], T], Optional[T]]: ...
def id[U](x: U) -> U: ...

fn, maybe_v = ho(id)
reveal_type(fn)
reveal_type(maybe_v)
```

Expected direction:
- callable occurrence can preserve/promote polymorphic callable behavior
- non-callable occurrence uses normal default/fallback behavior

### 1.4 Required-concrete non-callable position
Intended test name: `test_v1_required_concrete_noncallable_position`

```python
from typing import Callable

def make_value[A, R](f: Callable[[A], R]) -> R: ...
def id[T](x: T) -> T: ...

x = make_value(id)
```

Expected direction:
- no deferred callable residual survives in required-concrete positions

### 1.5 Class TArgs defer + field lookup finalization
Intended test name: `test_v1_class_targs_defer_then_field_lookup_finalize`

```python
from typing import Callable, reveal_type

class Box[T]:
    value: T

def make_box[A, R](f: Callable[[A], R]) -> Box[R]: ...
def id[T](x: T) -> T: ...

b = make_box(id)
reveal_type(b)
reveal_type(b.value)
```

Expected direction:
- class targs may temporarily carry deferred form internally
- field lookup boundary finalizes/eliminates deferred form

### 1.6 Polarity flip under contravariance
Intended test name: `test_v1_polarity_flip_under_contravariance`

```python
from typing import Callable

def ho[A](f: Callable[[Callable[[A], None]], None]) -> Callable[[A], None]: ...
def consume_int(cb: Callable[[int], None]) -> None: ...

r = ho(consume_int)
```

Expected direction:
- residual trigger logic respects recursive polarity flips

### 1.7 Bound method callable value normalization
Intended test name: `test_v1_bound_method_callable_normalization`

```python
from typing import Callable, reveal_type

class Box[T]:
    def id(self, x: T) -> T: ...

def ho[A, R](f: Callable[[A], R]) -> Callable[[A], R]: ...

b: Box[int]
g = ho(b.id)
reveal_type(g)
```

Expected direction:
- bound-receiver semantics preserved
- no explicit `self` reintroduced

### 1.8 Callback protocol callable value normalization
Intended test name: `test_v1_callback_protocol_callable_normalization`

```python
from typing import Callable, Protocol, reveal_type

class Callback[T](Protocol):
    def __call__(self, x: T) -> T: ...

def ho[A, R](f: Callable[[A], R]) -> Callable[[A], R]: ...

cb: Callback[int]
g = ho(cb)
reveal_type(g)
```

Expected direction:
- protocol `__call__` extraction composes with residual handling

### 1.9 Non-target alias flattening (visibility gating)
Intended test name: `test_v1_non_target_alias_flattening_visibility_gating`

```python
from typing import Callable

def ho[S, T](f: Callable[[S], T], x: T) -> Callable[[S], T]: ...
def id[U](x: U) -> U: ...

def leak_candidate():
    p = []
    p.append(1)
    g = ho(id, p[0])
    return g, p
```

Expected direction:
- if solver aliasing ties unrelated vars to a residual-bearing root, only target vars observe residual payload
- non-target reads flatten via gating (no sanitize dependence)

### 1.10 Coalesced legitimate targets remain visible
Intended test name: `test_v1_coalesced_legitimate_targets_remain_visible`

```python
from typing import Callable, reveal_type

def pair_ho[S, T](f: Callable[[S], T], g: Callable[[T], S]) -> tuple[Callable[[S], T], Callable[[T], S]]: ...
def id[U](x: U) -> U: ...

f1, f2 = pair_ho(id, id)
reveal_type(f1)
reveal_type(f2)
```

Expected direction:
- if legitimate call-scoped targets coalesce under UF, both target vars keep residual visibility
- no asymmetric flattening between legitimate targets

## 2) Overload Implementation

### 2.1 Issue #2105 minimal shape (no branch collapse)
Intended test name: `test_v1_overload_issue_2105_minimal_no_branch_collapse`

```python
from typing import Protocol, overload, Callable

class Foo(Protocol):
    @overload
    def __call__(self, x: bool, y: int | None) -> None: ...
    @overload
    def __call__(self, x: bool = False) -> None: ...

def higher_order[**P, T](callback: Callable[P, T], /, *args: P.args, **kwds: P.kwargs) -> Callable[P, T]: ...

def test(rmtree: Foo) -> None:
    higher_order(rmtree, y=1)
```

Expected direction:
- overload structure preserved through higher-order matching
- no existential first-live-branch commit

### 2.2 Pruning by solved bounds: zero survivors + delayed deduped diagnostic
Intended test name: `test_v1_overload_zero_survivors_delayed_deduped_diagnostic`

```python
from typing import Callable, overload

def ho[S, T](f: Callable[[S, T], tuple[S, T]], t: T) -> Callable[[S, T], tuple[S, T]]: ...

@overload
def f(x: int, y: int) -> tuple[int, int]: ...
@overload
def f(x: str, y: str) -> tuple[str, str]: ...
def f(x, y): ...

r = ho(f, 3.14)
```

Expected direction:
- branch set becomes empty after pruning
- one delayed incompatibility diagnostic per `(call_site_id, witness_id)`
- participating vars continue via quantified defaulting

### 2.3 Pruning by solved bounds: one survivor collapse
Intended test name: `test_v1_overload_one_survivor_collapse`

```python
from typing import Callable, overload

def ho[S, T](f: Callable[[S, T], S], t: T) -> Callable[[S, T], S]: ...

@overload
def f(x: int, y: int) -> int: ...
@overload
def f(x: str, y: str) -> str: ...
def f(x, y): ...

r = ho(f, 1)
```

Expected direction:
- solved constraints prune to one arm
- correlated vars collapse to concrete answers

### 2.4 Pruning by solved bounds: multiple survivors retained
Intended test name: `test_v1_overload_multiple_survivors_retained`

```python
from typing import Callable, overload

def ho[S, T](f: Callable[[S, T], S], t: T) -> Callable[[S, T], S]: ...

@overload
def f(x: int, y: int) -> int: ...
@overload
def f(x: bool, y: int) -> bool: ...
@overload
def f(x: str, y: str) -> str: ...
def f(x, y): ...

r = ho(f, 1)
```

Expected direction:
- keep compatible unresolved arms
- do not over-prune to a single branch

### 2.5 Probe-time unsatisfiable arm dropped
Intended test name: `test_v1_overload_probe_time_unsatisfiable_arm_dropped`

```python
from typing import Callable, overload, reveal_type

def higher_order[T](f: Callable[[int, T], T]) -> Callable[[T], T]: ...

@overload
def ov(x: int, y: str) -> float: ...
@overload
def ov(x: int, y: float) -> str: ...
@overload
def ov(x: bool, y: bool) -> bool: ...
def ov(x, y): ...

r = higher_order(ov)
reveal_type(r)
```

Expected direction:
- ineligible probe arm removed before witness payload is finalized

### 2.6 Probe-time all arms ineligible
Intended test name: `test_v1_overload_probe_time_all_arms_ineligible`

```python
from typing import Callable, overload, reveal_type

def higher_order[T](f: Callable[[int, T], T]) -> T: ...

@overload
def bad(x: str, y: str) -> str: ...
@overload
def bad(x: bool, y: bool) -> bool: ...
def bad(x, y): ...

r = higher_order(bad)
reveal_type(r)
```

Expected direction:
- immediate inconsistent witness
- delayed incompatibility diagnostic
- quantified-default continuation

### 2.7 Overload with generic branch
Intended test name: `test_v1_overload_with_generic_branch`

```python
from typing import Callable, overload, reveal_type

def ho[S, T](f: Callable[[S], T]) -> Callable[[S], T]: ...

@overload
def mix(x: int) -> int: ...
@overload
def mix[U](x: U) -> tuple[U, U]: ...
def mix(x): ...

r = ho(mix)
reveal_type(r)
```

Expected direction:
- overload and generic residual logic compose in one witness

### 2.8 Nested overload witness (overload inside overload)
Intended test name: `test_v1_nested_overload_witness`

```python
from typing import Callable, Protocol, overload, reveal_type

class InnerInt(Protocol):
    @overload
    def __call__(self, x: int) -> int: ...
    @overload
    def __call__(self, x: bool) -> bool: ...

class InnerStr(Protocol):
    @overload
    def __call__(self, x: str) -> str: ...
    @overload
    def __call__(self, x: bytes) -> bytes: ...

@overload
def outer(x: int) -> InnerInt: ...
@overload
def outer(x: str) -> InnerStr: ...
def outer(x):
    raise NotImplementedError

def ho[S, T](f: Callable[[S], Callable[[T], T]]) -> Callable[[S], Callable[[T], T]]: ...

g = ho(outer)
reveal_type(g)
```

Expected direction:
- deterministic nested-branch handling
- callable-level expansion recurses correctly

### 2.9 Bound overloaded method as callable value
Intended test name: `test_v1_bound_overloaded_method_callable_value`

```python
from typing import Callable, overload, reveal_type

class C:
    @overload
    def m(self, x: int) -> int: ...
    @overload
    def m(self, x: str) -> str: ...
    def m(self, x): ...

def ho[A, R](f: Callable[[A], R]) -> Callable[[A], R]: ...

c = C()
g = ho(c.m)
reveal_type(g)
```

Expected direction:
- bound receiver stripping and overload preservation compose

### 2.10 Deterministic delayed-diagnostic ordering
Intended test name: `test_v1_overload_deterministic_delayed_diagnostic_ordering`

```python
from typing import Callable, overload

def ho[S, T](f: Callable[[S, T], S], t: T) -> Callable[[S, T], S]: ...

@overload
def f(x: int, y: int) -> int: ...
@overload
def f(x: bool, y: int) -> bool: ...
@overload
def f(x: str, y: str) -> str: ...
def f(x, y): ...

_ = ho(f, 3.14)
```

Expected direction:
- stable traversal/pruning order
- deterministic delayed-diagnostic ordering

### 2.11 Cross-witness merge must not silently coalesce
Intended test name: `test_v1_overload_cross_witness_merge_no_silent_coalesce`

```python
from typing import Callable, overload

def combine[A, B, R](f: Callable[[A], R], g: Callable[[B], R]) -> Callable[[A, B], R]: ...

@overload
def f(x: int) -> int: ...
@overload
def f(x: str) -> str: ...
def f(x): ...

@overload
def g(x: bytes) -> bytes: ...
@overload
def g(x: bool) -> bool: ...
def g(x): ...

r = combine(f, g)
```

Expected direction:
- no silent cross-witness residual mixing
- v1 may use coarse fallback for precision loss cases, but behavior must be deterministic

### 2.12 ParamSpec argument-selected narrowing (deferred follow-up)
Intended test name: `test_v1_followup_paramspec_argument_selected_narrowing`

```python
from typing import Callable, overload

def use_paramspec[**P, R](f: Callable[P, R]) -> Callable[P, R]: ...

@overload
def f(x: int, y: int) -> int: ...
@overload
def f(x: int) -> str: ...
def f(*args): ...

r = use_paramspec(f)
```

Status:
- deferred follow-up (not required for v1 baseline)
