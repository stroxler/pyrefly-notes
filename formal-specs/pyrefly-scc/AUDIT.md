# Audit context

The specifications are planning, documentation, and auditing tools, not a
proof that the implementation follows the model.

The earlier audit examined the static models and their correspondence with
[Pyrefly source at 8003f9b](https://github.com/meta/pyrefly/blob/8003f9b3d96b207c916c4a5c5ba039fb568cb857/pyrefly/lib/alt/answers_solver.rs).
Its [report and probes remain in history](https://github.com/stroxler/pyrefly-notes/tree/8ef354e5238459dba374ed146df07f9b6793b290/formal-specs/pyrefly-scc).
Those static-scope findings are not automatically findings about the retained
dynamic behavior model.

The current pipeline keeps graph generation separate from solver behavior.
This cleanup retains the latest saved dynamic model without changing its
rules, and does not constitute a new behavioral audit against production.
Historical fixes and the original discovery assumption are described in the
[retrospective](RETROSPECTIVE.md) and [design sketch](DESIGN.md).

Source-level candidates from the earlier audit—lambda-type publication,
depth-overflow handling, and cross-module diagnostic routing—remain separate
follow-ups, not changes made by this repository cleanup.
