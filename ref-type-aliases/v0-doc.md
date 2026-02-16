# Design: Ref-Native Type Aliases (Eliminate AliasRecursive)

## Goal

Completely eliminate `Variable::AliasRecursive` and the cycle-breaking mechanism
from Pyrefly by making type alias references produce `TypeAliasData::Ref` at
binding time, with an **expand** step that resolves non-recursive Refs before
consumers see the type.

## Motivation

The existing `Variable::AliasRecursive` mechanism relies on the solver's
cycle-breaking / fixpoint infrastructure to handle recursive type aliases.
This infrastructure is being reimplemented in a way that would break recursive
alias handling. We need a complete replacement that decouples recursive type
alias resolution from binding-level recursion.

## Background: Why We Need Both Ref and Expansion

We tried using `Binding::TypeAliasRef` (producing `TypeAliasData::Ref`) for
self-references only — this works but doesn't handle mutual recursion.
We tried extending to ALL prior aliases — tests broke because
`TypeAlias(Ref(...))` is not semantically equivalent to the fully-resolved
type in all contexts (variance checking, tuple unpacking, LSP semantic tokens).

The root cause: `Ref` is a lazy indirection, but many consumers expect the
eagerly-resolved type. The solution is a two-layer architecture: produce Refs
eagerly (breaking cycles), then expand non-recursive Refs before consumers
see them.

## Design: Raw and Expanded Layers

### Existing binding structure

Pyrefly already has two bindings for type aliases:

- **`BindingTypeAlias`** (keyed by `KeyTypeAlias`): Evaluates the RHS expression
  of a type alias. Produces a `TypeAlias` (name + resolved type + style).
  This answer is **exported** cross-module (`EXPORTED: bool = true`).

- **`Binding::TypeAlias`** (keyed by `Key`): Calls `get_idx(key_type_alias)` to
  get the `TypeAlias` from above, then wraps it with type parameters via
  `wrap_type_alias`. Produces the final `Type` seen by consumers.

### New design: raw layer and expanded layer

We reuse these two existing bindings as the **raw layer** and **expanded layer**:

**Raw layer (`BindingTypeAlias` / `KeyTypeAlias`):**
When evaluating the RHS expression, name references are checked against the
binding table: if the name's binding (after following `Forward` pointers) is a
`Binding::TypeAlias`, the reference produces `Binding::TypeAliasRef` (which
solves to `TypeAliasData::Ref(...)`) instead of `Binding::Forward`. This is
triggered by a new `Usage::TypeAliasRhs` variant that signals we're inside a
type alias RHS. The result is that the raw body contains Refs for all
alias-to-alias references. **No binding-level cycles are possible** because
Refs don't trigger solving of the referenced alias.

**Expanded layer (`Binding::TypeAlias` / `Key`):**
After getting the raw `TypeAlias` from `KeyTypeAlias`, `wrap_type_alias`
**expands** non-recursive Refs before wrapping with tparams. Expansion reads
the **raw layer** (`KeyTypeAlias`) answers of referenced aliases — never the
expanded layer. This is critical: it means no binding-level dependencies
exist between expanded-layer bindings of different aliases.

### Why expansion must read from the raw layer

The binding solver may use fixpoints when it detects cycles. If expansion read
from the expanded layer (`Binding::TypeAlias`) of other aliases, then:
- Alias A's expanded layer would depend on alias B's expanded layer
- For mutual recursion, this creates a binding-level cycle
- In a fixpoint, each iteration would expand one layer deeper — the type grows
  on every iteration and never converges

By reading from the raw layer (`KeyTypeAlias`), expansion is purely local
computation within a single `Binding::TypeAlias` solve. The raw layer answers
are stable: same-module raw answers have no inter-alias dependencies (because
`Binding::TypeAliasRef` produces Refs without solving the referenced alias),
and cross-module raw answers are also stable once we implement the export
conversion described below (see "Cross-Module" section), which ensures
cross-module alias references arrive as Refs rather than resolved values.
So expansion produces the same result
regardless of fixpoint iteration. This makes expansion **idempotent over the
fixpoint**.

### Expansion algorithm

```
expand(type, visiting={}) =
    match type:
        TypeAlias(Ref(r)) | UntypedAlias(Ref(r)) =>
            let key = (r.module_name, r.index)
            if key in visiting: return type  // recursive, keep as Ref
            raw_body = lookup_raw(r)  // same-module: get_idx; cross-module: get_from_module
            expanded = expand(raw_body.ty, visiting ∪ {key})
            if r.args: substitute(expanded, r.args)
            else: expanded
        other =>
            recurse into children with expand
```

