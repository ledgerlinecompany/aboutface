import Testing

@testable import AboutFaceCore

/// `CameraReminderStateMachine` (§12.2/§16.4): exhaustive coverage of the
/// rising-edge-only firing rule, each of the three settle-time gates
/// (capturing, silenced, enabled), and the "a gate that blocks an edge
/// consumes it — no retroactive fire" decision documented on the machine
/// itself. Same fully-controlled-fake-clock shape as
/// `CameraGatingStateMachineTests` (no real sleeps; this type doesn't import
/// `AVFoundation`/`CoreMediaIO` either, so nothing here needs a live camera).
struct CameraReminderStateMachineTests {
  private let debounceMs = 500
  private var debounceSeconds: Double { Double(debounceMs) / 1000 }

  // MARK: - Basic rising-edge firing

  @Test("Rising edge fires once, after the debounce window elapses (not before)")
  func risingEdge_firesOnceAfterDebounce() {
    var machine = CameraReminderStateMachine(debounceMs: debounceMs)

    let tooSoon = machine.update(
      busy: true, isCapturing: false, isSilenced: false, isEnabled: true, now: 0)
    #expect(tooSoon == false)

    let stillTooSoon = machine.update(
      busy: true, isCapturing: false, isSilenced: false, isEnabled: true,
      now: debounceSeconds - 0.01)
    #expect(stillTooSoon == false)

    let settled = machine.update(
      busy: true, isCapturing: false, isSilenced: false, isEnabled: true, now: debounceSeconds)
    #expect(settled == true)
  }

  @Test("Holding busy true does not refire")
  func holdingTrue_doesNotRefire() {
    var machine = CameraReminderStateMachine(debounceMs: debounceMs)
    let first = settle(&machine, busy: true)
    #expect(first == true)

    for tick in stride(from: 1.0, through: 10.0, by: 1.0) {
      let repeated = machine.update(
        busy: true, isCapturing: false, isSilenced: false, isEnabled: true,
        now: debounceSeconds + tick)
      #expect(repeated == false)
    }
  }

  @Test("Falling then rising re-arms: a second episode fires again")
  func fallingThenRising_reArms() {
    var machine = CameraReminderStateMachine(debounceMs: debounceMs)
    var now = 0.0

    #expect(settle(&machine, busy: true, startingAt: now) == true)
    now += debounceSeconds + 1

    #expect(settle(&machine, busy: false, startingAt: now) == false)
    now += debounceSeconds + 1

    #expect(settle(&machine, busy: true, startingAt: now) == true)
  }

  @Test("Falling edge itself never fires, regardless of the gates")
  func fallingEdge_neverFires() {
    var machine = CameraReminderStateMachine(debounceMs: debounceMs)
    _ = settle(&machine, busy: true)
    let falling = settle(&machine, busy: false, startingAt: debounceSeconds + 1)
    #expect(falling == false)
  }

  // MARK: - The three settle-time gates

  @Test("Busy while capturing never fires — the hard constraint from §12.2's asymmetry")
  func busyWhileCapturing_neverFires() {
    var machine = CameraReminderStateMachine(debounceMs: debounceMs)
    let events = settle(&machine, busy: true, isCapturing: true)
    #expect(events == false)
  }

  @Test("Silence suppresses the reminder")
  func silenced_suppresses() {
    var machine = CameraReminderStateMachine(debounceMs: debounceMs)
    let events = settle(&machine, busy: true, isSilenced: true)
    #expect(events == false)
  }

  @Test("Disabled (Config.Camera.monitorReminderEnabled == false) suppresses the reminder")
  func disabled_suppresses() {
    var machine = CameraReminderStateMachine(debounceMs: debounceMs)
    let events = settle(&machine, busy: true, isEnabled: false)
    #expect(events == false)
  }

  // MARK: - No retroactive fire (documented judgment call)

  @Test(
    """
    Becoming un-silenced mid-episode does NOT retroactively fire a reminder \
    suppressed at settle time
    """
  )
  func unsilencingMidEpisode_doesNotRetroactivelyFire() {
    var machine = CameraReminderStateMachine(debounceMs: debounceMs)
    // Edge settles while silenced: suppressed, and consumed.
    let suppressed = settle(&machine, busy: true, isSilenced: true)
    #expect(suppressed == false)

    // Un-silence, busy stays true the whole time (no new edge) — later
    // observations must stay silent too, however many ticks pass.
    for tick in stride(from: 1.0, through: 10.0, by: 1.0) {
      let afterUnsilencing = machine.update(
        busy: true, isCapturing: false, isSilenced: false, isEnabled: true,
        now: debounceSeconds + tick)
      #expect(afterUnsilencing == false)
    }
  }

