import Testing

@testable import AboutFaceCore

/// The deadline's second gate evaluation, and the no-retroactive-fire rule
/// applied to both evaluation points — split out of
/// `CameraReminderStateMachineTests` above purely for `type_body_length`;
/// see that type's doc comment for the full rationale and the shared
/// fixtures (`debounceMs`/`delayMs`/`settleEdge`/`arm`) both suites use.
struct CameraReminderDeadlineGateTests {
  // MARK: - The field-finding delay's SECOND gate re-validation, at the deadline

  @Test(
    """
    Capturing starting during the delay drops the reminder at the deadline, silently — and it \
    does not fire later even once capturing stops again
    """
  )
  func capturingDuringDelay_dropsAtDeadlineAndStaysDropped() {
    var machine = CameraReminderStateMachine(
      debounceMs: reminderDebounceMs, delayMs: reminderDelayMs)
    let deadline = arm(&machine)

    // Mid-delay: capturing flips true, but the deadline hasn't arrived yet — a
    // tick here must not react to it early, only report still-pending.
    let midway = machine.update(
      busy: true, isCapturing: true, isSilenced: false, isEnabled: true, now: deadline - 0.5)
    #expect(midway == .pending(deadline: deadline))

    // At the deadline, capturing is still true: the phrase would be false
    // ("Monitor is off") since About Face itself is now capturing — dropped.
    let atDeadline = machine.update(
      busy: true, isCapturing: true, isSilenced: false, isEnabled: true, now: deadline)
    #expect(atDeadline == .nothing)

    // Capturing later stops, busy stays true throughout — no NEW edge, so no
    // retroactive fire even though the gate is favorable again.
    for tick in stride(from: 1.0, through: 10.0, by: 1.0) {
      let later = machine.update(
        busy: true, isCapturing: false, isSilenced: false, isEnabled: true,
        now: deadline + tick)
      #expect(later == .nothing)
    }
  }

  @Test("Silencing during the delay drops the reminder at the deadline, and it does not fire later")
  func silencingDuringDelay_dropsAtDeadlineAndStaysDropped() {
    var machine = CameraReminderStateMachine(
      debounceMs: reminderDebounceMs, delayMs: reminderDelayMs)
    let deadline = arm(&machine)

    let atDeadline = machine.update(
      busy: true, isCapturing: false, isSilenced: true, isEnabled: true, now: deadline)
    #expect(atDeadline == .nothing)

    for tick in stride(from: 1.0, through: 10.0, by: 1.0) {
      let later = machine.update(
        busy: true, isCapturing: false, isSilenced: false, isEnabled: true,
        now: deadline + tick)
      #expect(later == .nothing)
    }
  }

  @Test("Disabling during the delay drops the reminder at the deadline, and it does not fire later")
  func disablingDuringDelay_dropsAtDeadlineAndStaysDropped() {
    var machine = CameraReminderStateMachine(
      debounceMs: reminderDebounceMs, delayMs: reminderDelayMs)
    let deadline = arm(&machine)

    let atDeadline = machine.update(
      busy: true, isCapturing: false, isSilenced: false, isEnabled: false, now: deadline)
    #expect(atDeadline == .nothing)

    for tick in stride(from: 1.0, through: 10.0, by: 1.0) {
      let later = machine.update(
        busy: true, isCapturing: false, isSilenced: false, isEnabled: true,
        now: deadline + tick)
      #expect(later == .nothing)
    }
  }

  @Test("Camera going idle during the delay drops the reminder — nothing left to remind about")
  func cameraIdleDuringDelay_drops() {
    var machine = CameraReminderStateMachine(
      debounceMs: reminderDebounceMs, delayMs: reminderDelayMs)
    // Armed at reminderDebounceSeconds; deadline = reminderDebounceSeconds + reminderDelaySeconds.
    let deadline = arm(&machine)

    // Busy falls mid-delay (a false start, or a call that ended instantly)
    // and settles to false well before the original deadline.
    let fallStart = reminderDebounceSeconds + 0.1
    _ = machine.update(
      busy: false, isCapturing: false, isSilenced: false, isEnabled: true, now: fallStart)
    let fallSettled = machine.update(
      busy: false, isCapturing: false, isSilenced: false, isEnabled: true,
      now: fallStart + reminderDebounceSeconds)
    #expect(fallSettled == .nothing)

    // Ticking through to (and past) the original deadline never speaks.
    let atOriginalDeadline = machine.update(
      busy: false, isCapturing: false, isSilenced: false, isEnabled: true, now: deadline)
    #expect(atOriginalDeadline == .nothing)
  }

  // MARK: - No retroactive fire (documented judgment call, both evaluation points)

  @Test(
    """
    Becoming un-silenced after an edge-time drop does NOT retroactively fire — only a fresh \
    fall-then-rise re-arms
    """
  )
  func unsilencingAfterEdgeDrop_doesNotRetroactivelyFire_onlyFreshEdgeReArms() {
    var machine = CameraReminderStateMachine(
      debounceMs: reminderDebounceMs, delayMs: reminderDelayMs)
    let dropped = settleEdge(&machine, busy: true, isSilenced: true)
    #expect(dropped == .nothing)

    for tick in stride(from: 1.0, through: 10.0, by: 1.0) {
      let afterUnsilencing = machine.update(
        busy: true, isCapturing: false, isSilenced: false, isEnabled: true,
        now: reminderDebounceSeconds + tick)
      #expect(afterUnsilencing == .nothing)
    }

    // A genuinely fresh episode (fall, then rise) re-arms normally.
    var now = reminderDebounceSeconds + 11
    _ = machine.update(
      busy: false, isCapturing: false, isSilenced: false, isEnabled: true, now: now)
    #expect(
      machine.update(
        busy: false, isCapturing: false, isSilenced: false, isEnabled: true,
        now: now + reminderDebounceSeconds) == .nothing)
    now += reminderDebounceSeconds + 1

    let deadline = arm(&machine, startingAt: now)
    #expect(
      machine.update(
        busy: true, isCapturing: false, isSilenced: false, isEnabled: true, now: deadline)
        == .speakNow)
  }

  @Test(
    """
    A reminder dropped at the DEADLINE (not the edge) also does not retroactively fire on later \
    ticks — only a fresh fall-then-rise re-arms
    """
  )
  func droppedAtDeadline_doesNotRetroactivelyFire_onlyFreshEdgeReArms() {
    var machine = CameraReminderStateMachine(
      debounceMs: reminderDebounceMs, delayMs: reminderDelayMs)
    let deadline = arm(&machine)

    let dropped = machine.update(
      busy: true, isCapturing: true, isSilenced: false, isEnabled: true, now: deadline)
    #expect(dropped == .nothing)

    // Conditions become favorable again; busy never fell, so no new edge.
    for tick in stride(from: 1.0, through: 10.0, by: 1.0) {
      let later = machine.update(
        busy: true, isCapturing: false, isSilenced: false, isEnabled: true,
        now: deadline + tick)
      #expect(later == .nothing)
    }

    // Fresh episode: fall, then rise, re-arms and eventually fires.
    var now = deadline + 11
    _ = machine.update(
      busy: false, isCapturing: false, isSilenced: false, isEnabled: true, now: now)
    #expect(
      machine.update(
        busy: false, isCapturing: false, isSilenced: false, isEnabled: true,
        now: now + reminderDebounceSeconds) == .nothing)
    now += reminderDebounceSeconds + 1

    let secondDeadline = arm(&machine, startingAt: now)
    #expect(
      machine.update(
        busy: true, isCapturing: false, isSilenced: false, isEnabled: true, now: secondDeadline)
        == .speakNow)
  }
}
