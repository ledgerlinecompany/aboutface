import Testing

@testable import AboutFaceCore

/// `MonitorToggleIntent.decide(isRunning:mode:)` (§8's ⌘⌃⇧M): exhaustive
/// coverage of the three-way decision — see that type's doc comment for why
/// a plain boolean flip is not enough.
struct MonitorToggleIntentTests {

  @Test("Not running: startMonitor, regardless of mode")
  func notRunning_startsMonitor() {
    #expect(MonitorToggleIntent.decide(isRunning: false, mode: .setup) == .startMonitor)
    #expect(MonitorToggleIntent.decide(isRunning: false, mode: .monitor) == .startMonitor)
  }

  @Test("Running in Setup: switchToMonitor")
  func runningInSetup_switchesToMonitor() {
    #expect(MonitorToggleIntent.decide(isRunning: true, mode: .setup) == .switchToMonitor)
  }

  @Test("Running in Monitor: stop")
  func runningInMonitor_stops() {
    #expect(MonitorToggleIntent.decide(isRunning: true, mode: .monitor) == .stop)
  }
}
