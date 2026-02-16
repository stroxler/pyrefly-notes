# Implementation Plan: Ref-Native Type Aliases

This plan implements the design in `v0-doc.md`. It is organized as a
sequence of commits (diffs), each buildable and testable.

## Implementation Status

The implementation diverged significantly from the original plan below.
Here is what was actually implemented and what remains.

### Completed commits (in stack order)

1. **"Defer all static type BoundName creation"**: Prerequisite refactor —
   all BoundName creation goes through `defer_bound_name` (Step 0)
2. **"Add TypeAliasRef binding variant and Usage::TypeAliasRhs"**: Core
   binding variant. `finalize_bound_name` follows Forward chains via
   `follow_to_type_alias`. Initially self-reference only.
3. **"Handle UntypedAlias(Ref) in substitute_into_mut"**: Needed for
   generic alias subscripting at the raw layer.
4. **"Add type alias ref expansion helpers as dead code"**: Add
   `expand_type_alias_refs` / `expand_type_alias_refs_inner` to solve.rs.
   Uses `recurse_mut` (NOT `visit_mut` — `visit_mut` causes stack overflow).
5. **"Move cycle check from as_type_alias to wrap_type_alias"**: Move
   `check_type_alias_for_cyclic_reference` to after expansion point.
6. **"Enable all-aliases mode with expansion"**: `TypeAliasRef` for ALL
   same-module aliases (not just self-references). Expansion enabled in
   `wrap_type_alias`. Fixes for `Unpack(UntypedAlias)` in `untype_opt` and
   `specials.rs`. IDE support for `TypeAliasRef` in `find_definition_key_from`.
7. **"Follow through PossibleLegacyTParam in follow_to_type_alias"**:
   `follow_to_type_alias` now follows through `Binding::PossibleLegacyTParam`
   by looking up the `BindingLegacyTypeParam` to get the original idx. This
   unblocks `TypeAliasRef` production for all legacy type aliases.
8. **"Remove Variable::AliasRecursive"**: Removed the solver-level
   cycle-breaking variable entirely. All match arms, helper functions
   (`fresh_alias_recursive`, `finish_alias_recursive`), and the
   `Binding::TypeAlias`/`TypeAliasRef` arms in `create_recursive` removed.

### Key design decisions that differ from original plan

- **No `type_alias_names` map or `processing_type_alias_rhs` flag**:
  Instead of tracking alias names explicitly, we use `Usage::TypeAliasRhs`
  propagated through `ensure_type_impl`, and `finalize_bound_name` follows
  Forward chains to detect `Binding::TypeAlias` at the end of binding.

- **No `type_alias_tparams` map**: Tparams are stored directly in
  `Binding::TypeAliasRef { tparams }`, extracted from `Binding::TypeAlias`
  at `finalize_bound_name` time.

- **Cross-module (`KeyExport`) not changed**: The original plan included
  commit 6 to produce Ref for cross-module exports. This was not
  implemented. Cross-module aliases still use `TypeAlias(Value(...))`.

### Remaining gap: class-scoped attribute references

`test_class_attr` (`type X = int | list[C.X]`) is marked as `bug`. The
`C.X` attribute reference goes through solver-level attribute resolution,
not binding-level name lookup, so it can't produce `TypeAliasRef`.

### Future: solve-time Ref conversion (requires fixpoint)

Once the fixpoint-based solver is in place, the `C.X` gap (and any similar
solve-time-only self-references) can be handled by converting
`TypeAlias(Value(ta))` to `UntypedAlias(Ref(...))` in `untype_opt` when
`ta` is the alias currently being solved:

1. Track the current `KeyTypeAlias` being solved on the solver context
   (precedent: `wrap_type_alias` already has `current_index: Option<TypeAliasIndex>`)
2. In `untype_opt`, when hitting `TypeAlias(Value(ta))`, check if `ta`
   corresponds to the alias currently being solved
3. If so, produce `UntypedAlias(Ref(...))` instead of expanding

This achieves fixpoint idempotence: the `Ref` doesn't grow across
iterations, and `wrap_type_alias` handles expansion at use sites. Without a
fixpoint this doesn't work because the first iteration just gets a `Var`
that forces to `Unknown`, but with a fixpoint iteration 2+ correctly sees
the result from the prior iteration and converges.

