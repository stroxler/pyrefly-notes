module flat_files

// Concept: FileDirectory
// Purpose: provide named contents, distinguishing in-place updates from replacement.
// Operational principle: create makes a name readable; edits replace its
// contents without replacing the file; deletion makes the name unavailable.
//
// This first milestone has one directory, no paths, and opaque content values.
// These are logical file incarnations, not operating-system inode numbers.
sig Name {}
sig File {}
sig Content {}

one sig Directory {
    var entries: Name -> lone File,
    var contents: File -> lone Content,
    // Specification history, not a proposed engine registry. Fresh creates use
    // a new incarnation even when reusing a deleted name. A bounded scope can
    // exhaust File atoms; no claim of unbounded allocation is made here.
    var issued: set File
}

fun live: set File { Name.(Directory.entries) }
fun named: set Name { (Directory.entries).File }
fun read[n: Name]: lone Content { n.(Directory.entries).(Directory.contents) }

pred init {
    no Directory.entries
    no Directory.contents
    no Directory.issued
}

pred create[n: Name, f: File, c: Content] {
    no n.(Directory.entries)
    f not in Directory.issued
    Directory.entries' = Directory.entries + n -> f
    Directory.contents' = Directory.contents + f -> c
    Directory.issued' = Directory.issued + f
}

pred edit[n: Name, c: Content] {
    some n.(Directory.entries)
    c != read[n]
    Directory.entries' = Directory.entries
    Directory.contents' = Directory.contents ++ n.(Directory.entries) -> c
    Directory.issued' = Directory.issued
}

pred delete[n: Name] {
    some n.(Directory.entries)
    Directory.entries' = Directory.entries - n -> File
    Directory.contents' = Directory.contents - n.(Directory.entries) -> Content
    Directory.issued' = Directory.issued
}

pred idle {
    Directory.entries' = Directory.entries
    Directory.contents' = Directory.contents
    Directory.issued' = Directory.issued
}

fact behavior {
    init
    always (
        idle
        or (some n: Name, f: File, c: Content | create[n, f, c])
        or (some n: Name, c: Content | edit[n, c])
        or (some n: Name | delete[n])
    )
}

// Directory structure and contents are separate observables. Preserving this
// structure across edit exposes an incremental fast-path opportunity; it does
// not mean edited source cannot change imports, exports, or downstream results.
pred structureChanged { Directory.entries' != Directory.entries }
fun contentChanged: set File {
    { f: File | f.(Directory.contents') != f.(Directory.contents) }
}
