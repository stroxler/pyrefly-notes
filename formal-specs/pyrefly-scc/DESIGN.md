# SCC solving: design sketch

The specification is a planning, documentation, and auditing reference. Alloy
supplies graph cases; the TLA+ model describes the SCC protocol on those
inputs. Transition details belong in [the model](behavior/PyreflyFixpoint.tla),
not a parallel Markdown algorithm.

## The idea

Calculations whose answers depend cyclically on one another are solved as a
component rather than treating the first cycle break as a final answer:

- **Discover** which calculations belong together.
- **Start cold** with temporary cycle-breaking answers kept inside the component.
- **Refine** using previous answers and revisiting known members.
- **Restart when membership grows**, after active work has unwound safely.
- **Publish** only after the component's work has finished.

Calculation and driver frames make suspension explicit: a nested component
must finish or hand ownership back before its caller continues. An invalidated
pass retains answers for active readers but cannot publish them.

## The boundary

The design assumes each entrypoint discovers the full recursive component
before publishing a proper subcomponent. The model explores a concrete class
of graph inputs: initial cycles expose every cyclic participant, each full
edge appears within the visibility period, and noncyclic nodes expose their
full dependencies initially. Initial component partitions may still differ,
so late merges remain part of the model.

Every cold restart allows a full visibility period before publication. These
are graph-input conditions and a modeled protocol budget, not conclusions
about Python dependency discovery. Types, concrete convergence, concurrent
publication, depth overflow, and memory lifetime are outside this model.
There is no formal model-to-code relation. The [retrospective](RETROSPECTIVE.md)
separates the original audit record from later reconstructed fix links.
