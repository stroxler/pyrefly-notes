# Competing lambda inference contexts

A **native Alloy 6 temporal** system sketch exploring publication authority,
inference attempts, ThreadState working storage, and owner demand. Mutable `var`
fields describe state; primed action equations, `init`, and `always step` describe
behavior. Temporal assertions express the contract. There is no manual time index.

Read [lambda_inference.als](lambda_inference.als) for the model and
[TRACES.md](TRACES.md) for checked executions, and
[OWNER_CYCLES.md](OWNER_CYCLES.md) for unchecked reasoning about an owner that
depends on its nonowner. `witnesses.als` pins short witnesses;
`expectations.json` records exact temporal scopes and required outcomes.

## Run

Use Python 3, Java 17+, and the pinned Alloy 6.2.0 jar:

```sh
python3 check.py --java /path/to/java --jar /path/to/alloy-6.2.0.jar
python3 -m unittest -v test_check
```

The jar is not checked in. Pass `--jar`, set `ALLOY_JAR`, or place it at the
ignored `.tools/alloy-6.2.0.jar`; `check.py` rejects any other SHA-256 and
downloads nothing. Glucose is the default; `--solver sat4j` uses
the portable Java solver. The `.als` files also open in Alloy's GUI. Ignored `out/`
holds receipts, XML lassos, and readable traces. Tool errors, timeouts, incomplete
native traces, invalid loops, and unexpected outcomes make the runner fail.

## Contract and checked scope

One module, lambda, parameter, owner attempt, nonowner attempt, and optional other
read; one or two **ThreadState objects**, not OS threads. Two-state cases exercise
fresh installed slots, not concurrency. Main checks use exactly
16 native lasso states, with stutter padding admitting shorter prefixes. Shortest
witness controls use ranged upper bounds. Two-execution comparisons use one
shared temporal clock, independent step/stutter choices, and completion of all
three attempts in both executions.

Top-level attempts are serialized across ThreadStates. An uncomputed owner runs
synchronously on the caller's stack; recursive demand returns a placeholder
without immediate publication. Suspend/resume represents only this same-state
nested call. Duplicate owner solves and SCC commit-reservation waits are excluded,
not modeled as ordinary cross-thread blocking.

`Fixed` selects installed-first under any enclosing matching inference frame,
published-first otherwise; `Old` always selects installed-first. `AttemptLocal`
directly selects the expression attempt's hint: its controls are **definitional**,
not verification of frame storage. A SAT nonvacuity control admits two completed
reference executions with distinct owner-first/nonowner-first orders.
`OwnerOnly` is a first sketch: a nonowner attempt installs no hint and reads
the owner's publication, giving up its own contextual hint. `OwnerAuthoritative`
goes further: only the owner infers the lambda, and a nonowner is a pure reader
of the owner's binding. Inside the unfinished owner solve, an unowned reader gets
a cycle-break placeholder and an owned body binding reads working storage.

Within scope, publication authority and fixed independent reads **after
publication, outside inference** hold. Old independent reads and fixed nonowner
own-hint isolation fail. `OtherAlwaysPublishedFixed` fails in `RecursiveOther`,
with both no publication and an enclosing owner inference frame. Abstract result
schedule independence fails for `Fixed` and holds for the reference and for
`OwnerOnly`, whose nonowner reads always equal the publication. Under
`OwnerAuthoritative`, every read outside the owner's evaluation equals the
publication, and no unowned reader inside it sees working storage; a nested
nonowner's placeholder is a cycle left to SCC solving. Publication
is always `IntHint` **by construction**;
publication-value correctness and determinism are not established.

## Source snapshot and limits

Snapshot: `2d1d8c3f320c53c36efcd13d661740fb1f3cf0eb`; old resolver precedence:
`9cafdd1f8473ffee56d29b605ccd279e76869534`. Source mapping is in model comments.
Owner identity is an `Idx<Key>`, not necessarily an assignment key.

Owner phases condense synchronous SCC convergence, which can follow an ordinary
self-parameter demand. SCC iterations, cold paths skipping publication, older
driver deferred publication, competing owner solves, last-writer publication
versus first-writer answers, repeated/overload hints, and mutable solver variables
are omitted. So are nonowner inference nested inside Owner (a nonowner reaches
the owner's solve only as an `OwnerAuthoritative` pure reader), Other nested inside
Nonowner, reads before lambda entry, narrowing/shared fragment caches, diagnostics,
and incremental changes. Owner start merges solve start with lambda entry.

The observed overwrite uses implicit versus explicit `Any`, not `int` versus
`Any`. The result mapping is abstract sensitivity, not proof of final real `C.x`
nondeterminism. Checks support exploration, not a correctness proof. There is no
model-to-code refinement, unbounded proof, liveness claim, or all-fragment isolation
claim.
