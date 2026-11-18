# Checked lambda-inference traces

These tables come from actual **native Alloy 6** instances of the named commands,
not imagined same-thread interleavings. `Step` removes unchanged stutters;
`Native state` preserves the checker's original position. `int` and `Any` are
aliases for `IntHint` and `AnyHint`. A dash means no installed/published/read value.

The roles are **Owner** (expression inference and publication authority),
**Nonowner** (another inference of that expression), and **Other** (a fragment or
independent parameter read). `Working` is the shared slot in this execution's
ThreadState; it is not an attempt-local slot. Only one parameter is modeled.

The bugs are order dependence, so each section pairs two completed executions
with the same inputs (owner hint `int`, nonowner hint `Any`, one ThreadState)
that differ only in solve order. `Old` is the precedence before the source
snapshot; `Fixed` is the snapshot's precedence. `OwnerOnly` (section 4) and
`OwnerAuthoritative` (section 5) are sketches, not source behavior.

## 1. Original bug: an independent read depends on solve order (`Old`)

Commands: `run OldOtherBeforeNonowner` and `run OldOtherAfterNonowner`. The owner
completes first in both; Other then reads either before or after the nonowner's
inference on the same ThreadState.

### Other before nonowner

| Step | Native state | Action | Reader/attempt | Working | Published | Read result |
| --- | --- | --- | --- | --- | --- | --- |
| 0 | 0 | Initial | — | — | — | — |
| 1 | 1 | Start | Owner | int | — | — |
| 2 | 2 | RecursiveOwner | Owner | int | — | — |
| 3 | 3 | Read | Owner | int | — | int |
| 4 | 4 | ExitInference | Owner | int | — | — |
| 5 | 5 | Publish | Owner | int | int | — |
| 6 | 6 | Finish | Owner | int | int | — |
| 7 | 7 | Start | Other | int | int | — |
| 8 | 9 | CachedOwner | Other | int | int | — |
| 9 | 10 | Read | Other | int | int | int |
| 10 | 11 | Finish | Other | int | int | — |
| 11 | 12 | Start | Nonowner | Any | int | — |
| 12 | 13 | CachedOwner | Nonowner | Any | int | — |
| 13 | 14 | Read | Nonowner | Any | int | Any |
| 14 | 15 | Finish | Nonowner | Any | int | — |

### Other after nonowner

| Step | Native state | Action | Reader/attempt | Working | Published | Read result |
| --- | --- | --- | --- | --- | --- | --- |
| 0 | 0 | Initial | — | — | — | — |
| 1 | 1 | Start | Owner | int | — | — |
| 2 | 2 | RecursiveOwner | Owner | int | — | — |
| 3 | 3 | Read | Owner | int | — | int |
| 4 | 4 | ExitInference | Owner | int | — | — |
| 5 | 6 | Publish | Owner | int | int | — |
| 6 | 7 | Finish | Owner | int | int | — |
| 7 | 8 | Start | Nonowner | Any | int | — |
| 8 | 9 | CachedOwner | Nonowner | Any | int | — |
| 9 | 10 | Read | Nonowner | Any | int | Any |
| 10 | 11 | Finish | Nonowner | Any | int | — |
| 11 | 12 | Start | Other | Any | int | — |
| 12 | 13 | CachedOwner | Other | Any | int | — |
| 13 | 14 | Read | Other | Any | int | Any |
| 14 | 15 | Finish | Other | Any | int | — |

| Completed result | Other before nonowner | Other after nonowner |
| --- | --- | --- |
| Owner publication | int | int |
| Working slot at Other's read | int | Any |
| Other parameter read | int | **Any** |

`Old` always prefers the working slot. The nonowner's inference leaves `Any`
there, and nothing restores it, so a later independent read sees whichever
inference ran last on that ThreadState rather than the publication.
`IndependentAfterPublicationOld` has a counterexample. The ranged `OldReadLeak`
witness shows the after-nonowner leak needs **13 meaningful transitions**
(`OldReadLeakTooShort` is UNSAT at at most **13 states**).

## 2. Partial fix: the independent read no longer depends on order (`Fixed`)

Commands: `run FixedOtherBeforeNonowner` and `run FixedOtherAfterNonowner`, the
same two schedules under `Fixed`.

### Other before nonowner

| Step | Native state | Action | Reader/attempt | Working | Published | Read result |
| --- | --- | --- | --- | --- | --- | --- |
| 0 | 0 | Initial | — | — | — | — |
| 1 | 1 | Start | Owner | int | — | — |
| 2 | 2 | RecursiveOwner | Owner | int | — | — |
| 3 | 3 | Read | Owner | int | — | int |
| 4 | 4 | ExitInference | Owner | int | — | — |
| 5 | 5 | Publish | Owner | int | int | — |
| 6 | 6 | Finish | Owner | int | int | — |
| 7 | 7 | Start | Other | int | int | — |
| 8 | 9 | CachedOwner | Other | int | int | — |
| 9 | 10 | Read | Other | int | int | int |
| 10 | 11 | Finish | Other | int | int | — |
| 11 | 12 | Start | Nonowner | Any | int | — |
| 12 | 13 | CachedOwner | Nonowner | Any | int | — |
| 13 | 14 | Read | Nonowner | Any | int | Any |
| 14 | 15 | Finish | Nonowner | Any | int | — |

