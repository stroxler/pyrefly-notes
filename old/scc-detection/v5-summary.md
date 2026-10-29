 Pyrefly SCC Handling Improvements: V5 Plan Summary

  This plan outlines the roadmap for improving Strong Connected
  Component (SCC) handling to ensure correctness, isolation, and
  determinism in type checking.

  Core Goals
   1. Prevent `Var` Leakage: Ensure type variables created within
      an SCC do not escape unfinalized.
   2. Determinism: Guarantee consistent type checking results
      regardless of thread scheduling (though commit order remains
      deterministic).
   3. Isolation: Intermediate results should be invisible outside
      the active SCC until fully resolved.

  Key Architectural Concepts
   * Thread-Local Preliminary Storage: Intermediate answers are
     stored locally in the Scc struct (preliminary_results) rather
     than the global Calculation storage.
   * Batch Commit: Answers are written to global storage only when
     the entire SCC completes.
   * Leader Election: The first thread to write a "minimal" answer
     becomes the leader and commits the entire SCC; others wait.
   * Top-SCC Isolation: Reading answers for nodes in the current
     SCC is restricted to the local preliminary storage (enforced
     by "merge-before-read" logic).

  Implementation Phases

  Phase 0: Debug Infrastructure
   * Add zero-cost debug_println! macros and instrumentation to
     key SCC methods (on_scc_detected, merge_sccs, etc.) for
     introspection.

  Phase 1: Preliminary Storage & Batch Commit
   * 1a: Add preliminary_results to the Scc struct to hold
     type-erased answers (Box<dyn Any>) and pending errors.
   * 1b: Implement the batch commit protocol. When an SCC is
     complete:
       * Perform leader election (first-write-wins on minimal
         CalcId).
       * Leader commits all results to global storage (including
         cross-module answers via LookupAnswer).
       * Non-leaders spin-wait for the leader to finish.

  Phase 2: Enforce Top-SCC-Only Invariant
   * Restrict visibility: Calls to get_idx for nodes in the active
     SCC must read from preliminary_results, never global storage.
   * Add debug assertions to catch violations.

  Phase 3: Var Leakage Prevention
   * Track: Register every Var created via fresh_* with the active
     SCC.
   * Validate: Before committing, ensure all registered Vars in
     the answer have been resolved (forced).
   * Fallback: If validation fails, force remaining Vars
     immediately to prevent leakage (and log as a bug).

  Deferred Phases (4-6)
   * Restart after Merge: Restart computation from the break point
     when SCCs merge.
   * Fixpoint Iteration: Re-solve SCCs iteratively for precise
     recursive types.
   * Simplify: Optimize placeholder representations after
     stabilization.
