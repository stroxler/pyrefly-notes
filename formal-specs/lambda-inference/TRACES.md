# Checked lambda-inference traces

These tables come from actual **native Alloy 6** instances of the named predicates,
not imagined same-thread interleavings. `Step` removes unchanged stutters;
`Native state` preserves the checker's original position. `int` and `Any` are
aliases for `IntHint` and `AnyHint`. A dash means no installed/published/read value.

The roles are **Owner** (expression inference and publication authority),
**Nonowner** (another inference of that expression), and **Other** (a fragment or
independent parameter read). `Working` is the shared slot in this execution's
ThreadState; it is not an attempt-local slot. Only one parameter is modeled.

## 1. Minimum nested overwrite

Command: `run NestedOverwrite` in `witnesses.als`. The checked lasso has **10 states**,
loops at state **9**, and contains **9 meaningful transitions**. The ranged
`NestedOverwriteTooShort` command finds no witness with at most **9 states**.

| Step | Native state | Action | Reader/attempt | Nonowner own hint | Working | Published | Read result |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 0 | 0 | Initial | — | — | — | — | — |
| 1 | 1 | Start | Nonowner | Any | Any | — | — |
| 2 | 2 | ForceOwner | Nonowner | Any | int | — | — |
| 3 | 3 | RecursiveOwner | Owner | Any | int | — | — |
| 4 | 4 | Read | Owner | Any | int | — | int |
| 5 | 5 | ExitInference | Owner | Any | int | — | — |
| 6 | 6 | Publish | Owner | Any | int | int | — |
| 7 | 7 | Finish | Owner | Any | int | int | — |
| 8 | 8 | Resume | Nonowner | Any | int | int | — |
| 9 | 9 | Read | Nonowner | Any | int | int | int |

The nonowner chooses `Any` at entry. Its parameter read first demands the owner,
which runs synchronously on the **same ThreadState**, overwriting the working
slot with `int`. The outer attempt is suspended; it cannot execute arbitrary
steps while the nested owner is active. The owner exits its inference guard,
publishes, and returns without restoring the slot. The resumed nonowner then
reads `int`, not its own hint. `NonownerOwnHintFixed` finds this local-contract
failure within the main scope.

## 2. Old independent-read leak and fixed contrast

Commands: `run OldReadLeak` and `run FixedReadAfterNonowner`. Both generated
witnesses have **14 states**, with a final-state self-loop. `OldReadLeakTooShort`
is UNSAT at at most **13 states**, so the old leak needs **13 meaningful
transitions** in this model. No shortest-bound claim is made for the fixed contrast.

The old witness is:

| Step | Native state | Action | Reader/attempt | Working | Published | Read result |
| --- | --- | --- | --- | --- | --- | --- |
| 0 | 0 | Initial | — | — | — | — |
| 1 | 1 | Start | Owner | int | — | — |
| 2 | 2 | RecursiveOwner | Owner | int | — | — |
| 3 | 3 | Read | Owner | int | — | int |
| 4 | 4 | ExitInference | Owner | int | — | — |
| 5 | 5 | Publish | Owner | int | int | — |
| 6 | 6 | Finish | Owner | int | int | — |
| 7 | 7 | Start | Nonowner | Any | int | — |
| 8 | 8 | CachedOwner | Nonowner | Any | int | — |
| 9 | 9 | Read | Nonowner | Any | int | Any |
| 10 | 10 | Finish | Nonowner | Any | int | — |
| 11 | 11 | Start | Other | Any | int | — |
| 12 | 12 | CachedOwner | Other | Any | int | — |
| 13 | 13 | Read | Other | Any | int | Any |

The fixed contrast is independently generated with the same observed read inputs:
owner and nonowner are complete, no inference frame is active, working storage
contains the nonowner's `Any`, and the owner publication is `int`.

| Native witness | Working | Published | Independent read |
| --- | --- | --- | --- |
| `OldReadLeak` | Any | int | Any |
| `FixedReadAfterNonowner` | Any | int | int |

Thus `IndependentAfterPublicationOld` has a counterexample, while
`IndependentAfterPublicationFixed` has none within the checked scope. This
establishes the modeled precedence rule, not correctness of the published value.

## 3. Two completed same-input schedules

Both following witnesses use `Fixed`, one ThreadState, owner hint `int`, nonowner
hint `Any`, and an Other read outside inference. All three attempts complete.
The commands pin distinct initial attempts and exclude a nested Other read for
these displayed schedules. Each actual lasso has **16 native states**, ending in
a final-state loop; the table omits one unchanged stutter.

### Owner first: `run OwnerFirst`

