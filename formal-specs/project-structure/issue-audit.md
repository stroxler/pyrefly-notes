# Open Pyrefly issues: project-structure evidence

## Coverage and limits

Snapshot: **2026-10-29T16:42:42Z**. Paginated REST enumeration of
`facebook/pyrefly` returned 724 open items: **583 issues** and 141 pull requests.
All 583 issue IDs were unique. The repository's reported open-item count matched
the enumeration. GitHub returned canonical issue URLs under `meta/pyrefly`.

Keyword triage over the issue titles and bodies produced 168 candidates involving
configuration, layouts, imports, environments, stubs, aliases, incremental state,
or externally supplied structure. We inspected 45 selected bodies in full or in
substantial excerpts, and comment excerpts on 14 distinct issues. Enumeration is
complete for this snapshot; the detailed audit is selective, not a claim that all
583 reports were investigated. Issue contents and state can change after this date.

This audit covers Pyrefly's tracker only. Reports and requested behavior are
**evidence, not normative specifications**. We did not execute the reproductions,
verify every proposed cause, or audit competitor trackers. Python and packaging
references for the model are collected in [the proposal](proposal.md); issue
claims about standards still need to be checked against the appropriate
version-specific reference before becoming model constraints.

## Main finding

The strongest reports combine concerns rather than staying inside one subsystem:

- Editable exposure, per-project environments, and configuration applicability.
- Environment location, dependency configuration, and type-information selection.
- Stub/runtime roots, import context, and nominal identity.
- Symlinks, interpreter discovery, and incremental invalidation.
- Unsaved documents, filesystem modules, and downstream importer state.

Use one shared world with explicit storage, installation provenance, import
contexts, type-information providers, analysis intent, and observations. Modular
specification files should not imply independent feature models.

## Fifteen primary reports

### 1. Context and configuration boundaries

