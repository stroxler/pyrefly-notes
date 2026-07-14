# Elements of Shape Types: Int and IntTuple

This document describes an adjustment to Pyrefly's shape type system to be centered
around two elementary concepts: an `Int` type representing integer arithmetic and
an `IntTuple` type representing how a shape can be described by the sizes of dimensions.

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
- Related to both previous issues, `Type::Dim` and `Type::Size` (the old internal names)
  sort of represented the same thing

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
from shape_extensions import Int, IntVar, IntTuple

def square[N: IntVar](n: Int[N]) -> Tensor[[N, N]]:
    return torch.zeros((n, n))

def copy[Shape: IntTuple](x: Tensor[Shape]) -> Tensor[Shape]:
    return x.copy()
```

The key changes here are that:
- We no longer take shapes as type var tuples, which Avik and I agreed is not
  sustainable over library ecosystems for reasons I'll explain clearly shortly.
  But we do offer compact `Tensor[[N, N]]` notation.
- We introduce a dedicated `IntVar` *kind* of type variable for symbolic
  integers, written with a special-form upper bound. A `IntVar` type variable
  `N` names a symbolic dimension; the dimension type itself is spelled
  `Int[N]`. Shapes are type variables declared with an `IntTuple` bound. The
  `Dim` type no longer exists.

The `IntVar` kind is the crucial departure from the earlier `[N: Size]`
sketch: rather than a normal `TypeVar` carrying a `Size` upper bound, a symbolic
dimension is a genuinely distinct kind of type variable — internally a sibling of
`TypeVarTuple` and `ParamSpec`, not a bounded `TypeVar`. It just happens to be
*spelled* with upper-bound syntax. A consequence is that a normal `TypeVar` is no
longer permitted inside `Int`: writing `[N: Int]` gives you an ordinary
`TypeVar` (bounded by the `Int` class), which is *not* a symbolic dimension;
only an `IntVar` type variable is.


## Specific problems this solves

### Ability to represent classes with multiple shapes

Something I noticed immediately on applying shape annotations to a `torchrec` codebase was
that we need a way to represent a type that has multiple different shapes; in the new
annotation style:
```python
class JaggedTensor[V: IntTuple, L: IntTuple, O: IntTuple]:
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

This is the motivation for changing `Tensor[M, N]` to `Tensor[IntTuple[N, N]]`. The
spelling `Tensor[tuple[N, N]]` is also legal under coercion rules for `tuple` and
`IntTuple`, and we have defined `Tensor[[N, N]]` as shorthand syntax (only legal
when we are passing an `IntTuple` to a type argument bound by `IntTuple`). Note that
there is no ambiguity in `Tensor[[N, N]]`, since bare lists are not currently
permitted by the typing specification except in `Callable` and there's no overlap here.


### Performance and clarity in symbolic integer type argument rules

We noted two weeks ago week that the use of bare `N` in a class like
```python
class SquareMaker[N]:
    def __init__(self, n: Dim[N])We
        self.n = n
    def make_square(self) -> Tensor[N, N]:
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
class SquareMaker[N: IntVar]:
    def __init__(self, n: Int[N]):
        self.n = n
    def make_square(self) -> Tensor[[N, N]]:
        return torch.zeros((self.n, self.n))
```
and the `IntVar` kind on `N` would both
- Cause us to throw a type error (and coerce to the gradual `Int` for downstream)
  if someone tried to write `SquareMaker[str]`, and
- Trigger us to accept bare symbolic integers: `SquareMaker[N * 3 // M]` is
  shorthand syntax for `SquareMaker[Int[N * 3 // M]]`, which we automatically
  accept in a type argument if and only if that type parameter is an `IntVar`
  (just as with the list shorthand syntax for `IntTuple`).

There's an open question of whether we should eventually support inference so
that the `: IntVar` can be omitted. This is addressed later in a section on
potential enhancements.

### A clearer long-term path for a PEP specifying type-variable arithmetic

A new type variable kind is probably what we would need in a PEP: if we want to
add first-class support for symbolic arithmetic shapes to Python, we would need
a type variable class that supports arithmetic ops at runtime. A new kind, maybe
introduced with a new slug like `%`, is the obvious approach. So we might write
something like:
```python
def big_square[%N](n: Int[N]) -> Tensor[[N + N, N + N]]:
    torch.zeros(n + n, n + n)
```
and have the runtime create an `IntVar` class for `N` that supports the syntax we
need (exactly as occurs with `TypeVarTuple` and `ParamSpec` today, both of which
offer different syntactic rules than `TypeVar` and have their own runtime classes).


## What's going on under the hood

### The actual types versus syntactic sugar

In the updated type system, a type like
```
Tensor[[N * 3, *Shape]]
```
is only valid if `N: IntVar` and `Shape: IntTuple`, and it is really just
shorthand for
```
Tensor[IntTuple[Int[Int[N] * Int[3]], *Shape]]
```
(see a later section for a sketch of the actual datatypes).

The shorthand is applied automatically because:
- We accept list literals as a pun for `IntTuple[...]` any time it is passed
  as an argument to a parameter bound by `IntTuple`
- We accept bare symbolic arithmetic involving int literals and `IntVar`
  type variables any time we are:
  - inside of an `Int[...]` (you could write `x: Int[3] = 3` at the top level)
  - inside of an `IntTuple[...]` (which we are, with the rule above applied,
    in the `Tensor[[...]]`)

