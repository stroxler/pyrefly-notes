// Pyrefly SCC-solving stack model
// Ported from TLA+ specification

// --- Static structure: dependency graph ---

// Global calculation status for each node.
// Corresponds to state \in [Nodes -> {"Fresh", "InProgress", "Done"}] in TLA+.
enum GlobalState { Fresh, InProgress, Done }

sig Node {
  deps: set Node,
  var gstate: one GlobalState
}

// Limit graph complexity for tractable analysis.
// Each node has at most 3 dependencies (mirrors MaxDeps = 3 in TLA+).
fact BoundDeps {
  all n: Node | #n.deps <= 3
}

// --- SCC state ---

// SCC-local node states, modeling Scc.node_state in the implementation.
enum SccNodeState { SccInProgress, SccHasPlaceholder, SccDone }

// Each Scc atom is a "slot" that can hold an active SCC.
// An SCC is active iff it has members. We pre-allocate enough slots.
sig Scc {
  var members: set Node,
  var anchor: lone Int,
  var nstate: Node -> lone SccNodeState
}

// Active SCCs: those with at least one member.
fun activeSccs: set Scc {
  { s: Scc | some s.members }
}

// Which SCC does node n belong to? At most one, by disjointness.
fun sccOf[n: Node]: lone Scc {
  { s: Scc | n in s.members }
}

// Position of node n on the calc stack (empty if not on stack).
fun stackPos[n: Node]: lone Int {
  CalcStack.elems.n
}

// --- Calc stack (mutable global state) ---

// The calculation stack, modeled as a position-indexed array.
// Position 0 is the bottom; position (depth - 1) is the top.
// Corresponds to `stack \in Seq(Nodes)` in TLA+.
one sig CalcStack {
  var elems: Int -> lone Node,
  var depth: one Int
}

// --- Initial state ---

fact Init {
  // All nodes start Fresh.
  all n: Node | n.gstate = Fresh
  // Stack starts empty.
  CalcStack.depth = 0
  no CalcStack.elems
  // No active SCCs.
  all s: Scc | no s.members and no s.anchor and no s.nstate
  Trace.event = StutterEvt
}

// --- Stack helpers ---

// The node at the top of the stack (empty set if stack is empty).
fun stackTop: lone Node {
  CalcStack.elems[sub[CalcStack.depth, 1]]
}

// The set of all nodes currently on the stack.
// Corresponds to StackSet in TLA+.
fun stackNodes: set Node {
  Int.(CalcStack.elems)
}

// --- Frame conditions ---
// In Alloy 6, we must explicitly say what doesn't change (like UNCHANGED in TLA+).

pred stackUnchanged {
  CalcStack.elems' = CalcStack.elems
  CalcStack.depth' = CalcStack.depth
}

pred gstateUnchanged {
  gstate' = gstate
}

pred sccUnchanged {
  all s: Scc | {
    s.members' = s.members
    s.anchor' = s.anchor
    s.nstate' = s.nstate
  }
}

// --- Stack operations ---

pred pushStack[n: Node] {
  CalcStack.elems' = CalcStack.elems + (CalcStack.depth -> n)
  CalcStack.depth' = add[CalcStack.depth, 1]
}

pred popStack {
  let topIdx = sub[CalcStack.depth, 1] |
    CalcStack.elems' = CalcStack.elems - (topIdx -> stackTop)
  CalcStack.depth' = sub[CalcStack.depth, 1]
}

// --- Event tracking (for trace readability) ---

enum Event { StartRootEvt, DescendEvt, FinishEvt, DetectCycleEvt, PlaceholderEvt, StutterEvt }
one sig Trace {
  var event: one Event,
  var acted_on: one Node
}

// --- Transitions ---

// Start a new DFS root: pick any Fresh node when the stack is empty.
pred startRoot[n: Node] {
  // Guards
  CalcStack.depth = 0
  n.gstate = Fresh
  // Effects
  gstate' = gstate ++ (n -> InProgress)
  pushStack[n]
  sccUnchanged
  Trace.event' = StartRootEvt
  Trace.acted_on' = n
}

// The top of the stack has a Fresh dependency: push it.
pred descend[dep: Node] {
  // Guards
  CalcStack.depth > 0
  dep in stackTop.deps
  dep.gstate = Fresh
  // Effects
  gstate' = gstate ++ (dep -> InProgress)
  pushStack[dep]
  sccUnchanged
  Trace.event' = DescendEvt
  Trace.acted_on' = dep
}