Note: the raw layer's RHS evaluation calls `untype_opt`, which converts
`TypeAlias(Ref(...))` to `UntypedAlias(Ref(...))`. So in practice, Refs
in the raw body appear as `UntypedAlias(Ref(...))`. The expansion walker
must handle both forms — `TypeAlias(Ref(...))` (before `untype_opt`) and
`UntypedAlias(Ref(...))` (after `untype_opt`).

Note: expansion **inlines** the referenced alias body, stripping the
`TypeAlias` wrapper. This is intentional — it matches the behavior of
`Forward`-based resolution today, where the alias indirection disappears
and only the underlying type remains. Generic aliases wrapped in `Forall`
are handled by the `other` arm, which recurses into children and eventually
reaches the `TypeAlias(Ref(...))` node inside the `Forall`.

Key properties:
- **Reads raw layer only**: no expanded-layer dependencies between aliases
- **Idempotent**: expanding an already-expanded type is a no-op
- **Recursive Refs survive**: only truly recursive references remain as Refs
- **Non-recursive Refs disappear**: produce the same types as `Forward` today
- **Cycle detection**: the `visiting` set bounds expansion for mutual recursion
- **Generic scoping**: each Ref carries its own `args`, so nested generic
  aliases work correctly. E.g., `type A[T] = list[B[T]]` where `B[U] = dict[U]`:
  the Ref for `B[T]` has `args=[T]`, expansion substitutes `T` for `U` in B's
  body, and the outer substitution later replaces `T` with concrete args.

### Expansion location

Expansion happens in `wrap_type_alias`, after the raw body is fetched and
before wrapping in `TypeAlias(Value(...))`:

```rust
fn wrap_type_alias(&self, name, ta, params, range, errors) -> Type {
    // ta comes from get_idx(key_type_alias) — the raw layer
    let expanded_body = self.expand_type_alias_refs(ta.as_type(), &mut visiting);
    // ... resolve tparams, wrap as Forallable::TypeAlias(Value(expanded)).forall(tparams) ...
}
```

## Cross-Module Type Alias References

### Current behavior

Cross-module type alias references do **not** currently produce `Ref` at module
boundaries. When module `foo` imports alias `X` from module `bar`, `foo` receives
`TypeAliasData::Value(...)` — the fully inlined alias body. `TypeAliasData::Ref`
nodes only appear **inside** alias bodies, created by the `AliasRecursive`
cycle-breaking mechanism for same-module self-references.

The relevant code path: `wrap_type_alias` (solve.rs:1295) always produces
`TypeAliasData::Value(ta)`. The `KeyTypeAlias` answer is exported cross-module
(binding.rs: `EXPORTED: bool = true`), so other modules can look up the raw
body by `TypeAliasIndex`. But the `Type` flowing through imports is always
a `Value`.

### Why this must change

The fixpoint-idempotency requirement applies to **all** binding-level recursion,
not just same-module recursion. Cross-module cycles are possible:

```python
# a.py
from b import Y
type X = int | Y

# b.py
from a import X
type Y = str | X
```

If cross-module alias references go through `Binding::Forward` (as they do
today) and resolve to `TypeAliasData::Value(...)`, they create binding-level
dependencies between modules. In a fixpoint, each iteration would expand one
layer deeper — the type grows and never converges.

### Solution: Export as Ref via `KeyExport`

Change the **export path** so that the `Type` produced by `KeyExport` for type
aliases uses `TypeAliasData::Ref(...)` rather than `TypeAliasData::Value(...)`.
The expanded layer (`wrap_type_alias`) still produces `Value` for same-module
consumers — only the export converts it to `Ref`.

This means cross-module alias references are automatically Refs, matching
the same-module behavior from `Binding::TypeAliasRef`. The raw layer gets
Refs for all alias references uniformly, and the expanded layer expands them
all the same way.

For cross-module Refs, expansion uses `get_from_module` to read the raw-layer
(`KeyTypeAlias`) answer from the defining module. This is a cached answer
lookup — no re-computation.

### Annotation usage

Same-module annotations are unaffected: they resolve via `Binding::Forward` →
`Key` → `Binding::TypeAlias` → `wrap_type_alias`, which produces the
expanded-layer `Value` as before.