### Relationship to `int` and `tuple`

We have coercion rules that apply:
- For `Int`:
  - Literals coerce to `Int`, e.g. `Literal[3]` coerces to `Int[3]`, they are
    equivalent in the sense that they represent the same values.
  - The gradual type `Int` is short for `Int[int]`, and `int` coerces to `Int`,
    as does `Any`
  - Pretty much anything else would produce a type error, and become gradual `Int`
    for downstream analysis.
- For `IntTuple`:
  - A `tuple[X, Y, Z]` coerces to `IntTuple[Int(X), Int(Y), Int(Z)]`, where
    the `Int(...)` means applying Int coercion rules above.
  - The gradual `IntTuple` is short for `IntTuple[int, ...]` (which unlike
    `tuple[int, ...]` is gradual over the rank! And it is not idiomatic to
    write out). A `tuple[int, ...]` or `tuple[Any, ...]` coerces to it.
  - Anything else will throw a type error, and become gradual `IntTuple` for
    downstream analysis.

There are related gradual subtyping rules that are aligned with the coercion
rules, and attribute resolution on `Int` and `IntTuple` fall back to
`int` and `tuple` using these coercion rules.
- This means that, for example
  - if `s: IntTuple[N, M]`, then it's legal to pass `s` to
    `f(t: tuple[Any, ...]) -> None` by subtyping rules.
  - If `x: Int[N]` then `x * 1.5` is `float` by fallback to `int` behavior.
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
       | Int Int
       | IntTuple IntTuple


Int ::= {Add / Sub / Mul / FloorDiv / Pow} of Int Int   // symbolic arithmetic
         | Literal i64
         | Int                    // the gradual `Int` / `Int[int]`
         | Symbolic Type          // invariant: must be an `IntVar`-kind `Quantified` / `TypeVar` / `Var`

IntTuple ::= Concrete(Vec<Int>)
              | Gradual                                       // gradual `IntTuple`, gradual over the rank
              | Unpacked(Vec<Int>, Type, Vec<Int>)      // invariant: the middle must be `IntTuple` or an `IntTuple`-bound `TypeVar`
```

The invariants are a bit subtle because there's also a sense of canonicality:
- A canonical `Int` or `IntTuple` always has a type variable in every `Symbolic` / `Unpacked` slot
  (an `IntVar` for `Symbolic`, an `IntTuple`-bound variable for `Unpacked`);
  the symbolic and unpacked forms are only really there to allow symbolic manipulation
  involving type vars.
- But the hard invariant does allow for `Type::Int` / `Type::IntTuple` because that has
  to be permitted temporarily after var expansion, if a symbolic var gets solved / substituted.

## Future Extensions

This note covers work I've already done in a stack that's out for review:
introducing a new `IntVar` kind of type variable, unifying the original `Dim`
and `Size` types into an `Int[...]` type with crisper semantics, and creating a
first-class `IntTuple` type for shapes.

There are two major improvements Avik, Sam and I have discussed that I have
not yet begun. I don't think either of these is necessary to go after torch
early adopters so I'm not sure how soon I'll get to either of them.

### Inferring the `IntVar` kind without the `: IntVar` marker

Everything above requires the `IntVar` (and `IntTuple`) markers to be written
explicitly. A natural extension would be to *infer* the kind, so that a bare
`def square[N](n: Int[N]) -> ...` would recognize `N` as an `IntVar` from the way
it is used, letting authors omit the `: IntVar` "bounds" entirely.

This makes me a little nervous - the implicitness seems to violate the Zen of
Python, and if we offer inference now it might be hard to take it back later,
even though the ideal support is going to require a new kind with new syntax
type-level arithmetic, like the `%N` idea sketched above.

On the other hand, the syntax is indeed much lighter for functions with many
`IntVar`s if we can avoid the `: IntVar` boilerplate. I have a plan to
handle it - by optimizing inference rules around the `TypeVar` case and using
an early-exit when `shape_extensions` isn't imported at all, we can just
use the binding-level fixpoint to do inference (which is naturally cyclic
unless we go to great lengths not to make it so) but pay very small perf
costs on the vast majority of code that is not actually using `IntVar`.

### Type-level DSL

The current shape-transformation DSL is accessed by using a
`@uses_shape_dsl(dsl_func)` decorator to "register" a DSL function as modeling the
shapes of a user-space function. The DSL executes *after* the normal type inference,
and we glue the two results together.

This is a bit hard to understand because it's mixing type and value level logic,
and can be particularly confusing (at least to me and to agents) when dealing with
overloads.

I believe that by introducing a notion of literal-capturing type variables, we can
lift the DSL into the type system itself so we could model something like
```
from shape_extensions import IntTuple, IntVar, Int, Flag

def complicated_reshape_op[S: IntTuple, N: IntVar, B: Flag[bool]](
    x: Tensor[S], n: Int[N] flag: B
) -> Tensor[complicated_reshape_op_ir(S, N, B)]
```
where here `Flag[bool]` is a specially-behaving type variable that would allow us
to capture literal values passed into functions where the DSL wants to model them.

This is just a rough sketch of an idea. We might do better to avoid `Flag`
entirely and rely on overloads to handle it (allowing dsl calls to take
literals), but the main real point is to make the DSL functions actually operate as
type-level functions rather than having the dual-execution-and-merge logic we have
today.