// Is the SCC fully done and ready to commit?
// All members must be SccDone (or the node being popped right now),
// and all members must be off the calc stack (or the node being popped).
pred sccReadyToCommit[scc: Scc, poppingNode: Node] {
  all n: scc.members |
    scc.nstate[n] = SccDone or n = poppingNode
  all n: scc.members |
    n not in stackNodes or n = poppingNode
}

// The top of the stack has all deps resolved: pop it.
// A dep is resolved if it is globally Done, or SccDone/SccHasPlaceholder
// in the same SCC as the top node.
pred finishCalculation {
  CalcStack.depth > 0
  let top = stackTop |
  let topScc = sccOf[top] |
  {
    // Guard: all deps of top are resolved
    all dep: top.deps |
      dep.gstate = Done
      or (some topScc and dep in topScc.members
          and topScc.nstate[dep] in (SccDone + SccHasPlaceholder))

    // Effects depend on SCC membership
    no topScc => {
      // Case 1: Not in SCC — mark globally Done
      gstate' = gstate ++ (top -> Done)
      sccUnchanged
    } else {
      sccReadyToCommit[topScc, top] => {
        // Case 2: Last SCC member to finish — batch-commit
        gstate' = gstate ++ (topScc.members -> Done)
        // Deactivate the committed SCC
        topScc.members' = none
        no topScc.anchor'
        topScc.nstate' = none -> none
        // Other SCCs unchanged
        all s: Scc - topScc | {
          s.members' = s.members
          s.anchor' = s.anchor
          s.nstate' = s.nstate
        }
      } else {
        // Case 3: SCC member but others still in progress
        gstateUnchanged
        topScc.nstate' = topScc.nstate ++ (top -> SccDone)
        topScc.members' = topScc.members
        topScc.anchor' = topScc.anchor
        all s: Scc - topScc | {
          s.members' = s.members
          s.anchor' = s.anchor
          s.nstate' = s.nstate
        }
      }
    }

    popStack
    Trace.event' = FinishEvt
    Trace.acted_on' = top
  }
}

// The top of the stack has an InProgress dependency that is on the stack
// (or in an existing SCC whose members are on the stack): back-edge found.
// Create a new SCC or merge with existing overlapping SCCs.
pred detectCycle[dep: Node] {
  // Guards
  CalcStack.depth > 0
  dep in stackTop.deps
  dep.gstate = InProgress
  dep in stackNodes or some sccOf[dep]

  // Find the target position: dep's own stack position, or the deepest
  // (lowest index) stack position of any member of dep's SCC.
  let depScc = sccOf[dep] |
  let targetPos = (no depScc) =>
      stackPos[dep]
    else
      min[depScc.members.~(CalcStack.elems)] |
  let cycleMembers = { n: stackNodes | stackPos[n] >= targetPos } |
  // SCCs that overlap with the cycle members
  let overlapping = { s: activeSccs | some (s.members & cycleMembers) } |
  {
    targetPos >= 0

    // If cycle is already fully contained in one SCC, no-op
    (some s: activeSccs | cycleMembers in s.members) => {
      sccUnchanged
    } else {
      // Merge: union all overlapping SCC members with cycle members.
      // Reuse one SCC slot (or allocate a new one), deactivate the rest.
      let allMembers = cycleMembers + overlapping.members |
      let minAnchor = (some overlapping) =>
          min[overlapping.anchor + targetPos]
        else
          targetPos |
      // Pick a slot: reuse an overlapping SCC if available, else allocate
      let mergeInto = (some overlapping) =>
          { s: overlapping | s.anchor = max[overlapping.anchor] }
        else
          (Scc - activeSccs) |
      some target: mergeInto | {
        target.members' = allMembers
        target.anchor' = minAnchor
        // Existing SCC members keep their node_state; new members get SccInProgress
        target.nstate' =
          (overlapping.nstate) ++ (cycleMembers - overlapping.members) -> SccInProgress
        // Deactivate other overlapping SCCs (merged away)
        all s: overlapping - target | {
          s.members' = none
          no s.anchor'
          s.nstate' = none -> none
        }
        // Non-overlapping SCCs unchanged
        all s: Scc - overlapping - target | {
          s.members' = s.members
          s.anchor' = s.anchor
          s.nstate' = s.nstate
        }
      }
    }
  }

  gstateUnchanged
  stackUnchanged
  Trace.event' = DetectCycleEvt
  Trace.acted_on' = dep
}