### Other after nonowner

| Step | Native state | Action | Reader/attempt | Working | Published | Read result |
| --- | --- | --- | --- | --- | --- | --- |
| 0 | 0 | Initial | — | — | — | — |
| 1 | 1 | Start | Owner | int | — | — |
| 2 | 2 | RecursiveOwner | Owner | int | — | — |
| 3 | 3 | Read | Owner | int | — | int |
| 4 | 4 | ExitInference | Owner | int | — | — |
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

| Completed result | Other before nonowner | Other after nonowner |
| --- | --- | --- |
| Owner publication | int | int |
| Working slot at Other's read | int | Any |
| Other parameter read | int | int |

Outside any lambda inference frame, `Fixed` prefers the publication, so the
leftover `Any` no longer reaches Other. `IndependentAfterPublicationFixed` has
no counterexample within the checked scope. This establishes the modeled
precedence rule, not correctness of the published value. In both schedules the
owner ran first, so the nonowner read its own `Any`; section 3 varies that order.

## 3. Remaining bug: a nonowner's own read still depends on order (`Fixed`)

Commands: `run OwnerFirst` and `run NonownerFirst`. Both use `Fixed` and complete
all three attempts; Other reads last, outside inference.

### Owner first

| Step | Native state | Action | Reader/attempt | Working | Published | Read result |
| --- | --- | --- | --- | --- | --- | --- |
| 0 | 0 | Initial | — | — | — | — |
| 1 | 1 | Start | Owner | int | — | — |
| 2 | 2 | RecursiveOwner | Owner | int | — | — |
| 3 | 3 | Read | Owner | int | — | int |
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

### Nonowner first

| Step | Native state | Action | Reader/attempt | Working | Published | Read result |
| --- | --- | --- | --- | --- | --- | --- |
| 0 | 0 | Initial | — | — | — | — |
| 1 | 1 | Start | Nonowner | Any | — | — |
| 2 | 3 | ForceOwner | Nonowner | int | — | — |
| 3 | 4 | RecursiveOwner | Owner | int | — | — |
| 4 | 5 | Read | Owner | int | — | int |
| 5 | 6 | ExitInference | Owner | int | — | — |
| 6 | 7 | Publish | Owner | int | int | — |
| 7 | 8 | Finish | Owner | int | int | — |
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
| Nonowner parameter read | Any | **int** |
| Other parameter read | int | int |
| Abstract nonowner result | AnyResult | StrResult |

In the nonowner-first schedule, the nonowner installs `Any` at entry. Its
parameter read first demands the owner, which runs synchronously on the **same
ThreadState** and overwrites the working slot with `int`. The outer attempt is
suspended; it cannot execute steps while the nested owner is active. The owner
exits its inference guard, publishes, and returns without restoring the slot.
The resumed nonowner is still inside its own inference frame, so `Fixed` prefers
the working slot and reads `int`, not its own hint. In the owner-first schedule
the owner is already done, nothing overwrites the slot, and the nonowner reads
`Any`.

`NonownerOwnHintFixed` finds the local failure within the main scope. The ranged
`NestedOverwrite` witness needs **9 meaningful transitions**
(`NestedOverwriteTooShort` is UNSAT at at most **9 states**).

The result function deliberately maps `int -> StrResult` and `Any -> AnyResult`.
`FinalNonownerScheduleIndependentFixed` self-composes two executions under one
native temporal clock and finds a difference once **both** are complete. Their
local step/stutter choices remain independent.

This is **abstract sensitivity**, not proof of an order-dependent final `C.x`
for a Python fixture. `Old` has the same nonowner behavior, so this is a
remaining gap rather than a regression. The source observation distinguishes
implicit and explicit `Any`; additional inference attempts and final getter
handling can erase an intermediate effect. No model-to-code refinement is
supplied.

The corresponding reference assertion has no counterexample within scope.
`ReferenceSchedulesExist` also produces two completed reference executions with
different owner-first/nonowner-first orders. These controls are **definitional**:
`AttemptLocal` directly returns each expression attempt's chosen hint, rather
than verifying a concrete storage/restoration implementation.

## 4. Sketch: only the owner installs a working hint (`OwnerOnly`)

