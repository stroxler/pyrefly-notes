# SCC solving: a retrospective

The post-hoc specification gave auditing a reference contract: calculations
that depend cyclically must be solved together, provisional results must stay
local, and completion must leave no active work behind. The changes below
show how the implementation evolved around that contract, through fixes,
structural simplifications, and later refinements.

## What changed

- **Missed members leaked provisional answers.** A path could leave an SCC
  and re-enter it without bringing the intervening calculation into the
  component. The no-leakage contract made this suspicious;
  [the April fix](https://github.com/meta/pyrefly/commit/7d09729fcf1c5d074277ded418822649d1ec4430)
  added absorption, and July's
  [caller-membership check](https://github.com/meta/pyrefly/commit/99604f5e70d5bf9bca1638bdc055e2c9647bf4b4)
  and [overlap check](https://github.com/meta/pyrefly/commit/63412a1f8907549497f2da4ad79890c7c6fcc2ef)
  replaced unreliable positional shortcuts.

- **Stack-bound accounting drifted.** Balancing pushes and pops was fragile
  when membership changed between them.
  [Two missing increments were repaired](https://github.com/meta/pyrefly/commit/347814292508f2107020f2ceefc2cea2bcedfecd);
  after membership-based detection replaced its readers, the
  [upper-bound field and bookkeeping were deleted](https://github.com/meta/pyrefly/commit/5d3b33fb09e8f509aaa270e06b1a677b054dfda0).
  This removed the unreliable running total, not the stable completion anchor.

- **Expansion did not always request a restart.** Absorbing previously
  untracked calculations could grow membership without invalidating the pass.
  [The fix marked that expansion](https://github.com/meta/pyrefly/commit/55b435306d420cfa15418c9bf53c9aa3f08134de),
  matching the spec's restart contract. Restart remained
  [deliberately deferred until the pass unwound](https://github.com/meta/pyrefly/commit/d07528cc1717c8eaacddb7ab89f572ce1887ccf8)
  to avoid repeatedly driving the same members.

- **Two progress maps obscured one protocol.** Discovery and iteration
  maintained parallel per-node state maps.
  [Unifying them](https://github.com/meta/pyrefly/commit/0c61ae9203de9399794ac6f3da8faa131eb5a165)
  removed redundant bookkeeping and made comparison with the spec's single
  state machine easier; this was a structural simplification, not a separately
  demonstrated nondeterminism fix.

- **A merged component could lose its driver.**
  [The first fix](https://github.com/meta/pyrefly/commit/9cd13c27f9123c69311df144ba08772e9e50b971)
  prevented yielding to a nonexistent ancestor driver. Later,
  [explicit caller handoff](https://github.com/meta/pyrefly/commit/96330511ef81267ab37ecf1e1bc97b2835d91056)
  kept absorbed active work alive, and
  [marking discovered members as in progress](https://github.com/meta/pyrefly/commit/eb1548d976209c45826423d499abd88ac22e27d2)
  stopped a shared-answer shortcut from mistakenly removing an active caller.

- **Concurrent publication could interleave component results.**
  [Ordered ownership before publication](https://github.com/meta/pyrefly/commit/dc25fba53ab340fce1135ba92ded51c5796035a0)
  serialized workers solving the same component. The component-wide publication
  contract highlighted the risk; non-identical overlapping components remain
  an explicit boundary of the design.

- **Evicted module state could leave iteration stuck.** A drive could do no
  work yet leave the same calculation queued forever.
  [Removing unstarted work after a no-op drive](https://github.com/meta/pyrefly/commit/f7776174d5ee187a2cb3909cab9f79f10d9913d4)
  fixed that loop. Eviction is outside the model, so this is an operational
  repair rather than evidence that the model covers module lifetime.

- **The caller could receive an old answer after a successful fixpoint.**
  [Rereading the published answer](https://github.com/meta/pyrefly/commit/ce47d1cbfc649e2392419a1ee6b0ca4d3ce1c0f0)
  replaced the discovery-phase return value. This directly serves the
  no-provisional-answer-leakage contract: a correct cache alone was not enough.

- **Local tracking and shared-cache decisions were entangled.**
  [Removing the cache dependency from stack handling](https://github.com/meta/pyrefly/commit/1bf73739f226b1f0d02fd9d2945f9e348a17ba57)
  clarified the local state machine. The old review's blanket suspicion of
  shared reads was too broad: reusing another worker's published final answer
  is not itself a provisional leak.

## What the history does not establish

Missing-state fallbacks received
[debug assertions](https://github.com/meta/pyrefly/commit/c87d6f4752f74f76c164fa752441b1b19dc20309),
but this was a diagnostic mitigation, not a complete resolution. Likewise,
retaining answers during unwind is intentional:
[the later generation-based representation](https://github.com/meta/pyrefly/commit/9c4463c7849d91d7dbaea7114a13b6918e7f76bf)
makes both their lifetime and the required cold restart explicit.

The commits report improved repeatability on SymPy and Apprise. Those are
historical test outcomes, not a guarantee that every source of nondeterminism
was eliminated. The missed-reentry commit explicitly attributes its finding
to a violation of the specification; elsewhere, these entries connect changes
to the contract without claiming the spec caused every fix.

The remaining discovery assumption and current model gaps are summarized in
[the audit](../AUDIT.md); detailed transition explanations live in the spec
comments and the linked commits.
