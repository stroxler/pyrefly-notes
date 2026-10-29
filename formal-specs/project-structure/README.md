# Python project structure

The primary model is a precise system sketch for tractable code organization.
Checks support exploration and auditing, not a proof of the model or Pyrefly.

## Review surface

Start with [`project_tree.als`](project_tree.als) and the short [concept sketch](DESIGN.md).
The primary model stays within a **200-line review budget**; regression checks and
tooling are separate. It evolves the flat-directory milestone rather than keeping
competing active versions.

This milestone adds a rooted directory hierarchy and directory-scoped settings:

- Create a file or directory, edit a file, and delete a subtree.
- Edit preserves identity and structure, including for ordinary config files.
- Nearest ancestor configuration wins under an explicitly chosen whole-value
  profile; deleting an override exposes the current ancestor declaration.
- Keep the selected declaration's identity as well as its settings value.

There are no aliases, moves, observations, interpreter queries, exclusions, or
refactor policies yet. Malformed/unknown config parsing and partial-field merging
are also outside the chosen profile. The distinguished config filename is a
symbol, not a claim about a particular Python tool's discovery rules.

## Run checks

With Python 3, a POSIX host, Java 17+, and an Alloy **6.2.0** CLI named `alloy`:

```sh
cd formal-specs/project-structure
python3 run_alloy.py
python3 -m unittest -v test_run_alloy test_model_mutations
```

[`project_tree_checks.als`](project_tree_checks.als) states every command's bounds
and expected outcome. Generic checks use 2 directories, 2 files, 2 names,
2 contents, 2 settings, and 5 steps, allowing one level below Root. Deeper lifecycle
witnesses use their own larger bounds; this does not check every invariant at
those larger sizes. Witnesses retain flat-file cases and add nested settings,
same-name/different-directory, subtree removal, and skipped unconfigured ancestors.

The runner defaults to MiniSat (`--solver sat4j` selects Java-only checking), one
process, a requested 512 MiB heap, and a 180-second timeout. Existing output paths
are never overwritten. Receipts, terminal outcomes, and errors are checked;
failures and interruption clean up the POSIX process group. A custom launcher must
preserve that group and heap setting. `--output /path/to/new-directory` keeps results.

Checks are bounded, not evidence of arbitrary-size correctness or measured
performance. Finite incarnation history permits creation only in the trace prefix.
Content and settings are abstract; same-content writes are idle/no-ops. No fairness
or eventual-progress assumption is included. The model itself can be opened in
Alloy on other supported hosts; the runner's process-control contract is POSIX-only.

## Next layers

1. Exclusions and environments, with separate checking/refactor eligibility.
2. Interacting symlinks/editable installs and changing observations.

Normalize real-world mechanisms at boundaries, but preserve meaningful identities,
contexts, and the file-edit fast path. [The initial proposal](proposal.md) and
[issue audit](issue-audit.md) provide discovery context, not normative definitions.