Commands: `run OwnerOnlyOwnerFirst` and `run OwnerOnlyNonownerFirst`, the
section 3 schedules under `OwnerOnly`. A nonowner attempt installs no hint at
entry; its read still demands the owner first, then reads the owner's
publication. Owner and Other reads keep `Fixed` precedence.

### Owner first

| Step | Native state | Action | Reader/attempt | Working | Published | Read result |
| --- | --- | --- | --- | --- | --- | --- |
| 0 | 0 | Initial | — | — | — | — |
| 1 | 1 | Start | Owner | int | — | — |
| 2 | 2 | RecursiveOwner | Owner | int | — | — |
| 3 | 3 | Read | Owner | int | — | int |
| 4 | 4 | ExitInference | Owner | int | — | — |
| 5 | 5 | Publish | Owner | int | int | — |
| 6 | 7 | Finish | Owner | int | int | — |
| 7 | 8 | Start | Nonowner | int | int | — |
| 8 | 9 | CachedOwner | Nonowner | int | int | — |
| 9 | 10 | Read | Nonowner | int | int | int |
| 10 | 11 | Finish | Nonowner | int | int | — |
| 11 | 12 | Start | Other | int | int | — |
| 12 | 13 | CachedOwner | Other | int | int | — |
| 13 | 14 | Read | Other | int | int | int |
| 14 | 15 | Finish | Other | int | int | — |

### Nonowner first

| Step | Native state | Action | Reader/attempt | Working | Published | Read result |
| --- | --- | --- | --- | --- | --- | --- |
| 0 | 0 | Initial | — | — | — | — |
| 1 | 1 | Start | Nonowner | — | — | — |
| 2 | 2 | ForceOwner | Nonowner | int | — | — |
| 3 | 3 | RecursiveOwner | Owner | int | — | — |
| 4 | 5 | Read | Owner | int | — | int |
| 5 | 6 | ExitInference | Owner | int | — | — |
| 6 | 7 | Publish | Owner | int | int | — |
| 7 | 8 | Finish | Owner | int | int | — |
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
| Nonowner parameter read | int | int |
| Other parameter read | int | int |
| Abstract nonowner result | StrResult | StrResult |

`NonownerReadsPublicationOwnerOnly`, `IndependentAfterPublicationOwnerOnly`, and
`FinalNonownerScheduleIndependentOwnerOnly` have no counterexample within scope.
`OwnerOnlySchedulesExist` produces both completed orders in one comparison, so
the schedule-independence check is not vacuous.

The nonowner never uses its own contextual hint, so this contract **replaces**
`NonownerOwnHint` rather than satisfying it. The nonowner still runs a lambda
inference frame, and the sketch never places it inside the owner's solve;
section 5 removes both limits.

## 5. Sketch: one owner does all lambda inference (`OwnerAuthoritative`)

Only the owner infers the lambda. A nonowner is a pure reader of the owner's
binding, like Other: it installs nothing and runs no inference frame. Readers
outside the owner's evaluation get the publication. A reader reached **inside**
the unfinished owner solve is a dependency cycle and gets a cycle-break
`placeholder`, never working storage, unless it is a body binding the owner's
evaluation owns (`OwnedBody`, e.g. a comprehension in the lambda body), which
reads working storage directly. A nonowner may be reached inside the owner's
solve only under this policy, since a pure reader cannot contaminate the
owner's slot.

### Top-level orders

Commands: `run AuthoritativeOwnerFirst` and `run AuthoritativeNonownerFirst`.

#### Owner first

| Step | Native state | Action | Reader/attempt | Working | Published | Read result |
| --- | --- | --- | --- | --- | --- | --- |
| 0 | 0 | Initial | — | — | — | — |
| 1 | 1 | Start | Owner | int | — | — |
| 2 | 3 | RecursiveOwner | Owner | int | — | — |
| 3 | 4 | Read | Owner | int | — | int |
| 4 | 5 | ExitInference | Owner | int | — | — |
| 5 | 6 | Publish | Owner | int | int | — |
| 6 | 7 | Finish | Owner | int | int | — |
| 7 | 8 | Start | Nonowner | int | int | — |
| 8 | 9 | CachedOwner | Nonowner | int | int | — |
| 9 | 10 | Read | Nonowner | int | int | int |
| 10 | 11 | Finish | Nonowner | int | int | — |
| 11 | 12 | Start | Other | int | int | — |
| 12 | 13 | CachedOwner | Other | int | int | — |
| 13 | 14 | Read | Other | int | int | int |
| 14 | 15 | Finish | Other | int | int | — |

#### Nonowner first

