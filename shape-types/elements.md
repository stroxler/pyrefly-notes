# Elements of Shape Types: Size and SizeTuple

This document describes an adjustment to Pyrefly's shape type system to be centered
around two elementary concepts: a `Size` type representing integer arithmetic and
a `SizeTuple` type representing how a shape can be described by the sizes of dimensions.

My motivation is to address a series of problems I encountered working with production code
and with numpy stubs:
- A performance problem caused by the implicit behavior of bare type variables
- Inability to express user-defined types (for example `JaggedTensor` generic over multiple shapes)
- Difficulty expressing operations that take shape tuples directly, like `torch.zeros((3, 4))`

In addition, my proposal addresses a set of concerns I had about my own ability to understand
the implementation (which is necessary in order to rapidly improve it to meet customer needs)
and the semantics (which we eventually need to be able to describe if we write a PEP):
- Symbolic integer type variables were unconstrained, but they had to be integers which felt odd
- The `Dim` type behaved pretty atypically, to work around the previous issue.
- Related to both previous issues, `Type::Dim` and `Type::Size` sort of represented the same thing

## A sketch of the change

The change is probably best outlined by a simple example.

Consider these two functions code in the current system:
```python
from torch import Tensor
from shape_extensions import Dim

def square[N](n: Dim[N]) -> Tensor[N, N]:
    return torch.zeros((n, n))

def copy[*Shape](x: Tensor[*Shape]) -> Tensor[*Shape]:
    return x.copy()
```

The proposal would write this as
```python
from torch import Tensor
from shape_extensions import Size, SizeTuple

def square[N: Size](n: N) -> Tensor[[N, N]]:
    return torch.zeros((n, n))

def copy[Shape: SizeTuple](x: Tensor[Shape]) -> Tensor[Shape]:
    return x.copy()
```

The key changes here are that:
- We no longer take shapes as type var tuples, which Avik and I agreed is not
  sustainable over library ecosystems for reasons I'll explain clearly shortly.
  But we do offer compact `Tensor[[N, N]]` notation.
- We represent both symbolic integers and shapes as type variables with explicit
  bounds of `Size` and `SizeTuple`. The `Dim` type no longer exists.


## Specific problems this solves

### Ability to represent classes with multiple shapes

Something I noticed immediately on applying shape annotations to a `torchrec` codebase was
that we need a way to represent a type that has multiple different shapes; in the new
annotation style:
```python
class JaggedTensor[V: ShapeTuple, L: ShapeTuple, O: ShapeTuple]:
    values: Tensor[V]
    lengths: Tensor[L]
    offsets: Tensor[O]
```
(This probably isn't the optimal description of `JaggedTensor`, but that's beside
the point - there are certainly multiple shapes involved).

The same thing could easily come up in an `nn.Module` that has two different input
tensors that both play a role in the `forward` method. We have some built-in magic to
support `nn.Module`, but it's actually not unusual for user-defined classes to
do similar things.

This is a huge problem, because it is syntactically impossible in Python to take
multiple `TypeVarTuple` parameters - *by definition* they just consume all variadic
parameters. So `JaggedTensor` as described above cannot be written at all in a world
where `Tensor` takes its shape variadically.

This is the motivation for changing `Tensor[M, N]` to `Tensor[SizeTuple[N, N]]`. The
spelling `Tensor[tuple[N, N]]` is also legal under coercion rules for `tuple` and
`SizeTuple`, and we have defined `Tensor[[N, N]]` as shorthand syntax (only legal
when we are passing a `SizeTuple` to a type argument bound by `SizeTuple`). Note that
there is no ambiguity in `Tensor[[N, N]]`, since bare lists are not currently
permitted by the typing specification except in `Callable` and there's no overlap here.


### Performance and clarity in symbolic integer type argument rules

I posted last week that the use of bare `N` in a class like
```python
def class SquareMaker[N]
    def __init__(n: Dim[N]):
        self.n = n
    def make_square(self) -> Tensor[N, N]
        return torch.zeros((self.n, self.n))
```
causes a performance problem in the current implementation, because there's no
marker on `N` saying it is special. But in fact, it is special:
- First, it has to be a symbolic integer for this code to be valid. Saying
  something like `SquareMaker[str]` is garbage that the representation permits,
  since `N` is unconstrained, but is meaningless because `Dim[str]` is meaningless.
- Second, we want to allow symbolic integer syntax in call sites so that you
  could write `SquareMaker[3]` or `SquareMaker[N * 3 // M]` inside a shape-typed
  function.

In the new setup, we would write
```python
def class SquareMaker[N: Size]
    def __init__(n: Dim[N]):
        self.n = n
    def make_square(self) -> Tensor[N, N]
        return torch.zeros((self.n, self.n))
```
and the `Size` bound on `N` would both
- Cause us to throw a type error (and coerce to the gradual `Size` for downstream)
  if someone tried to write `SquareMaker[str]`, and
- Trigger us to accept bare symbolic integers: `SquareMaker[[N * 3 // M]]` is
  shorthand syntax for `SquareMaker[Size[[N * 3 // M]]]`, which we automatically
  accept in a type argument if and only if that argument is bounded by `Size` (just
  as with the list shorthand syntax for `SizeTuple`.)

