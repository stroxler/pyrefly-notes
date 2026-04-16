# Residual Examples Catalog

Purpose: collect a superset of examples for callable-residual design validation.

Legend:
- `source: v1-doc` means copied from `callable_witness_projection_design_v1.md`.
- `source: prototype-test` means copied from stale prototype test commits
  (`814f933cfe`, `afa896072a`, `678b0d8b8b`, `b9b12ae58f`, `bcd2e7eeec`, `030a8ff215`).
- `source: new-edge-candidate` means newly proposed coverage.

Phase-gating note:
- several examples below describe target behavior for residual machinery that is
  intentionally not fully implemented on trunk yet; these remain design/paper
  examples until corresponding phases land.

## 0) Trunk-Correct Baselines (pre-residual implementation)

### 0.1 Illegal bare `P.args` return annotation
`source: new-edge-candidate`

```python
from typing import Callable, overload, reveal_type

# Bare `P.args` as a return annotation is syntactically/semantically invalid.
def ho[**P, R](f: Callable[P, R]) -> P.args: ...

@overload
def f(x: int) -> str: ...
@overload
def f(x: str) -> int: ...
def f(x): ...

args = ho(f)
reveal_type(args)
```

Expected on trunk (already correct):
- emit invalid-annotation error for bare `P.args` return annotation
- continue by degrading resulting type to gradual unknown (`Unknown`/`Any`,
  depending on surface naming in diagnostics)
- this is intentionally not a callable-residual semantics test; add as a
  regression before residual implementation.

## 1) v1 Design Doc Examples

### 1.1 Overload preservation (issue #2105 shape)
`source: v1-doc`

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

Expected: passing an overloaded callable preserves overload structure instead of committing to one branch.

### 1.2 Quantified projection remains valid
`source: v1-doc`

```python
def wrap[**P, T](f: Callable[P, T]) -> Callable[P, Awaitable[T]]: ...
def identity[X](x: X) -> X: ...
```

Expected:

```text
wrap(identity): forall Y. [(Y) -> Awaitable[Y]]
```

### 1.3 Degeneracy after Concatenate stripping
`source: v1-doc`

```python
def strip_first[**P, T](
    f: Callable[Concatenate[Any, P], T]
) -> Callable[P, T]: ...
```

Applied to `forall Y. [(Y, int) -> Y]`:

```text
forall Y. [(int) -> Y]
```

Expected:
- emit transform-induced degeneracy diagnostic (`Y` no longer inferable from
  params)
- continuation uses fallback/defaulting per boundary policy (do not require the
  preserved `forall` surface form in v0)

### 1.4 Non-ParamSpec callable coupling
`source: v1-doc`

```python
def add_prefix[A, R](f: Callable[[A], R]) -> Callable[[int, A], R]: ...
def id[T](x: T) -> T: ...
```

Expected: `A` and `R` remain coupled through one witness.

Status:
- policy-sensitive in v0: exact surface form for this coupling may vary until
  generic re-promotion mechanics are finalized.

### 1.5 TypeVarTuple projection
`source: v1-doc`

```python
def unpack_first[T, *Ts](
    f: Callable[[T, *Ts], T]
) -> Callable[[*Ts], T]: ...

@overload
def parse(mode: str, raw: bytes) -> str: ...
@overload
def parse(mode: str) -> str: ...
```

Expected:

```text
Overload(Callable[[bytes], str], Callable[[], str])
```

Status:
- phase-gated for v0: TypeVarTuple + overload projection precision may
  temporarily fall back/default until corresponding tactical tracks land.

### 1.6 Multi-witness overlap (deferred)
`source: v1-doc`

```python
f = Overload(Callable[[int], int], Callable[[str], str])
g = Overload(Callable[[int], int], Callable[[bytes], bytes])
def h[**P, R](f: Callable[P, R], g: Callable[P, R]) -> R: ...
```

Expected for this phase: fallback (no witness intersection).

Status:
- fallback shape is intentionally coarse in v0 (`Any` via
  `fallback_for_residuals(...)`); richer witness-intersection behavior is
  follow-up.

### 1.7 Pinned witness degeneracy
`source: v1-doc`

