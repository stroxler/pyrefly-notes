# Python project structure

Start with one small domain model and extend the same world in stages. This is
planning, documentation, and auditing—not a proof of Pyrefly's implementation.

## First milestone: flat files

- [Concept-design sketch](DESIGN.md): purpose, state, actions, and operational
  principle, following Daniel Jackson's framing.
- [`flat_files.als`](flat_files.als): one directory with named files and opaque
  contents. Create allocates an incarnation; edit preserves identity and directory
  structure; delete retires it. No Pyrefly APIs or caches are modeled.
- [`flat_files_checks.als`](flat_files_checks.als): structural/content locality,
  whole-lifetime identity, fresh recreation, and lifecycle witnesses. Every
  command states its scope and expected SAT/UNSAT outcome.

On a POSIX host, with Python 3, Java, and an Alloy **6.2.0** CLI named `alloy`:

```sh
cd formal-specs/project-structure
python3 run_alloy.py
python3 -m unittest -v test_run_alloy test_model_mutations
```

The runner defaults to MiniSat (`--solver sat4j` selects Java-only checking), one
Java process, a requested 512 MiB heap, and a 180-second timeout. Cleanup on
failure, timeout, Ctrl-C, or SIGTERM terminates the launcher's POSIX process group,
including inherited checker children, with at most ten additional seconds for
reaping. A custom launcher must preserve that group and not override the heap.
`--output /path/to/new-directory` preserves receipts and witness JSON;
an existing directory is never overwritten. Missing/incomplete receipts or
terminal results, unexpected outcomes, checker errors, and timeouts fail
validation. Mutation regressions exercise both SAT/UNSAT mismatch directions.

A successful bounded check establishes no counterexample within its stated
scope—not correctness for all directory sizes, a runtime speedup, or a relation
to implementation code. Content values are abstract; a same-content write is an
idle/no-op here. File allocation history is specification-only, and finite scopes
can exhaust the supply of incarnations. The main checks bound 2 names, 3 file
incarnations, 2 contents, and at most 6 lasso steps. Allocation history grows, so
creation occurs only in the finite prefix, not the loop. No fairness or
eventual-progress property is assumed. The Alloy model can be opened directly on
other supported hosts; this small runner's process-control contract is POSIX-only.

## Extension order

1. Flat files and the identity-preserving edit fast path.
2. Directory hierarchy and sub-config applicability.
3. Exclusions and virtualenvs, separating checking, import visibility, and
   automated-refactor eligibility.
4. Interacting symlinks and editable installations, including changing
   observations and normalization at boundaries.

Concepts can be understood separately, but their composition must exercise
shared identities and interactions. Real-world events need not be core actions:
an installation retarget can become logical delete/create; a file edit must not
lose its identity/structure distinction.

## Discovery context

- [Initial modeling proposal](proposal.md): broader exploratory domain questions.
- [Open-issue audit](issue-audit.md): motivating reports and evidence limits,
  not normative definitions.
