module project_tree

// Purpose: organize named contents while distinguishing edits from replacement.
// A single rooted tree extends the flat-directory sketch; no aliases or moves.
// Node atoms identify logical incarnations, not operating-system inode numbers.
abstract sig Node {}
sig File, Dir extends Node {}
one sig Root extends Dir {}
sig Name {}
one sig ConfigName extends Name {}
sig Settings {}
one sig Default extends Settings {}

// Parsing is normalized at the boundary: a config-slot file has known, valid
// settings. For ordinary files this interpretation is ignored. Invalid/unknown
// configs and partial-setting merges are outside this milestone's profile.
sig Content { setting: one Settings }

one sig Tree {
    var entries: Dir -> Name -> lone Node,
    var contents: File -> lone Content,
    // Specification history only. Name reuse allocates a fresh incarnation.
    var issued: set Node
}

fun children: Dir -> Node {
    { d: Dir, o: Node | some n: Name | d -> n -> o in Tree.entries }
}
fun parent: Node -> Dir { ~children }
fun live: set Node { Root + Name.(Dir.(Tree.entries)) }
fun files: set File { live & File }
fun dirs: set Dir { live & Dir }
fun entry[d: set Dir, n: Name]: set Node { n.(d.(Tree.entries)) }
fun read[f: File]: lone Content { f.(Tree.contents) }
fun subtree[o: Node]: set Node { o.*children }

// Purpose: determine which settings govern an object, without copying settings
// into the object. This is an explicit nearest-ancestor, whole-value profile,
// not a claim about Python, Pyrefly, glob sub-configs, or config inheritance.
// A directory's own declaration governs it and its configuration file too.
// Composition: ordinary file creation/edit/deletion changes scope declarations;
// hierarchy determines applicability. No special config-update action is needed.
fun declaration[d: Dir]: lone Settings {
    (entry[d, ConfigName] & File).(Tree.contents).setting
}
fun configured: set Dir { { d: dirs | some declaration[d] } }
fun applicable[o: Node]: set Dir { o.*parent & configured }
fun nearestIn[o: Node, declared: set Dir]: set Dir {
    let candidates = o.*parent & declared |
        { d: candidates | no (d.^children & candidates) }
}
fun nearest[o: Node]: set Dir { nearestIn[o, configured] }
fun source[o: Node]: set File { entry[nearest[o], ConfigName] & File }
fun settings[o: Node]: set Settings {
    let d = nearest[o] | some d => d.declaration else Default
}

pred init {
    no Tree.entries
    no Tree.contents
    Tree.issued = Root
}

// Private common insertion: callers provide the contents frame for their kind.
pred insert[d: Dir, n: Name, o: Node] {
    d in dirs
    no entry[d, n]
    o not in Tree.issued
    Tree.entries' = Tree.entries + d -> n -> o
    Tree.issued' = Tree.issued + o
}

pred create[d: Dir, n: Name, f: File, c: Content] {
    insert[d, n, f]
    Tree.contents' = Tree.contents + f -> c
}

pred mkdir[d: Dir, n: Name, child: Dir] {
    insert[d, n, child]
    Tree.contents' = Tree.contents
}

pred edit[f: File, c: Content] {
    f in files
    c != read[f]
    Tree.entries' = Tree.entries
    Tree.contents' = Tree.contents ++ f -> c
    Tree.issued' = Tree.issued
}

// Remove the named subtree; Root remains. Descendant contents disappear too.
// This abstracts a reconciled logical removal, not an atomic disk transaction.
pred delete[o: Node] {
    o in live - Root
    let removed = subtree[o] | {
        Tree.entries' = Tree.entries - Dir -> Name -> removed
        Tree.contents' = Tree.contents - removed -> Content
    }
    Tree.issued' = Tree.issued
}

pred idle {
    Tree.entries' = Tree.entries
    Tree.contents' = Tree.contents
    Tree.issued' = Tree.issued
}

fact behavior {
    init
    always (
        idle
        or (some d: Dir, n: Name, f: File, c: Content | create[d, n, f, c])
        or (some d, child: Dir, n: Name | mkdir[d, n, child])
        or (some f: File, c: Content | edit[f, c])
        or (some o: Node | delete[o])
    )
}

// Edit preserves name bindings, but editing a config can change settings for
// descendants. These observables expose distinct incremental opportunities;
// no cache, watcher protocol, or actual performance is modeled here.
pred structureChanged { Tree.entries' != Tree.entries }
fun contentChanged: set File {
    { f: File | f.(Tree.contents') != f.(Tree.contents) }
}
fun policyChanged: set Node {
    { o: live & live' | (source[o])' != source[o] or (settings[o])' != settings[o] }
}
