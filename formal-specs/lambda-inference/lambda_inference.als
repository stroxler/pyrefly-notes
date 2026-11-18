module lambda_inference

// Purpose: separate publication authority from contextual inference attempts.
// Snapshot: facebook/pyrefly 2d1d8c3f320c53c36efcd13d661740fb1f3cf0eb.
// This is a native Alloy 6 temporal system sketch.
// It is not a refinement proof of the Rust implementation.
sig ThreadState {} // A solver state object, not an OS thread identity.
abstract sig Hint {}
one sig IntHint, AnyHint extends Hint {}
abstract sig Result {}
one sig StrResult, AnyResult extends Result {}
abstract sig Policy {}
one sig Old, Fixed, AttemptLocal, OwnerOnly extends Policy {}
abstract sig Frame {} // Attempt continuations; inferenceFrames identifies live lambda guards.
one sig Owner, Nonowner, Other extends Frame {}
abstract sig Phase {}
one sig New, Demand, Suspended, Ready, Selected, BodyDone, Published, Done extends Phase {}
abstract sig Event {}
one sig Initial, Start, ForceOwner, CachedOwner, RecursiveOwner,
        Resume, Read, ExitInference, Publish, Finish extends Event {}

// Composition: each execution has an owner/publication concept, an attempt stack,
// and per-ThreadState working storage. A parameter read demands the owner FIRST.
// The model has one module, lambda, parameter, and designated publication owner.
sig Execution {
  policy: one Policy,
  var phase: Frame -> one Phase,
  var thread: Frame -> lone ThreadState,
  var parent: Frame -> lone Frame,
  var top: ThreadState -> lone Frame,
  var installed: ThreadState -> lone Hint,
  var published: lone Hint,
  var selected: Frame -> lone Hint,
  var event: one Event,
  var actor: lone Frame
}
fun ownHint[f: Frame]: lone Hint {
  (f = Owner => IntHint else (f = Nonowner => AnyHint else none))
}
fun stack[e: Execution, ts: ThreadState]: set Frame {
  ts.(e.top).*(e.parent)
}
fun inferenceFrames[e: Execution, ts: ThreadState]: set Frame {
  { f: stack[e, ts] & (Owner + Nonowner) |
    f.(e.phase) in Demand + Suspended + Ready + Selected }
}
pred active[e: Execution, f: Frame] {
  some f.(e.thread)
  f.(e.thread).(e.top) = f
}
fun firstAvailable[a, b: lone Hint]: one Hint {
  some a => a else (some b => b else AnyHint)
}
// AttemptLocal is a definitional contract: choose returns the attempt's hint
// directly. Its controls do not verify a frame-storage implementation.
// OwnerOnly sketches owner-authoritative inference: a nonowner attempt installs
// no hint, demands the owner as usual, and then reads the owner's publication.
// Owner and Other reads keep Fixed precedence.
fun choose[e: Execution, f: Frame]: one Hint {
  let working = f.(e.thread).(e.installed) |
    e.policy = Old => firstAvailable[working, e.published] else
    e.policy = AttemptLocal =>
      (f in Owner + Nonowner => ownHint[f] else
        firstAvailable[e.published, working]) else
    (e.policy = OwnerOnly and f = Nonowner) =>
      firstAvailable[e.published, working] else
    // alt/answers_solver.rs::resolve_lambda_param_type tests ANY enclosing
    // infers=true frame, not the identity or read intent of the current caller.
    (some inferenceFrames[e, f.(e.thread)] =>
      firstAvailable[working, e.published] else
      firstAvailable[e.published, working])
}
// Which attempts install their own hint at entry.
pred installsHint[e: Execution, f: Frame] {
  f = Owner or (f = Nonowner and e.policy != OwnerOnly)
}
fun result[h: Hint]: one Result { h = IntHint => StrResult else AnyResult }
// Abstract sensitivity witness only: int -> str, Any -> Any. This is not a
// claim that a particular property/lambda program has these inferred results.

pred init[e: Execution] {
  e.phase = Frame -> New
  no e.thread
  no e.parent
  no e.top
  no e.installed
  no e.published
  no e.selected
  e.event = Initial
  no e.actor
}
pred label[e: Execution, ev: Event, f: lone Frame] {
  e.event' = ev
  e.actor' = f
}

