# Tensor Shape Functions in Stubs

## Overview

This document proposes moving tensor shape logic from an embedded Rust DSL to Python stub files (`.pyi`), enabling library extensibility and code navigation.

## Motivation

### Current Architecture Limitations

Pyrefly currently implements tensor shape inference using a Domain Specific Language (DSL) embedded as a string constant in `crates/pyrefly_types/src/tensor_ops_registry.rs`. The `TensorOpsRegistry` struct contains ~80 hardcoded registrations mapping qualified names like `"torch.matmul"` to DSL function names like `"matmul_ir"`.

**Problems:**

1. **Not extensible**: Third-party libraries cannot provide shape logic for their operations. Adding support for a new library requires modifying pyrefly's source code and recompiling.

2. **Poor code navigation**: The DSL is embedded in a Rust string literal. There's no way to "Go to Definition" from a tensor operation to its shape logic. Developers cannot easily discover or understand how shapes are computed.

3. **Tight coupling**: Shape logic for PyTorch is mixed with the registry mechanism in Rust code. Library authors who understand tensor shapes may not know Rust.

### Goals

1. **Library extensibility**: Allow library authors to ship shape logic in their type stubs, enabling pyrefly to understand custom tensor operations without modifying pyrefly itself.

2. **Code navigation**: Enable "Go to Definition" from tensor API to shape implementation, making shape logic discoverable and editable with full IDE support.

3. **Scalability**: Multiple libraries should be able to reuse common shape operations (e.g., both PyTorch and JAX can reference the same `reshape_ir` logic).

## Proposed Design

### Decorator-Based Registration

Add a `@uses_shape` decorator to API functions in stub files that references the IR function implementing the shape logic.

**Example:**

```python
# torch/__init__.pyi
from torch_shapes import Tensor, uses_shape, reshape_ir, matmul_ir

class Tensor[*Shape]:
    @uses_shape(reshape_ir)
    @overload
    def reshape(self, *shape: int) -> Tensor: ...
    
    @uses_shape(reshape_ir)
    @overload
    def reshape(self, shape: tuple[int, ...]) -> Tensor: ...

@uses_shape(reshape_ir)
def reshape(input: Tensor, shape: tuple[int, ...]) -> Tensor: ...

@uses_shape(matmul_ir)
def matmul(input: Tensor, other: Tensor) -> Tensor: ...
```

### IR Function Definitions

IR functions (shape implementations) live in `torch_shapes.pyi` and are regular Python functions using a restricted subset of Python syntax.

```python
# torch_shapes.pyi
from typing import TypeVar, Callable
from typing_extensions import ParamSpec

P = ParamSpec('P')
T = TypeVar('T')

class Tensor[*Shape]:
    """Tensor with shape type parameter."""
    shape: tuple[int, ...]

class Dim:
    """Symbolic dimension type."""
    pass

def uses_shape(ir_fn: Callable[P, T]) -> Callable[[Callable[P, T]], Callable[P, T]:
    """Decorator marking which IR function implements shape logic for an API."""
    ...

# Helper functions (used by IR functions, not registered as ops)
def normalize_dim(rank: int, dim: int) -> int:
    if dim < 0:
        return dim + rank
    return dim

def replace_dim(dims: list[int | Dim], i: int, value: int | Dim) -> list[int | Dim]:
    return dims[:i] + [value] + dims[i + 1:]

# IR functions (referenced by @uses_shape decorators)
def reshape_ir(self: Tensor, shape: list[int | Dim]) -> Tensor:
    minus_one_count = len([d for d in shape if d == -1])
    if minus_one_count > 1:
        raise Error("can only specify one unknown dimension as -1")
    has_bad_neg = len([d for d in shape if isinstance(d, int) and d < -1]) > 0
    if has_bad_neg:
        raise Error("invalid negative dimension value (only -1 is allowed)")
    if minus_one_count > 0:
        known = torch_shapes.prod([d for d in shape if d != -1])
        total = torch_shapes.prod(self.shape)
        if isinstance(total, int) and isinstance(known, int) and total % known != 0:
            raise Error("could not infer size for dimension -1")
        return Tensor(shape=[total // known if d == -1 else d for d in shape])
    return Tensor(shape=shape)

def matmul_ir(self: Tensor, other: Tensor) -> Tensor:
    r1 = len(self.shape)
    r2 = len(other.shape)
    if r1 == 1 and r2 == 1:
        return Tensor(shape=[])
    if r1 == 1 and r2 == 2:
        return Tensor(shape=[other.shape[1]])
    if r1 == 2 and r2 == 1:
        return Tensor(shape=[self.shape[0]])
    if r1 == 2 and r2 == 2:
        return Tensor(shape=[self.shape[0], other.shape[1]])
    # ... handle batched matmul
    return Tensor(shape=broadcast(self.shape[:-2], other.shape[:-2]) + [self.shape[-2]] + [other.shape[-1]])
```