```python
def takes_s(f: Callable[[S, int], S]) -> Callable[[S, int], S]: ...
def poly[T](x: T, y: T) -> T: ...
```

Expected when checking `takes_s(poly)`: `Callable[[int, int], int]`.

### 1.8 Baseline higher-order identity shape
`source: v1-doc`

```python
def higher_order[T](f: Callable[[T], T]) -> Callable[[T], T]:
    return f
```

Context: canonical motivating shape where solving `T` to a single concrete type is insufficient for overload/generic preservation.

### 1.9 Existing instantiate-first forall behavior
`source: v1-doc`

```python
def f[T]() -> Callable[[T], T]: ...
g = f()  # reveals as a forall callable shape
```

Context: design must remain compatible with existing instantiate-first + re-quantify behavior.

### 1.10 Class witness carrier shape
`source: v1-doc`

```text
MyDecorator(some_callable) -> MyDecorator[Projected(w, P), Projected(w, T)]
```

Context: projections/residuals may live in class targs internally and are interpreted at member lookup/finalization boundaries.

## 2) Prototype Stack Tests (stale, unlanded)

### 2.1 ParamSpec + generic function identity
`source: prototype-test` (`test_param_spec_generic_function`)

```python
from typing import Callable, reveal_type
def identity[**P, R](x: Callable[P, R]) -> Callable[P, R]:
    return x
def foo[T](x: T, y: T) -> T:
    return x
foo2 = identity(foo)
reveal_type(foo2)  # revealed type in stale test: (x: Unknown, y: Unknown) -> Unknown
```

### 2.2 ParamSpec + generic constructor identity
`source: prototype-test` (`test_param_spec_generic_constructor`)

```python
from typing import Callable, reveal_type
def identity[**P, R](x: Callable[P, R]) -> Callable[P, R]:
  return x
class C[T]:
  x: T
  def __init__(self, x: T) -> None:
    self.x = x
c2 = identity(C)
reveal_type(c2)  # revealed type in stale test: (x: Unknown) -> C[Unknown]
x: C[int] = c2(1)
```

### 2.3 No internal projection leak (concrete callable)
`source: prototype-test` (`test_no_projection_leak_in_reveal_type`)

```python
from typing import Callable, reveal_type
def identity[**P, R](x: Callable[P, R]) -> Callable[P, R]:
    return x
def foo(x: int) -> str:
    return str(x)
result = identity(foo)
reveal_type(result)  # expected concrete: (x: int) -> str
```

### 2.4 No internal projection leak (generic callable)
`source: prototype-test` (`test_no_projection_leak_generic`)

```python
from typing import Callable, reveal_type
def identity[**P, R](x: Callable[P, R]) -> Callable[P, R]:
    return x
def generic_fn[T](x: T) -> T:
    return x
result = identity(generic_fn)
reveal_type(result)  # stale behavior: (x: Unknown) -> Unknown; key invariant is no internal projection text
```

### 2.5 ParamSpec identity on overloaded callable
`source: prototype-test` (`test_paramspec_identity_overloaded`)

```python
from typing import Callable, overload, reveal_type
def identity[**P, R](x: Callable[P, R]) -> Callable[P, R]:
    return x

@overload
def f(x: int) -> str: ...
@overload
def f(x: str) -> int: ...
def f(x): ...

result = identity(f)
reveal_type(result)  # stale behavior in test: first overload branch only
```

### 2.6 ParamSpec wrap generic return
`source: prototype-test` (`test_paramspec_wrap_generic_return`)

```python
from typing import Callable, Awaitable, reveal_type
def wrap[**P, T](f: Callable[P, T]) -> Callable[P, Awaitable[T]]: ...
def identity_fn[X](x: X) -> X: ...

result = wrap(identity_fn)
reveal_type(result)  # stale behavior: (x: Unknown) -> Awaitable[Unknown]
```

### 2.7 Non-ParamSpec identity with generic callable
`source: prototype-test` (`test_non_paramspec_identity_generic`)

```python
from typing import Callable, reveal_type
def simple_identity[A, R](f: Callable[[A], R]) -> Callable[[A], R]:
    return f
def generic_fn[T](x: T) -> T: ...
result = simple_identity(generic_fn)
reveal_type(result)  # stale behavior: (Unknown) -> Unknown
```