  @Test(
    """
    Capturing stopping mid-episode does NOT retroactively fire a reminder \
    suppressed at settle time — the same rule as the silence case, applied \
    to the constraint that is actually load-bearing in practice
    """
  )
  func capturingStoppingMidEpisode_doesNotRetroactivelyFire() {
    var machine = CameraReminderStateMachine(debounceMs: debounceMs)
    // Realistic shape: About Face starts capturing while idle, which is
    // itself what makes the raw busy signal read true (§12.2's asymmetry).
    let suppressed = settle(&machine, busy: true, isCapturing: true)
    #expect(suppressed == false)

    // Capturing stops; busy stays true throughout (e.g. a real conferencing
    // app is also on the call) — no NEW edge occurred, so nothing fires.
    for tick in stride(from: 1.0, through: 10.0, by: 1.0) {
      let afterStopping = machine.update(
        busy: true, isCapturing: false, isSilenced: false, isEnabled: true,
        now: debounceSeconds + tick)
      #expect(afterStopping == false)
    }
  }

  @Test("Enabling mid-episode does NOT retroactively fire a reminder suppressed at settle time")
  func enablingMidEpisode_doesNotRetroactivelyFire() {
    var machine = CameraReminderStateMachine(debounceMs: debounceMs)
    let suppressed = settle(&machine, busy: true, isEnabled: false)
    #expect(suppressed == false)

    let afterEnabling = machine.update(
      busy: true, isCapturing: false, isSilenced: false, isEnabled: true,
      now: debounceSeconds + 5)
    #expect(afterEnabling == false)
  }

  @Test("A suppressed episode still re-arms normally once busy falls and rises again")
  func suppressedEpisode_stillReArmsOnNextRisingEdge() {
    var machine = CameraReminderStateMachine(debounceMs: debounceMs)
    var now = 0.0

    #expect(settle(&machine, busy: true, isCapturing: true, startingAt: now) == false)
    now += debounceSeconds + 1

    #expect(settle(&machine, busy: false, isCapturing: false, startingAt: now) == false)
    now += debounceSeconds + 1

    // Fresh edge, gates now favorable: fires.
    #expect(settle(&machine, busy: true, isCapturing: false, startingAt: now) == true)
  }

  // MARK: - Debounce behavior (mirrors CameraGatingStateMachineTests)

  @Test("Flapping busy signal before the debounce window elapses never fires")
  func flappingBeforeDebounce_neverFires() {
    var machine = CameraReminderStateMachine(debounceMs: debounceMs)

    var fired = false
    var now = 0.0
    for _ in 0..<20 {
      fired =
        fired
        || machine.update(
          busy: true, isCapturing: false, isSilenced: false, isEnabled: true, now: now)
      now += debounceSeconds / 4
      fired =
        fired
        || machine.update(
          busy: false, isCapturing: false, isSilenced: false, isEnabled: true, now: now)
      now += debounceSeconds / 4
    }
    #expect(fired == false)
  }

  @Test("Settling back to the original value before debounce elapses cancels the pending edge")
  func settlingBackToOriginal_cancelsPendingEdge() {
    var machine = CameraReminderStateMachine(debounceMs: debounceMs)

    var fired = false
    fired =
      fired
      || machine.update(
        busy: true, isCapturing: false, isSilenced: false, isEnabled: true, now: 0)
    fired =
      fired
      || machine.update(
        busy: false, isCapturing: false, isSilenced: false, isEnabled: true,
        now: debounceSeconds / 2)
    fired =
      fired
      || machine.update(
        busy: false, isCapturing: false, isSilenced: false, isEnabled: true,
        now: debounceSeconds * 10)
    #expect(fired == false)
  }

  @Test("Exact debounce boundary (now - pendingSince == debounceSeconds) fires")
  func exactBoundaryFires() {
    var machine = CameraReminderStateMachine(debounceMs: debounceMs)
    _ = machine.update(
      busy: true, isCapturing: false, isSilenced: false, isEnabled: true, now: 100)
    let settled = machine.update(
      busy: true, isCapturing: false, isSilenced: false, isEnabled: true,
      now: 100 + debounceSeconds)
    #expect(settled == true)
  }

  // MARK: - Helpers

  /// Feeds `busy` starting at `startingAt`, then again after the debounce
  /// window has fully elapsed, returning whatever the second call yields —
  /// the settled result of a signal that transitions once and then holds.
  @discardableResult
  private func settle(
    _ machine: inout CameraReminderStateMachine,
    busy: Bool,
    isCapturing: Bool = false,
    isSilenced: Bool = false,
    isEnabled: Bool = true,
    startingAt: Double = 0
  ) -> Bool {
    _ = machine.update(
      busy: busy, isCapturing: isCapturing, isSilenced: isSilenced, isEnabled: isEnabled,
      now: startingAt)
    return machine.update(
      busy: busy, isCapturing: isCapturing, isSilenced: isSilenced, isEnabled: isEnabled,
      now: startingAt + debounceSeconds)
  }
}
