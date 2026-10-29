# Pyrefly SCC solving: specification audit

**The specifications remain a useful reference for auditing Pyrefly's design, but they are not a proof of the current implementation or of entrypoint-independent results.** The current implementation makes several important obligations explicit that the executable models omit. The models themselves also contain a progress bug and checks whose coverage is narrower than their names suggest.

This does not negate the original development result. A simplified, post-hoc specification can expose implementation mistakes by making the intended contract precise, even when it is not a complete abstraction of the implementation. That is the strongest framing for a blog post about this work.

## Scope and evidence

Audit date: 2026-10-29. Implementation references below use [Pyrefly source at `8003f9b`](https://github.com/meta/pyrefly/blob/8003f9b3d96b207c916c4a5c5ba039fb568cb857/pyrefly/lib/alt/answers_solver.rs). This file was compared with the current landed source used for the audit; its contents agree, ignoring a trailing blank line. This is a source audit, not verification of a particular released executable.

The original models are copied without modification from [`learn-specification` at `345a774`](https://github.com/stroxler/learn-specification/tree/345a7744598e1e8ab9e6d8ef161dc876c2d8c8b2/tla%2B). The six model/config/design files also agree in nonblank source with the earlier `2f77693` snapshot first examined. The original gap analysis, `fixpoint/spec-issues.md`, is historical evidence, not a current verdict. No Pyrefly code was changed, built, or tested in this audit. Independent Claude and Codex reviews supplement direct source inspection and the executable TLC checks described below.

Model references use the exact files in this directory, not the extra line separators introduced by browser rendering.

## 1. What the executable models represent

`stack/pyrefly_stack.tla` models demand-driven traversal, cycle detection, SCC merging, placeholders, and completion. `fixpoint/PyreflyFixpoint.tla` adds cold/warm phases, answer-availability sets, and repeated driving of known members.

Both models choose a graph nondeterministically at initialization and then freeze it. In the fixpoint model, `VisibleGraph(n) == graph[n]` (line 92). Nondeterministic graph selection and dependency traversal order are **not** nondeterministic edge visibility across successive solves.

The answer sets contain node identifiers, not inferred types. Neither model includes concurrent workers, shared-slot reservation, answer generations, Rust lifetimes, diagnostics, concrete convergence comparisons, or a relational property comparing outputs from different entrypoints.

`DESIGN.md` describes a planned dynamic model, including `phase_graphs` and `FullTraversalPhase`, which the executable module does not implement. `DYNAMIC_GRAPH.md` is a pipeline sketch. These documents need conspicuous status labels when read alongside the executable models.

The author reports a successful division of labor: Alloy could not scale to simulating the fixpoint process, but worked well for generating graph cases that TLC consumed as fixed inputs. The static checked-in module does not refute that historical experiment; the generator and generated-case corpus are not included in these two supplied model directories. Preserving those artifacts would make the experiment reproducible.

## 2. Where the current implementation supports the intended contract

### One local state machine, separate answer storage

The current SCC has one `SccNodeState` map, with `Fresh`, `InProgress`, `HasPlaceholder`, and `Done` ([lines 1378–1519](https://github.com/meta/pyrefly/blob/8003f9b3d96b207c916c4a5c5ba039fb568cb857/pyrefly/lib/alt/answers_solver.rs#L1378-L1519)). In the ordinary protocol, `Fresh` means queued work, not an already-live calculation; the opt-in overflow path is a candidate exception discussed below. Newly detected stack members and absorbed live frames are initialized as `InProgress` ([1598–1629](https://github.com/meta/pyrefly/blob/8003f9b3d96b207c916c4a5c5ba039fb568cb857/pyrefly/lib/alt/answers_solver.rs#L1598-L1629), [1759–1781](https://github.com/meta/pyrefly/blob/8003f9b3d96b207c916c4a5c5ba039fb568cb857/pyrefly/lib/alt/answers_solver.rs#L1759-L1781)).

The regression `test_published_answer_during_cycle_expansion_preserves_live_caller` records why this distinction matters: treating an active caller as Fresh can let a later shared-answer shortcut remove that caller from the SCC. The current test exercises the expansion and ownership handoff deterministically, without timing-dependent threads ([4295–4359](https://github.com/meta/pyrefly/blob/8003f9b3d96b207c916c4a5c5ba039fb568cb857/pyrefly/lib/alt/answers_solver.rs#L4295-L4359)).

### Membership expansion invalidates a pass, but does not immediately destroy its storage

`SccAnswers::NeedsDemotion` retains constituent current and previous generations while active calls unwind ([386–524](https://github.com/meta/pyrefly/blob/8003f9b3d96b207c916c4a5c5ba039fb568cb857/pyrefly/lib/alt/answers_solver.rs#L386-L524)). The driver checks this state **before** convergence or the five-iteration cutoff, discards those generations, and cold-restarts the enlarged SCC ([3247–3273](https://github.com/meta/pyrefly/blob/8003f9b3d96b207c916c4a5c5ba039fb568cb857/pyrefly/lib/alt/answers_solver.rs#L3247-L3273)). Advancing or committing an SCC requiring demotion is explicitly rejected.

Consequently, seeing `max(iteration)` in `Scc::merge` is no longer sufficient evidence of the historical stale-iteration bug. That number describes a doomed pass, not permission to publish it. The correct obligation is: retained answers remain confined to unwinding work, and no result from the invalidated pass survives the required restart.

This is not a literal implementation of the model's immediate `MergedPhase == 0` reset. A closer model needs a distinct invalidated/unwinding state, with restart at a safe boundary. Simply deleting the retained generations would confuse semantic invalidation with memory lifetime. The no-surviving-result rule is an obligation, not a claim that every auxiliary side effect obeys it: the contextual lambda-type publication candidate below bypasses this protocol.

### Ownership expresses suspended continuations

`SccOwner::{Phase0, Driver, Caller}` separates initial discovery, an iterative driver, and an absorbed active caller ([1522–1533](https://github.com/meta/pyrefly/blob/8003f9b3d96b207c916c4a5c5ba039fb568cb857/pyrefly/lib/alt/answers_solver.rs#L1522-L1533)). A nested driver leaves a merged SCC for its older owner; a driver that has absorbed its caller yields until that caller finishes ([1343–1361](https://github.com/meta/pyrefly/blob/8003f9b3d96b207c916c4a5c5ba039fb568cb857/pyrefly/lib/alt/answers_solver.rs#L1343-L1361)). These are real obligations absent from the models.

### Completion and publication are separate

Anchor arithmetic releases a phase-zero/caller-owned SCC only at the appropriate recursive boundary. Driver-owned SCCs are excluded from that completion path. Known Fresh members are explicitly driven, and final answer collection checks matching membership and Done states ([931–953](https://github.com/meta/pyrefly/blob/8003f9b3d96b207c916c4a5c5ba039fb568cb857/pyrefly/lib/alt/answers_solver.rs#L931-L953), [1784–1835](https://github.com/meta/pyrefly/blob/8003f9b3d96b207c916c4a5c5ba039fb568cb857/pyrefly/lib/alt/answers_solver.rs#L1784-L1835), [3173–3195](https://github.com/meta/pyrefly/blob/8003f9b3d96b207c916c4a5c5ba039fb568cb857/pyrefly/lib/alt/answers_solver.rs#L3173-L3195)). Anchor arithmetic is therefore a proof obligation, not inherently a bug merely because the specification uses an explicit all-done predicate.

After iteration, `force_idx` rereads the shared result so an outside caller receives the final answer, not the pre-iteration answer. Shared-slot reads can reuse another worker's published result; the relevant distinction is published versus provisional, not an absolute ban on cross-thread reads ([2513–2579](https://github.com/meta/pyrefly/blob/8003f9b3d96b207c916c4a5c5ba039fb568cb857/pyrefly/lib/alt/answers_solver.rs#L2513-L2579)).

## 3. Confirmed gaps in the model

### A reachable unfinished deadlock passes the supplied safety configuration

Use the static graph:

```
a -> {b, c}
b -> {b}
c -> {b}
```

Start at `a`, discover and finish `b`'s self-cycle, leaving its SCC ready for iteration. The model then permits `a` to descend into `c` before that child SCC completes. Transitioning `b` to phase 1 makes it Fresh but off-stack. Now `c` cannot finish or descend into `b`; cycle detection has no live target position; and driving `b` requires a stack depth of 1 while the actual depth is 2.

TLC reproduced this eight-state counterexample with all original safety invariants enabled. `DeadlockProbe` only fixes this graph and permits terminal stuttering after `Finished`, so intended termination is not misreported as deadlock.

This is a **model bug, not a demonstrated Rust deadlock**. Rust invokes `iterative_resolve_scc` before returning from the dependency lookup ([2559–2561](https://github.com/meta/pyrefly/blob/8003f9b3d96b207c916c4a5c5ba039fb568cb857/pyrefly/lib/alt/answers_solver.rs#L2559-L2561)). The model admits an impossible caller continuation. Its config disables deadlock checking and comments out `Liveness`, concealing the problem.

### `AllAnswersAtCommit` is vacuous

The predicate requires an active final-phase SCC with all members Done and off-stack (fixpoint lines 615–623). But the last member's `FinishCalculation` directly commits and removes the SCC, instead of first materializing that all-Done state (lines 416–440).

A reachability probe confirms the antecedent is never reached in the supplied three-node scope. It also follows from the transition structure: entering the final phase resets members to Fresh; finishing the last member removes the SCC. Checking this invariant cannot establish answer completeness at the publication event.

Repair it as an assertion on the committing action, including the finishing member's new answer, or split answer recording from publication. Add a positive reachability witness for the state/event the assertion checks.

### The static scope does not exercise iterative membership expansion

A second probe confirms that none of the original three-node executions expands an affected SCC already at a positive phase. A deliberate mutation preserving the maximum constituent phase rather than resetting to zero also passes every original configured property, with the same reachable-state count.

That is evidence of a blind spot, not evidence that demotion is unnecessary. Dynamic visibility is exactly what makes late membership discovery important in the implementation. Generated schedules should explicitly witness this event before a reset property is treated as meaningful regression coverage.

### Other checks have narrower meanings

`NoCrossSccLeakage` records placeholder and previous-answer reads whose actions already require same-SCC membership. It does not record all reads of Done answers and resets its history on merges and phase transitions. `PrevAnswersComplete` is useful answer-availability bookkeeping, not a theorem about inferred values. `CommittedSccMatchesTruth` checks membership on entering the final phase, not specifically at publication.

The model also preserves existing Done states during a merge while clearing answer sets. This creates an abstraction mismatch: a Done node can lack a modeled current answer. The actual implementation retains those generations during unwind. A revised model should explicitly couple node state to answer availability.

## 4. State the discovery assumption at the publication boundary

A precise version of the intended assumption is:

> For every admitted execution and entrypoint, no strict subcomponent of the intended SCC can reach publication: the complete component is discovered before the first convergence or iteration-budget exit that would otherwise commit it. Any observed membership expansion invalidates the current pass and requires a cold restart.

The graph algorithm cannot establish this for arbitrary nondeterministic edge visibility. Proving it for Python bindings is a separate language-semantics problem, outside this audit.

The timing matters. Consider a full graph `a -> {a,b}`, `b -> {a}`. From `a`, expose only its self-edge through discovery and passes 1–2, and expose the edge to `b` from hypothetical pass 3 onward. Equal answers in passes 1 and 2 allow an early commit of `{a}`. The exposure schedule is monotone and would reveal everything within five continued passes, but the driver has already stopped. Delaying exposure until hypothetical pass 6 gives the budget version.

These are abstract schedules, **not Python reproducers**. They explain why counterfactual eventual exposure is weaker than discovery before actual publication. An edge made available to a node that is never subsequently driven has not been discovered. Without monotonicity or retained-edge closure, a union of edges exposed in different passes is weaker still.

## 5. Concurrency and value semantics remain separate obligations

The real reservation protocol orders members by `CalcId`, reserves before publishing, and publishes in reverse order. Identical competing SCC batches serialize on their lowest member. This is not a single machine-atomic update of all slots, and the implementation explicitly preserves a weaker fallback for workers reaching publication with non-identical membership ([3063–3117](https://github.com/meta/pyrefly/blob/8003f9b3d96b207c916c4a5c5ba039fb568cb857/pyrefly/lib/alt/answers_solver.rs#L3063-L3117)). The fallback may mix worker results and is explicitly not proven correct. That is consistent with treating completeness as an assumption, not resolving it with a graph-only proof.

Likewise, fixed iteration count can model structural protocol safety, but cannot prove early convergence soundness when answer values and their influence on edge discovery are absent. Deterministic root selection and restart help make outcomes reproducible; proving equality across entrypoints additionally requires deterministic solving/equality/side effects under an adequate dependency model.

## 6. Implementation candidates and engineering follow-ups

The independent code review identified three concrete source-level candidates. The control/data-flow facts below were checked against the source, but none has a newly executed Rust or Python reproducer in this audit. They should be tracked separately from the TLC-confirmed model failures.

1. **Provisional contextual lambda types escape the answer commit protocol.** Every warm iteration calls `K::before_record`, including non-final passes ([2917–2927](https://github.com/meta/pyrefly/blob/8003f9b3d96b207c916c4a5c5ba039fb568cb857/pyrefly/lib/alt/answers_solver.rs#L2917-L2927)). For `Key`, this publishes owned lambda-parameter types to a shared last-writer-wins map; later independent lookups force the owner and fall back to that map ([2305–2328](https://github.com/meta/pyrefly/blob/8003f9b3d96b207c916c4a5c5ba039fb568cb857/pyrefly/lib/alt/answers_solver.rs#L2305-L2328)). A losing worker can still finish an earlier pass after another worker publishes the owner, overwriting the associated parameter types with its provisional values. Unlike errors and traces, this side effect is not tied to winning the owner's reservation. This is the highest-priority isolation candidate: add a controlled two-worker regression and defer these side effects with the corresponding answer generation/slot.

2. **Opt-in depth overflow can strand a queued SCC member.** The depth check runs before pushing a frame ([2543–2547](https://github.com/meta/pyrefly/blob/8003f9b3d96b207c916c4a5c5ba039fb568cb857/pyrefly/lib/alt/answers_solver.rs#L2543-L2547)). The placeholder handler can upgrade a Fresh, already-known SCC member to HasPlaceholder even though no calculation for it started ([1676–1697](https://github.com/meta/pyrefly/blob/8003f9b3d96b207c916c4a5c5ba039fb568cb857/pyrefly/lib/alt/answers_solver.rs#L1676-L1697)). Fresh-only driving then skips it, while final collection requires Done. Repeated overflow on that queued member can therefore lead to a final-collection panic. This needs an explicit overflow/aborted-calculation state or equivalent handling, not an assumption that every placeholder corresponds to a live frame. Reachability through real Python bindings remains to be demonstrated.

3. **Cross-module non-convergence diagnostics use the driver's collector.** The cross-module branch constructs a collector for the member but extends `self.base_errors` rather than publishing to that member's target collector ([3314–3326](https://github.com/meta/pyrefly/blob/8003f9b3d96b207c916c4a5c5ba039fb568cb857/pyrefly/lib/alt/answers_solver.rs#L3314-L3326)). `ErrorCollector::extend` discards incoming errors when its receiver has `ErrorStyle::Never`, unlike ordinary cross-module SCC errors routed through the target load. An inactive driving module can therefore suppress a member's diagnostic; a cross-module regression should establish the user-visible behavior. Associate diagnostics with the winning member's side effects rather than a batch-wide `did_commit` flag.

These candidates do not require arbitrary nondeterministic edge visibility. They illustrate the benefit of applying the specification's *intent* beyond its modeled variables, while keeping reproducibility claims honest.

For maintainability, the old terminology and redundant top-SCC membership branch should be cleaned up independently of semantic changes. `detected_at` is used to identify a merge target, despite being described as debug-only. Keep membership, phase invalidation, continuation ownership, and answer/side-effect publication as separate concepts with explicit interfaces.

For performance, preserve the published-answer fast path and avoid whole-component scans on non-SCC lookups. Ordered Fresh-member selection can require repeated map scans; a driver with an unrelated outer caller also goes through the nonmember-reentry helper before each driven root. Those are inspection-based cost observations, not measured regressions. Doomed-pass completion is a deliberate trade-off that can discover more members before restarting. A future extraction/refactor should benchmark both ordinary acyclic solving and large SCCs rather than optimizing only the latter.

## 7. Executed checks and reproducibility

Using TLC version `2026.03.12.220102` (`0a0bffb`):

- Original fixpoint config: 343 initial graphs; **134,716 generated / 45,878 distinct states**, complete, no violation of configured checks.
- Three-node stack config: **41,425 generated / 14,948 distinct states**, complete, no configured invariant violation.
- Final-all-Done and positive-phase-expansion absence probes: complete, **45,878 distinct states**, confirming both absences in the configured scope.
- Deliberately incorrect phase-preserving merge mutation: complete, **45,878 distinct states**, no configured violation.
- Fixed unfinished-deadlock witness: **eight-state counterexample**, TLC exit 11, all original safety invariants retained.
- Original four-node stack config: **incomplete** after a four-minute bound. The last progress sample reported over nine million distinct states; no completed verification claim is made for it.

The final runner repeats the small baseline and all audit witnesses against the exact copied sources. Its success means the **expected audit outcomes** reproduced, including the model deadlock and the undetected mutation; it does not label those undesirable behaviors correct. The original models remain unchanged.

## 8. Sharing the result and trying Quint

The blog's central claim can be strong without being a proof claim: a compact, machine-checkable statement of intent gave agents a reference they could use to locate subtle implementation/design mismatches that ordinary code review had missed. The reported half-dozen fixes and disappearance of stubborn nondeterminism are the author's development experience. Historical repeated-run results are evidence of observed reliability improvement, not a universal nondeterminism theorem or a reconstructed causal proof for every fix.

For a shareable case study, preserve one concrete before/after bug, its violated contract, the code fix and regression, and the observed corpus behavior. Label three evidence layers separately: checking the model; auditing code against it; and testing the implementation. Include the explicit discovery assumption rather than burying it.

Quint is a plausible follow-up, not necessary to validate the original success. Its [simulator documentation](https://quint.sh/docs/simulator) describes sampled executions, invariant checking, sample/step bounds, and seed replay; it explicitly says simulation is not verification and does not support temporal properties. Its [model-checker documentation](https://quint.sh/docs/model-checkers) supports TLC for explicit-state checking and Apalache for bounded symbolic checking.

A focused comparison would keep the TLA+ baseline and port one revised, dynamic-membership protocol model. Check tiny scopes exhaustively; simulate larger generated cases with fixed seeds; save failing traces as regressions. Include late expansion, driver/caller handoff, and pre-publication completeness witnesses. For progress properties, retain model checking or explicitly bounded progress monitors: larger safety simulations alone will not establish eventual completion. No Quint port or performance benchmark was performed in this audit.