### 2.8 ParamSpec transform on overloaded callable
`source: prototype-test` (`test_paramspec_transform_overloaded`)

```python
from typing import Callable, overload, reveal_type
def transform[**P, T](f: Callable[P, T]) -> Callable[P, T]: ...

@overload
def multi(x: int, y: str) -> bool: ...
@overload
def multi(x: str) -> int: ...
def multi(*args, **kwargs): ...

result = transform(multi)
reveal_type(result)  # stale behavior in test: first overload branch only
```

### 2.9 Add-prefix transform on generic callable
`source: prototype-test` (`test_add_prefix_generic`)

```python
from typing import Callable, reveal_type
def add_prefix[A, R](f: Callable[[A], R]) -> Callable[[int, A], R]: ...
def identity_fn[T](x: T) -> T: ...
result = add_prefix(identity_fn)
reveal_type(result)  # stale behavior: (int, Unknown) -> Unknown
```

### 2.10 Concatenate strip-first sanity
`source: prototype-test` (`test_concatenate_strip_first`)

```python
from typing import Callable, Concatenate, Any, reveal_type
def strip_first[**P, T](
    f: Callable[Concatenate[Any, P], T]
) -> Callable[P, T]: ...
def two_arg(x: int, y: str) -> bool: ...
result = strip_first(two_arg)
reveal_type(result)  # expected concrete: (y: str) -> bool
```

### 2.11 Callable class wrapper
`source: prototype-test` (`test_callable_class_wrapper`)

```python
from typing import Callable, reveal_type

class Wrapper[**P, R]:
    fn: Callable[P, R]
    def __init__(self, fn: Callable[P, R]) -> None:
        self.fn = fn
    def __call__(self, *args: P.args, **kwargs: P.kwargs) -> R:
        return self.fn(*args, **kwargs)

def wrap[**P, R](f: Callable[P, R]) -> Wrapper[P, R]:
    return Wrapper(f)

def simple(x: int) -> str: ...
result = wrap(simple)
reveal_type(result)   # expected concrete wrapper paramization
result2 = result(1)
reveal_type(result2)  # expected: str
```

### 2.12 Class-field lookup through projected tparams
`source: prototype-test` (`test_class_field_projected_tparams`)

```python
from typing import Callable, reveal_type

class Container[**P, R]:
    fn: Callable[P, R]
    result: R
    def __init__(self, fn: Callable[P, R]) -> None:
        self.fn = fn

def make_container[**P, R](f: Callable[P, R]) -> Container[P, R]: ...
def simple(x: int) -> str: ...
c = make_container(simple)
reveal_type(c.fn)      # expected: (x: int) -> str
reveal_type(c.result)  # expected: str
```

### 2.13 Issue #2105 minimal repro
`source: prototype-test` (`test_issue_2105_minimal`)

```python
from typing import Protocol, overload, Callable

class Foo(Protocol):
    @overload
    def __call__(
        self,
        x: bool,
        y: int | None
    ) -> None: ...
    @overload
    def __call__(
        self,
        x: bool = False,
    ) -> None: ...

def higher_order[**P, T](callback: Callable[P, T], /, *args: P.args, **kwds: P.kwargs) -> Callable[P, T]: ...

def test(rmtree: Foo) -> None:
    higher_order(rmtree, y=1)  # stale behavior: error due to branch collapse
```

### 2.14 Issue #2105 original repro
`source: prototype-test` (`test_issue_2105_original`)

```python
import shutil
from contextlib import ExitStack

def foo(tmpdir):
    with ExitStack() as resources:
        resources.callback(shutil.rmtree, tmpdir, ignore_errors=True)  # stale behavior: overload-branch mismatch

def bar(tmpdir):
    shutil.rmtree(tmpdir, ignore_errors=True)
```

## 3) Additional Edge-Case Candidates (new)

### 3.1 Overload pruning by solved bounds: zero survivors (incompatible)
`source: new-edge-candidate`

```python
from typing import Callable, overload

def ho[S, T](f: Callable[[S, T], S], t: T) -> Callable[[S, T], S]: ...

@overload
def f(x: int, y: int) -> int: ...
@overload
def f(x: str, y: str) -> str: ...
def f(x, y): ...

r = ho(f, 3.14)
```

