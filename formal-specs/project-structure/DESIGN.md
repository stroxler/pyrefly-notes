# Flat files: concept-design sketch

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
