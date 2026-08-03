import Testing

@testable import AboutFaceCore

/// `CameraGatingStateMachine` (§12.2): exhaustive coverage of the
/// configured/unconfigured × busy-transition × mode rule table, plus
/// debounce timing exercised with a fully controlled fake clock (no real
/// sleeps — CI rule: no test may require a live camera, and this type
/// doesn't even import `AVFoundation`, so nothing here needs one).
struct CameraGatingStateMachineTests {
  private let debounceMs = 500
  private var debounceSeconds: Double { Double(debounceMs) / 1000 }

  // MARK: - free → busy

  @Test("off + unconfigured + busy: no event, even well past the debounce window")
  func offUnconfiguredBusy_noEvent() {
    var machine = CameraGatingStateMachine(debounceMs: debounceMs)
    let events = settle(&machine, busy: true, appConfigured: false, mode: .off)
    #expect(events.isEmpty)
  }

  @Test("off + configured + busy: activateMonitor, only after the debounce window elapses")
  func offConfiguredBusy_activatesMonitorAfterDebounce() {
    var machine = CameraGatingStateMachine(debounceMs: debounceMs)

    let tooSoon = machine.update(
      selectedDeviceBusy: true, appConfigured: true, mode: .off, now: 0)
    #expect(tooSoon.isEmpty)

    let stillTooSoon = machine.update(
      selectedDeviceBusy: true, appConfigured: true, mode: .off, now: debounceSeconds - 0.01)
    #expect(stillTooSoon.isEmpty)

    let settled = machine.update(
      selectedDeviceBusy: true, appConfigured: true, mode: .off, now: debounceSeconds)
    #expect(settled == [.activateMonitor])
  }

  @Test("setup + busy (configured): leaveSetup after debounce")
  func setupBusyConfigured_leavesSetup() {
    var machine = CameraGatingStateMachine(debounceMs: debounceMs)
    let events = settle(&machine, busy: true, appConfigured: true, mode: .setup)
    #expect(events == [.leaveSetup])
  }

  @Test("setup + busy (unconfigured): leaveSetup fires regardless of appConfigured")
  func setupBusyUnconfigured_stillLeavesSetup() {
    var machine = CameraGatingStateMachine(debounceMs: debounceMs)
    let events = settle(&machine, busy: true, appConfigured: false, mode: .setup)
    #expect(events == [.leaveSetup])
  }

  @Test("monitor + busy: no event — already active")
  func monitorBusy_noEvent() {
    var machine = CameraGatingStateMachine(debounceMs: debounceMs)
    let events = settle(&machine, busy: true, appConfigured: true, mode: .monitor)
    #expect(events.isEmpty)
  }

  // MARK: - busy → free

  @Test("monitor + free (device released): deactivateMonitor after debounce")
  func monitorFree_deactivatesMonitorAfterDebounce() {
    var machine = CameraGatingStateMachine(debounceMs: debounceMs)
    // Establish "busy" as the debounced baseline first, mirroring what a
    // real session looks like (Monitor only got here because the device
    // was busy at some point).
    _ = settle(&machine, busy: true, appConfigured: true, mode: .monitor, startingAt: 0)

    let tooSoon = machine.update(
      selectedDeviceBusy: false, appConfigured: true, mode: .monitor, now: 10)
    #expect(tooSoon.isEmpty)

    let settled = machine.update(
      selectedDeviceBusy: false, appConfigured: true, mode: .monitor, now: 10 + debounceSeconds)
    #expect(settled == [.deactivateMonitor])
  }

  @Test("off + free: no event")
  func offFree_noEvent() {
    var machine = CameraGatingStateMachine(debounceMs: debounceMs)
    // Baseline debouncedBusy starts false, so free→free is a non-event by
    // construction; assert explicitly so the "off + free" cell in the rule
    // table has a pinned test even though it can never fire an event.
    let events = machine.update(
      selectedDeviceBusy: false, appConfigured: true, mode: .off, now: 0)
    #expect(events.isEmpty)
  }

  @Test("setup + free: no event")
  func setupFree_noEvent() {
    var machine = CameraGatingStateMachine(debounceMs: debounceMs)
    let events = machine.update(
      selectedDeviceBusy: false, appConfigured: true, mode: .setup, now: 0)
    #expect(events.isEmpty)
  }

