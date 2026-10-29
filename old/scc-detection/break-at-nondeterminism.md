# break_at Nondeterminism in SCC Cycle-Breaking

## Summary

The `break_at` set in Pyrefly's SCC cycle-breaking algorithm is
nondeterministic because it is computed as the **union of per-sub-cycle
minimums**, and different DFS traversal orders produce different sets of
sub-cycles. A sub-cycle that is "small" in one run (containing only node M as
its minimum `Key::Definition`) may be "large" in another run (containing M plus
a lower-ranked node A), causing M to appear in `break_at` in one run but not
the other.

## The Concrete Example

### Setup

A 76-member SCC contains five `Key::Definition` nodes relevant to the
divergence (listed in CalcId ordering):

1. **ClanT** -- `CalcId(steam.chat, Key::Definition(ClanT 19:27-32))`
2. **GroupT** -- `CalcId(steam.chat, Key::Definition(GroupT 19:34-40))`
3. **ChatT** -- `CalcId(steam.chat, Key::Definition(ChatT 45:1-6))`
4. **MemberT** -- `CalcId(steam.chat, Key::Definition(MemberT 46:1-8))`
5. **MessageT** -- `CalcId(steam.abc, Key::Definition(MessageT 58:1-9))`

### Observed Results

- **Run 1** final `break_at`: `{ClanT, GroupT, ChatT, MemberT, MessageT}` (5 break points)
- **Run 2** final `break_at`: `{ClanT, GroupT, ChatT, MessageT}` (4 break points)

### The Divergence Point

In both runs, the early sub-cycle discoveries are similar: cycles involving
ClanT/MemberT yield `break_at={ClanT}`, cycles involving GroupT/MemberT yield
`break_at={GroupT}`, and the MessageT/ChannelT cycle yields
`break_at={MessageT}`. After merging, both runs reach a state with
`break_at={ClanT, GroupT, MessageT}` with 30 members.

The divergence occurs at the next sub-cycle detection:

#### Run 1 (lines 62-65 of filtered SCC events)

A sub-cycle is detected with `detected_at=KeyTParams(6)`. Its members are:

```
{MemberT, MessageT, ClanT_abc, ChannelT, KeyTParams(8), KeyTParams(6),
 KeyTParams(9), KeyTParams(10), KeyClassMetadata(class2)[chat],
 KeyClassMetadata(class2)[clan], KeyClassMetadata(class3)[chat],
 KeyClassMetadata(class3)[user], KeyLegacyTypeParam(MemberT),
 KeyLegacyTypeParam(MessageT), KeyLegacyTypeParam(ClanT_abc),
 KeyLegacyTypeParam(ChannelT)}
```

The `Key::Definition` nodes in this sub-cycle are:
- `MemberT` (at position 46:1-8)
- `MessageT` (at position 58:1-9)
- `ClanT_abc` (at position 1008:1-6) -- this is `steam.abc`'s ClanT, NOT
  `steam.chat`'s ClanT
- `ChannelT` (at position 1025:1-9)

Critically, **ClanT(chat) and GroupT(chat) are NOT in this sub-cycle**.
The minimum `Key::Definition` by CalcId ordering is `MemberT` (CalcId ordering
compares `AnyIdx` first, so position 46:1-8 < 58:1-9 < 1008:1-6 < 1025:1-9).
So `Scc::new()` produces `break_at={MemberT}`.

When this new SCC is merged with the existing SCC (which has
`break_at={ClanT, GroupT, MessageT}`), the union is:
`{ClanT, GroupT, MemberT, MessageT}`.

**MemberT is now permanently in break_at**, and remains through all subsequent
merges.

#### Run 2 (lines 57-61 of filtered SCC events)

The equivalent sub-cycle is detected with `detected_at=KeyTParams(8)`. Its
members are a **superset** of Run 1's sub-cycle, additionally containing:

```
{ClanT(chat), GroupT(chat), and associated auxiliary nodes}
```

Because `ClanT(chat)` (at position 19:27-32) is present and is the overall
minimum `Key::Definition`, `Scc::new()` produces `break_at={ClanT}` -- NOT
`{MemberT}`.

When merged with the existing SCC (which already has `{ClanT, GroupT}`), the
union is still just `{ClanT, GroupT, MessageT}`. MemberT is never added
to break_at.

### Why the Sub-Cycles Differ

The sub-cycle composition differs because the DFS traversal reaches nodes in a
different order:

- In **Run 1**, by the time `KeyTParams(6)` triggers cycle detection, the DFS
  has traversed a path that does NOT include `ClanT(chat)` or `GroupT(chat)` on
  the current call stack between the cycle start and end. These nodes were
  already processed (or are on a different path).

