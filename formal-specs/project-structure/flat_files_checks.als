module flat_files_checks
open flat_files

// These are conclusions to check, not invariants assumed by the behavior fact.
assert WellFormed {
    always (
        (all f: File | lone (Directory.entries).f)
        and Directory.contents.Content = live
        and live in Directory.issued
    )
}

assert CreateIsLocal {
    all n: Name, f: File, c: Content | always (
        create[n, f, c] implies (
            named' = named + n
            and live' = live + f
            and structureChanged
            and contentChanged = f
            and (read[n])' = c
            and (all other: Name - n | {
                other.(Directory.entries') = other.(Directory.entries)
                (read[other])' = read[other]
            })
        )
    )
}

assert EditPreservesIdentityAndStructure {
    all n: Name, c: Content | always (
        edit[n, c] implies (
            Directory.entries' = Directory.entries
            and live' = live
            and named' = named
            and Directory.issued' = Directory.issued
            and not structureChanged
        )
    )
}

assert EditIsLocal {
    all n: Name, c: Content | always (
        edit[n, c] implies (
            contentChanged = n.(Directory.entries)
            and (read[n])' = c
            and (all other: Name - n | (read[other])' = read[other])
        )
    )
}

assert DeleteIsLocal {
    all n: Name | always (
        delete[n] implies (
            named' = named - n
            and live' = live - n.(Directory.entries)
            and structureChanged
            and contentChanged = n.(Directory.entries)
            and no (read[n])'
            and (all other: Name - n | {
                other.(Directory.entries') = other.(Directory.entries)
                (read[other])' = read[other]
            })
        )
    )
}

assert RetiredFilesDoNotReturn {
    all f: File | always (
        f in Directory.issued - live implies always f not in live
    )
}

assert LifetimeIdentity {
    all n: Name, f: File | always (
        n -> f in Directory.entries implies always (
            f in live implies n -> f in Directory.entries
        )
    )
}

assert UnrelatedActionsPreserveRead {
    all n: Name | always (
        some read[n] and no (contentChanged & n.(Directory.entries))
        implies (read[n])' = read[n]
    )
}

assert IdlePreservesEverything {
    always (idle implies (
        not structureChanged and no contentChanged
        and Directory.issued' = Directory.issued
    ))
}

// A structural observer can keep its directory map for edits, but not for
// create/delete. This checks an observable distinction, not a runtime speedup.
assert StructuralChangeMeansCreateOrDelete {
    always (structureChanged iff (
        (some n: Name, f: File, c: Content | create[n, f, c])
        or (some n: Name | delete[n])
    ))
}

// Operational-principle witnesses prevent a collection of vacuous checks:
// the model must admit each action, two independent files, and name reuse.
pred EditLifecycle {
    some n: Name, f: File, initial, updated: Content | {
        initial != updated
        create[n, f, initial]; edit[n, updated]; delete[n]; idle
    }
}

pred TwoFiles {
    some disj a, b: Name, disj f, g: File, x, y: Content | {
        x != y
        create[a, f, x]; create[b, g, x]; edit[a, y]; delete[a]; idle
    }
}

pred RecreateName {
    some n: Name, disj old, fresh: File, c: Content | {
        create[n, old, c]; delete[n]; create[n, fresh, c]; idle
    }
}

// Reusing a deleted name must allocate a new incarnation. Unlike the witness,
// the quantified new file is not assumed distinct: freshness is a conclusion.
assert RecreationUsesNewIdentity {
    all n: Name, old: File | always (
        n.(Directory.entries) = old
        and (delete[n]; some f: File, c: Content | create[n, f, c])
        implies n.(Directory.entries)'' != old
    )
}

check WellFormed for 2 Name, 3 File, 2 Content, 6 steps expect 0
check CreateIsLocal for 2 Name, 3 File, 2 Content, 6 steps expect 0
check EditPreservesIdentityAndStructure for 2 Name, 3 File, 2 Content, 6 steps expect 0
check EditIsLocal for 2 Name, 3 File, 2 Content, 6 steps expect 0
check DeleteIsLocal for 2 Name, 3 File, 2 Content, 6 steps expect 0
check RetiredFilesDoNotReturn for 2 Name, 3 File, 2 Content, 6 steps expect 0
check UnrelatedActionsPreserveRead for 2 Name, 3 File, 2 Content, 6 steps expect 0
check IdlePreservesEverything for 2 Name, 3 File, 2 Content, 6 steps expect 0
check StructuralChangeMeansCreateOrDelete for 2 Name, 3 File, 2 Content, 6 steps expect 0
run EditLifecycle for exactly 1 Name, exactly 1 File, exactly 2 Content, 5 steps expect 1
run TwoFiles for exactly 2 Name, exactly 2 File, exactly 2 Content, 6 steps expect 1
run RecreateName for exactly 1 Name, exactly 2 File, exactly 1 Content, 5 steps expect 1
check RecreationUsesNewIdentity for 2 Name, 3 File, 2 Content, 6 steps expect 0
check LifetimeIdentity for 2 Name, 3 File, 2 Content, 6 steps expect 0
