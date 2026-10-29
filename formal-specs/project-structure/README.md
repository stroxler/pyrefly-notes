# Python project structure

**Status:** domain discovery and modeling proposal. No executable formal model has
been checked yet.

The goal is to understand the domain, not to encode Pyrefly's current rules.
Python and packaging references constrain the semantics; Pyrefly, pyright, ty,
zuban, mypy, and issue reports provide examples and counterexamples. The model may
motivate substantial implementation refactors.

## Design objective

Consider both the real world and a simple, modular system for handling it.
Preserve meaningful domain distinctions, but simplify their representation at
boundaries so the most complex core has fewer concepts and actions to handle.
Discovery and event adapters can normalize different mechanisms into shared
inputs and operations. They must preserve relevant context and interactions;
normalization is not a reason to assume the underlying features are independent.

## Documents

- [Modeling proposal](proposal.md): domain distinctions, observation boundaries,
  candidate properties, temporal behavior, and a staged Alloy 6 approach.
- [Open-issue audit](issue-audit.md): motivating scenarios and questions from open
  Pyrefly reports, with explicit coverage and evidence limits.

## One world, interacting features

Specification files may be modular, but scenarios must share one world. Editable
installs, interpreter and virtual-environment location, symlinks, ordered import
providers, namespace packages, stubs, configuration, and incremental updates
interact. Do not assume these are independent problems or validate only isolated
feature models.

Start with combined scenarios such as an editable project reached through a
symlink from an environment outside the workspace, then remove or recreate that
environment, change the alias target, or introduce a competing package or stub.
The model should reveal which inputs determine each result and which observations
are insufficient to determine it.

Keep semantic module identity, resource identity, distribution provenance,
configuration applicability, checking scope, and modification intent distinct.
Tool-specific policies should be explicit parameters rather than hidden axioms.

## Synthetic engine events

Real-world changes need not be engine primitives. An editable-install retarget can
be represented as deleting the old installation contribution and creating the
new one, rebuilding its derived state rather than adding a special fast path.
These are logical events: neither source tree is deleted, and contributions from
other installations must remain intact.

Compare the composed operation's outcomes after reconciliation. If intermediate
absence must not be visible, the pair needs a shared publication boundary, not
necessarily a new engine primitive. The model is a planning and auditing tool;
this comparison is not a proof of implementation correctness.

## Validation expectations

- Maintain a source ledger for semantic claims and open policy questions.
- Exercise interactions across layouts and event chains, not only per-feature cases.
- Seek allowed worlds with identical observations but different required answers.
- Keep reference semantics separate from candidate discovery algorithms.
- Record scope bounds, assumptions, counterexamples, and deliberate broken variants.
- Use implementation comparisons as evidence, not a majority-vote oracle.
