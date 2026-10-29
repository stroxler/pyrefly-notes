# Project structure: concept-design sketch

The primary Alloy model is a precise system sketch and concept vocabulary for
making code organization tractable. Checks support exploration and auditing;
proving either the model or Pyrefly correct is not its main purpose.

Following Daniel Jackson's [concept-design framing](https://groups.csail.mit.edu/sdg/pubs/2022/nfm-jackson.pdf),
organize around purpose, state, actions, and an operational principle—not one
concept per existing source file.

## FileTree

- **Purpose:** organize named contents while distinguishing edits from replacement.
- **State:** a rooted directory tree, name bindings, and file contents. Allocation
  history distinguishes logical incarnations, not operating-system inodes.
- **Actions:** create a file, create a directory, edit a file, or remove a subtree.
- **Operational principle:** a name locates contents within its directory; edit
  changes the same file; removal retires the subtree; name reuse creates a new
  incarnation. Identical basenames in different directories are independent.

## Scoped settings

- **Purpose:** give each object a coherent settings context without copying
  configuration into every object.
- **State/input:** declarations and containment. In this composition, a declaration
  comes from an ordinary file in a distinguished configuration-name slot.
- **Actions/composition:** file create/edit/delete changes declarations using the
  same FileTree actions. Applicability and selection are derived queries.
- **Operational principle:** an ancestor supplies settings until a nearer scope
  overrides it. Editing the ancestor leaves the override intact; removing the
  override reveals the ancestor's latest settings.

This is an explicit nearest-ancestor, whole-value policy profile, not a universal
rule for Python or tools. It includes a directory's own declaration when selecting settings for
that directory and its config file. Parsing is normalized at the boundary; malformed
or unknown configs, glob scopes, and partial-setting merges are not modeled yet.
The source declaration's identity is retained even when two declarations have
identical settings. An ordinary edit leaves this settings profile unchanged; a
config edit can affect its scope without changing directory structure.

## Keep the same world small

Next add exclusions and environments, separating import visibility, source
provenance, checking eligibility, and refactor permission. Then add interacting
aliases/editable exposure. Preserve spelling versus observed identity, and
current configuration versus historical observations; unknown identity must not
become observed inequality.

A candidate composition is **normalize observations → derive separate decisions
→ invalidate dependencies**. Retain provenance and relevant observed absences.
Retargets/rebuilds can normalize into binding replacement or logical delete/create;
file edit remains distinct. Dependencies, not global rebuilding or feature-specific
repair paths, should preserve fast paths. These layers are future work, not
semantics already supplied by the known-world tree model.

Ask whether representative regressions share a small vocabulary rather than
requiring one repair action per case. Counterexamples may reveal a missing
invariant, dependency, or a need to change the representation itself.

The [SCC retrospective](https://github.com/stroxler/pyrefly-notes/blob/e5e7ce781bdc458cbfa6b8cf294a9218bccd1b6b/formal-specs/pyrefly-scc/RETROSPECTIVE.md)
is a precedent for organizing simplification around an explicit protocol. Detailed
semantics belong in [the Alloy source](project_tree.als), not a parallel Markdown
specification. Future stages and a model-to-code relation remain explicit boundaries.