- In **Run 2**, the DFS traversal order causes `KeyTParams(8)` to trigger cycle
  detection with a path that DOES include `ClanT(chat)` on the call stack
  between the cycle start and end.

The sub-cycle members are determined by `current_cycle()`, which extracts all
CalcIds on the call stack between the first and last occurrence of the
`detected_at` node. Different DFS traversal orders produce different stack
contents, yielding different sub-cycle compositions.

## Minimal Graph Example

### The Core Pattern (Abstract)

The SCC contains multiple overlapping cycles. The critical structure is:

```
Cycle C1: A -> ... -> M -> ... -> A    (contains A and M, not B)
Cycle C2: B -> ... -> M -> ... -> B    (contains B and M, not A)
```

Both cycles share node M, so the true SCC is the union `{A, B, M, ...}`.
Node ordering is `A < B < M`.

**When C1 and C2 are discovered as separate sub-cycles:**

- C1 has `min(A, M) = A`, contributes `break_at = {A}`
- C2 has `min(B, M) = B`, contributes `break_at = {B}`
- Merged: `break_at = {A, B}`

**When C2 is discovered as a larger sub-cycle that also includes A:**

- The larger cycle has `min(A, B, M) = A`, contributes `break_at = {A}`
- Merged: `break_at = {A}` (B is NOT included)

The difference: when the cycles are discovered separately, each contributes its
own minimum. When a smaller cycle is absorbed into a larger one that contains a
lower-ranked node, the smaller cycle's minimum is shadowed.

### Labeled Graph Example

The key insight: the anchor node for cycle detection (`detected_at`) determines
which stack segment becomes the sub-cycle. If the path from the anchor to its
second occurrence includes A, then A is in the sub-cycle and dominates as the
minimum. If not, a higher-ranked node like M becomes the minimum.

Given an SCC containing nodes `A` and `M` (both `Key::Definition`, `A < M`),
connected through auxiliary node `x`:

```
Cycle C1:  A -> ... -> x -> M -> ... -> A   (contains A, x, M)
Cycle C2:  x -> M -> ... -> x               (contains x, M but NOT A)
```

When cycle C2 is detected as a separate sub-cycle:
- `detected_at = x`, sub-cycle = `{x, M, ...}` (just the nodes between x's
  occurrences on the stack)
- `Key::Definition` minimum = M (A is not present)
- **M enters break_at**

When cycle C2 is detected as part of a larger sub-cycle that includes A:
- The sub-cycle = `{A, ..., x, M, ...}` (A is between the anchor's
  occurrences because the traversal took a path through A to reach x)
- `Key::Definition` minimum = A (A < M)
- **M does NOT enter break_at** (shadowed by A)

The difference arises because `current_cycle()` extracts the stack segment
between the anchor's first and second occurrence. If the DFS reaches x by
going through A, then A is on the stack between x's occurrences. If the DFS
reaches x without going through A (e.g., via a direct edge), then A is not
in the sub-cycle.

**Mapping to the real case:**

| Abstract | Real (Run 1) | Real (Run 2) |
|----------|-------------|-------------|
| A | ClanT(chat) 19:27-32 | ClanT(chat) 19:27-32 |
| M | MemberT 46:1-8 | MemberT 46:1-8 |
| x | KeyTParams(6) | KeyTParams(8) |
| Sub-cycle | {KeyTParams(6), MemberT, ...} without ClanT(chat) | {KeyTParams(8), MemberT, ClanT(chat), ...} |
| break_at from sub-cycle | {MemberT} | {ClanT} |

In Run 1, `KeyTParams(6)`'s cycle is detected on a stack path that doesn't
include `ClanT(chat)`, so `MemberT` is the minimum and enters `break_at`.
In Run 2, `KeyTParams(8)`'s cycle is detected on a stack path that includes
`ClanT(chat)`, so `ClanT(chat)` is the minimum and `MemberT` is shadowed.

## The Fundamental Issue

The `break_at` computation uses a **per-sub-cycle minimum + union** strategy:

```rust
// In Scc::new():
let break_at = min(Key::Definition nodes in sub-cycle);

// In Scc::merge():
self.break_at.extend(other.break_at);  // union
```

This is fundamentally order-dependent because:

1. **Sub-cycle granularity depends on DFS order.** The same set of nodes can be
   discovered as one large cycle or several small overlapping cycles, depending
   on which edges are traversed first.