Target coverage: `T` is solved from normal bounds (`T=float`), pruning all overload branches and creating a delayed incompatibility error at witness origin.

Resolution note: design now specifies post-error residual handling for this case.
After delayed incompatibility is detected, solve all remaining residual vars to
their quantified defaults (often gradual, but may be a declared typevar
default), rather than using generic fallback on partially pruned residuals.

### 3.2 Overload pruning by solved bounds: one survivor (collapse)
`source: new-edge-candidate`

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

Target coverage: `T` is solved from non-residual bounds (`T=int`), pruning to one branch and collapsing correlated residuals for other vars (`S`) to concrete branch answers.

### 3.3 Overload pruning by solved bounds: multiple survivors remain
`source: new-edge-candidate`

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

Target coverage: solving `T=int` prunes the `str` branch but leaves at least two active branches (`int/int`, `bool/int`), so unresolved correlated vars should still materialize overload residuals (not collapse).

### 3.3b Overload probe-time unsatisfiable arm is dropped before witness capture
`source: new-edge-candidate`

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
- probe branch `(bool, bool) -> bool` is unsatisfiable against pattern
  `Callable[[int, T], T]` and must be excluded from `OverloadProjections`
  at probe time
- residual transform should therefore produce only:
  `Overload(Callable[[str], float], Callable[[float], str])`

Target coverage:
- explicit distinction between probe-time branch admissibility and finish-time
  branch pruning against solved concrete bounds
- protects against incorrectly retaining unsatisfiable probe arms in witness
  payloads, which would otherwise leak spurious overload branches.

### 3.3c Overload probe-time all-arms-ineligible forces quantified defaulting
`source: new-edge-candidate`

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
- both overload arms are probe-time ineligible against `Callable[[int, T], T]`
- witness is treated as immediately inconsistent (probe-empty)
- delayed incompatibility diagnostic is emitted at witness origin
- participating unresolved vars are forced through quantified defaulting at
  finish (no overload residual materialization; no `PartialQuantified` leak).

Target coverage:
- parity between probe-empty inconsistency and finish-time empty-after-pruning
  inconsistency behavior
- ensures deterministic continuation semantics when no branch is admissible.

### 3.4 Multiple residual candidates for one var (fallback path)
`source: new-edge-candidate`

```python
from typing import Callable, overload

def pick[**P, R](f: Callable[P, R], g: Callable[P, R]) -> Callable[P, R]: ...

@overload
def a(x: int) -> int: ...
@overload
def a(x: str) -> str: ...
def a(x): ...

@overload
def b(x: bytes) -> bytes: ...
@overload
def b(x: bool) -> bool: ...
def b(x): ...

result = pick(a, b)
```

Target coverage:
- both inputs are residual-producing callable values
- verifies `fallback_for_residuals(...)` for multiple distinct residual
  candidates on one var.

### 3.5 Generic residual re-promotion in return callable
`source: new-edge-candidate`

```python
from typing import Callable, reveal_type

def ho[A, R](f: Callable[[A], R]) -> Callable[[A], R]: ...
def id[T](x: T) -> T: ...

r = ho(id)
reveal_type(r)
```

Target coverage: unresolved generic vars become residual-then-forall rather than partial/Unknown.

### 3.6 Generic inside overload branch (composition)
`source: new-edge-candidate`

```python
from typing import Callable, overload, reveal_type

def wrap[**P, T](f: Callable[P, T]) -> Callable[P, T]: ...

@overload
def f(x: int) -> int: ...
@overload
def f[T](x: T) -> T: ...
def f(x): ...

r = wrap(f)
reveal_type(r)
```

Target coverage: nested generic markers inside overload branch projection/finalization.

### 3.7 Overload with a generic branch
`source: new-edge-candidate`

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

Target coverage: one overload witness contains a concrete branch plus a generic
branch; verifies branch-local generic residual capture and finalization are
composable inside one overload projection payload.

### 3.8 Residual elimination in non-callable required-concrete position
`source: new-edge-candidate`

```python
from typing import Callable

def make_value[A, R](f: Callable[[A], R]) -> R: ...
def id[T](x: T) -> T: ...

x = make_value(id)
```