| Step | Native state | Action | Reader/attempt | Working | Published | Read result |
| --- | --- | --- | --- | --- | --- | --- |
| 0 | 0 | Initial | — | — | — | — |
| 1 | 1 | Start | Nonowner | — | — | — |
| 2 | 2 | ForceOwner | Nonowner | int | — | — |
| 3 | 4 | RecursiveOwner | Owner | int | — | — |
| 4 | 5 | Read | Owner | int | — | int |
| 5 | 6 | ExitInference | Owner | int | — | — |
| 6 | 7 | Publish | Owner | int | int | — |
| 7 | 8 | Finish | Owner | int | int | — |
| 8 | 9 | Resume | Nonowner | int | int | — |
| 9 | 10 | Read | Nonowner | int | int | int |
| 10 | 11 | Finish | Nonowner | int | int | — |
| 11 | 12 | Start | Other | int | int | — |
| 12 | 13 | CachedOwner | Other | int | int | — |
| 13 | 14 | Read | Other | int | int | int |
| 14 | 15 | Finish | Other | int | int | — |

### Readers inside the owner's solve

Commands: `run AuthoritativeNestedNonowner` and `run AuthoritativeOwnedBody`.
Both start the owner first and reach a reader while the owner is in demand.

#### Unrelated nonowner inside the owner

| Step | Native state | Action | Reader/attempt | Working | Published | Read result |
| --- | --- | --- | --- | --- | --- | --- |
| 0 | 0 | Initial | — | — | — | — |
| 1 | 1 | Start | Owner | int | — | — |
| 2 | 3 | Start | Nonowner | int | — | — |
| 3 | 4 | RecursiveOwner | Nonowner | int | — | — |
| 4 | 5 | Read | Nonowner | int | — | placeholder |
| 5 | 6 | Finish | Nonowner | int | — | — |
| 6 | 7 | RecursiveOwner | Owner | int | — | — |
| 7 | 8 | Read | Owner | int | — | int |
| 8 | 9 | ExitInference | Owner | int | — | — |
| 9 | 10 | Publish | Owner | int | int | — |
| 10 | 11 | Finish | Owner | int | int | — |
| 11 | 12 | Start | Other | int | int | — |
| 12 | 13 | CachedOwner | Other | int | int | — |
| 13 | 14 | Read | Other | int | int | int |
| 14 | 15 | Finish | Other | int | int | — |

#### Owned body binding inside the owner

| Step | Native state | Action | Reader/attempt | Working | Published | Read result |
| --- | --- | --- | --- | --- | --- | --- |
| 0 | 0 | Initial | — | — | — | — |
| 1 | 1 | Start | Owner | int | — | — |
| 2 | 3 | Start | Other | int | — | — |
| 3 | 4 | RecursiveOwner | Other | int | — | — |
| 4 | 5 | Read | Other | int | — | int |
| 5 | 6 | Finish | Other | int | — | — |
| 6 | 7 | RecursiveOwner | Owner | int | — | — |
| 7 | 8 | Read | Owner | int | — | int |
| 8 | 9 | ExitInference | Owner | int | — | — |
| 9 | 10 | Publish | Owner | int | int | — |
| 10 | 11 | Finish | Owner | int | int | — |
| 11 | 12 | Start | Nonowner | int | int | — |
| 12 | 13 | CachedOwner | Nonowner | int | int | — |
| 13 | 14 | Read | Nonowner | int | int | int |
| 14 | 15 | Finish | Nonowner | int | int | — |

| Completed result | Owner first | Nonowner first | Nested nonowner | Owned body |
| --- | --- | --- | --- | --- |
| Owner publication | int | int | int | int |
| Nonowner parameter read | int | int | **placeholder** | int |
| Other parameter read | int | int | int | int (working) |

`SingleAnswerAuthoritative` (every Nonowner or Other read outside the owner's
evaluation equals the publication), `NoWorkingLeakAuthoritative` (an unowned
reader inside it gets the placeholder), and `OwnedBodyReadsWorkingAuthoritative`
have no counterexample within scope. `FinalNonownerScheduleIndependentAuthoritative`
holds for completed executions without a placeholder read, and
`AuthoritativeSchedulesExist` shows both top-level orders in one comparison.

The nested nonowner's placeholder differs from the publication. That read is a
cycle between the two bindings, so its final answer belongs to SCC solving, not
to lambda storage; this model does not decide it. The owner is never shown
depending on the nonowner, so the cycle is only modeled from the owner side;
[OWNER_CYCLES.md](OWNER_CYCLES.md) sketches the full cycle by hand.
Owner phases still condense fixpoint convergence: per-iteration wiping of
working storage and iteration-aware publication are not modeled, and with one
owner hint the owned body's working read always equals the eventual
publication.

## 6. Recursive Other read: availability boundary

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

Main commands, including every paired schedule above, use an exact **16-state
native lasso** ending in a final-state loop; tables omit unchanged stutters.
Stutter padding admits shorter prefixes. Witness commands retain explicit ranged
bounds; the runner validates every native JSON state and XML trace/loop length.
The closing self-loop is not another meaningful inference action. All **38**
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