In principle, this solve-time mechanism alone could replace ALL of the
binding-time `TypeAliasRef` plumbing — every self-reference would just
cycle through the solver and get converted to a `Ref` in `untype_opt`. We
don't plan to do this because the binding-time approach is more efficient:
it avoids creating solver cycles entirely for the common cases, which is
better than detecting and recovering from them after they occur.

---

## Original Plan (for reference)

The commits below are the original plan. The actual implementation above
diverged from this structure but achieved the same goals.

## Commit 1: Add `Binding::TypeAliasRef` variant (no-op)

Add the new binding variant and its solve-time handler. Nothing produces it
yet, so this is a pure addition with no behavioral change.

**binding.rs:**
- Add variant to `Binding` enum:
  ```rust
  TypeAliasRef {
      name: Name,
      key_type_alias: Idx<KeyTypeAlias>,
  },
  ```
- Add arms in `Display`, `symbol_kind`, and any other match-all sites.

**solve.rs (`binding_to_type`):**
- Add handler for `Binding::TypeAliasRef`:
  ```rust
  Binding::TypeAliasRef { name, key_type_alias } => {
      let index = self.bindings().idx_to_key(*key_type_alias).0;
      let r = TypeAliasRef {
          name: name.clone(),
          args: None,
          module_name: self.module().name(),
          module_path: self.module().path().clone(),
          index,
      };
      let tparams = self
          .bindings()
          .type_alias_ref_tparams(name, *key_type_alias)
          .cloned()
          .unwrap_or(TypeAliasParams::Legacy(None));
      let tparams = self.create_type_alias_params_recursive(&tparams);
      Forallable::TypeAlias(TypeAliasData::Ref(r)).forall(tparams)
  }
  ```

**Verification:** All tests pass, no behavioral change.

## Commit 2: Track type alias names in `BindingsBuilder`

Add the infrastructure to know which names are type aliases and whether
we're currently processing a type alias RHS.

**bindings.rs (`BindingsBuilder`):**
- Add fields:
  ```rust
  type_alias_names: SmallMap<Name, Idx<KeyTypeAlias>>,
  processing_type_alias_rhs: Option<Name>,
  ```
- Add methods:
  ```rust
  pub fn register_type_alias(&mut self, name: Name, idx: Idx<KeyTypeAlias>)
  pub fn set_processing_type_alias_rhs(&mut self, name: Option<Name>)
  pub fn is_processing_type_alias_rhs(&self) -> bool
  pub fn lookup_type_alias(&self, name: &Name) -> Option<Idx<KeyTypeAlias>>
  ```

**bindings.rs (`BindingsInner`):**
- Add `type_alias_tparams: SmallMap<(Name, Idx<KeyTypeAlias>), TypeAliasParams>`
  to store tparams for `Binding::TypeAliasRef` solve-time lookup.
- Pass through from `BindingsBuilder` to `BindingsInner` to `Bindings`.
- Add `type_alias_ref_tparams(&self, name, idx) -> Option<&TypeAliasParams>`
  accessor on `Bindings`.

**target.rs (legacy aliases):**
- After creating `KeyTypeAlias`, call `register_type_alias(name, idx)`.
- Wrap `ensure_type` call with `set_processing_type_alias_rhs(Some(name))`
  / `set_processing_type_alias_rhs(None)`.
- After `ensure_type` completes and tparams are known, store them in
  `type_alias_tparams`.

**stmt.rs (PEP 695 scoped aliases):**
- Same pattern: register, set flag around RHS processing, store tparams.

**stmt.rs (TypeAliasType):**
- Same pattern.

**Verification:** All tests pass, no behavioral change (nothing reads these
fields yet).

## Commit 3: Produce `Binding::TypeAliasRef` for same-module aliases

Wire up the binding-time interception.

**expr.rs (`ensure_name_impl`):**
- When `self.is_processing_type_alias_rhs()` is true and the name is in
  `self.lookup_type_alias(name)`, produce `Binding::TypeAliasRef { name, key_type_alias }`
  instead of `Binding::Forward(lookup_result_idx)`.
- This only fires in type alias RHS evaluation. Value-level references
  are unaffected because `processing_type_alias_rhs` is false outside
  alias RHS processing.

**Expected test changes:** At this point, same-module alias references in
type alias bodies will produce `Ref` instead of fully-resolved types.
Tests that check recursive alias behavior may change. Tests for
non-recursive aliases will break because the Refs aren't expanded yet.
This is expected — the expand step (commit 4) fixes it.

