// Dynamic graph schedule generator (scaffold)
//
// This Alloy model is intentionally minimal. It documents the target shape
// and the two simulation assumptions used for SCC-discovery-complete cases.
//
// These assumptions are stronger than real-world behavior by design.

sig Node {}

one sig Params {
  // Number of dynamic graph steps generated.
  step_count: one Int
}

one sig FullGraph {
  edges: Node -> Node
}

// Dynamic graph by step index (0..steps-1), represented as step-scoped edges.
sig Step {
  idx: one Int,
  edges: Node -> Node
}

// Nodes that participate in at least one directed cycle in FullGraph.
// Uses transitive closure, so this includes both multi-node cycles and
// self-loops.
fun FullCycleNodes: set Node {
  { n: Node | n in n.^(FullGraph.edges) }
}

// The initial dynamic step (idx = 0).
fun InitialStep: set Step {
  { s: Step | s.idx = 0 }
}

// Nodes that participate in at least one directed cycle in step 0.
fun InitialDynamicCycleNodes: set Node {
  { n: Node | some s: InitialStep | n in n.^(s.edges) }
}

// Soundness: every dynamic edge must be a true edge.
fact DynamicIsSubsetOfFull {
  all s: Step | s.edges in FullGraph.edges
}

// Useful simulation cases require at least one true cycle.
fact NonEmptyFullCycleSet {
  some FullCycleNodes
}

// For initial exploration, keep the schedule horizon fixed.
fact FixedStepCount {
  Params.step_count = 4
}

// Step indexing: steps are exactly indexed 0..step_count-1.
fact StepIndexing {
  all s: Step | s.idx >= 0 and s.idx < Params.step_count
  all i: Int | (i >= 0 and i < Params.step_count) implies one s: Step | s.idx = i
}

// Simulation assumption: cycle participants in the initial dynamic graph
// exactly match cycle participants in the full graph.
fact InitialCycleNodesMatchFull {
  InitialDynamicCycleNodes = FullCycleNodes
}

// Coverage: every true edge must appear in at least one dynamic step.
fact EveryFullEdgeAppearsInSomeStep {
  all src, dst: Node |
    src->dst in FullGraph.edges implies some s: Step | src->dst in s.edges
}

// Note: extraction tooling converts Alloy JSON traces into TLA constants.

run {
  some Node
} for 4 Node, exactly 4 Step, 6 Int