Sam Goldman noted, in my post last week, that we could probably solve the perf issue
by using the variance inference algorithm, since it has the same sort of behavior
of depending on the fanout of the typed surface area of `SquareMaker` and all classes
that appear in its class fields.

This might be a great idea if we decide that bounding by `Size` is too much
syntactic overhead, but I'm also inclined to think the explicit bounds may actually
be worth the verbosity: they follow the "explicit is better than implicit" Zen
of Python. And I'll note that `Size` really is behaving as a bound, not just a marker.
As we saw with `SquareMaker[str]` the incoming type has to be a valid symbolic
integer or it's a type error.

## What's going on under the hood

### The actual types versus syntactic sugar

In the updated type system, a type like
```
Tensor[[N * 3, *Shape]]
```
is only valid if `N: Size` and `Shape: SizeTuple`, and it is really just
shorthand for
```
Tensor[SizeTuple[Size[Size[N] * Size[3]], *Shape]]
```
(see a later section for a sketch of the actual datatypes).

The shorthand is applied automatically because:
- We accept list literals as a pun for `SizeTuple[...]` any time it is passed
  as an argument to a parameter bound by `SizeTuple`
- We accept bare symbolic arithmetic involving int literals and `Size`-bound
  type variables any time we are:
  - inside of a `Size[...]` (you could write `x: Size[3] = 3` at the top level)
  - inside of a `SizeTuple[...]` (which we are, with the rule above applied,
    in the `Tensor[[...]]`)

### Relationship to `int` and `tuple`

We have coercion rules that apply:
- For `Size`:
  - Literals coerce to `Size`, e.g. `Literal[3]` coerces to `Size[3]`, they are
    equivalent in the sense that they represent the same values.
  - The gradual type `Size` is short for `Size[int]`, and `int` coerces to `Size`,
    as does `Any`
  - Pretty much anything else would produce a type error, and become gradual `Size`
    for downstream analysis.
- For `SizeTuple`:
  - A `tuple[X, Y, Z]` coerces to `SizeTuple[Size(X), Size(Y), Size(Z)]`, where
    the `Size(...)` means applying Size coercion rules above.
  - The gradual `SizeTuple` is short for `SizeTuple[int, ...]` (which unlike
    `tuple[int, ...]` is gradual over the rank! And it is not idiomatic to
    write out). A `tuple[int, ...]` or `tuple[Any, ...]` coerces to it.
  - Anything else will throw a type error, and become gradual `SizeTuple` for
    downstream analysis.

There are related gradual subtyping rules that are aligned with the coercion
rules, and attribute resolution on `Size` and `SizeTuple` fall back to
`int` and `tuple` using these coercion rules.
- This means that, for example
  - if `s: SizeTuple[N, M]`, then it's legal to pass `s` to
    `f(t: tuple[Any, ...]) -> None` by subtyping rules.
  - If `x: Size[N]` then `x * 1.5` is `float` by fallback to `int` behavior.
- This is very similar to how `TypedDict` falls back to `dict`
  - The problem is very similar: we're dealing with exactly the same set
    of actual values (`x` is an `int` and `s` is a `tuple` at runtime), but
    with different static typing rules in play on top of the normal PEP 484 ones.


### A sketch of the Rust representation

At the outset of this work, we had the rust datatypes defined approximately as
```
Type ::= <other types>
       | Dim
       | Size Size
       // (no way to express SizeTuple directly, you could use `Tuple` of `Dim`)


// invariant: to be valid, the `Type`s have to be either `Size` or `Dim`
Size ::= Operation BinOp Type Type
       | Literal i64

// invariant: to make sense the `Type` has to a `Size` or a TypeVar (`Quantified` / `Var`)
Dim ::= Dim Type

// This didn't exist as a first-class type, but inside of `ShapedArray` it
// was present, and behaved differently than a normal tuple, because there
// were invariants about the entries being some
ShapeArrayShape = Struct(Tuple)

Tuple ::= Concrete(Vec<Type>)
        | Unpack(Vec<Type>, Type, Vec<Type>)
        | Unbounded
```

and after the change it is
```
Type ::= <other types>
       | Size Size
       | SizeTuple SizeTuple



Size ::= Operation BinOp SizeExpr SizeExpr
       | Literal i64
       | Symbolic Type    // invariant: must be `Size` or a `Size`-bounded TypeVar (`Quantified` / Var`)

SizeTuple ::= Concrete(Vec<Size>)
            | Unpack(Vec<Size>, Type, Vec<Size>)  // invariant: the type must be `SizeTuple` or a `SizeTuple`-bound `TypeVar`
```

The invariants are a bit subtle because there's also a sense of canonicality:
- A canonical `Size` or `SizeTuple` always have a `TypeVar` in every `Symbolic` / `Unpack` slot;
  the symbolic and unpack forms are only really there to allow symbolic manipulation
  involving type vars.
- But the hard invariant does allow for `Type::Size` / `Type::SizeTuple` because that has
  to be permitted temporarily after var expansion, if a symbolic var gets solved / substituted.