Target coverage: required-concrete fallback/diagnostic outside callable-legal positions.

### 3.9 Class TArgs allowed internally, resolved at member lookup
`source: new-edge-candidate`

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

Target coverage: internal allowance in class targs and forced resolution on field lookup.

### 3.10 Cross-witness residuals in one callable output (coherence fallback)
`source: new-edge-candidate`

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

Target coverage:
- concrete call site that introduces incompatible overload witness identities in
  one transform path
- fallback should win over incoherent witness mixing.

Status:
- v0 expected result for `R` is `Any` via `fallback_for_residuals(...)` because
  multiple distinct residual candidates remain.
- follow-up candidate policy: overload-aware union-like fallback (for this
  concrete case, `int | str | bytes | bool`) may preserve more precision.

### 3.11 (moved) Illegal bare `P.args` return annotation
Moved to **0.1** because this is an already-correct trunk baseline and not
residual-specific behavior.

### 3.12 No-leak sanitization on out-of-scope vars
`source: new-edge-candidate`

```python
# Shape-only sketch: higher-order call creates residuals in call scope while
# another linked var outside quantified handle is mutated through union-find.
# Assert final reveals/errors do not surface internal residual artifacts.
```

Target coverage: call-end sanitization of residual leaks outside allowed scope.

### 3.13 Auto-promotion split across callable vs non-callable outputs
`source: new-edge-candidate`

```python
from typing import Callable, Optional, reveal_type

def ho[T](f: Callable[[T], T]) -> tuple[Callable[[T], T], Optional[T]]: ...
def id[U](x: U) -> U: ...

fn, maybe_v = ho(id)
reveal_type(fn)
reveal_type(maybe_v)
```

Target coverage: when `T` participates in value-side generic matching,
auto-promotion can preserve callable genericity while degrading non-callable
positions.

Expected direction under current design:
- callable component promotes (`forall`-like callable result)
- non-callable `Optional[T]` side falls back/defaults (typically `Optional[Unknown]`)

Semantics note:
- this may look worse than trunk partial-type linkage (single partial `T` shared
  across both tuple components)
- accepted in this phase: prioritizes callable usability and practical behavior
  over strict soundness, given existing generic scoping unsoundness and lack of
  weak type-variable semantics.

### 3.14 Nested overload witness (overload-inside-overload)
`source: new-edge-candidate`

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

Target coverage:
- recursive overload handling when outer overload branch solutions themselves
  contain overloaded callable structure
- verifies finishing/finalization recursion does not assume one overload layer
- stresses deterministic branch ordering/pruning at multiple nesting levels.
- useful for exposing design gaps around nested witness capture/elimination.

### 3.15 Value is a bound method
`source: new-edge-candidate`

```python
from typing import Callable, reveal_type

class Box[T]:
    def id(self, x: T) -> T: ...

def ho[A, R](f: Callable[[A], R]) -> Callable[[A], R]: ...

b: Box[int]
g = ho(b.id)
reveal_type(g)
```

Target coverage:
- bound-method witness handling through residual creation/finalization
- verifies method-binding semantics compose with callable residual machinery
  (strip/bind first parameter behavior and no nested-boundmethod artifacts).

Expected direction:
- result keeps bound callable shape `Callable[[int], int]` (no explicit `self`
  parameter in the callable result)
- overload/generic residual machinery must preserve existing method-binding
  behavior rather than treating bound methods as raw unbound function values.

### 3.16 Value is a callback protocol
`source: new-edge-candidate`

```python
from typing import Callable, Protocol, reveal_type

class Callback[T](Protocol):
    def __call__(self, x: T) -> T: ...

def ho[A, R](f: Callable[[A], R]) -> Callable[[A], R]: ...

cb: Callback[int]
g = ho(cb)
reveal_type(g)
```

Target coverage:
- protocol-callable values as witnesses (non-function callable values)
- verifies residual path does not assume concrete `Function`/`Overload`
  representation only.

Expected direction:
- callback protocol value is normalized through `__call__` extraction before
  residual creation/pruning/finalization logic
- result is equivalent to passing an explicit function with the same signature
  (`Callable[[int], int]` in this shape), with no residual-path divergence.

