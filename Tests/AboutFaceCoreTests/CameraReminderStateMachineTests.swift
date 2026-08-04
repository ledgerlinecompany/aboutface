import Testing

@testable import AboutFaceCore

/// `CameraReminderStateMachine` (§12.2/§16.4): exhaustive coverage of the
/// rising-edge-only firing rule, each of the three settle-time gates
/// (capturing, silenced, enabled), the field-finding
/// `Config.Camera.reminderDelayMs` delay between a settled edge and speech,
/// the SECOND gate re-validation at that delay's deadline, and the "a gate
/// that blocks an evaluation consumes it — no retroactive fire" decision
/// documented on the machine itself, now applying at both evaluation
/// points. Same fully-controlled-fake-clock shape as
/// `CameraGatingStateMachineTests` (no real sleeps; this type doesn't import
/// `AVFoundation`/`CoreMediaIO` either, so nothing here needs a live camera).
///
/// Split across two suites purely to stay under SwiftLint's
/// `type_body_length` (this file's own equivalent of `Config+Audio.swift`'s
/// precedent for `file_length`): `CameraReminderStateMachineTests` covers
/// the debounce/arm/delay mechanics; `CameraReminderDeadlineGateTests`
/// (below) covers the deadline's second gate evaluation and the
/// no-retroactive-fire rule specifically. Shared fixtures (`debounceMs`,
/// `delayMs`, and the `settleEdge`/`arm` helpers) live at file scope so
/// both suites use the exact same numbers.
struct CameraReminderStateMachineTests {
  // MARK: - Rising edge settles into `.pending`, not `.speakNow`

  @Test("Rising edge settles into .pending, not .speakNow — deadline is settle-time + the delay")
  func risingEdge_settlesIntoPending() {
    var machine = CameraReminderStateMachine(
      debounceMs: reminderDebounceMs, delayMs: reminderDelayMs)

    let tooSoon = machine.update(
      busy: true, isCapturing: false, isSilenced: false, isEnabled: true, now: 0)
    #expect(tooSoon == .nothing)

    let settled = machine.update(
      busy: true, isCapturing: false, isSilenced: false, isEnabled: true,
      now: reminderDebounceSeconds)
    #expect(settled == .pending(deadline: reminderDebounceSeconds + reminderDelaySeconds))
  }

  @Test("Nothing is spoken before the delay elapses; it is spoken exactly at/after the boundary")
  func delay_notSpokenBeforeBoundary_spokenAtBoundary() {
    var machine = CameraReminderStateMachine(
      debounceMs: reminderDebounceMs, delayMs: reminderDelayMs)
    let deadline = arm(&machine)

    let tooSoon = machine.update(
      busy: true, isCapturing: false, isSilenced: false, isEnabled: true, now: deadline - 0.01)
    #expect(tooSoon == .pending(deadline: deadline))

    let onTime = machine.update(
      busy: true, isCapturing: false, isSilenced: false, isEnabled: true, now: deadline)
    #expect(onTime == .speakNow)
  }

  @Test("Holding busy true after speaking does not refire")
  func holdingTrueAfterSpeaking_doesNotRefire() {
    var machine = CameraReminderStateMachine(
      debounceMs: reminderDebounceMs, delayMs: reminderDelayMs)
    let deadline = arm(&machine)
    let spoken = machine.update(
      busy: true, isCapturing: false, isSilenced: false, isEnabled: true, now: deadline)
    #expect(spoken == .speakNow)

    for tick in stride(from: 1.0, through: 10.0, by: 1.0) {
      let repeated = machine.update(
        busy: true, isCapturing: false, isSilenced: false, isEnabled: true,
        now: deadline + tick)
      #expect(repeated == .nothing)
    }
  }

  @Test("Falling then rising re-arms: a second episode fires again, delay included both times")
  func fallingThenRising_reArms() {
    var machine = CameraReminderStateMachine(
      debounceMs: reminderDebounceMs, delayMs: reminderDelayMs)

    let firstDeadline = arm(&machine, startingAt: 0)
    #expect(
      machine.update(
        busy: true, isCapturing: false, isSilenced: false, isEnabled: true, now: firstDeadline)
        == .speakNow)

    var now = firstDeadline + 1
    _ = machine.update(
      busy: false, isCapturing: false, isSilenced: false, isEnabled: true, now: now)
    let fallOutcome = machine.update(
      busy: false, isCapturing: false, isSilenced: false, isEnabled: true,
      now: now + reminderDebounceSeconds)
    #expect(fallOutcome == .nothing)
    now += reminderDebounceSeconds + 1

