module project_tree_checks
open project_tree

// Conclusions, not assumptions of behavior. Frames also guard future edits.
assert WellFormed {
    always (
        no Tree.entries.Root
        and (all o: Node | lone Tree.entries.o)
        and no (iden & ^children)
        and live = Root.*children
        and (all d: Dir - dirs | no d.(Tree.entries))
        and Tree.contents.Content = files
        and live in Tree.issued
    )
}

assert EditIdentityAndLocality {
    all f: File, c: Content | always (edit[f, c] implies (
        Tree.entries' = Tree.entries and live' = live
        and Tree.issued' = Tree.issued and not structureChanged
        and contentChanged = f and (read[f])' = c
        and (all other: files - f | (read[other])' = read[other])
    ))
}

assert CreateIsLocal {
    all d: Dir, n: Name, f: File, c: Content | always (create[d, n, f, c] implies (
        live' = live + f and Tree.entries in Tree.entries'
        and contentChanged = f and structureChanged
        and policyChanged in subtree[d]
        and (n != ConfigName implies no policyChanged)
    ))
}

assert MkdirIsLocal {
    all d, child: Dir, n: Name | always (mkdir[d, n, child] implies (
        live' = live + child and Tree.entries in Tree.entries'
        and no contentChanged and no policyChanged
    ))
}

assert DeleteIsLocal {
    all o: Node | always (delete[o] implies (
        live' = live - subtree[o]
        and contentChanged = subtree[o] & File
        and (all survivor: live - subtree[o] |
            (Tree.entries.survivor)' = Tree.entries.survivor)
        and policyChanged in { x: live & live' | some (source[x] & subtree[o]) }
    ))
}

assert RetiredNodesDoNotReturn {
    all o: Node | always (o in Tree.issued - live implies always o not in live)
}

assert LifetimeIdentity {
    all d: Dir, n: Name, o: Node | always (
        d -> n -> o in Tree.entries implies always (
            o in live implies d -> n -> o in Tree.entries
        )
    )
}

assert SettingsAreWellDefined {
    always (all o: live | one settings[o] and lone nearest[o] and source[o] in files)
}

assert NearestScopeWins {
    always (all o: live, a: applicable[o] | a in (nearest[o]).*parent)
}

assert DeletingOverrideRevealsAncestor {
    all f: File | always (delete[f] implies (all x: live & live' |
        source[x] = f implies (
            let above = (f.parent).parent |
                some above => ((source[x])' = source[above]
                    and (settings[x])' = settings[above])
                else (no (source[x])' and (settings[x])' = Default)
        )
    ))
}

assert SettingsFollowSource {
    always (all o: live |
        some source[o] => settings[o] = source[o].(Tree.contents).setting
        else settings[o] = Default)
}

// Editing an ordinary file does not change this settings profile. Config edits
// can affect descendants, but a nearer declaration shields its own scope.
assert EditRespectsScopes {
    all f: File, c: Content | always (
        edit[f, c] implies policyChanged in { o: live | source[o] = f }
    )
}

assert RecreationUsesNewIdentity {
    all d: Dir, n: Name, old: File | always (
        entry[d, n] = old
        and (delete[old]; some f: File, c: Content | create[d, n, f, c])
        implies (entry[d, n])'' != old
    )
}

// Root-only witnesses retain the previous flat model's operational examples.
pred EditLifecycle {
    some n: Name - ConfigName, f: File, x, y: Content | {
        x != y
        create[Root, n, f, x]; edit[f, y]; delete[f]; idle
    }
}
pred TwoFiles {
    some disj a, b: Name - ConfigName, disj f, g: File, x, y: Content | {
        x != y
        create[Root, a, f, x]; create[Root, b, g, x]; edit[f, y]; delete[f]; idle
    }
}
pred RecreateName {
    some n: Name - ConfigName, disj old, fresh: File, c: Content | {
        create[Root, n, old, c]; delete[old]; create[Root, n, fresh, c]; idle
    }
}

// The same basename may denote different files in different directories.
pred SameNameInDifferentDirs {
    some n: Name - ConfigName, d: Dir - Root, disj f, g: File, c: Content | {
        mkdir[Root, n, d]; create[Root, ConfigName, f, c]; create[d, ConfigName, g, c];
        { entry[Root, ConfigName] = f and entry[d, ConfigName] = g and idle }
    }
}

// Root configuration changes while a nested declaration shields the child.
// Deleting that nested config then exposes the updated parent settings.
pred NestedConfigLifecycle {
    some n: Name - ConfigName, d: Dir - Root, disj top, nested, leaf: File,
         x, y, z: Content | {
        disj[x.setting, y.setting, z.setting]
        create[Root, ConfigName, top, x]; mkdir[Root, n, d];
        create[d, ConfigName, nested, y]; create[d, n, leaf, x];
        edit[top, z];
        { source[leaf] = nested and settings[leaf] = y.setting and delete[nested] };
        { source[leaf] = top and settings[leaf] = z.setting and idle }
    }
}

pred RemoveNestedDirectory {
    some n: Name - ConfigName, disj a, b: Dir - Root, f: File, c: Content | {
        mkdir[Root, n, a]; mkdir[a, n, b]; create[b, n, f, c]; delete[a];
        { live = Root and no Tree.contents and idle }
    }
}

pred SkipUnconfiguredAncestor {
    some n: Name - ConfigName, disj a, b: Dir - Root, disj top, nested: File,
         x, y: Content | {
        x.setting != y.setting
        create[Root, ConfigName, top, x]; mkdir[Root, n, a]; mkdir[a, n, b];
        create[b, ConfigName, nested, y];
        { source[b] = nested and settings[b] = y.setting and delete[nested] };
        { source[b] = top and settings[b] = x.setting and idle }
    }
}

check WellFormed for 2 Dir, 2 File, 2 Name, 2 Content, 2 Settings, 5 steps expect 0
check EditIdentityAndLocality for 2 Dir, 2 File, 2 Name, 2 Content, 2 Settings, 5 steps expect 0
check CreateIsLocal for 2 Dir, 2 File, 2 Name, 2 Content, 2 Settings, 5 steps expect 0
check MkdirIsLocal for 2 Dir, 2 File, 2 Name, 2 Content, 2 Settings, 5 steps expect 0
check DeleteIsLocal for 2 Dir, 2 File, 2 Name, 2 Content, 2 Settings, 5 steps expect 0
check RetiredNodesDoNotReturn for 2 Dir, 2 File, 2 Name, 2 Content, 2 Settings, 5 steps expect 0
check LifetimeIdentity for 2 Dir, 2 File, 2 Name, 2 Content, 2 Settings, 5 steps expect 0
check SettingsAreWellDefined for 2 Dir, 2 File, 2 Name, 2 Content, 2 Settings, 5 steps expect 0
check NearestScopeWins for 2 Dir, 2 File, 2 Name, 2 Content, 2 Settings, 5 steps expect 0
check DeletingOverrideRevealsAncestor for 2 Dir, 2 File, 2 Name, 2 Content, 2 Settings, 5 steps expect 0
check SettingsFollowSource for 2 Dir, 2 File, 2 Name, 2 Content, 2 Settings, 5 steps expect 0
check EditRespectsScopes for 2 Dir, 2 File, 2 Name, 2 Content, 2 Settings, 5 steps expect 0
check RecreationUsesNewIdentity for 2 Dir, 2 File, 2 Name, 2 Content, 2 Settings, 5 steps expect 0
run EditLifecycle for exactly 1 Dir, exactly 1 File, exactly 2 Name, exactly 2 Content, 1 Settings, 5 steps expect 1
run TwoFiles for exactly 1 Dir, exactly 2 File, exactly 3 Name, exactly 2 Content, 1 Settings, 6 steps expect 1
run RecreateName for exactly 1 Dir, exactly 2 File, exactly 2 Name, exactly 1 Content, 1 Settings, 5 steps expect 1
run SameNameInDifferentDirs for exactly 2 Dir, exactly 2 File, exactly 2 Name, 1 Content, 1 Settings, 5 steps expect 1
run NestedConfigLifecycle for exactly 2 Dir, exactly 3 File, exactly 2 Name, exactly 3 Content, exactly 3 Settings, 8 steps expect 1
run RemoveNestedDirectory for exactly 3 Dir, exactly 1 File, exactly 2 Name, 1 Content, 1 Settings, 6 steps expect 1
run SkipUnconfiguredAncestor for exactly 3 Dir, exactly 2 File, exactly 2 Name, exactly 2 Content, 2 Settings, 7 steps expect 1