### 3.16b Callback protocol with overload `__call__`
`source: new-edge-candidate`

```python
from typing import Callable, Protocol, overload, reveal_type

class OvCallback(Protocol):
    @overload
    def __call__(self, x: int) -> int: ...
    @overload
    def __call__(self, x: str) -> str: ...

def ho[A, R](f: Callable[[A], R]) -> Callable[[A], R]: ...

cb: OvCallback
g = ho(cb)
reveal_type(g)
```

Target coverage:
- callback protocol value whose `__call__` is itself overloaded
- verifies callable extraction + overload residual machinery compose without
  requiring the value to already be represented as `Type::Overload`.

### 3.16c Value is a bound overloaded method
`source: new-edge-candidate`

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

Target coverage:
- bound method whose underlying callable witness is overloaded
- verifies bound receiver stripping and overload residual preservation compose in
  one path.

Expected direction:
- `g` should behave as overloaded callable on the bound argument shape
  (`(int) -> int` and `(str) -> str`), with no explicit `self` parameter
  reintroduced in result types.

### 3.17 Sanitization leak attempt: partial var merged with overload residual
`source: new-edge-candidate`

```python
from typing import Callable, overload

def ho[S, T](f: Callable[[S], T], x: T) -> Callable[[S], T]: ...

@overload
def ov(x: int) -> int: ...
@overload
def ov(x: str) -> str: ...
def ov(x): ...

def leak_candidate():
    p = []              # likely partial element var
    p.append(1)
    g = ho(ov, p[0])    # attempt to union/merge external partial with call-scoped T
    return g, p
```

Target coverage:
- out-of-scope partial-origin var potentially merged into call-scoped residual var
- verifies sanitize phase rewrites leaked residuals on non-call-scoped vars.

### 3.18 Sanitization leak attempt: partial var merged with generic residual
`source: new-edge-candidate`

```python
from typing import Callable

def ho[S, T](f: Callable[[S], T], x: T) -> Callable[[S], T]: ...
def id[U](x: U) -> U: ...

def leak_candidate():
    p = []              # likely partial element var
    p.append(1)
    g = ho(id, p[0])    # generic path instead of overload path
    return g, p
```

Target coverage:
- same leak shape as 3.17, but with generic residual markers/promotion path
- checks sanitize behavior is consistent across overload vs generic residual kinds.

### 3.19 Sanitization leak attempt via `Unwrap`-style flow (exploratory)
`source: new-edge-candidate`

```python
from typing import Callable, overload

def ho[S, T](f: Callable[[S], T], use: Callable[[T], None]) -> Callable[[S], T]: ...

@overload
def ov(x: int) -> int: ...
@overload
def ov(x: str) -> str: ...
def ov(x): ...

captured = []
g = ho(ov, lambda y: captured.append(y))
```

Target coverage:
- lambda parameter `y` is expected to be represented with an unwrap-like solver
  var in contextual typing paths (`fresh_unwrap` path for lambda params)
- `y` is tied to call-scoped `T`, so this attempts a merge path from non-call
  unwrap var into residual-producing call scope
- sanitize invariant: no deferred residual artifact should remain observable via
  the out-of-scope lambda/`captured` path after call completion.

Tightening contract:
- this example is intended to be treated as a concrete trigger, not a sketch:
  lambda param creation should allocate unwrap-like vars in current solver
- test instrumentation should confirm:
  1. at least one unwrap-like var created for lambda param `y`
  2. that var receives/propagates constraints from call-scoped `T`
  3. no deferred residual survives on out-of-scope vars after sanitize

### 3.20 Sanitization leak attempt via `Recursive` var
`source: new-edge-candidate`

```python
from typing import Callable, overload

def ho[S, T](f: Callable[[S], T], x: T) -> Callable[[S], T]: ...

@overload
def ov(x: int) -> int: ...
@overload
def ov(x: str) -> str: ...
def ov(x): ...

def f(n):
    if n <= 0:
        return 0
    return g(n - 1)

def g(n):
    return f(n)

r = ho(ov, f(1))
```

Target coverage:
- unannotated mutually recursive bindings are expected to pass through recursive
  placeholder machinery during answer solving (SCC cold-start path)
- ties recursion-produced values into call-scoped `T` to probe potential
  residual leakage through recursive-origin vars.

