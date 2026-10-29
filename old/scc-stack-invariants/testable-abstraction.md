# Toward a Testable SCC Graph Abstraction

This document records thinking on how to decouple the SCC/fixpoint graph
traversal logic from `AnswersSolver` so that it can be tested independently
of the type checker. It should be read alongside `suspected-bug.md`.

## Why testability matters here

The stop-gap fix in `set_iteration_node_done` and `mark_iteration_changed`
(silent early-return instead of panic) is almost certainly safe in the
specific scenario we identified. But "almost certainly" is doing a lot of
work. The root cause — stale `anchor_pos` triggering a premature SCC pop
in `on_calculation_finished` — involves a precise interaction between:

- the `CalcStack` depth at the time Phase-0 discovery runs,
- the depth at the time the iterating SCC is re-pushed,
- and whatever new cycles form inside `K::solve` during iterative solving.

Without a test that actually exercises this causal chain, we cannot verify
the fix, and we cannot verify any future proper fix (Option A or Option B
from `suspected-bug.md`) either. The existing unit tests in `answers_solver.rs`
manipulate `scc_stack` directly, bypassing `on_calculation_finished` and
`push_scc` entirely, so they do not exercise the mechanism at all.

The deeper problem: in LSP mode this bug is reachable only because
dependencies of SCC members are not yet cached, which means the real scenario
requires a realistic computation graph. Constructing that graph with actual
Python bindings is expensive; constructing it with a lightweight synthetic
graph would be straightforward — if the graph-traversal logic were abstracted.

## Where the coupling actually lives

Reading `answers_solver.rs`, the coupling is narrower than it appears:

**`CalcStack` is already largely self-contained.** Its fields are
`RefCell<Vec<CalcId>>`, `RefCell<Vec<Scc>>`, and two auxiliary maps.
All of its methods (`push`, `pop_and_drain_completed_sccs`,
`on_scc_detected`, `on_calculation_finished`, `mark_iteration_changed`,
`set_iteration_node_done`, etc.) treat `CalcId` as an opaque ordered key.
None of them touch Python types, bindings, or the type solver.

**The two real coupling points are:**

1. **`CalcId` carries `Bindings`.** The struct is
   `CalcId(pub Bindings, pub AnyIdx)`. For the graph-traversal machinery,
   only the identity matters — something with `Clone + Ord + Hash` is
   sufficient. The `Bindings` arc pulls in the full module/binding data
   everywhere `CalcId` is used.

2. **The "solve a node" mechanism is entangled with `AnswersSolver`.**
   Today `K::solve` takes `&AnswersSolver` as its receiver, which is how
   it calls `get_idx` on dependencies. All the type-checker-specific logic
   (error collectors, deep-forcing, `LoopPhi` bypass, `answers_equal`)
   lives in `AnswersSolver::calculate_and_record_answer` and
   `calculate_and_record_answer_iterative`. This is the driver loop.

The iterative convergence machinery (`drive_all_iteration_members`,
`iterative_resolve_scc`, `commit_final_answers`) also lives in
`AnswersSolver`, not in `CalcStack`. Moving it alongside `CalcStack`
in a clean abstraction would make the driver loop the main thing to
inject or parameterize.

## What a clean abstraction looks like

The target is a `SccDriver<K, V>` that owns a `CalcStack<K>` and a per-node
cache, and accepts a user-supplied "solve" closure:

```rust
trait DependencyGraph {
    type Key: Clone + Ord + Hash + Debug;
    type Value: Clone + PartialEq;

    /// Compute the value for `key`. May call `get` on dependency keys.
    fn solve(&self, key: &Self::Key, get: &dyn Fn(&Self::Key) -> Self::Value)
        -> Self::Value;

    /// Placeholder value used to break cycles on first encounter.
    fn placeholder(&self, key: &Self::Key) -> Self::Value;
}

struct SccDriver<G: DependencyGraph> {
    graph: G,
    cache: HashMap<G::Key, G::Value>,
    calc_stack: CalcStack<G::Key>,
}

impl<G: DependencyGraph> SccDriver<G> {
    pub fn get(&self, key: &G::Key) -> G::Value { ... }
}
```