### Library Extensibility

Third-party libraries can reference built-in IR functions or define their own.

**Reusing built-in IR functions:**

```python
# mylib/__init__.pyi
from torch_shapes import Tensor, uses_shape, reshape_ir

@uses_shape(reshape_ir)  # Reuse PyTorch's reshape logic
def my_reshape(x: Tensor, shape: tuple[int, ...]) -> Tensor: ...
```

**Defining custom IR functions:**

```python
# mylib/__init__.pyi
from torch_shapes import Tensor, uses_shape
from mylib.shapes import custom_ir

@uses_shape(custom_ir)
def custom_op(x: Tensor, dim: int) -> Tensor: ...

# mylib/shapes.pyi
from torch_shapes import Tensor, Dim

def custom_ir(x: Tensor, dim: int) -> Tensor:
    return Tensor(shape=[d for i, d in enumerate(x.shape) if i != dim])
```

## Architecture

### Stub Discovery Mechanism

Pyrefly discovers shape functions by scanning stub files:

1. **Find stub files**: Locate all `.pyi` files in the module search path, including bundled stubs and installed libraries.

2. **Parse and extract**: For each stub file, parse with pyrefly's Python parser and extract:
   - Functions decorated with `@uses_shape`
   - The IR function reference from the decorator
   - All function definitions (potential IR functions)

3. **Resolve references**: Resolve IR function references to their definitions:
   - **Name nodes** (`@uses_shape(reshape_ir)`): Look up via imports
   - **Attribute nodes** (`@uses_shape(torch_shapes.reshape_ir)`): Direct module lookup
   - **String literals** (`@uses_shape("reshape_ir")`): Global name search (fallback)

4. **Collect IR functions**: Gather source code for all referenced IR functions plus helper functions they use.

5. **Parse DSL**: Parse the collected IR function sources using the existing DSL parser.

6. **Build registry**: Create `TensorOpsRegistry` mapping API qualified names to parsed IR functions.

### Function Reference Resolution

The discovery mechanism implements limited import resolution for stub files:

**Example resolution:**

```python
# torch/__init__.pyi
from torch_shapes import reshape_ir

@uses_shape(reshape_ir)
def reshape(...): ...
```

Resolution steps:
1. Parse `torch/__init__.pyi`, find `reshape` function with `@uses_shape(reshape_ir)`
2. See `reshape_ir` is a Name node, look up in file's imports
3. Find `from torch_shapes import reshape_ir`
4. Locate `torch_shapes.pyi`, find `def reshape_ir(...)`
5. Extract source code for `reshape_ir`

**Import graph:**
```
torch/__init__.pyi ──┐
torch/nn/__init__.pyi ├─→ torch_shapes.pyi
mylib/__init__.pyi ───┘
mylib/__init__.pyi ─────→ mylib/shapes.pyi
```

The graph is acyclic - `torch_shapes.pyi` never imports from API stubs.

### Registry Construction

