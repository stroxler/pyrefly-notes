# Owner–nonowner cycles: a pencil-and-paper sketch

**Status: unchecked reasoning.** The Alloy model never makes the owner depend on
the nonowner, and it condenses fixpoint convergence into single owner phases.
This note sketches why owner-authoritative inference
([`OwnerAuthoritative`](TRACES.md#5-sketch-one-owner-does-all-lambda-inference-ownerauthoritative))
should still behave when it does. Checking that would need a model of SCC
iterations (for example in TLA+ or Quint), not this one.

## Setup

- **O**, the owner: the only binding that infers the lambda. It installs its
  contextual hint in working storage and exports the parameter type π.
- **L**, the lambda-parameter binding: depends on O and answers π.
- **N**, the nonowner: a pure reader of L.

If O's evaluation also demands N, the bindings form the cycle `N → L → O → N`,
which is solved as one SCC. A back edge reads the cold placeholder `p0` in
iteration 1 and the previous iteration's answer afterwards.

## The two entry orders

Entry at O (the owner first):

| Iteration | O | N | L |
| --- | --- | --- | --- |
| 1 (cold) | install the hint, demand N; then export π1 from n1 | n1 = f(`p0`) | back edge to O: `p0` |
| k | wipe, reinstall, demand N; then export π_k | n_k = f(π_{k-1}) | back edge: π_{k-1} |

Entry at N (the nonowner first); calls nest left to right and answers return
right to left:

| Iteration | N | L | O |
| --- | --- | --- | --- |
| 1 (cold) | n1 = f(π1) | demand O: π1 | runs nested; back edge to N: N's placeholder; exports π1 |
| k | n_k = f(π_k) | π_k | wipe, reinstall; reads N's previous answer; exports π_k |

The entries break the cycle at different bindings, so their intermediate
iterations differ: L lags one iteration from O, or is current. A converged
result satisfies the same equations either way (π = export(O), L = π,
n = f(π)), so the lambda adds **no order dependence beyond SCC solving's own**:
the final answers are entry-independent whenever the SCC's are.

## Conditions

1. **Wipe working storage at each iteration**, including cached answers for
   owned body bindings, so π_k is a function of iteration k's inputs alone.
   Otherwise every node answer can appear converged while π still depends on
   earlier iterations, and L commits a π the owner's body did not see.
2. **L is an ordinary SCC member**, so its answer is compared for convergence
   and committed with the SCC. With condition 1, equal inputs give
   π_k = π_{k-1} at convergence, so the lagged L agrees with the owner's final
   export.
3. **No publication outside the SCC commit.** A reader outside the SCC must
   never see an iteration's π.
4. **No unowned reader sees working storage**, the property
   `NoWorkingLeakAuthoritative` checks within the Alloy model's scope.

## Gaps at the source snapshot

At `2d1d8c3`:

- `Binding::LambdaParameter` resolves through `check_shortcut` (`alt/traits.rs`).
  L is not a memoized calculation, so N depends on O directly and π reaches it
  outside any convergence check (condition 2).
- The iterative SCC path calls `before_record` →
  `publish_owned_lambda_param_types` in every warm iteration, copying the
  owner's thread-local slot into the shared `Answers` map before the SCC
  commits. The discovery pass and cold iteration publish nothing, and
  `commit_final_answers` publishes no lambda types. The map is last writer
  wins and is never rolled back (condition 3).
- `ThreadState::lambda_param_types` has no reset at iteration boundaries; only
  speculative calls snapshot and restore it (`alt/call.rs`) (condition 1).

## Ordinary SCC risks

These are not specific to lambdas:

- **Hint-dependent edges.** If O demands N only under some hints, the cold
  placeholder can hide the edge until a later iteration; membership grows and
  the SCC restarts, which is correct but costly.
- **Oscillation.** π → N → O's hint → π can fail to converge. At the iteration
  limit the result depends on the last iteration.
- **Placeholder-derived hints.** A cold-iteration hint can come from N's
  placeholder, making π1 meaningless; cold-iteration errors are already
  swallowed and later iterations replace π.

## What a fixpoint model should show

That conditions 1 and 2 are necessary: dropping either lets the SCC commit an L
that disagrees with the owner's final export, and keeping both makes the
committed (O, L, N) entry-independent whenever the base SCC solver is.