  // MARK: - Debounce behavior

  @Test("Flapping busy signal before the debounce window resets the timer — no event")
  func flappingBeforeDebounce_neverFires() {
    var machine = CameraGatingStateMachine(debounceMs: debounceMs)

    var events: [CameraGatingEvent] = []
    var now = 0.0
    // Toggle every quarter of the debounce window — never holds steady long
    // enough for the debounce window to elapse.
    for _ in 0..<20 {
      events += machine.update(
        selectedDeviceBusy: true, appConfigured: true, mode: .off, now: now)
      now += debounceSeconds / 4
      events += machine.update(
        selectedDeviceBusy: false, appConfigured: true, mode: .off, now: now)
      now += debounceSeconds / 4
    }
    #expect(events.isEmpty)
  }

  @Test("Settling back to the original value before debounce elapses cancels the pending event")
  func settlingBackToOriginal_cancelsPendingEvent() {
    var machine = CameraGatingStateMachine(debounceMs: debounceMs)

    var events: [CameraGatingEvent] = []
    events += machine.update(selectedDeviceBusy: true, appConfigured: true, mode: .off, now: 0)
    events += machine.update(
      selectedDeviceBusy: false, appConfigured: true, mode: .off, now: debounceSeconds / 2)
    // Even after waiting well past the original debounce deadline, nothing
    // should fire: the signal returned to its already-known (free) value.
    events += machine.update(
      selectedDeviceBusy: false, appConfigured: true, mode: .off, now: debounceSeconds * 10)
    #expect(events.isEmpty)
  }

  @Test("Exact debounce boundary (now - pendingSince == debounceSeconds) fires")
  func exactBoundaryFires() {
    var machine = CameraGatingStateMachine(debounceMs: debounceMs)
    _ = machine.update(selectedDeviceBusy: true, appConfigured: true, mode: .off, now: 100)
    let events = machine.update(
      selectedDeviceBusy: true, appConfigured: true, mode: .off, now: 100 + debounceSeconds)
    #expect(events == [.activateMonitor])
  }

  @Test("Repeated updates after settling do not re-fire the same event")
  func settledState_doesNotRefire() {
    var machine = CameraGatingStateMachine(debounceMs: debounceMs)
    let first = settle(&machine, busy: true, appConfigured: true, mode: .off, startingAt: 0)
    #expect(first == [.activateMonitor])

    let repeated = machine.update(
      selectedDeviceBusy: true, appConfigured: true, mode: .monitor, now: 1000)
    #expect(repeated.isEmpty)
  }

  @Test("A full session shape: activate, then release deactivates")
  func fullSessionShape() {
    var machine = CameraGatingStateMachine(debounceMs: debounceMs)
    var now = 0.0

    let activated = settle(
      &machine, busy: true, appConfigured: true, mode: .off, startingAt: now)
    #expect(activated == [.activateMonitor])
    now += debounceSeconds + 1

    // Caller applies the event: mode is now .monitor for subsequent calls.
    let stillBusy = machine.update(
      selectedDeviceBusy: true, appConfigured: true, mode: .monitor, now: now)
    #expect(stillBusy.isEmpty)
    now += 5

    let released = settle(
      &machine, busy: false, appConfigured: true, mode: .monitor, startingAt: now)
    #expect(released == [.deactivateMonitor])
  }

  // MARK: - Helpers

  /// Feeds `busy` starting at `startingAt`, then again after the debounce
  /// window has fully elapsed, returning whatever the second call yields —
  /// the settled result of a signal that transitions once and then holds.
  @discardableResult
  private func settle(
    _ machine: inout CameraGatingStateMachine,
    busy: Bool,
    appConfigured: Bool,
    mode: CameraGatingMode,
    startingAt: Double = 0
  ) -> [CameraGatingEvent] {
    _ = machine.update(
      selectedDeviceBusy: busy, appConfigured: appConfigured, mode: mode, now: startingAt)
    return machine.update(
      selectedDeviceBusy: busy, appConfigured: appConfigured, mode: mode,
      now: startingAt + debounceSeconds)
  }
}