```rust
// Pseudocode
fn build_registry() -> TensorOpsRegistry {
    // Discover all shape functions from stubs
    let discovered = discover_shape_functions();
    
    // Collect IR function sources
    let ir_sources: Vec<String> = discovered.ir_functions
        .values()
        .map(|f| f.source_code.clone())
        .collect();
    
    // Parse DSL
    let combined = ir_sources.join("\n\n");
    let dsl_fns = parse_dsl(&combined)?;
    let fn_lookup = build_lookup(dsl_fns);
    
    // Build registry
    let mut registry = TensorOpsRegistry::new();
    for (api_name, ir_name) in discovered.api_to_ir {
        let dsl_fn = dsl_fn(&fn_lookup, &ir_name);
        registry.register(api_name, dsl_fn);
    }
    
    registry
}
```

## File Organization

### PyTorch Stubs

```
pyrefly/
  crates/pyrefly_bundled/stubs/
    torch_shapes.pyi          # IR functions, helpers, decorator, Tensor/Dim types
  test/tensor_shapes/fixtures/
    torch/
      __init__.pyi            # API stubs with @uses_shape decorators
      nn/
        __init__.pyi          # More decorated APIs
        functional.pyi
```

### Library Stubs

```
mylib/
  __init__.pyi                # APIs with @uses_shape decorators
  shapes.pyi                  # Optional: custom IR functions
```

Libraries can choose to:
- Only reference built-in IR functions from `torch_shapes`
- Define custom IR functions in `shapes.pyi`
- Mix both approaches

## nn.Module Support

For `nn.Module` subclasses that need to capture `__init__` parameters, the decorator accepts a `capture_init` argument:

```python
# torch/nn/__init__.pyi
from torch_shapes import Tensor, uses_shape, maxpool_forward_ir

class MaxPool2d:
    @uses_shape(maxpool_forward_ir, capture_init=["kernel_size", "stride", "padding", "dilation"])
    def forward(self, input: Tensor) -> Tensor: ...

# torch_shapes.pyi
def maxpool_forward_ir(
    input: Tensor,
    kernel_size: Dim = 1,
    stride: Dim | None = None,
    padding: Dim = 0,
    dilation: Dim = 1
) -> Tensor:
    return pool_ir(input, kernel_size, stride, padding, dilation)
```

The `capture_init` list specifies which `__init__` parameters should be stored in the `Type::NNModule` and made available to the IR function during shape inference.

## Benefits

### Code Navigation

**Before:**
```
User code: x.reshape((2, 3))
    ↓ "Go to Definition"
torch/__init__.pyi: def reshape(...): ...
    ↓ (dead end)
```

**After:**
```
User code: x.reshape((2, 3))
    ↓ "Go to Definition"
torch/__init__.pyi: @uses_shape(reshape_ir)
                    def reshape(...): ...
    ↓ "Go to Definition" on reshape_ir
torch_shapes.pyi: def reshape_ir(self: Tensor, shape: list[int | Dim]) -> Tensor:
                      ...
```

### Scalability

Multiple libraries can reuse the same IR functions:

```python
# torch/__init__.pyi
@uses_shape(reshape_ir)
def reshape(...): ...

# jax/__init__.pyi  
@uses_shape(reshape_ir)  # Same IR, different API
def reshape(a: Tensor, newshape: tuple[int, ...]) -> Tensor: ...

# mylib/__init__.pyi
@uses_shape(reshape_ir)  # Reuse for wrapper
def my_reshape(x: Tensor, shape: tuple[int, ...]) -> Tensor: ...
```

The `reshape_ir` function is defined once and reused everywhere.

### Explicit Dependencies

Imports make dependencies clear:

```python
from torch_shapes import reshape_ir, matmul_ir, sum_ir

@uses_shape(reshape_ir)
def reshape(...): ...

@uses_shape(matmul_ir)  
def matmul(...): ...
```

### IDE Support

