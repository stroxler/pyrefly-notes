# Dynamic Graph Pipeline Sketch

## Goal

Keep the algorithm model focused by moving dynamic-graph generation into a separate step.
Use Alloy to generate valid dynamic dependency schedules, then run TLC against those schedules as constants.

## High-Level Flow

1. Read a single pipeline config (YAML/JSON) with model size and generation knobs.
2. Run Alloy on a generator model that emits one valid `full_graph` plus `deps_by_solve`.
3. Convert Alloy output to a TLA constants file (or cfg fragment).
4. Run TLC on `PyreflyFixpoint.tla` with those constants.
5. Collect pass/fail + counterexample artifacts.

## Data Model

Core generated constants:

- `Nodes`
- `MaxSolve`
- `full_graph : [Nodes -> SUBSET Nodes]`
- `deps_by_solve : [Nodes -> [0..MaxSolve -> SUBSET Nodes]]`
- `TrueSccSets` (optional, if precomputed externally)

Runtime state in TLA (already/mostly present conceptually):

- `solve_ix : [Nodes -> Nat]` (increment when node is solved)
- `VisibleDeps(n) == deps_by_solve[n][Min(solve_ix[n], MaxSolve)]`

## Generator Constraints

Alloy generator should enforce these hard constraints:

1. Soundness:
   `deps_by_solve[n][k] ⊆ full_graph[n]` for all `n, k`.

2. Optional monotonicity (recommended):
   `deps_by_solve[n][k] ⊆ deps_by_solve[n][k+1]`.

3. Non-true-SCC nodes are complete immediately (your condition a):
   if `n` is not in any `TrueSccSets` member, then `deps_by_solve[n][0] = full_graph[n]`.

4. True SCC must trigger fixpoint entry (your condition b):
   for each `S ∈ TrueSccSets`, phase/solve-0 visible intra-SCC edges must include at least one directed cycle in `S`.
   Practical check: for each `S`, there exists `n ∈ S` reachable from itself via `deps_by_solve[*][0]` restricted to `S`.

5. True SCC eventually fully exposed during fixpoint horizon (your condition c):
   for each `S ∈ TrueSccSets`, each `n ∈ S`, and each `d ∈ full_graph[n]`, there exists `k ∈ 0..N` such that `d ∈ deps_by_solve[n][k]`.

## Suggested Artifacts

- `alloy/dyn_graph_gen.als`: generator model.
- `scripts/gen_dynamic_graph.sh`: one-shot pipeline entrypoint.
- `scripts/alloy_json_to_tla.py`: converts Alloy JSON to TLA constants.
- `generated/case_<id>.cfg.inc`: TLC include fragment with generated constants.
- `generated/case_<id>.json`: raw graph/schedule for debugging.
- `runs/<timestamp>/`: TLC stdout, stats, and counterexample traces.

## TLC Integration

Two practical options:

1. Template cfg:
   maintain `PyreflyFixpoint.generated.cfg.tmpl` and render constants in place.

2. Constant override file:
   keep base cfg static, inject generated constants via separate include/concat step.

For each generated case:

1. materialize cfg
2. run TLC
3. archive result and failing trace (if any)

## Pipeline CLI Sketch

`./scripts/gen_dynamic_graph.sh --nodes 4 --max-deps 2 --max-solve 4 --iterations 50 --seed 123`

Outputs:

- list of generated cases
- which cases passed/failed invariants/properties
- paths to failing traces

## Validation Strategy

1. Start with tiny scopes (`|Nodes|=3` or `4`) and a small number of generated cases.
2. Ensure generator never emits invalid schedules (explicit validator script).
3. Add regression corpus: store a few historically interesting schedules and run them on every change.
4. Scale case count once runtime is predictable.

## Open Design Choices

1. Whether `TrueSccSets` is generated in Alloy or recomputed in TLA from `full_graph`.
2. Whether monotonicity is required or just allowed.
3. Whether condition (c) must hold by exactly `N` or by any `k ≤ N`.
4. Whether to require per-node coverage guarantees or only SCC-level guarantees.

## Why This Split Helps

- Keeps `PyreflyFixpoint.tla` focused on solver correctness.
- Makes dynamic-graph assumptions explicit and reviewable.
- Lets us evolve generator constraints independently of solver logic.