**Strategy:** Run tests to identify failures, then proceed to commit 4
before fixing. Alternatively, gate the `TypeAliasRef` production behind a
flag and only enable it after commit 5.

**Recommended approach:** Implement commits 3-5 together as a single
logical change. Test after commit 5, not after commit 3.

## Commit 4: Implement the expand step

Add the `expand_type_alias_refs` method to the solver.

**solve.rs:**
```rust
fn expand_type_alias_refs(
    &self,
    ty: &Type,
    visiting: &mut SmallSet<(ModuleName, TypeAliasIndex)>,
) -> Type {
    // Walk the type tree. For each node:
    //   TypeAlias(Ref(r)) | UntypedAlias(Ref(r)) =>
    //     let key = (r.module_name, r.index);
    //     if visiting.contains(&key): return node unchanged (recursive)
    //     visiting.insert(key);
    //     let raw = lookup_raw(r);  // get_idx or get_from_module
    //     let expanded = expand(raw.as_type(), visiting);
    //     visiting.remove(&key);
    //     if r.args: substitute(expanded, r.args)
    //     else: expanded
    //   other => recurse into children
}
```

Key implementation notes:
- Must handle both `Type::TypeAlias(box TypeAliasData::Ref(r))` and
  `Type::UntypedAlias(box TypeAliasData::Ref(r))` — the raw layer's
  `untype_opt` converts the former to the latter.
- For same-module Refs: `self.get_idx(KeyTypeAlias(r.index))` to read
  the raw-layer answer.
- For cross-module Refs: `self.get_from_module(r.module_name, Some(&r.module_path), &KeyTypeAlias(r.index))`
  to read the raw-layer answer from the other module.
- The visiting set uses `(ModuleName, TypeAliasIndex)`, not just `Name`,
  to handle cross-module cycles correctly.
- Use the existing type-walking infrastructure (check if there's a
  `map_type` or similar helper) rather than writing a manual recursive
  walker.

## Commit 5: Call expand in `wrap_type_alias`

Wire up the expand step.

**solve.rs (`wrap_type_alias`):**
- After `let ta = self.get_idx(*key_type_alias)` (which fetches the raw
  body), call `expand_type_alias_refs` on the body before processing
  tparams:
  ```rust
  fn wrap_type_alias(&self, name, mut ta, params, range, errors) -> Type {
      // Expand non-recursive Refs in the raw body
      let mut visiting = SmallSet::new();
      visiting.insert((self.module().name(), /* this alias's index */));
      let expanded_ty = self.expand_type_alias_refs(ta.as_type(), &mut visiting);
      ta.set_type(expanded_ty);  // or construct a new TypeAlias with the expanded body
      // ... existing tparams logic unchanged ...
  }
  ```
- The current alias must be in the visiting set from the start, so
  self-references remain as Refs.

**Verification:** Run full test suite. Same-module non-recursive aliases
should now produce identical types to before (Refs expanded away).
Recursive aliases should have Refs only for truly recursive references.
Check test_cyclic, test_generic_legacy, test_generic_typealiastype, and
variance/tuple/LSP tests.

## Commit 6: Change `KeyExport` to produce Ref for type aliases

**traits.rs or solve.rs (`KeyExport::solve`):**
- Pattern-match on the inner `Binding`:
  ```rust
  match &binding.0 {
      Binding::TypeAlias { name, tparams, key_type_alias, .. } => {
          let index = answers.bindings().idx_to_key(*key_type_alias).0;
          let r = TypeAliasRef {
              name: name.clone(),
              args: None,
              module_name: answers.module().name(),
              module_path: answers.module().path().clone(),
              index,
          };
          let tparams = answers.create_type_alias_params_recursive(tparams);
          Arc::new(Forallable::TypeAlias(TypeAliasData::Ref(r)).forall(tparams))
      }
      _ => {
          // existing solve_binding path for non-alias bindings
          Arc::new(answers.solve_binding(&binding.0, range, errors).arc_clone_ty())
      }
  }
  ```
- **Critical:** This must NOT call `solve_binding` for type aliases.
  `create_type_alias_params_recursive` is the lightweight tparams
  computation (already used by `create_recursive`) — it resolves TypeVar
  definitions but does not trigger alias expansion.

**Verification:** Cross-module alias tests should still pass. Cross-module
annotations now receive `Ref` instead of `Value`, resolved lazily via
`untype_alias`. Run cross-module test cases and the full suite.

