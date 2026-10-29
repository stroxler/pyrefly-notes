# Graph generation and solver exploration

The experiment used a useful division of labor: Alloy constructed graph
cases, while TLC explored the solver's behavior on fixed inputs. Modeling
both jobs in Alloy did not scale as well.

```text
Alloy -> graph cases -> TLC -> counterexamples and regressions
```

The record now includes the [Alloy stack experiment](../alloy-stack/) and the
[dynamic-graph generator, exporter, and historical TLA consumers](../dynamic-fixpoint/).
Their short reading guides distinguish executable tools from scaffolds; their
schemas and transition rules are documented in the source.

Keeping generation separate makes dependency-discovery assumptions reviewable
without adding the generator's search space to every solver run. Cases need
late-expansion coverage, and relevant edges must actually be traversed before
publication—not merely appear in a hypothetical later pass.

The main `fixpoint/` model remains a separate, static simplification. Preserving
the dynamic experiment does not transfer the static audit's findings to those
versions or establish their assumptions for Python code.