Cross-module annotations now receive `Ref` (from `KeyExport`) instead of
`Value`. They resolve lazily via `untype_alias` → `get_from_module`, which
is a cached answer lookup. The per-usage cost is negligible.

### Expansion cost summary

The total number of full recursive expansions in a module equals the number
of type alias definitions in that module — one expansion per alias, in
`wrap_type_alias`. Each expansion reads raw-layer answers from referenced
aliases (same-module or cross-module), all via cached lookups. The result is
cached as the expanded-layer answer. Annotation usages just read the cache.

## Implementation Steps

### Step 0 (prerequisite): Defer all BoundName creation, including static types

**File:** `expr.rs`, `bindings.rs`

Currently `ensure_name_impl` creates BoundName bindings immediately for
`Usage::StaticTypeInformation` (line 370) and defers them for other usages.
This was an optimization — static types don't participate in partial type
pinning, so there was no reason to defer. But `finalize_bound_name` already
has handling for `StaticTypeInformation` (lines 1145-1148), indicating the
design anticipated deferred static type bindings.

**Change:** Remove the `if used_in_static_type` special case and have ALL
BoundName creations go through `defer_bound_name`, regardless of usage.

**Known differences from the immediate path** (neither should affect behavior):
- The deferred path short-circuits Forward chains: it produces
  `Forward(terminal_idx)` rather than `Forward(first_idx)`. Both resolve to
  the same value at solve time since Forwards are chased transitively.
- When a partial type exists in the chain, the deferred path calls
  `mark_does_not_pin_if_first_use`. The immediate path doesn't, but this is
  arguably more correct — it explicitly marks that static type references
  shouldn't pin partial types (which they already don't, since
  `StaticTypeInformation` has no `current_idx`).

**Verification:** Run the full test suite. If all tests pass, this confirms
the change is behavioral equivalent and establishes a uniform deferred
BoundName path that the subsequent steps can build on.

**Why this matters:** Steps 2-3 below add a `Usage::TypeAliasRhs` variant
that must go through the deferred path (to handle forward references to
later-defined aliases). The deferred path also needs to work correctly with
`intercept_lookup` for legacy tparam collection. Doing this refactor first
as a standalone change (a) validates that deferred static type BoundNames
work correctly, (b) simplifies the subsequent steps since there's only one
code path to modify, and (c) isolates any issues to a single, simple change.

### Step 1: Add `Binding::TypeAliasRef` variant

**File:** `binding.rs`

```rust
/// A reference to a type alias in the same module, used within type alias RHS
/// expressions to produce TypeAliasData::Ref directly. Avoids binding-level
/// cycles between type aliases.
TypeAliasRef {
    name: Name,
    key_type_alias: Idx<KeyTypeAlias>,
},
```