## Commit 7: Remove `Variable::AliasRecursive`

With same-module and cross-module aliases both using the Ref-native
approach, `AliasRecursive` is dead code.

**solver.rs:**
- Remove `Variable::AliasRecursive(TypeAliasRef, Arc<TParams>)` variant
- Remove `finish_alias_recursive`
- Remove `fresh_alias_recursive`
- Remove the `AliasRecursive` arms in `force_var`, `pin_placeholder_type`,
  and any other match sites

**answers_solver.rs:**
- Remove the `Binding::TypeAlias` arm in `create_recursive` (or change it
  to return a simple error/unknown, since we should never hit it)

**Verification:** Full test suite. `grep -r AliasRecursive` should return
zero results (except possibly in test comments/documentation).

## Commit 8: Handle implicit legacy aliases

Implicit legacy aliases (e.g., `X = Union[str, list["X"]]` without
`: TypeAlias`) are only recognized as aliases at solve time, not at binding
time. They can't use `Binding::TypeAliasRef` because we don't know they're
aliases when processing bindings.

**Assessment:** Check how `is_definitely_type_alias_rhs` works at binding
time. If it covers `Union[...]`, `Optional[...]`, and common patterns, those
implicit aliases are already registered and will get `TypeAliasRef` treatment
via the `type_alias_names` map.

For truly implicit aliases that aren't detectable at binding time, they will
fall through to `Binding::Forward` and resolve normally. Since
`AliasRecursive` has been removed, recursive implicit aliases that aren't
detectable at binding time will hit the solver's generic cycle-breaking
instead. This may produce different (possibly worse) error messages but
should not crash.

**Action:** Run the test suite and identify any regressions in implicit
alias handling. If specific patterns need support, add them to the binding-
time detection heuristics.

## Commit 9: Audit `Ref` consumers

Verify that all code paths that consume `TypeAliasData` handle `Ref`
correctly, especially for cross-module aliases which now always arrive as
`Ref`.

**Key files to audit:**
- `subset.rs` — subtyping comparison via `get_type_alias`
- Error formatting / display code — ensure `Ref` is resolved before display
- LSP features (hover, go-to-definition, semantic tokens)
- `untype_alias` in answers_solver.rs — already handles `Ref` via
  `get_from_module`, but verify edge cases (module not found, etc.)

**Action:** Run the full test suite including LSP tests and conformance
tests. Fix any regressions.

## Commit 10 (throw-away): Stress test — flip `AnyIdx` sort order

This commit validates that our design truly decouples type alias resolution
from binding-level cycle breaking. The current SCC cycle breaker picks the
minimal `CalcId`, and `AnyIdx` ordering determines which binding type is
minimal. Currently `Key` (variant 0) sorts before `KeyTypeAlias` (variant 2),
so cycles are broken at the expanded layer.

If our design is correct, the sort order shouldn't matter — there should
be no cycles between `Key` and `KeyTypeAlias` for type aliases at all.

**binding.rs:**
- Move `KeyTypeAlias` before `Key` in the `AnyIdx` enum:
  ```rust
  pub enum AnyIdx {
      KeyTypeAlias(Idx<KeyTypeAlias>),  // was variant 2, now variant 0
      Key(Idx<Key>),                     // was variant 0, now variant 1
      KeyExpect(Idx<KeyExpect>),
      // ... rest unchanged ...
  }
  ```

**Verification:** Run the full test suite. If ANY type-alias-related tests
fail, it means we still have a hidden dependency on the sort order and the
design has a gap. If all tests pass, the design is validated.

**Important:** Do NOT land this commit. Revert it after validation. The sort
order may matter for non-alias cycles (classes, functions, etc.), and
changing it could have unintended effects elsewhere. This is purely a
stress test for the type alias changes.

## Order of Operations

The recommended implementation order is:

1. Commits 1-2: Infrastructure (no behavioral change)
2. Commits 3-5: Core same-module implementation (test after 5)
3. Commit 6: Cross-module handling (test)
4. Commit 7: Remove AliasRecursive (test)
5. Commit 8-9: Cleanup and audit (test)
6. Commit 10: Stress test (validate, then revert)

Commits 1-2 can be landed independently as safe no-ops. Commits 3-5
should be developed together but can potentially be landed as a stack.
Commit 6 depends on 3-5. Commit 7 depends on 6. Commits 8-9 are
follow-ups. Commit 10 is throw-away validation.
