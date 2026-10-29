# Modeling Python project structure

## Recommendation

Start with an implementation-independent Alloy 6 domain model, then add an observation model and temporal transitions. Do not begin by formalizing Pyrefly's caches, configuration structs, or editable-install heuristics. Those are candidate implementations whose assumptions the domain model should test.

The goal is a vocabulary and a set of justified semantic contracts that describe Python projects across tools. A good outcome may be a significant Pyrefly refactor, a new discovery protocol, or the discovery that some questions cannot be answered from the information currently available.

This is an initial modeling proposal, not an executable or checked formal specification. No model-checking results are claimed.

## 1. There is no single project tree

Several different structures coexist:

- **Storage:** paths, directory entries, resources, symlink targets, existence, and contents. Path spelling, resolved location, and the identity of a resource incarnation are different concepts.
- **Source/build projects:** source trees, build configuration, generated artifacts, and the relationship between development sources and what a build exposes. A repository can contain several such projects.
- **Distributions and installations:** separately installable distributions, their metadata, and particular installations into particular environments. An editable installation relates an installation to a source project; it does not replace the environment or distribution concepts.
- **Import structure:** qualified module names, modules, regular packages, namespace portions, finders, providers, and ordered search locations in a particular execution context.
- **Type-information structure:** inline annotations, adjacent stubs, separate complete/partial stub packages, namespace stubs, and typeshed. This is related to but distinct from runtime import structure.
- **Analysis context and intent:** target version/platform, invocation assumptions, selected environment, open buffers, configuration applicability, checking scope, and the user's intent about which files tools may modify.

Relationships are not generally one-to-one. Several distributions may contribute to one namespace package. A distribution may expose several import packages. The same physical source may be reachable under different module names or in different environments. A stub and its runtime implementation may belong to different distributions and reside in different locations.

In particular, avoid a single primitive relation called `owns`. At minimum, distinguish distribution provenance, configuration applicability, import visibility, diagnostic scope, and modification permission. Their relationship is something to investigate, not an axiom.

## 2. Separate semantic facts, incomplete evidence, and policy

### Semantic core

Use Python's import reference, namespace-package specification, packaging specifications, and typing specification to define the supported semantic profiles. Keep MUST, SHOULD, examples, and unspecified behavior distinct.

Important starting constraints:

- Import lookup is contextual and ordered, not membership in a set of roots.
- Under the standard path-based finder, a namespace portion encountered earlier does not prevent a later concrete module or regular package from winning. Namespace portions are combined only when that search finds no concrete module/package.
- Resolving a dotted name proceeds through its parents. A submodule searches its resolved parent's package path, rather than restarting unrestricted global lookup for the entire dotted name.
- Runtime modules need not come from a filesystem directory. Builtins, frozen modules, archives, and custom finders need representable extension points.
- Type-information lookup is not runtime lookup. Model adjacent `.pyi` precedence, stub distributions, partial merging, namespace fallback, and target-version information separately.
- Editable distribution metadata identifies installation mode and source-project provenance. It does not specify a complete module-to-source map.

### Observation model

A tool sees an incomplete, possibly stale subset of the world: files it has read, interpreter-query results, client configuration, build metadata, and watcher notifications. Define these as observations of the semantic world rather than making them the world itself.

Distinguish:

- not observed;
- successfully observed absence or an empty result;
- failure to observe;
- stale observation;
- positive and negative evidence of a particular fact.

Do not assert that a successful interpreter query is an eternally authoritative description of every import provider. Queries have a scope, execution context, and observation time; arbitrary hooks may not expose a static mapping.

One especially useful Alloy query asks for **two allowed worlds that produce the same observations but require different answers**. Such an instance demonstrates that the observations are insufficient. This can reveal the need for another query, an explicit user declaration, a build-backend interface, or an honest unsupported/unknown result.

### Policy layer

Python does not prescribe which nested analyzer config wins, what an editor workspace means, which files receive diagnostics, or which external sources an IDE may rename. Those are real parts of the tooling problem, but not facts derived solely from Python import semantics.

Represent explicit analysis intent and candidate policies separately. Evaluate their consistency and user-facing consequences. Do not disguise one tool's default as the true domain.

## 3. A particularly important editable-install distinction

PEP 660 guarantees editable-install behavior but permits different mechanisms. Its examples include path insertion, proxy modules, and symlink structures. The `direct_url.json` URL points at the project directory; it does not guarantee that the importable files are exactly `<project>` or `<project>/src`.

Consequently, the proposed semantic model must represent **exposure of module names to source resources**, not merely positive directory prefixes. Directory-root matching can be a discovery strategy for a supported profile, but cannot define editable installations universally.

For example, a path-based installation may expose additional scripts in a project directory; a more precise proxy-based installation can expose only selected modules. Both are legitimate mechanisms. Importability, membership in the source project, and permission to refactor remain separate questions.

The Pyright import-resolution document explicitly identifies import-hook-based editables as beyond its static discovery capability. Treat this as evidence of an information boundary, not evidence that such projects are invalid Python projects.