// The top of the stack is in an SCC and has a dep that is SccInProgress
// in the same SCC. A placeholder (Type::Var) is created so computation
// can proceed with a temporary answer.
pred createPlaceholder[dep: Node] {
  CalcStack.depth > 0
  let top = stackTop |
  let topScc = sccOf[top] |
  {
    some topScc
    dep in top.deps
    dep in topScc.members
    topScc.nstate[dep] = SccInProgress
    // Mark dep as having a placeholder
    topScc.nstate' = topScc.nstate ++ (dep -> SccHasPlaceholder)
    topScc.members' = topScc.members
    topScc.anchor' = topScc.anchor
    all s: Scc - topScc | {
      s.members' = s.members
      s.anchor' = s.anchor
      s.nstate' = s.nstate
    }
  }
  gstateUnchanged
  stackUnchanged
  Trace.event' = PlaceholderEvt
  Trace.acted_on' = dep
}

pred stutter {
  gstateUnchanged
  stackUnchanged
  sccUnchanged
  Trace.event' = StutterEvt
  Trace.acted_on' = Trace.acted_on
}

fact Transitions {
  always {
    (some n: Node | startRoot[n])
    or (some dep: Node | descend[dep])
    or (some dep: Node | detectCycle[dep])
    or (some dep: Node | createPlaceholder[dep])
    or finishCalculation
    or stutter
  }
}

// --- Invariants ---

// Stack depth matches elements: elems has entries exactly at indices 0..depth-1.
pred stackConsistent {
  all i: Int |
    (i >= 0 and i < CalcStack.depth) iff some CalcStack.elems[i]
}

// Everything on the stack is globally InProgress.
// Corresponds to StackIsInProgress in TLA+.
pred stackIsInProgress {
  all n: stackNodes | n.gstate = InProgress
}

// A node that is Done has all deps Done.
// Corresponds to DepsBeforeDone in TLA+.
pred depsBeforeDone {
  all n: Node |
    n.gstate = Done implies all dep: n.deps | dep.gstate = Done
}

// No node appears in more than one SCC.
// Corresponds to SccMembersDisjoint in TLA+.
pred sccMembersDisjoint {
  all disj s1, s2: activeSccs |
    no (s1.members & s2.members)
}

// SCC members are globally InProgress (never Done while SCC exists).
// Corresponds to SccMembersGloballyInProgress in TLA+.
pred sccMembersInProgress {
  all s: activeSccs | all n: s.members |
    n.gstate = InProgress
}

// Active SCCs have distinct anchors (implicit stack ordering).
// Corresponds to SccStackOrdered in TLA+.
pred sccStackOrdered {
  all disj s1, s2: activeSccs |
    s1.anchor != s2.anchor
}

// Every active SCC has at least one member on the calc stack.
// Corresponds to SccHasLiveMember in TLA+.
pred sccHasLiveMember {
  all s: activeSccs |
    some (s.members & stackNodes)
}

// --- Exploration commands ---

// Show a trace where all nodes reach Done.
run show {
  eventually all n: Node | n.gstate = Done
} for exactly 4 Node, exactly 2 Scc, 5 Int, 12 steps

// Show a trace with a multi-node SCC that resolves.
run showCycle {
  some s: Scc | eventually #s.members >= 2
  eventually all n: Node | n.gstate = Done
} for exactly 4 Node, exactly 2 Scc, 5 Int, 15 steps

check StackConsistent {
  always stackConsistent
} for exactly 4 Node, 4 Scc, 5 Int, 10 steps

check StackIsInProgress {
  always stackIsInProgress
} for exactly 4 Node, 4 Scc, 5 Int, 10 steps

check DepsBeforeDone {
  always depsBeforeDone
} for exactly 4 Node, 4 Scc, 5 Int, 10 steps

check SccMembersDisjoint {
  always sccMembersDisjoint
} for exactly 4 Node, 4 Scc, 5 Int, 10 steps

check SccMembersInProgress {
  always sccMembersInProgress
} for exactly 4 Node, 4 Scc, 5 Int, 10 steps

check SccStackOrdered {
  always sccStackOrdered
} for exactly 4 Node, 4 Scc, 5 Int, 10 steps

check SccHasLiveMember {
  always sccHasLiveMember
} for exactly 4 Node, 4 Scc, 5 Int, 10 steps