// Entry combines frame push and initial hint installation. Read selection is
// separate from demand, so a forced owner can overwrite the shared slot first.
// Expr::Lambda uses enter_lambda_inference and set_lambda_param_type.
pred start[e: Execution, f: Frame, ts: ThreadState] {
  f.(e.phase) = New
  // Top-level attempts are serialized even across distinct ThreadState objects.
  // Competing owner solves and SCC commit-reservation waits are outside scope.
  no ThreadState.(e.top)
  e.phase' = e.phase ++ f -> Demand
  e.thread' = e.thread ++ f -> ts
  e.parent' = e.parent
  e.top' = e.top ++ ts -> f
  e.installed' = (installsHint[e, f] =>
    e.installed ++ ts -> ownHint[f] else e.installed)
  e.published' = e.published
  e.selected' = e.selected
  label[e, Start, f]
}
// A receiver-only/other binding can be evaluated synchronously while the owner
// is active. Its infers=false frame does not mask an enclosing inference frame.
pred nestedOther[e: Execution] {
  Other.(e.phase) = New
  Owner.(e.phase) = Demand
  active[e, Owner]
  let ts = Owner.(e.thread) | {
    e.phase' = e.phase ++ Other -> Demand
    e.thread' = e.thread ++ Other -> ts
    e.parent' = e.parent ++ Other -> Owner
    e.top' = e.top ++ ts -> Other
  }
  e.installed' = e.installed
  e.published' = e.published
  e.selected' = e.selected
  label[e, Start, Other]
}
// get_idx(owner): an uncomputed owner runs on the SAME ThreadState and pauses
// its caller. Only the new stack top may take steps until it is popped.
// Owner phases condense synchronous SCC convergence, not a single Rust pass.
pred forceOwner[e: Execution, f: Frame] {
  active[e, f]
  f.(e.phase) = Demand
  Owner.(e.phase) = New
  let ts = f.(e.thread) | {
    e.phase' = e.phase ++ f -> Suspended ++ Owner -> Demand
    e.thread' = e.thread ++ Owner -> ts
    e.parent' = e.parent ++ Owner -> f
    e.top' = e.top ++ ts -> Owner
    e.installed' = e.installed ++ ts -> IntHint
  }
  e.published' = e.published
  e.selected' = e.selected
  label[e, ForceOwner, f]
}
// Recursive get_idx returns a placeholder without publishing. We abstract its
// type away: the resolver still selects installed/published/fallback afterward.
pred demandAvailable[e: Execution, f: Frame] {
  active[e, f]
  f.(e.phase) = Demand
  Owner.(e.phase) = Done or Owner in f.*(e.parent)
  e.phase' = e.phase ++ f -> Ready
  e.thread' = e.thread
  e.parent' = e.parent
  e.top' = e.top
  e.installed' = e.installed
  e.published' = e.published
  e.selected' = e.selected
  label[e, (Owner.(e.phase) = Done => CachedOwner else RecursiveOwner), f]
}
// Resume only the caller of a completed same-ThreadState nested owner solve.
pred resume[e: Execution, f: Frame] {
  active[e, f]
  f.(e.phase) = Suspended
  f.(e.thread) = Owner.(e.thread)
  Owner.(e.phase) = Done
  e.phase' = e.phase ++ f -> Ready
  e.thread' = e.thread
  e.parent' = e.parent
  e.top' = e.top
  e.installed' = e.installed
  e.published' = e.published
  e.selected' = e.selected
  label[e, Resume, f]
}
pred readParam[e: Execution, f: Frame] {
  active[e, f]
  f.(e.phase) = Ready
  e.phase' = e.phase ++ f -> Selected
  e.thread' = e.thread
  e.parent' = e.parent
  e.top' = e.top
  e.installed' = e.installed
  e.published' = e.published
  e.selected' = e.selected ++ f -> choose[e, f]
  label[e, Read, f]
}
// The owner lambda guard exits before Key::before_record publishes. The owner
// solve continuation remains on the calculation stack until its answer records.
pred exitOwnerInference[e: Execution] {
  active[e, Owner]
  Owner.(e.phase) = Selected
  e.phase' = e.phase ++ Owner -> BodyDone
  e.thread' = e.thread
  e.parent' = e.parent
  e.top' = e.top
  e.installed' = e.installed
  e.published' = e.published
  e.selected' = e.selected
  label[e, ExitInference, Owner]
}
// Publication is always IntHint in this restricted model: no competing owner
// solves or nonowner inference nested inside Owner can contaminate its slot.
// Only publication AUTHORITY is checked, not value correctness or determinism.
// Key::before_record calls publish_owned_lambda_param_types for its own IDs.
// Publication copies expanded working storage; it is not an inference-frame pop.
pred publishOwner[e: Execution] {
  active[e, Owner]
  Owner.(e.phase) = BodyDone
  e.phase' = e.phase ++ Owner -> Published
  e.thread' = e.thread
  e.parent' = e.parent
  e.top' = e.top
  e.installed' = e.installed
  e.published' = Owner.(e.thread).(e.installed)
  e.selected' = e.selected
  label[e, Publish, Owner]
}
// LambdaBindingContext::drop only pops the frame; it does NOT restore installed.
pred finish[e: Execution, f: Frame] {
  active[e, f]
  (f = Owner => f.(e.phase) = Published else f.(e.phase) = Selected)
  e.phase' = e.phase ++ f -> Done
  e.thread' = e.thread
  e.parent' = e.parent - f -> Frame
  e.top' = (e.top - f.(e.thread) -> Frame) +
    f.(e.thread) -> f.(e.parent)
  e.installed' = e.installed
  e.published' = e.published
  e.selected' = e.selected
  label[e, Finish, f]
}
pred stutter[e: Execution] {
  e.phase' = e.phase
  e.thread' = e.thread
  e.parent' = e.parent
  e.top' = e.top
  e.installed' = e.installed
  e.published' = e.published
  e.selected' = e.selected
  e.event' = e.event
  e.actor' = e.actor
}
pred step[e: Execution] {
  (some f: Frame, ts: ThreadState | start[e, f, ts]) or
  nestedOther[e] or
  (some f: Frame | forceOwner[e, f] or demandAvailable[e, f] or
    resume[e, f] or readParam[e, f] or finish[e, f]) or
  exitOwnerInference[e] or publishOwner[e] or stutter[e]
}
fact Executions {
  all e: Execution | init[e]
  always (all e: Execution | step[e])
}