At solve time, produces `Forallable::TypeAlias(TypeAliasData::Ref(r)).forall(tparams)`
where tparams are looked up from a side channel (since legacy alias tparams
aren't known at binding time).

### Step 2: Add a `Usage::TypeAliasRhs` variant

**File:** `expr.rs`

Add a new variant to the `Usage` enum:
```rust
/// Type alias RHS context. Like StaticTypeInformation, does not pin
/// partial types. Additionally signals that name references pointing
/// to type alias bindings should produce Binding::TypeAliasRef instead
/// of Binding::Forward.
TypeAliasRhs,
```

Update `Usage` methods (`narrowing_from`, `current_idx`, `may_pin_partial_type`)
to treat `TypeAliasRhs` like `StaticTypeInformation` (no pinning, no current
idx).

In `ensure_name_impl`, `TypeAliasRhs` must go through the `intercept_lookup`
path (for legacy tparam collection) just like `StaticTypeInformation`. After
Step 0, both usages go through `defer_bound_name`, so the only change needed
in `ensure_name_impl` is widening the `intercept_lookup` guard:
```rust
let used_in_static_type = matches!(usage, Usage::StaticTypeInformation | Usage::TypeAliasRhs);
```

Then change the three type alias RHS processing sites to use `TypeAliasRhs`
instead of `StaticTypeInformation`:
- `bind_single_name_assign` in `target.rs` (the `is_definitely_type_alias`
  branch that calls `ensure_type`)
- `Stmt::TypeAlias` in `stmt.rs` (PEP 695 `type X = ...`)
- `ensure_type_alias_type_args` in `stmt.rs` (`TypeAliasType(...)` calls)

This requires threading the new usage through `ensure_type` / `ensure_type_impl`,
which currently hardcodes `Usage::StaticTypeInformation`. The simplest approach
is to add a `usage` parameter to `ensure_type` (or use an enum to select
between static-type and type-alias-rhs modes).

**Legacy tparam compatibility:** `intercept_lookup` creates
`KeyLegacyTypeParam` and `PossibleLegacyTParam` bindings synchronously
during AST traversal, and the `LegacyTParamCollector` captures their indices
directly — independent of the BoundName binding. For names that are NOT
potential tparams (including type aliases), `intercept_lookup` returns the
original `Idx<Key>`, not a `PossibleLegacyTParam` idx. This means the
deferred path correctly sees the original binding for type alias names,
while tparam names go through `PossibleLegacyTParam` as before.

### Step 3: Produce `Binding::TypeAliasRef` in `finalize_bound_name`

**File:** `bindings.rs`

In `finalize_bound_name`, add handling for `Usage::TypeAliasRhs`: follow
the `Forward` chain from `lookup_result_idx` (table lookups only, no solving)
until reaching the first non-`Forward` binding. If it's
`Binding::TypeAlias { name, key_type_alias, .. }`, produce
`Binding::TypeAliasRef { name, key_type_alias }` instead of the usual
`Binding::Forward`. Otherwise fall through to normal Forward handling.

```rust
// In finalize_bound_name, before the existing logic:
if matches!(deferred.usage, Usage::TypeAliasRhs) {
    if let Some((name, key_type_alias)) = self.follow_to_type_alias(deferred.lookup_result_idx) {
        self.insert_binding_idx(deferred.bound_name_idx, Binding::TypeAliasRef { name, key_type_alias });
        return;
    }
    // Not a type alias — fall through to normal Forward
    self.insert_binding_idx(deferred.bound_name_idx, Binding::Forward(default_idx));
    return;
}
```

The helper `follow_to_type_alias` walks the binding table following `Forward`
pointers until it finds a non-Forward binding. If it's `Binding::TypeAlias`,
return the name and `key_type_alias` idx. Otherwise return `None`.

**Why deferred**: After Step 0, all BoundName creation goes through the
deferred path. Deferred processing runs after the full AST traversal, by
which point all type alias declarations have been processed and their
`Binding::TypeAlias` bindings exist in the table. This means forward
references to later-defined aliases correctly resolve through their Forward
chains to `Binding::TypeAlias`, without needing any pre-pass or auxiliary
name table.

Note: `Binding::TypeAliasRef` is ONLY produced during type alias RHS
evaluation (guarded by `Usage::TypeAliasRhs`). Value-level references
to alias names (e.g., `print(MyAlias)`, `isinstance(x, MyAlias)`, class
bases) go through the normal `Binding::Forward` → `Binding::TypeAlias` path
and are unaffected.

### Step 4: Implement the expand step

**File:** `solve.rs`

Add `expand_type_alias_refs` method that walks a type, expanding
Refs by reading their `KeyTypeAlias` (raw layer) answers. Uses `get_idx` for
same-module Refs and `get_from_module` for cross-module Refs. Uses a visiting
set for cycle detection.

### Step 5: Call expand in `wrap_type_alias`

After fetching the raw `TypeAlias` and before wrapping with tparams, expand
non-recursive Refs in the body. This restores semantic equivalence with the
current `Forward`-based resolution for non-recursive aliases.

### Step 6: Handle tparams for `Binding::TypeAliasRef`

For generic aliases, `Binding::TypeAliasRef` needs tparams to produce a proper
`Forall` wrapper. Since legacy alias tparams aren't known at binding time,
store a `type_alias_tparams` map in `BindingsInner` that maps
`(Name, Idx<KeyTypeAlias>)` to `TypeAliasParams`. This is populated after
`ensure_type` completes at each alias construction site.

**Generic subscripts at solve time:** When a generic type alias `B[T]` is
referenced inside another alias's RHS, `Binding::TypeAliasRef` produces a
`TypeAliasData::Ref` with `args: None` wrapped in a `Forall`. The subscript
handler at solve time (`expr_infer` for `Expr::Subscript`) must detect that
the value being subscripted is a `TypeAlias(Ref(...))` wrapped in `Forall`,
specialize the `Forall` with the provided type arguments, and produce a
`TypeAlias(Ref(name, args=[T, ...]))`. This is the same mechanism used today
for `Variable::AliasRecursive` — the `TypeAliasRef` struct already has an
`args: Option<TArgs>` field for this purpose — but care must be taken to
ensure the specialization path handles Refs correctly in all cases (e.g.,
nested generics, partially applied type parameters).

### Step 7: Change exports to produce Ref instead of Value

In the `KeyExport` solve path, when the underlying binding is a
`Binding::TypeAlias`, produce `TypeAliasData::Ref(...)` using the module
coordinates and `TypeAliasIndex` from the binding.

**Mechanism:** `BindingExport` wraps a `Binding`, typically
`Binding::Forward(idx)`. The export solver should follow the `Forward` chain
(table lookups only, no solving) until it reaches the first non-`Forward`
binding. If that binding is `Binding::TypeAlias { name, key_type_alias, .. }`,
produce a `TypeAliasData::Ref(...)` directly. If the first non-`Forward`
binding is anything else (e.g., `Binding::Phi`, `Binding::Narrow`,
`Binding::NameAssign`), fall through to the normal `solve_binding` path.
Only `Binding::TypeAlias` triggers the Ref shortcut.

**Critical:** `KeyExport` must emit the `Ref` **without triggering expansion**
(i.e., without calling `solve_binding` or `wrap_type_alias`). If `KeyExport`
triggered expansion first, it would create a dependency cycle:
Raw → KeyExport → Expanded → Raw, violating fixpoint idempotency. The export
must be a constant operation that extracts the alias identity from the binding
and constructs a `Ref` from it.

**Tparams:** For generic aliases, the export must produce a `Forall` wrapper
so importers know the alias is generic. Use `create_type_alias_params_recursive`
(the lightweight tparams computation already used by `create_recursive`) to
compute tparams from the `TypeAliasParams` field on `Binding::TypeAlias`.
This does not create inter-alias dependencies since it only resolves TypeVar
definitions, which are stable.

`wrap_type_alias` itself still produces `Value` — only the export path
produces `Ref`. This ensures cross-module consumers get Refs while
same-module consumers get the expanded Value.

### Step 8: Remove `AliasRecursive`

Once all alias types use the Ref-native approach and exports produce Refs:
- Remove `Variable::AliasRecursive`
- Remove `finish_alias_recursive` and `fresh_alias_recursive`
- Remove `Binding::TypeAlias` arm in `create_recursive`
- Simplify `force_var` and `pin_placeholder_type`

### Step 9: Handle implicit legacy aliases

Implicit legacy aliases (`X = Union[str, list["X"]]` without `TypeAlias`
annotation) are only detected at solve time. Options:
- (a) Detect at binding time via `is_definitely_type_alias_rhs` heuristics
- (b) Accept that implicit aliases may not support recursion (best-effort)

Option (a) is partially implemented — covers `Union`, `Optional`, etc.

**String forward references:** String annotations in type alias RHS expressions
(e.g., `list["X"]`) are parsed into expressions by `ensure_type` at binding
time. The parsed name expressions flow through `ensure_name_impl` where the
`Usage::TypeAliasRhs` interception applies, so string forward references to
aliases correctly produce `Binding::TypeAliasRef`.

## Verification

- All existing tests pass (including variance, tuple unpacking, LSP)
- Conformance tests unchanged
- Recursive alias tests pass for all three alias types (PEP 695, legacy,
  TypeAliasType)
- Mutual recursion tests pass
- Cross-module recursive alias tests pass
- Audit `subset.rs` and other consumers that call `get_type_alias`: ensure
  they handle cross-module `Ref` correctly and don't degenerate to `unknown`/`Any`
  when the Ref's module can't be found (this is a known fragile path today)

## Performance

The expand step walks the type tree for each alias body. Cost is
O(body size × number of aliases in a cycle). Since expansion reads raw-layer
answers (which are stable), there is no unbounded re-expansion. Different
aliases may independently expand the same referenced alias body — this
duplication is acceptable because alias bodies are small.

## What This Achieves

1. **Decouples recursive aliases from binding-level recursion**: no
   `AliasRecursive`, no fixpoint involvement for alias cycles
2. **Idempotent over fixpoints**: expansion reads stable raw-layer data,
   producing the same result regardless of iteration count
3. **No semantic changes for same-module consumers**: expanded types are
   identical to what `Forward` produces today. Cross-module consumers now
   receive `Ref` instead of `Value` via `KeyExport`, but `untype_alias`
   resolves both equivalently.
4. **Reuses existing binding structure**: no new key types needed, just a
   new `Binding::TypeAliasRef` variant and an expand step in `wrap_type_alias`