The inner `get` callback passed to `solve` is just a closure over
`SccDriver::get`. The re-entrancy this requires (calling `get` while `get`
is already on the call stack) is exactly what the existing `RefCell`-based
`CalcStack` design was built for. A closure-based driver could use the same
`RefCell` approach with no architectural change.

For a test graph, this becomes trivially expressible:

```rust
struct TestGraph {
    edges: HashMap<u32, Vec<u32>>,
}

impl DependencyGraph for TestGraph {
    type Key = u32;
    type Value = u32;

    fn solve(&self, key: &u32, get: &dyn Fn(&u32) -> u32) -> u32 {
        for dep in self.edges.get(key).unwrap_or(&vec![]) {
            get(dep);
        }
        *key
    }

    fn placeholder(&self, _key: &u32) -> u32 { 0 }
}
```

## What this unlocks for testing

With a `SccDriver<TestGraph>`, we can write tests that actually exercise the
root cause mechanism described in `suspected-bug.md`. Concretely, the
scenario that triggers the bug is:

1. Nodes A and B form an SCC: A depends on B, B depends on A.
2. `iterative_resolve_scc` drives A; A's solve calls `get(X)`.
3. X depends on Y, Y depends on X — a new Phase-0 cycle forms while the
   iterating SCC-AB is on `scc_stack`.
4. `on_calculation_finished` for the XY anchor fires; the completion loop
   checks SCC-AB's stale `anchor_pos` and pops it prematurely.
5. A nested `iterative_resolve_scc` commits SCC-AB; `scc_stack` is now empty.
6. Control returns to A's `calculate_and_record_answer_iterative`;
   `mark_iteration_changed` and `set_iteration_node_done` find no SCC.

With a synthetic graph, constructing this scenario is just a matter of
defining the right adjacency list and the right evaluation order for A's
solve. No Python source, no bindings, no module loading.

Such a test would:
- Exercise `on_calculation_finished`'s completion loop (the actual bug site).
- Exercise `push_scc` with the stale `anchor_pos` (the root cause).
- Verify that the stop-gap fix causes graceful return rather than panic.
- Serve as a regression test for any future proper fix (Option A or B).

The tests in D96362924 do none of this: they directly pop `scc_stack` by
hand and assert that the functions panic, which is both wrong after the fix
(the `#[should_panic]` would not fire) and untethered from the actual
trigger mechanism.

## Effort estimate and phasing

**Extracting `CalcStack` to be generic over a key type**: mostly mechanical.
Replace `CalcId` with `K: Clone + Ord + Hash` throughout the struct and its
methods. `Scc`, `SccIterationState`, and `IterationNodeState` use
type-erased `Arc<dyn Any + Send + Sync>` for values, which can stay as-is
or be made generic over a value type separately.

**Providing `SccDriver` and the `DependencyGraph` trait**: moderate effort.
The driver loop (`iterative_resolve_scc`, `drive_all_iteration_members`,
`commit_final_answers`) currently lives in `AnswersSolver`. Lifting it into
a free-standing driver with an injected solve callback is the main work.

**Keeping `AnswersSolver` working**: the existing `AnswersSolver` becomes an
implementation of `DependencyGraph` where `K::solve` is dispatched to the
type checker's binding solver. Functionally unchanged from the outside.

This is a significant refactor but not a speculative one: every piece of
the extracted logic already exists, it just needs its coupling to
`Bindings` and `AnyIdx` severed. The refactor does not change any
observable behavior — it only changes what can be tested.

A reasonable phasing:
1. Introduce the `DependencyGraph` trait and `SccDriver` in a new module,
   with `AnswersSolver` as the only implementation (no behavior change).
2. Write the synthetic graph tests for the stale-`anchor_pos` scenario.
3. Implement and test the proper fix (Option A or B) against those tests.
4. Remove the stop-gap early-returns once the proper fix is verified.