## 4. What the stack contributes

The current editable-install work provides useful counterexample families, not normative definitions:

- An import-path entry is not itself proof of editable provenance.
- A broad source ancestor can contain installed dependencies; nested positive and negative boundaries cannot be reduced to one global flag.
- Canonical comparison keys and import-path spelling have different jobs.
- Metadata can change while Python source files do not.
- Removing an environment can erase the current evidence needed to notice its restoration.
- A successful query can omit an absent directory, not just fail entirely.
- Recreating files at the same paths can change their contents without changing the set of roots.
- Changes unrelated to an environment should not force that environment to be requeried.

These suggest broader questions: how are observations invalidated, how are absent-but-relevant locations tracked, and how does the tool distinguish a resource's new incarnation from its old cached content? The answers should not require copying the stack's particular retained-owner map or cache design.

## 5. Static counterexamples beyond editable installs

The first model should actively generate layouts that disprove tempting assumptions:

- **Namespace versus regular package:** `r0/pkg/part.py` with no `r0/pkg/__init__.py`, and `r1/pkg/__init__.py` with no `part.py`, with search order `[r0, r1]`. Under the standard path-based finder and fresh imports, the regular package in `r1` wins; the earlier namespace portion is not a second location for its children. This is a source-derived reference scenario, not a claim that every static type-information view must use the same resources.
- **One file, several names:** with roots `/repo` and `/repo/pkg`, `/repo/pkg/mod.py` can be exposed as both `pkg.mod` and `mod`. The model must not impose a unique name per physical file. A tool may choose a preferred name as policy, but that is not a Python semantic invariant.
- **Different runtime and interface locations:** a runtime package and a separate partial stub distribution can contribute different pieces of the typing view. Ordinary runtime shadowing, complete stub replacement, and partial stub merging need separate rules.
- **Several analysis contexts:** one source file may participate in multiple build targets or workspaces with different dependencies and target environments. The file alone cannot necessarily determine a unique resolution context.
- **Overlay versus disk:** an open unsaved document can differ from the file an importer would see on disk. Whether the analysis view overlays imports, creates virtual modules, or treats the document separately is an explicit contract.

The independent Pyrefly code pass found separate forward-resolution and reverse-naming walks, mode-dependent configuration/membership rules, and file/build-target context selection. These motivate the examples and refactor hypotheses; derived implementation counterexamples were not executed, so this proposal does not report them as verified Pyrefly bugs.

## 6. Temporal model

Keep three things separate: a world mutation, an observation/notification, and a tool computation. A filesystem change does not magically update an analyzer snapshot.

Useful transitions include:

- create/delete/replace/move a file or directory;
- retarget a symlink;
- install/uninstall/replace a distribution;
- change import-provider registration or ordered paths;
- change target environment or analysis intent;
- change project/build/configuration metadata;
- open/edit/close an overlay;
- start/complete/fail a query or discovery pass;
- deliver/coalesce/reorder a notification;
- reconcile observations and publish a new analysis view.

Distinguish real-world transitions from the engine's synthetic event vocabulary. For example, an editable-install retarget may normalize to deleting the old installation contribution followed by creating the new one, rebuilding affected derived state. This does not delete either source tree or unrelated installations. Compare reconciled outcomes; if intermediate absence must be hidden, use a shared publication boundary. A specialized retarget primitive needs a concrete semantic or performance justification.

Expose multi-step installations and non-atomic reads where useful, since real processes can observe partial installation states. Fair scheduling does not turn an inherently insufficient observation into complete knowledge.

Within the model, a useful consistency criterion is **observational equivalence with an independent reference interpretation**, not equality of internal cache or watch sets. After external changes stop, and assuming sufficient observations are eventually obtained and processing progresses, the incremental view should converge to the reference view for the declared supported profile. This is a planning and auditing criterion, not a claim to prove Pyrefly's implementation correct or to establish a formal model-to-code relation.

That reference is a fresh static-analysis interpretation of the declared world/context/policy, not whatever an already-running CPython process currently has in `sys.modules`. Runtime module caching deliberately preserves history in ways an editor's fresh-analysis target need not preserve.

Additional proposed contracts:

- A result advertised as current must not silently depend on invalidated observations.
- Failed or missing observations must not be upgraded into unjustified positive facts.
- A computation finishing after its input context has been superseded must not overwrite a newer published view.
- Directory replacement must invalidate dependent contents as well as import-location results.
- A disappearing relevant location must remain discoverable through a retained observation dependency or a reconciliation mechanism.
- Context-isolated changes should preserve unaffected results, subject to any genuinely shared dependencies.

Lost notifications require an explicit recovery assumption, such as a rescan or another observation source. Unconditional eventual convergence with arbitrarily lost events and no reconciliation is impossible. Watcher behavior belongs in the observation contract, not in Python's semantics.

## 7. Alloy 6 first; a second temporal language only when justified

