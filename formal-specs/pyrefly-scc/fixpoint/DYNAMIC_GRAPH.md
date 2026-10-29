# Graph generation and solver exploration

The experiment used a useful division of labor: Alloy constructed graph
cases, while TLC explored the solver's behavior on fixed inputs. Modeling
both jobs in Alloy did not scale as well.

```text
Alloy -> graph cases -> TLC -> counterexamples and regressions
```

Keeping graph generation separate makes dependency-discovery assumptions
reviewable without adding the generator's search space to every solver run.
Generated cases need to expose missing-member and late-expansion scenarios,
not just ordinary cycles. Coverage must concern edges actually traversed
before publication, not edges that would appear if solving continued after
an early exit.

The checked-in solver model currently freezes its graph. The historical
generator and generated-case corpus are not included here; this sketch does
not describe an executable pipeline in this directory. When those artifacts
are added, their schemas and generation constraints should be documented
beside the generator code rather than duplicated in Markdown.

A future Quint experiment could compare small exhaustive runs with larger
seeded simulations. Saved failing cases remain useful regardless of the
chosen specification language.