// Operational principles and checked boundaries.
assert OnlyOwnerPublishes {
  always (all e: Execution |
    e.published' != e.published => e.event' = Publish and e.actor' = Owner)
}
assert StackDiscipline {
  always (all e: Execution | {
    no iden & ^(e.parent)
    all ts: ThreadState, f: stack[e, ts] | f.(e.thread) = ts
    all f: Frame | (f.(e.phase) in New + Done => f not in ThreadState.(e.top))
  })
}
assert IndependentAfterPublicationFixed {
  always (all e: Execution |
    (e.policy = Fixed and e.event = Read and e.actor = Other and
     no inferenceFrames[e, Other.(e.thread)] and some e.published) =>
      Other.(e.selected) = e.published)
}
assert IndependentAfterPublicationOld {
  always (all e: Execution |
    (e.policy = Old and e.event = Read and e.actor = Other and
     no inferenceFrames[e, Other.(e.thread)] and some e.published) =>
      Other.(e.selected) = e.published)
}
assert NonownerOwnHintFixed {
  always (all e: Execution |
    (e.policy = Fixed and e.event = Read and e.actor = Nonowner) =>
      Nonowner.(e.selected) = ownHint[Nonowner])
}
assert ExpressionOwnHintReference {
  always (all e: Execution |
    (e.policy = AttemptLocal and e.event = Read and e.actor in Owner + Nonowner) =>
      e.actor.(e.selected) = ownHint[e.actor])
}
assert OtherAlwaysPublishedFixed {
  always (all e: Execution |
    (e.policy = Fixed and e.event = Read and e.actor = Other) =>
      Other.(e.selected) = e.published)
}
pred completed[e: Execution] { Frame.(e.phase) = Done }
assert FinalNonownerScheduleIndependentFixed {
  always (all disj e, f: Execution |
    (e.policy = Fixed and f.policy = Fixed and completed[e] and completed[f]) =>
      result[Nonowner.(e.selected)] = result[Nonowner.(f.selected)])
}
assert FinalNonownerScheduleIndependentReference {
  always (all disj e, f: Execution |
    (e.policy = AttemptLocal and f.policy = AttemptLocal and
     completed[e] and completed[f]) =>
      result[Nonowner.(e.selected)] = result[Nonowner.(f.selected)])
}
// OwnerOnly: the nonowner reads the publication, so its result cannot depend on
// order. This deliberately gives up the nonowner's own contextual hint.
assert NonownerReadsPublicationOwnerOnly {
  always (all e: Execution |
    (e.policy = OwnerOnly and e.event = Read and e.actor = Nonowner) =>
      (some e.published and Nonowner.(e.selected) = e.published))
}
assert IndependentAfterPublicationOwnerOnly {
  always (all e: Execution |
    (e.policy = OwnerOnly and e.event = Read and e.actor = Other and
     no inferenceFrames[e, Other.(e.thread)] and some e.published) =>
      Other.(e.selected) = e.published)
}
assert FinalNonownerScheduleIndependentOwnerOnly {
  always (all disj e, f: Execution |
    (e.policy = OwnerOnly and f.policy = OwnerOnly and
     completed[e] and completed[f]) =>
      result[Nonowner.(e.selected)] = result[Nonowner.(f.selected)])
}
pred OwnerFirst {
  some e: Execution | {
    e.policy = Fixed
    after (e.event = Start and e.actor = Owner)
    always no Other.(e.parent)
    eventually completed[e]
    eventually (e.event = Start and e.actor = Nonowner and Owner.(e.phase) = Done)
    eventually (Nonowner.(e.phase) = Done and Nonowner.(e.selected) = AnyHint)
    eventually (e.event = Start and e.actor = Other and Nonowner.(e.phase) = Done)
  }
}
pred NonownerFirst {
  some e: Execution | {
    e.policy = Fixed
    after (e.event = Start and e.actor = Nonowner)
    always no Other.(e.parent)
    eventually completed[e]
    eventually (e.event = ForceOwner and e.actor = Nonowner)
    eventually (Nonowner.(e.phase) = Done and Nonowner.(e.selected) = IntHint)
  }
}
// Paired schedules for the independent read: the owner completes first, then
// Other reads either before or after the nonowner's inference on that state.
pred OwnerThenBoth[e: Execution, p: Policy] {
  e.policy = p
  after (e.event = Start and e.actor = Owner)
  always no Other.(e.parent)
  eventually completed[e]
}
pred OtherBeforeNonowner[p: Policy] {
  some e: Execution | {
    OwnerThenBoth[e, p]
    eventually (e.event = Start and e.actor = Other and Nonowner.(e.phase) = New)
  }
}
pred OtherAfterNonowner[p: Policy] {
  some e: Execution | {
    OwnerThenBoth[e, p]
    eventually (e.event = Start and e.actor = Other and Nonowner.(e.phase) = Done)
  }
}
pred OtherOnFreshThreadState {
  eventually (some e: Execution |
    e.policy = Fixed and e.event = Read and e.actor = Other and
    Owner.(e.phase) = Done and Other.(e.thread) != Owner.(e.thread) and
    no Other.(e.thread).(e.installed) and Other.(e.selected) = e.published)
}
// Paired OwnerOnly schedules, matching OwnerFirst and NonownerFirst.
pred OwnerOnlyOwnerFirst {
  some e: Execution | {
    OwnerThenBoth[e, OwnerOnly]
    eventually (e.event = Start and e.actor = Nonowner and Owner.(e.phase) = Done)
    eventually (e.event = Start and e.actor = Other and Nonowner.(e.phase) = Done)
  }
}
pred OwnerOnlyNonownerFirst {
  some e: Execution | {
    e.policy = OwnerOnly
    after (e.event = Start and e.actor = Nonowner)
    always no Other.(e.parent)
    eventually completed[e]
    eventually (e.event = ForceOwner and e.actor = Nonowner)
  }
}
// Nonvacuity control: OwnerOnly admits both completed orders in one comparison.
pred OwnerOnlySchedulesExist {
  some disj e, f: Execution | {
    e.policy = OwnerOnly
    f.policy = OwnerOnly
    after (e.event = Start and e.actor = Owner and
      f.event = Start and f.actor = Nonowner)
    always (no Other.(e.parent) and no Other.(f.parent))
    eventually (completed[e] and completed[f])
    eventually (e.event = Start and e.actor = Nonowner and Owner.(e.phase) = Done)
    eventually (f.event = ForceOwner and f.actor = Nonowner)
  }
}
// Nonvacuity control: the definitional reference admits both completed orders.
pred ReferenceSchedulesExist {
  some disj e, f: Execution | {
    e.policy = AttemptLocal
    f.policy = AttemptLocal
    after (e.event = Start and e.actor = Owner and
      f.event = Start and f.actor = Nonowner)
    always (no Other.(e.parent) and no Other.(f.parent))
    eventually (completed[e] and completed[f])
    eventually (e.event = Start and e.actor = Nonowner and Owner.(e.phase) = Done)
    eventually (f.event = ForceOwner and f.actor = Nonowner)
  }
}

// Main safety checks use an exact 16-state lasso. Stutter padding also admits
// shorter prefixes without changing their read/publication observations.
// Native lasso bounds count states in the prefix plus loop, not arbitrary actions.
// Stuttering preserves the event marker, so a final read can loop unchanged.
// Executions independently step/stutter under the same temporal clock.
check OnlyOwnerPublishes for 16 but exactly 1 Execution, exactly 2 ThreadState,
  16..16 steps expect 0
check StackDiscipline for 16 but exactly 1 Execution, exactly 2 ThreadState,
  16..16 steps expect 0
check IndependentAfterPublicationFixed for 16 but exactly 1 Execution,
  exactly 2 ThreadState, 16..16 steps expect 0
check IndependentAfterPublicationOld for 16 but exactly 1 Execution,
  exactly 1 ThreadState, 16..16 steps expect 1
check NonownerOwnHintFixed for 16 but exactly 1 Execution, exactly 1 ThreadState,
  16..16 steps expect 1
check ExpressionOwnHintReference for 16 but exactly 1 Execution,
  exactly 2 ThreadState, 16..16 steps expect 0
check OtherAlwaysPublishedFixed for 16 but exactly 1 Execution,
  exactly 1 ThreadState, 16..16 steps expect 1
check FinalNonownerScheduleIndependentFixed for 16 but exactly 2 Execution,
  exactly 1 ThreadState, 16..16 steps expect 1
check FinalNonownerScheduleIndependentReference for 16 but exactly 2 Execution,
  exactly 1 ThreadState, 16..16 steps expect 0
run OwnerFirst for 16 but exactly 1 Execution, exactly 1 ThreadState,
  16..16 steps expect 1
run NonownerFirst for 16 but exactly 1 Execution, exactly 1 ThreadState,
  16..16 steps expect 1
check NonownerReadsPublicationOwnerOnly for 16 but exactly 1 Execution,
  exactly 2 ThreadState, 16..16 steps expect 0
check IndependentAfterPublicationOwnerOnly for 16 but exactly 1 Execution,
  exactly 2 ThreadState, 16..16 steps expect 0
check FinalNonownerScheduleIndependentOwnerOnly for 16 but exactly 2 Execution,
  exactly 1 ThreadState, 16..16 steps expect 0
run OwnerOnlyOwnerFirst for 16 but exactly 1 Execution, exactly 1 ThreadState,
  16..16 steps expect 1
run OwnerOnlyNonownerFirst for 16 but exactly 1 Execution, exactly 1 ThreadState,
  16..16 steps expect 1
run OwnerOnlySchedulesExist for 16 but exactly 2 Execution, exactly 1 ThreadState,
  16..16 steps expect 1
run OldOtherBeforeNonowner { OtherBeforeNonowner[Old] } for 16 but
  exactly 1 Execution, exactly 1 ThreadState, 16..16 steps expect 1
run OldOtherAfterNonowner { OtherAfterNonowner[Old] } for 16 but
  exactly 1 Execution, exactly 1 ThreadState, 16..16 steps expect 1
run FixedOtherBeforeNonowner { OtherBeforeNonowner[Fixed] } for 16 but
  exactly 1 Execution, exactly 1 ThreadState, 16..16 steps expect 1
run FixedOtherAfterNonowner { OtherAfterNonowner[Fixed] } for 16 but
  exactly 1 Execution, exactly 1 ThreadState, 16..16 steps expect 1
run OtherOnFreshThreadState for 16 but exactly 1 Execution, exactly 2 ThreadState,
  16..16 steps expect 1
run ReferenceSchedulesExist for 16 but exactly 2 Execution, exactly 1 ThreadState,
  16..16 steps expect 1