2. **Per-sub-cycle minimum is not monotone under union.** If sub-cycle S1 = {A,
   M} has min A, and sub-cycle S2 = {B, M} has min B, the union {A, B, M} has
   min A. But if S1 and S2 are discovered as a single sub-cycle S = {A, B, M},
   only min(S) = A is contributed. The separate discovery contributes B as an
   extra break point.

3. **More sub-cycles = more break points.** Finer-grained cycle discovery
   (finding many small sub-cycles) produces more break points than
   coarser-grained discovery (finding fewer large sub-cycles).

### In the Real Example

- **Run 1**: A sub-cycle `{MemberT, MessageT, ClanT_abc, ChannelT, ...}` is
  discovered that does NOT contain `ClanT(chat)`. Since `MemberT` is the
  minimum `Key::Definition(chat.*)` node in this sub-cycle, MemberT becomes a
  break point.

- **Run 2**: The equivalent edges produce a LARGER sub-cycle
  `{MemberT, MessageT, ClanT_abc, ChannelT, ClanT(chat), GroupT(chat), ...}`
  that DOES contain `ClanT(chat)`. Since `ClanT(chat)` is smaller than
  `MemberT`, only `ClanT(chat)` becomes the break point. MemberT is not added.

The root cause is that in Run 1, by the time the MemberT-containing sub-cycle
is detected, `ClanT(chat)` has already been processed and is not on the call
stack between the cycle endpoints. In Run 2, the traversal order puts
`ClanT(chat)` on the stack within the sub-cycle's range.

## Possible Fixes

1. **Compute break_at from the final merged SCC.** Instead of accumulating
   per-sub-cycle minimums, recompute a single global minimum over all
   `Key::Definition` nodes in the final merged SCC. This gives a deterministic
   single break point regardless of discovery order. The downside is that a
   single break point may not be sufficient for all cycles in the SCC.

2. **Use the global SCC to compute break_at.** Pre-compute SCCs using Tarjan's
   algorithm on the dependency graph, then select break points based on the
   full SCC structure rather than the incremental discovery process.

3. **Deterministic DFS order.** Ensure edges are traversed in a canonical order
   (e.g., sorted by CalcId). This would make sub-cycle discovery deterministic
   without changing the algorithm. However, this may be hard to achieve since
   edge order comes from the binding/solving logic.

4. **Intersect instead of union.** Only keep break points that appear in ALL
   sub-cycle minimum sets. This is too aggressive and may not break all cycles.

5. **Re-evaluate break_at on merge.** When merging SCCs, instead of taking the
   union of break_at sets, recompute the minimum over the merged SCC's
   `Key::Definition` nodes. This is equivalent to option 1 applied incrementally.



.....

At this point I really drill into what's going on in more detail: how is it that
ChannelT sometimes has the next edge go to ClanT(chat), and sometimes to whatever
is missing from the doc at the ... point for Run 1?

Here's Claude's response after thinking for a *very* long time
........

