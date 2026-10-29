# SCC solving: an audit retrospective

The provenance for the model-assisted audit is the
[original gap analysis in learn-specification](https://github.com/stroxler/learn-specification/blob/8b673158bf56a3f9cf618163260cf9e2ade83a16/tla%2B/pyrefly_fixpoint/spec-issues.md).
It records the concerns raised against the intended protocol. The fixing-commit
links below were reconstructed later; that is separate evidence, not an
original six-bug attribution ledger.

## The clearest worked example

A dependency path could leave an SCC and re-enter it without adding the
intervening calculation to the component. That allowed a preliminary answer
to escape. The [April 3 fix](https://github.com/meta/pyrefly/commit/7d09729fcf1c5d074277ded418822649d1ec4430)
explicitly describes the missing merge as a violation of the specification's
no-leakage contract. Its reported 6,000-run SymPy check found no nondeterminism
at that checkpoint. This supports a specification-guided audit story; the
commit does not distinguish the TLA model from the earlier Markdown contract.

## Concerns recorded by the original audit

- **Duplicated progress state:** the audit flagged two per-node state maps.
  [Unifying them on April 1](https://github.com/meta/pyrefly/commit/0c61ae9203de9399794ac6f3da8faa131eb5a165)
  reduced the bookkeeping that had to stay synchronized. This was a structural
  simplification, not a separately reproduced nondeterminism fix.
- **Local lifecycle versus shared results:**
  [separating stack handling from the cache on April 2](https://github.com/meta/pyrefly/commit/1bf73739f226b1f0d02fd9d2945f9e348a17ba57)
  clarified which state governs recursion. Reusing a published final answer
  is legitimate; the original suspicion of all shared reads was too broad.
- **Missing-state fallbacks:** [debug assertions](https://github.com/meta/pyrefly/commit/c87d6f4752f74f76c164fa752441b1b19dc20309)
  made violations visible, but did not resolve every underlying path.
- **Restart and lifetime:** [explicit caller handoff](https://github.com/meta/pyrefly/commit/96330511ef81267ab37ecf1e1bc97b2835d91056)
  and [retained answer generations](https://github.com/meta/pyrefly/commit/9c4463c7849d91d7dbaea7114a13b6918e7f76bf)
  later clarified the contract. A pass can be invalid for publication while
  its answers remain available to active readers. Eager deletion was not the
  right literal interpretation of the simplified model.

These links associate later changes with recorded concerns. They do not
independently establish that the formal model caused every change.

## Later bug fixes, not attributed to the original model-assisted episode

- **July 29:** [caller-membership re-entry](https://github.com/meta/pyrefly/commit/99604f5e70d5bf9bca1638bdc055e2c9647bf4b4)
  and [overlap detection](https://github.com/meta/pyrefly/commit/63412a1f8907549497f2da4ad79890c7c6fcc2ef)
  addressed concrete SymPy and Apprise failures. The
  [unreliable upper-bound bookkeeping was then removed](https://github.com/meta/pyrefly/commit/5d3b33fb09e8f509aaa270e06b1a677b054dfda0).
- **September 8:** [live members were distinguished from queued work](https://github.com/meta/pyrefly/commit/eb1548d976209c45826423d499abd88ac22e27d2),
  preventing a shared-answer shortcut from removing an active caller. A
  deterministic regression demonstrated the old initialization's failure.

## Attribution boundary

The early-March framework fixes are excluded from the conservative
formal-model-assisted account: they precede the committed TLA model history.
Uncommitted work could change that chronology, so this exclusion does not
contradict the author's recollection. The earlier Markdown contract is a
separate source of intent, not evidence that the later TLA model existed then.

The original audit is a record of findings and questions, not proof that every
allegation was a bug. The design's discovery assumption remains explicit in
[the sketch](DESIGN.md); current code findings are kept separate in
[the audit context](AUDIT.md).
