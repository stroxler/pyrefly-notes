# Callable Residuals: Overview

## The problem

When a generic or overloaded callable is passed to a higher-order function, naively solving the type variables loses information. Consider:

```python
def identity[A, R](f: Callable[[A], R]) -> Callable[[A], R]:
    return f

def generic_fn[T](x: T) -> T: ...

result = identity(generic_fn)
```

Without residuals, the solver matches `generic_fn` against `Callable[[A], R]`, unifies `A` and `R` to `Unknown`, and produces `(Unknown) -> Unknown`, destroying the generic structure. Passing an overloaded function suffers a similar fate, committing to the first matching branch and discarding the rest.

Callable residuals solve both problems by **deferring resolution**. Instead of committing to concrete types during subset solving, the solver records what it learned and materializes the answer later. This preserves the polymorphic or overloaded structure through the call boundary.

## Architecture: three stages

Residual handling follows three stages (covered in detail in `design-v1.md`):

### 1. Capture (subset solving)

During argument matching, when a generic or overloaded callable is compared against a pattern like `Callable[[A], R]`, the solver records *residual candidates* on the quantified variables `A` and `R` rather than immediately solving them. Overload branches are probed individually using snapshot/rollback without committing to any single branch.

### 2. Finishing (`Variable` → `Type`)

When `finish_quantified` runs at the end of a call, variables with residual candidates are materialized into internal `Type::CallableResidual` artifacts. For overloaded residuals, branches that are incompatible with the final solved bounds are pruned.

### 3. Finalization (boundary semantics)

At callable boundaries (such as return type substitution or class-field lookup), residual artifacts are transformed into safe, boundary-appropriate types:
- **Generics** are re-promoted to `Forall` callables.
- **Overloads** are reconstructed by substituting surviving branches and combining them into `Type::Overload`.
- **Non-callable positions** gracefully fallback (typically to gradual/Unknown).

## Invariants and leak prevention

Residual types are internal solver artifacts that must never appear in user-visible output. We prevent leaks via:

- **Variable-read gating:** Residual payloads are only visible to specific target variables. Reads by unrelated variables see a flattened fallback type.
- **Boundary finalization:** Residuals are cleanly eliminated at explicit boundaries (call returns, class-field access).
- **Subset-cache partitioning:** Cache keys include residual context to prevent cache hits from accidentally suppressing candidate capture.

## Further reading

- `design-v1.md` — Normative design, data representations, invariant specifications, and details on class type parameter handling.
- `examples-v1.md` — Executable examples covering generic and overload scenarios, pruning, cross-witness behavior, and edge cases.