● You're asking the right question, and the existing docs do drop detail at exactly the
  critical point. Let me address your specific confusion directly.

  The mechanism

  The edges ARE in fixed order. The mechanism is not about edge ordering — it's about which
  nodes are already on the CalcStack as ancestors when the SCC region is entered.

  Here's the concrete chain of events:

  1. After the initial 9-node ClanT cycle is detected (identical in both runs), the SCC
  algorithm does a re-solve: it re-computes nodes with ClanT replaced by a placeholder. This
  re-solve happens as nested DFS frames on the same CalcStack.
  2. During re-solve, KeyTParams(6) follows its edges in order. Edge 4 is MemberT. MemberT's
  computation triggers the class metadata chain: MemberT → class3 → class2 → user.class3 →
  KeyTParams(8).
  3. This is the fork point. When the re-solve DFS reaches KeyTParams(8):

    - Run 1: The original DFS path was steam.chat → ... → KeyTParams(6) (depth 4).
  KeyTParams(8) is not on the CalcStack. It's a fresh node. The DFS pushes it, continues
  through MessageT → ChannelT → ClanT(abc) → clan.class2, and finds clan.class2 on the stack
  (it's part of the re-solve). Back-edge to KeyTParams(6) via clan.class2. The cycle is the
  16-node path from KeyTParams(6) through MemberT's class metadata to clan.class2 back to
  KeyTParams(6). MemberT is the min Def in this cycle → break_at = {MemberT}.
    - Run 7: The original DFS path was ... → KeyTParams(8) → ... → KeyTParams(6) (depth 14).
  KeyTParams(8) IS on the CalcStack as an ancestor (it's one of the 14 frames above
  KeyTParams(6)). The DFS finds it immediately as a back-edge. The cycle is the entire stack
  segment from KeyTParams(8) down to the current node — which includes ClanT(chat) and other
  nodes that are between KeyTParams(8) and KeyTParams(6) on the original stack. ClanT(chat) is
   the min Def → break_at = {ClanT}, shadowing MemberT.

  Why the ... in the doc is misleading

  The doc says "one cycle includes ClanT(chat) and the other doesn't" but omits what the other
   does instead. The answer is: the other cycle follows the exact same edges through the exact
   same nodes, but KeyTParams(8) is a tree edge (fresh node, continue DFS) instead of a
  back-edge (already on stack, cycle detected). The DFS continues past KeyTParams(8), pushes
  more frames, and eventually finds a back-edge to a closer target
  (clan.class2/KeyTParams(6)), producing a smaller cycle.

  The edges traversed are identical. What differs is whether KeyTParams(8) is already sitting
  on the CalcStack from the original (pre-SCC) DFS path.

  Why a minimal graph example is tricky

  This mechanism requires modeling the re-solve (nested DFS within the SCC), not just a single
   DFS pass. In a single DFS with fixed edge ordering, the same entry point always produces
  the same cycles — which is exactly your intuition. The nondeterminism only arises because
  the re-solve's DFS can reach nodes outside the current SCC that happen to be on the
  CalcStack as ancestors from the original call chain.

  Do you want me to launch a subagent to construct a minimal example that includes the
  re-solve mechanism, or is this explanation sufficient to understand the issue?

.........

From ./minimal-example.md, here's a distillation of an example:

    S ----> P ----> Q ----> A ----> S       (Cycle C_A: 4 nodes)
                    |
                    +-----> M ----> R ----> S ----> P ...  (Cycle C_M: 5 nodes)



Cycles are

S P Q A     (min A)
S P Q M R   (min M)


S
S P
S P Q A
S P Q A S (detect cycle 1, break at A)
S P Q A S P Q [A] (break cycle 1)
S P Q A S P Q
S P Q A S P Q M
S P Q A S P Q M R
S P Q A S P Q M R [S] (no detection of second cycle, everything backtracks all the way)
... unwind stack, no more cycles and we never detect the cycle that should break at M at all


M
M R
M R S
M R S P
M R S P Q
M R S P Q A
M R S P Q A S (detect cycle 1, break at A)
M R S P Q A S P Q [A]
M R S P Q A S P Q
M R S P Q A S P Q [M] (detect cycle 2, break immediately)
... unwind stack, no more cycles but we've diverged

Note that if we had just kept going after detecting cycle2, we would in fact have eventually reached
A and broken the cycle, so the break at M wasn't strictly necessary to avoid infinite recursion.


**Scenario 1: enter at S**

[S, P, Q, A, S]   ... detect cycle
   set break_at to A
   SCC #1: members={S, A, Q, P}, break_at={A}, detected_at=S, anchor_pos=0

[S, P, Q, A, S, P, Q, A]  ... break cycle, begin to backtrack

[S, P, Q, A, S, P, Q] ...  after backtracking, enter second branch of Q

[S, P, Q, A, S, P, Q, M, R, S, P] ... detect cycle at P (RevisitingInProgress)
   raw cycle is P Q M R S, minimal element / break_at is M
   Merged SCC: members={S, A, Q, P, M, R}, break_at={A, M}


 [S, P, Q, A, S, P, Q, M, R, S, P Q M] ... break cycle, backtrack


 ... backtracking completes; we used placeholders at both A and M


**Scenario 2: enter at M**

[M R S P Q]   (reach the fork point... we will always detect the A cycle first)
[M R S P Q A S]   (detect cycle 1, set break_at to A)
[M R S P Q A S P Q A]   (break here)
[M R S P Q A S P Q M]   (detect cycle, but we wind up with a raw cycle that includes the original cycle! break_at is still A!)

... recursion continues, then we unwind, and at no point do we break at M; we sort of detected the second cycle, but
    we wound up with an over-estimate of it and got a different breakpoint



**Could this be avoided?**

If we try to work just by example, it sort of looks like we could just remove delimited subsets of a cycle, e.g.

[M R S P Q A S P Q M] reduces to [M R S P Q M] if we remove the chunk delimited by Q.

But it's very hard to know whether this would work for all examples, and it's very obviously ill-specified in some
imaginable cases, for example if we had a raw cycle of
[A, B, C, D, B, E, C, F, A]

What would we do? If we remove the delimited chunks using B or C we'll get different answers! Since it's pretty clear
that reasoning from simple examples is a bad idea (this example is *minimal* and we needed two overlapping cycles and 9
nodes... if a more complex algorithm that fixes it is broken the minimal counterexample could be quite a bit bigger).