| Step | Native state | Action | Reader/attempt | Working | Published | Read result |
| --- | --- | --- | --- | --- | --- | --- |
| 0 | 0 | Initial | — | — | — | — |
| 1 | 1 | Start | Owner | int | — | — |
| 2 | 3 | RecursiveOwner | Owner | int | — | — |
| 3 | 4 | Read | Owner | int | — | int |
| 4 | 5 | ExitInference | Owner | int | — | — |
| 5 | 6 | Publish | Owner | int | int | — |
| 6 | 7 | Finish | Owner | int | int | — |
| 7 | 8 | Start | Nonowner | Any | int | — |
| 8 | 9 | CachedOwner | Nonowner | Any | int | — |
| 9 | 10 | Read | Nonowner | Any | int | Any |
| 10 | 11 | Finish | Nonowner | Any | int | — |
| 11 | 12 | Start | Other | Any | int | — |
| 12 | 13 | CachedOwner | Other | Any | int | — |
| 13 | 14 | Read | Other | Any | int | int |
| 14 | 15 | Finish | Other | Any | int | — |

### Nonowner first: `run NonownerFirst`

| Step | Native state | Action | Reader/attempt | Working | Published | Read result |
| --- | --- | --- | --- | --- | --- | --- |
| 0 | 0 | Initial | — | — | — | — |
| 1 | 1 | Start | Nonowner | Any | — | — |
| 2 | 2 | ForceOwner | Nonowner | int | — | — |
| 3 | 3 | RecursiveOwner | Owner | int | — | — |
| 4 | 4 | Read | Owner | int | — | int |
| 5 | 5 | ExitInference | Owner | int | — | — |
| 6 | 6 | Publish | Owner | int | int | — |
| 7 | 7 | Finish | Owner | int | int | — |
| 8 | 9 | Resume | Nonowner | int | int | — |
| 9 | 10 | Read | Nonowner | int | int | int |
| 10 | 11 | Finish | Nonowner | int | int | — |
| 11 | 12 | Start | Other | int | int | — |
| 12 | 13 | CachedOwner | Other | int | int | — |
| 13 | 14 | Read | Other | int | int | int |
| 14 | 15 | Finish | Other | int | int | — |

| Completed result | Owner first | Nonowner first |
| --- | --- | --- |
| Owner parameter read | int | int |
| Owner publication | int | int |
| Nonowner parameter read | Any | int |
| Other parameter read | int | int |
| Abstract nonowner result | AnyResult | StrResult |

The result function deliberately maps `int -> StrResult` and `Any -> AnyResult`.
`FinalNonownerScheduleIndependentFixed` self-composes two executions under one
native temporal clock and finds a difference once **both** are complete. Their
local step/stutter choices remain independent.

This is **abstract sensitivity**, not proof of an order-dependent final `C.x`
for a Python fixture. The source observation distinguishes implicit and explicit
`Any`; additional inference attempts and final getter handling can erase an
intermediate effect. No model-to-code refinement is supplied.

The corresponding reference assertion has no counterexample within scope.
`ReferenceSchedulesExist` also produces two completed reference executions with
different owner-first/nonowner-first orders. These controls are **definitional**:
`AttemptLocal` directly returns each expression attempt's chosen hint, rather
than verifying a concrete storage/restoration implementation.

## 4. Recursive Other read: availability boundary

Command: `run RecursiveOther`. It has **5 states**, loops at state **4**, and
contains **4 meaningful transitions**; at most **4 states** is UNSAT.

| Step | Native state | Action | Reader/attempt | Working | Published | Read result |
| --- | --- | --- | --- | --- | --- | --- |
| 0 | 0 | Initial | — | — | — | — |
| 1 | 1 | Start | Owner | int | — | — |
| 2 | 2 | Start | Other | int | — | — |
| 3 | 3 | RecursiveOwner | Other | int | — | — |
| 4 | 4 | Read | Other | int | — | int |

Other has no inference hint of its own, but an owner inference guard encloses it.
The recursive owner demand does not publish yet. Fixed selection therefore uses
the available installed type. The unconditional `OtherAlwaysPublishedFixed`
assertion fails here because **there is no publication to read**. This boundary
is not automatically an implementation bug; the independent-after-publication
contract has explicit availability and no-enclosing-inference preconditions.

## Bounds and limits

Main commands use an exact **16-state native lasso**, with unchanged-state stutter
padding admitting shorter prefixes. Witness commands retain explicit ranged
bounds; the runner validates every native JSON state and XML trace/loop length.
The closing self-loop is not another meaningful inference action. All **20**
expected SAT/UNSAT outcomes and **14** runner controls pass.

These results concern publication **authority** and read precedence only.
Publication is always `IntHint` by construction: there is no nonowner inference
nested inside Owner to contaminate its slot. Publication-value correctness and
determinism are **not established**. Top-level attempts are serialized even
across ThreadStates; duplicate owner solves and SCC commit-reservation waiting
are excluded, not modeled as ordinary cross-thread blocking. Owner phases
condense synchronous SCC convergence, not an individual Rust solver pass.

See the README for the source snapshot and excluded repeated-hint, cache, cold-SCC,
older-driver deferred-publication, and incremental behaviors. The evidence bundle
contains the named commands' native XML lassos, JSON receipts, and full normalized
traces, so every table can be reconstructed without relying on a temporary path.