Tightening contract:
- treat this as concrete if solver instrumentation confirms recursive placeholder
  allocation for `f`/`g` during solve
- if this snippet stops triggering placeholder allocation after solver changes,
  replace the seed with a known recursive-placeholder-producing pattern from
  `cycles.rs` while keeping the same `ho(..., x: T)` merge shape
- required invariant remains unchanged: sanitize must prevent deferred residual
  escape through non-call-scoped recursive-origin vars

### 3.21 Mixed residual kinds on one var (`Overload` + `Generic`)
`source: new-edge-candidate`

```python
from typing import Callable, overload

def merge[A, R](f: Callable[[A], R], g: Callable[[A], R]) -> Callable[[A], R]: ...

@overload
def ov(x: int) -> int: ...
@overload
def ov(x: str) -> str: ...
def ov(x): ...

def id[T](x: T) -> T: ...

r = merge(ov, id)
```

Target coverage:
- same call-scoped var may receive heterogeneous residual candidates
  (`Overload` and `Generic`)
- verifies multiple-distinct-candidate fallback path.

### 3.22 Polarity-flip recursion (pattern side under contravariance)
`source: new-edge-candidate`

```python
from typing import Callable

def ho[A](f: Callable[[Callable[[A], None]], None]) -> Callable[[A], None]: ...

def consume_int(cb: Callable[[int], None]) -> None: ...

r = ho(consume_int)
```

Target coverage:
- recursive subset checks where callable pattern/value orientation flips
  in contravariant positions
- validates `CallContext` polarity tracking, not fixed got/want assumptions.

### 3.23 Overload with no participating pattern vars (degenerate no-op)
`source: new-edge-candidate`

```python
from typing import Callable, overload

def ho(f: Callable[[int], int]) -> int: ...

@overload
def ov(x: int) -> int: ...
@overload
def ov(x: str) -> int: ...
def ov(x): ...

v = ho(ov)
```

Target coverage:
- confirms overload residual machinery is not engaged when visitor finds no
  participating pattern vars for the active callable match.

### 3.24 Coexistence: legacy `Projected` with `CallableResidual`
`source: new-edge-candidate`

```python
# Integration sketch:
#   Construct/observe a type tree that contains both legacy Type::Projected
#   and new Type::CallableResidual during migration.
#   Verify boundary finalization runs deterministic local fixed-point
#   elimination until neither deferred form remains (per boundary policy).
```

Target coverage:
- migration-period interaction between two deferred representations
- fixed-point ordering/termination guard behavior.

Status:
- phase-gated until `Type::CallableResidual` lands in solver/type model.

### 3.25 Export boundary flattening from class `TArgs`
`source: new-edge-candidate`

```python
# Integration sketch:
#   1) Build class instance with residual in internal TArgs.
#   2) At member lookup boundary, internal policy may allow TArgs retention.
#   3) At export/serialization boundary, assert full flattening
#      (no residual in TArgs or anywhere else).
```

Target coverage:
- stricter export invariant versus return/member boundaries.

Status:
- depends on the explicit export-hook contract:
  `finalize_for_export(...)` must run immediately before serialization and must
  eliminate all deferred forms (including inside `TArgs`).

### 3.26 Determinism stress: pruning + delayed diagnostics ordering
`source: new-edge-candidate`

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

_ = ho(f, 3.14)  # forces full-prune incompatibility path
```

Target coverage:
- stable branch-processing order
- stable delayed-error message/order across runs.

Status:
- phase-gated until overload residual pruning/delayed diagnostics are implemented.

### 3.27 ParamSpec first-branch fallback policy (explicit)
`source: new-edge-candidate`

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

Target coverage:
- codifies provisional ParamSpec fallback rule (first declared overload branch)
  when the callable-shape fallback path is entered.
- this is a callable-shape fallback policy and is distinct from per-var
  multi-candidate residual arbitration (`fallback_for_residuals`).

## 4) Notes for Next Pass

- This file is intentionally redundant; next pass can prune to a smaller
  pencil-and-paper core set.
- Keep both kinds of entries:
  - behavior-defining examples (design semantics)
  - invariant tests (no-leak, boundary sanitization, deterministic fallback)
