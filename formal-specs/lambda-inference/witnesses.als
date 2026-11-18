module witnesses
open lambda_inference

// Native temporal witnesses use eventual read states; the final state stutters.
// Prefix-plus-loop state bounds include the initial state. The closing stutter
// is not counted as a meaningful action in the displayed trace.
pred NestedOverwrite {
  eventually (some e: Execution | {
    e.policy = Fixed
    e.event = Read
    e.actor = Nonowner
    Nonowner.(e.selected) = IntHint
    Other.(e.phase) = New
  })
}
pred OldReadLeak {
  eventually (some e: Execution | {
    e.policy = Old
    e.event = Read
    e.actor = Other
    Other.(e.selected) = AnyHint
    e.published = IntHint
    (Owner + Nonowner).(e.phase) = Done
  })
}
pred RecursiveOther {
  eventually (some e: Execution | {
    e.policy = Fixed
    e.event = Read
    e.actor = Other
    no e.published
    Owner.(e.phase) = Demand
    Nonowner.(e.phase) = New
  })
}
run NestedOverwrite for 10 but exactly 1 Execution, exactly 1 ThreadState,
  1..10 steps expect 1
run NestedOverwriteTooShort { NestedOverwrite } for 9 but exactly 1 Execution,
  exactly 1 ThreadState, 1..9 steps expect 0
run OldReadLeak for 14 but exactly 1 Execution, exactly 1 ThreadState,
  1..14 steps expect 1
run OldReadLeakTooShort { OldReadLeak } for 13 but exactly 1 Execution,
  exactly 1 ThreadState, 1..13 steps expect 0
run RecursiveOther for 5 but exactly 1 Execution, exactly 1 ThreadState,
  1..5 steps expect 1
run RecursiveOtherTooShort { RecursiveOther } for 4 but exactly 1 Execution,
  exactly 1 ThreadState, 1..4 steps expect 0