    let secondDeadline = arm(&machine, startingAt: now)
    #expect(
      machine.update(
        busy: true, isCapturing: false, isSilenced: false, isEnabled: true, now: secondDeadline)
        == .speakNow)
  }

  @Test("Falling edge, once armed but before the deadline, never produces .speakNow")
  func fallingEdgeBeforeDeadline_neverFires() {
    var machine = CameraReminderStateMachine(
      debounceMs: reminderDebounceMs, delayMs: reminderDelayMs)
    // The armed deadline is reminderDebounceSeconds + reminderDelaySeconds;
    // the falling edge below lands well before it.
    _ = arm(&machine)

    _ = machine.update(
      busy: false, isCapturing: false, isSilenced: false, isEnabled: true,
      now: reminderDebounceSeconds + 0.1)
    let fallSettled = machine.update(
      busy: false, isCapturing: false, isSilenced: false, isEnabled: true,
      now: reminderDebounceSeconds + 0.1 + reminderDebounceSeconds)
    #expect(fallSettled == .nothing)
  }

  // MARK: - The three edge-settle-time gates (never even arms)

  @Test(
    "Busy while capturing at edge-settle never arms — the hard constraint from §12.2's asymmetry")
  func busyWhileCapturingAtEdge_neverArms() {
    var machine = CameraReminderStateMachine(
      debounceMs: reminderDebounceMs, delayMs: reminderDelayMs)
    let outcome = settleEdge(&machine, busy: true, isCapturing: true)
    #expect(outcome == .nothing)
  }

  @Test("Silence at edge-settle never arms")
  func silencedAtEdge_neverArms() {
    var machine = CameraReminderStateMachine(
      debounceMs: reminderDebounceMs, delayMs: reminderDelayMs)
    let outcome = settleEdge(&machine, busy: true, isSilenced: true)
    #expect(outcome == .nothing)
  }

  @Test("Disabled (Config.Camera.monitorReminderEnabled == false) at edge-settle never arms")
  func disabledAtEdge_neverArms() {
    var machine = CameraReminderStateMachine(
      debounceMs: reminderDebounceMs, delayMs: reminderDelayMs)
    let outcome = settleEdge(&machine, busy: true, isEnabled: false)
    #expect(outcome == .nothing)
  }

  // MARK: - Debounce behavior (mirrors CameraGatingStateMachineTests)

  @Test("Flapping busy signal before the debounce window elapses never arms, never fires")
  func flappingBeforeDebounce_neverArmsOrFires() {
    var machine = CameraReminderStateMachine(
      debounceMs: reminderDebounceMs, delayMs: reminderDelayMs)

    var now = 0.0
    for _ in 0..<20 {
      let a = machine.update(
        busy: true, isCapturing: false, isSilenced: false, isEnabled: true, now: now)
      #expect(a == .nothing)
      now += reminderDebounceSeconds / 4
      let b = machine.update(
        busy: false, isCapturing: false, isSilenced: false, isEnabled: true, now: now)
      #expect(b == .nothing)
      now += reminderDebounceSeconds / 4
    }
  }

  @Test("Settling back to the original value before debounce elapses cancels the pending edge")
  func settlingBackToOriginal_cancelsPendingEdge() {
    var machine = CameraReminderStateMachine(
      debounceMs: reminderDebounceMs, delayMs: reminderDelayMs)

    #expect(
      machine.update(busy: true, isCapturing: false, isSilenced: false, isEnabled: true, now: 0)
        == .nothing)
    #expect(
      machine.update(
        busy: false, isCapturing: false, isSilenced: false, isEnabled: true,
        now: reminderDebounceSeconds / 2) == .nothing)
    #expect(
      machine.update(
        busy: false, isCapturing: false, isSilenced: false, isEnabled: true,
        now: reminderDebounceSeconds * 10) == .nothing)
  }

  @Test(
    "Exact debounce boundary (now - pendingSince == reminderDebounceSeconds) arms, with the correct deadline"
  )
  func exactDebounceBoundaryArms() {
    var machine = CameraReminderStateMachine(
      debounceMs: reminderDebounceMs, delayMs: reminderDelayMs)
    _ = machine.update(
      busy: true, isCapturing: false, isSilenced: false, isEnabled: true, now: 100)
    let settled = machine.update(
      busy: true, isCapturing: false, isSilenced: false, isEnabled: true,
      now: 100 + reminderDebounceSeconds)
    #expect(settled == .pending(deadline: 100 + reminderDebounceSeconds + reminderDelaySeconds))
  }
}
