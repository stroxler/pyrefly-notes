# Flat files: concept-design sketch

The primary Alloy model is a system sketch more precise than Markdown: a rich
vocabulary of concepts and their composition that makes code organization
tractable. Its main goal is not to prove either the model or Pyrefly correct.
Checks support exploration and auditing; they are not the organizing purpose.
The [SCC retrospective](https://github.com/stroxler/pyrefly-notes/blob/e5e7ce781bdc458cbfa6b8cf294a9218bccd1b6b/formal-specs/pyrefly-scc/RETROSPECTIVE.md)
is a precedent: an explicit protocol helped organize auditing and simplification,
including unified progress state, removed bookkeeping, and clearer separation
of local tracking from shared-cache decisions—not a proof of today's code.

Following Daniel Jackson's [concept-design framing](https://groups.csail.mit.edu/sdg/pubs/2022/nfm-jackson.pdf),
start with one concept rather than one concept per source file.

## FileDirectory

- **Purpose:** store and retrieve contents by name, letting consumers distinguish
  an in-place update from replacement.
- **State:** a directory's name-to-file bindings and each live file's contents.
  Allocation history in the model distinguishes file incarnations; it is not a
  proposed engine data structure.
- **Actions:** create an unused name with a fresh file; edit an existing file's
  contents; delete a binding and its file. Idle is only temporal-model plumbing.
- **Operational principle:** create makes a file readable by name; editing changes
  what that same file contains; deleting makes it unavailable. Reusing the name
  creates a different file, even if the contents are identical.

The distinction exposes a performance opportunity without modeling a cache:
edit preserves directory structure, while create/delete change it. An edit can
still change imports, exports, and downstream diagnostics. No runtime speedup or
implementation-correctness proof follows from checking this model.

## Distinctions to preserve as the model grows

The editable-install work reports three recurring gaps. Treat these as evidence
for domain questions, not as proof of existing code behavior or new subsystems:

- **Import exposure versus ownership:** import visibility, source provenance,
  checking eligibility, and refactor permission are distinct contextual relations.
  An import root or editable ancestor alone cannot stand in for all four.
- **Spelling versus observed identity:** aliases can identify one directory, and
  one pathname can later identify another. Preserve the identity basis of
  observed ownership evidence; do not silently transfer it to a replacement.
  Explicit path-based user intent may follow different, declared rules. Unknown
  identity stays unknown; failure to observe equality is not observed inequality.
- **Configuration versus observations:** cached queries, live inspections, and
  resolved snapshots may describe different moments. Retain enough provenance
  to decide when they can be combined rather than treating them as one current fact.

Future interaction cases should include an installed dependency below editable
source, alias retargeting, directory replacement at an unchanged pathname with
cached positive evidence, and a configuration change between observations. The
flat-file model supplies the edit/recreation distinction, not these ownership or
observation semantics yet.

## Candidate organizing principle

**Normalize observations → derive separate decisions → invalidate dependencies.**

Observations state what is known, its source, and when/context it was obtained.
Interpret them under declared import semantics and policy precedence to derive
import visibility, checking eligibility, and refactor ownership separately.
Dependencies connect each decision to its supporting observations and policy,
including relevant observed absences. Changes invalidate affected decisions,
not every result or several feature-specific repair paths.

At the boundary, a symlink retarget can replace an observed binding and an
environment rebuild can delete/create relevant observations. A file edit remains
identity-preserving. Explicit dependencies, rather than rebuilding everything,
should preserve the fast paths. These are candidate design choices to investigate,
not semantics already supplied by the flat-file model.

The abstraction test is whether representative regressions can share the same
small vocabulary without scenario-specific actions or ownership exceptions.
Counterexamples should prompt us to examine missing invariants, dependencies, or
the state representation itself—not formalize another repair to existing code.
New domain concepts can be added in stages; they need a purpose beyond one bug.

## Grow the same world

1. **Flat files:** create/edit/delete, identity, contents, and local effects.
2. **Directory hierarchy and sub-configs:** add containment and configuration
   applicability, composing concepts over the same file identities.
3. **Exclusions and environments:** separate checking scope, import visibility,
   and automated-refactor eligibility; make environment/context selection explicit.
4. **Aliases and editable exposure:** combine symlinks, installation provenance,
   environments, scopes, and their changing observations.

At each stage, seek the smallest concepts/actions that meet the purpose and test
interactions, not isolated features. Normalize real-world mechanisms at boundaries
where their relevant effects are equivalent. Preserve edit's identity and
structure fast path rather than replacing every update with delete/create.

The detailed assumptions, frames, assertions, and bounds live beside the Alloy
code. These specifications are for planning, documentation, and auditing; future
stages and a formal relation to implementation code remain explicit boundaries.