Function references enable standard IDE features:
- **Find references**: Show all APIs using `reshape_ir`
- **Rename**: Rename `reshape_ir` and update all decorators
- **Auto-import**: IDE suggests importing `reshape_ir` when adding decorator
- **Type checking**: Verify IR function exists and has compatible signature

## Migration Plan

### Phase 1: Infrastructure (2 weeks)

1. Create `torch_shapes.pyi` with:
   - `uses_shape` decorator definition
   - `Tensor` and `Dim` types
   - Helper functions (`normalize_dim`, `replace_dim`, etc.)

2. Implement stub discovery mechanism:
   - Scan stub files for `@uses_shape` decorators
   - Resolve function references via imports
   - Collect IR function definitions
   - Parse DSL and build registry

3. Support both embedded DSL and stub-based DSL during transition.

### Phase 2: Torch Migration (3 weeks)

Migrate operations from embedded DSL to stubs:

1. For each operation in `tensor_ops_registry.rs`:
   - Add `@uses_shape(ir_name)` decorator to stub in `torch/__init__.pyi`
   - Move IR function from `DSL_SOURCE` to `torch_shapes.pyi`
   - Remove hardcoded `registry.register()` call

2. Test parity with existing test suite.

3. Once all operations migrated, remove `DSL_SOURCE` constant.

### Phase 3: Library Extensibility (2 weeks)

1. Implement module resolution for shape stubs:
   - Discover stubs in user projects and installed libraries
   - Handle precedence (user > library > bundled)

2. Add conflict detection for duplicate shape definitions.

3. Test with example third-party library.

### Phase 4: Cleanup (1 week)

1. Remove embedded DSL code from `tensor_ops_registry.rs`
2. Update documentation
3. Add tests for library-provided shape functions

## Timeline

| Phase | Duration | Description |
|-------|----------|-------------|
| Infrastructure | 2 weeks | Discovery mechanism, torch_shapes.pyi |
| Torch migration | 3 weeks | Move 80+ operations to stubs |
| Library extensibility | 2 weeks | Module resolution, precedence |
| Cleanup | 1 week | Remove embedded DSL, docs |
| **Total** | **8 weeks** | ~2 months |

## Design Alternatives Considered

### Alternative 1: Decorator on IR Functions

```python
# shapes.pyi
@shape_function("torch.reshape")
def reshape_ir(...): ...
```

**Rejected because:**
- Navigation goes API → (dead end), not API → IR
- Each API needs its own IR function (no reuse)
- Less discoverable - must look in shapes.pyi to see what's available

### Alternative 2: String References Only

```python
@uses_shape("reshape_ir")
def reshape(...): ...
```

**Rejected because:**
- No IDE support for navigation, find references, rename
- Typos not caught until runtime
- Dependencies not explicit in imports

### Alternative 3: Keep Embedded DSL

Keep current architecture with DSL in Rust string.

**Rejected because:**
- No library extensibility
- No code navigation
- Shape logic inaccessible to library authors

## Open Questions

1. **Module organization**: Should `torch_shapes.pyi` be bundled with pyrefly or with torch stubs? Bundled with pyrefly ensures it's always available, but torch stubs might want to customize.

2. **Versioning**: How to handle different versions of torch with different shape semantics? The IR functions in `torch_shapes.pyi` may need version-specific variants.

3. **Performance**: Should we cache the parsed registry across pyrefly invocations? The discovery and parsing happens at startup and could be cached.

4. **Error messages**: When an IR function has a shape error, should we report the location in the stub file or in the user's code? Probably both - "shape error in reshape_ir (torch_shapes.pyi:45) called from user_code.py:10".

## Conclusion

Moving shape functions to stubs with decorator-based registration enables library extensibility and provides excellent code navigation. The function reference approach (`@uses_shape(reshape_ir)`) maximizes IDE support and makes dependencies explicit. The 8-week implementation timeline is justified by the significant benefits for the tensor shape ecosystem.