**[#3556](https://github.com/meta/pyrefly/issues/3556): multiple venvs in one check.**
A monorepo report describes a `DataFrame` being rejected where the displayed
expected type is also `DataFrame`. Follow-up reproduction output varies with
single-file versus project invocation, `VIRTUAL_ENV`, and workspace-folder
layout. The reporter's initial explanation of duplicate class objects is
explicitly AI-assisted; the reproduction output is evidence, but that causal
explanation is not independently established.

Model question: which context governs the imports of shared library source? A
file can participate in several applications and environments. Equal distribution
names, versions, or displayed type names must not automatically imply equal
runtime objects or static nominal identities.

**[#5131](https://github.com/meta/pyrefly/issues/5131): configuration shipped in a dependency.**
The report provides a wheel-like dependency containing `mypy.ini`, an external
site-packages directory, and migration warnings during a check of unrelated user
code. Moving the environment inside the project changes the observed behavior;
the follow-up also reports different type results. Why a particular discovery
root is selected remains an implementation hypothesis.

Model question: how are configuration applicability and installation provenance
related? Ignoring a dependency's development configuration when checking an
application is a candidate tooling policy, not a rule prescribed by Python.
Editable dependencies and explicit user configuration may need different
contracts.

**[#3788](https://github.com/meta/pyrefly/issues/3788): nested per-project environments.**
A multi-root editor workspace fails to locate third-party imports from a nested
venv. Maintainer comments describe upward environment discovery rather than
recursive venv crawling and suggest nested configuration as a workaround. This
is evidence about one discovery strategy, not a requirement for the domain.

**[#4381](https://github.com/meta/pyrefly/issues/4381): a Nix monorepo without a venv.**
CLI and LSP import results differ. The reporter describes project source roots
also appearing in interpreter-provided paths. The cause is unresolved. Include
non-venv environments so directory naming does not silently define environment
identity or source ownership.

### 2. Checking scope is not import context

**[#3005](https://github.com/meta/pyrefly/issues/3005): tests in a src layout.**
Imports involving `tests/conftest.py` work under the test runner but fail in the
checker. Maintainer comments distinguish `project-includes` from import roots.
Related [#2686](https://github.com/meta/pyrefly/issues/2686) concerns a bare import
from a tests directory. Model runner assumptions explicitly rather than deriving
import visibility from the set of files selected for diagnostics.

**[#4403](https://github.com/meta/pyrefly/issues/4403): meanings of exclusion.**
The discussion exposes competing meanings of exclusion: suppress diagnostics,
omit indexing, or make a file unavailable. These are separate policies and
relations. A directly selected file may be checked even if no runtime import name
reaches it, so do not assume that checked files are a subset of runtime-importable
files.

### 3. Runtime resources, interfaces, and identity

**[#4439](https://github.com/meta/pyrefly/issues/4439): stubs and source across root categories.**
A reporter supplies a reproduction and a result matrix: a stub package on
`search-path` with its importable runtime package in site-packages yields
`missing-source`, while several same-category arrangements work. The reproduction
includes successful runtime-import output. We have not run it ourselves.

Model question: are runtime presence and interface selection independent queries,
and how are their answers associated across roots? A root's implementation
category should not stand in for the semantic distinction between an interface
and its implementation.

**[#4425](https://github.com/meta/pyrefly/issues/4425): inconsistent type providers.**
The report describes an `openpyxl` class selected from bundled stubs in one
context and installed source in another. Use it to investigate context keys,
provider selection, and identity—not to assume all similarly named classes must
be unified.

**[#2859](https://github.com/meta/pyrefly/issues/2859): editable source and installed stubs.**
The reported package combines an editable source mapping with generated stubs
beside an extension in site-packages. Stubs are found in a non-editable
arrangement but not in the editable one. A contributor's later minimal example
uses a different stub-overlay arrangement and should not replace the original
scenario.

### 4. Package structure and names

**[#5223](https://github.com/meta/pyrefly/issues/5223): relative imports in migration files.**
The report uses a filename such as `0001_initial.py` and a parent-relative import.
The suspected naming cause is unverified. Keep the importing package context
separate from restrictions of identifier syntax in an ordinary import statement;
programmatic imports need their own supported profile.

**[#5207](https://github.com/meta/pyrefly/issues/5207): many namespace portions.**
A performance report describes an Airflow namespace arrangement with 232 search
roots after configuration migration. This motivates many-portion fixtures and
ordered provider semantics; it is not necessary to begin Alloy checking with
hundreds of atoms. Small instances should exercise the same structural
relationships, including competing regular packages.

### 5. Aliasing and observation

**[#1336](https://github.com/meta/pyrefly/issues/1336): updates through symlinks.**
A symlinked module import remains stale after editing the underlying file. The
thread describes a reverted fix and a related symlinked-interpreter case. Model
path spelling, resource identity, import names, and interpreter-selection context
separately. Canonicalizing every path is not automatically a valid solution.

**[#3529](https://github.com/meta/pyrefly/issues/3529): excluded unreadable symlink targets.**
Traversal into an excluded, permission-denied directory still errors. This asks
which exclusion policy applies before traversal and whether an observation is
required at all. Do not assume every exclusion necessarily removes import
visibility or every comparison may follow a link.

### 6. Temporal consistency

**[#5005](https://github.com/meta/pyrefly/issues/5005): unsaved dependency edits.**
A native TSP reproduction reports the dependency's exported value as `str` and
the importing use as `int` in the same snapshot. Its scope is specifically
Windows and TSP with the stated indexing mode; ordinary LSP and other platforms
were not established by that report.

**[#5012](https://github.com/meta/pyrefly/issues/5012): disk changes under a running LSP.**
A self-contained report describes a watched dependency edit producing an error in
an unchanged importer, while a fresh check is clean and restarting the server
clears it. The reported typing example is more detailed than the project model
needs; retain the event chain and dependency observation relationships without
modeling the entire type solver.

## Adjacent evidence and gaps

- [#1763](https://github.com/meta/pyrefly/issues/1763): extension-only modules with
  no source or stub; runtime presence must not imply available type information.
- [#5193](https://github.com/meta/pyrefly/issues/5193): importing a submodule and
  observing it through an alias of its parent; distinguishes module objects from
  path/name lookup alone.
- [#4302](https://github.com/meta/pyrefly/issues/4302): Windows ignore patterns and
  includes; the reported cause needs verification against ignore-pattern rules.
- [#3512](https://github.com/meta/pyrefly/issues/3512): build-system-supplied
  configuration and structure.
- [#3176](https://github.com/meta/pyrefly/issues/3176): script-local environment
  information, motivating invocation context beyond a repository root.

The keyword pass found no title/body matches explicitly describing
case-sensitive or case-insensitive filesystems. This is a search-coverage gap,
not proof that no relevant report exists or that the behavior is correct. Archive
imports, custom finders, symlink retargeting, and transient installation states
also need specification-led cases rather than waiting for a matching open issue.

## Interaction coverage

| Scenario family | Interacting dimensions | Evidence |
|---|---|---|
| Shared library | Editable exposure × per-project environments × invocation/workspace context | #3556 |
| Configured dependency | Environment inside/outside project × installed config × analysis settings | #5131, #3788 |
| Non-venv monorepo | Interpreter-provided paths × source roots × CLI/LSP context | #4381 |
| Stub/source split | Editable/regular installation × provider roots × nominal identity | #4439, #4425, #2859 |
| Aliased environment | Symlinked file/interpreter × environment discovery × observation invalidation | #1336 |
| Traversal boundary | Exclusion policy × links × failed observations | #3529 |
| Session update | Disk/overlay × unchanged importer × provider/resource identity | #5005, #5012 |
| Namespace competition | Multiple portions × ordered roots × regular-package shadowing | #5207 plus reference semantics |

These are starting combinations, not a complete cross-product. Compose them:
install the shared library through an alias into an external environment, put its
stubs elsewhere, then recreate the environment or retarget the alias while an
importer has an unsaved overlay. Include absence and query failure as states.

## Candidate modeling contracts

Keep the following independently justified, with policy choices made explicit:

1. Resolution depends on a declared import context and module name, not a
   universal environment attached to a physical file.
2. Checking scope, import exposure, indexing, and modification intent are
   separate relations; their desired agreements are stated rather than assumed.
3. Runtime presence and typing-provider selection are separate, including
   complete/partial stubs and source/extension-only modules.
4. A resource may back multiple module names and contexts. Reconciliation must
   account for every dependent view without incorrectly merging distinct modules.
5. Configuration applicability crosses installation boundaries only under an
   explicit analysis policy; editable provenance alone does not decide it.
6. For a fixed context, policy, and supported semantic profile, mode-specific
   implementations should produce the same relevant answers once reconciled.
7. With sufficient observations and processing progress, a quiescent incremental
   view converges to the independent reference view of disk plus the declared
   overlay policy. Equality after every arbitrary event prefix is too strong.
8. World changes, notification delivery, failed queries, invalidation, and
   publication are separate transitions. Arbitrarily lost notifications require
   an explicit recovery mechanism before eventual convergence can be promised.

## Out of scope for this audit

Type-inference and framework-specific semantics, stub-generation quality,
baselines, general crashes, and standalone editor feature requests. Performance
is considered only where it reveals a structural fixture. Partially initialized
runtime modules and import side effects are possible later extensions, not an
excuse to model the entire Python execution engine in the first milestone.