Alloy is a natural fit for overlapping relations, identity/spelling distinctions, namespace contributions, distribution provenance, and counterexample generation across small project layouts. Model order explicitly; a relational model must not accidentally discard search precedence.

Alloy 6 also supports mutable relations, next-state expressions, temporal operators, and lasso traces. It can express both event-chain scenarios and liveness contracts. Begin with small scopes and bounded traces; when stable, use complete temporal checking for small finite scopes with a supported NuSMV/nuXmv backend. Unbounded time does not mean an unbounded filesystem universe or a proof of arbitrary Rust code.

A complementary TLA+ model becomes valuable if query concurrency, scheduling, atomic publication, and reconciliation protocols dominate the problem. Quint is attractive if executable transition traces and a replay harness are the main benefit. Do not maintain two copies of the entire semantic domain simply because both languages are available. Share scenario formats, vocabulary, and explicit correspondence tests if a second model is added.

## 8. A staged repository project

Home: `formal-specs/project-structure/` in `stroxler/pyrefly-notes`.

Keep the specification modular for readability, but interpret the modules in one shared world. Do not assume editable exposure, virtual-environment location, path aliasing, package resolution, and observation lifecycles decompose independently. Run combined layouts and transitions from the first executable milestone; extend their interaction coverage as the model grows.

The [open-issue audit](issue-audit.md) is a source of motivating cases and unanswered questions, not an alternative source of normative semantics.

1. **Domain vocabulary and source ledger.** For each claim, record its source and whether it is guaranteed, recommended, conventional, a tooling limitation, or an open policy question.
2. **Static Alloy core.** Cover contextual ordered path imports, regular and namespace packages, source/distribution/installation distinctions, and a typing-view extension. Show small illustrative instances and disproved naive assumptions before adding caches.
3. **Observation and information-sufficiency model.** Compare different worlds with identical available evidence. Include hook-based editables, aliases, missing paths, and incomplete query results.
4. **Temporal contracts.** Add changes to project structures and delayed observations. Reproduce the stack's disappearance/recreation families, then combine them with namespace, config, and environment changes.
5. **Candidate implementation/refinement model.** Encode a simple discovery/reconciliation algorithm separately and check it against the semantic contracts. Deliberately broken variants should produce counterexamples, guarding against tautological assertions or overconstrained facts.
6. **Trace replay and implementation comparison.** Materialize model scenarios as fixtures. Use CPython as an oracle for the declared runtime subset; the typing specification and explicit intent for the static view. Run Pyrefly, pyright, ty, zuban, and mypy as evidence, with equivalent target context and documented differences. Tool agreement is not a replacement for the reference contract.

Store counterexamples and their expected semantics, not just the final no-counterexample checks. A useful first milestone is a checked small model that demonstrates why several plausible simplifications are false and reproduces one temporal bug family; not a claim to have captured every Python project.

## 9. Refactors the model may motivate

These are architectural hypotheses, not conclusions already proved by a model:

- Separate analysis scope, modification intent, import exposure, and distribution provenance instead of asking one root list to answer all four.
- Key semantic module identity by an appropriate context plus qualified name; share physical contents separately when safe.
- Have discovery return an explicit result with evidence/dependencies and supported capabilities, rather than only path lists.
- Make a resolved analysis view immutable, with explicit observation validity and publication rules.
- Track dependencies on absence and on provider/search ordering, not only dependencies on files that were successfully found.
- Put installation mechanisms behind provider adapters whose limitations are explicit; avoid encoding `src` layouts or virtual-environment naming conventions into the core domain.

Whether a single snapshot/generation scheme is sufficient, whether multiple observation versions are required, and whether reconciliation is preferable to retained historical watches should be determined by the model and practical cost constraints.

## Sources consulted

Normative/reference sources:

- Python import system: https://docs.python.org/3/reference/import.html
- Python path initialization: https://docs.python.org/3/library/sys_path_init.html
- Python site initialization: https://docs.python.org/3/library/site.html
- Namespace packages: https://peps.python.org/pep-0420/
- Editable installations: https://peps.python.org/pep-0660/
- Direct URL metadata: https://packaging.python.org/en/latest/specifications/direct-url-data-structure/
- Type-information distribution and lookup: https://typing.python.org/en/latest/spec/distributing.html
- Alloy 6 temporal capabilities: https://alloytools.org/alloy6.html

Implementation evidence:

- Pyrefly's current editable-install and project-structure work informed the counterexample families and architectural hypotheses. These are not claims that every later implementation version behaves identically.
- Pyright's documented import-resolution strategies and limitations: https://github.com/microsoft/pyright/blob/main/docs/import-resolution.md
- Notes repository: https://github.com/stroxler/pyrefly-notes

The Python `/3/` references are moving documents. Executable models should pin specific version/platform profiles and citations; startup behavior in particular changes between versions. This initial proposal does not claim a comparative audit of all five type checkers. The accompanying issue audit records its own coverage and evidence limits.
