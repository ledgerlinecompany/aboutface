import Testing

@testable import AboutFaceCore

/// `CenterStageStateMachine` (§12.5's app-side wiring): debounce of the raw
/// `CenterStageSignal` into a settled `Outcome`, the live `isEnabled` gate,
/// and `routerActive`'s collapse to a `Bool` for
/// `FeedbackRouter.setCenterStageActive(_:at:)`. Same fully-controlled-fake-
/// clock shape as `CameraMismatchStateMachineTests` (no real sleeps; this
/// type imports neither `AVFoundation` nor `CoreMediaIO`, so nothing here
/// needs a live camera).
struct CenterStageStateMachineTests {
  private let debounceMs = 500
  private var debounceSeconds: Double { Double(debounceMs) / 1000 }

  // MARK: - Debounce

  @Test("A settling .active signal is not reflected before the debounce window elapses")
  func active_notReflectedBeforeDebounceElapses() {
    var machine = CenterStageStateMachine(debounceMs: debounceMs)

    let tooSoon = machine.update(signal: .active, isEnabled: true, now: 0)
    #expect(tooSoon == .notActive)  // still the initial default
    #expect(!machine.routerActive)

    let stillTooSoon = machine.update(
      signal: .active, isEnabled: true, now: debounceSeconds - 0.01)
    #expect(stillTooSoon == .notActive)
    #expect(!machine.routerActive)
  }

  @Test("A settled .active signal (debounce elapsed) reports .active and routerActive == true")
  func active_settledAfterDebounceElapses() {
    var machine = CenterStageStateMachine(debounceMs: debounceMs)
    _ = machine.update(signal: .active, isEnabled: true, now: 0)
    let settled = machine.update(signal: .active, isEnabled: true, now: debounceSeconds)
    #expect(settled == .active)
    #expect(machine.routerActive)
  }

  @Test("Flapping between .active and .notActive faster than the debounce window never settles")
  func flapping_neverSettles() {
    var machine = CenterStageStateMachine(debounceMs: debounceMs)
    var now = 0.0
    for _ in 0..<20 {
      let a = machine.update(signal: .active, isEnabled: true, now: now)
      #expect(a == .notActive)
      #expect(!machine.routerActive)
      now += debounceSeconds / 4
      let b = machine.update(signal: .notActive, isEnabled: true, now: now)
      #expect(b == .notActive)
      now += debounceSeconds / 4
    }
  }

  // MARK: - Rising and falling edges

  @Test("Rising then falling edge, both settled: routerActive tracks true then false")
  func risingThenFallingEdge_routerActiveTracksBoth() {
    var machine = CenterStageStateMachine(debounceMs: debounceMs)
    _ = machine.update(signal: .active, isEnabled: true, now: 0)
    let afterRising = machine.update(signal: .active, isEnabled: true, now: debounceSeconds)
    #expect(afterRising == .active)
    #expect(machine.routerActive)

    var now = debounceSeconds + 1
    _ = machine.update(signal: .notActive, isEnabled: true, now: now)
    now += debounceSeconds
    let afterFalling = machine.update(signal: .notActive, isEnabled: true, now: now)
    #expect(afterFalling == .notActive)
    #expect(!machine.routerActive)
  }

  // MARK: - `.unknown` (`.deviceNotFound`): resolves to not-active, stays distinguishable

  @Test(
    "A settled .unknown signal reports .unknown (distinct from .notActive), and routerActive is false"
  )
  func unknown_settlesDistinctFromNotActive_routerActiveFalse() {
    var machine = CenterStageStateMachine(debounceMs: debounceMs)
    _ = machine.update(signal: .unknown, isEnabled: true, now: 0)
    let settled = machine.update(signal: .unknown, isEnabled: true, now: debounceSeconds)
    #expect(settled == .unknown)
    #expect(settled != .notActive)
    #expect(!machine.routerActive)
  }

  @Test("Losing the device mid-.active (settling to .unknown) drops routerActive to false")
  func activeThenDeviceLost_routerActiveDropsFalse() {
    var machine = CenterStageStateMachine(debounceMs: debounceMs)
    _ = machine.update(signal: .active, isEnabled: true, now: 0)
    _ = machine.update(signal: .active, isEnabled: true, now: debounceSeconds)
    #expect(machine.routerActive)

    var now = debounceSeconds + 1
    _ = machine.update(signal: .unknown, isEnabled: true, now: now)
    now += debounceSeconds
    let settled = machine.update(signal: .unknown, isEnabled: true, now: now)
    #expect(settled == .unknown)
    #expect(!machine.routerActive)
  }

  // MARK: - `isEnabled`: a live gate

  @Test("Disabled reports .disabled regardless of the underlying settled signal")
  func disabled_reportsDisabled() {
    var machine = CenterStageStateMachine(debounceMs: debounceMs)
    _ = machine.update(signal: .active, isEnabled: true, now: 0)
    let disabled = machine.update(signal: .active, isEnabled: false, now: debounceSeconds)
    #expect(disabled == .disabled)
  }

  @Test("Re-enabling shows the current truth immediately — debounce kept advancing underneath")
  func reEnabling_showsCurrentTruthImmediately() {
    var machine = CenterStageStateMachine(debounceMs: debounceMs)
    _ = machine.update(signal: .active, isEnabled: false, now: 0)
    let stillDisabled = machine.update(signal: .active, isEnabled: false, now: debounceSeconds)
    #expect(stillDisabled == .disabled)

    // Re-enabling with the same settled signal shows it right away, with no
    // fresh debounce required.
    let reEnabled = machine.update(signal: .active, isEnabled: true, now: debounceSeconds + 0.001)
    #expect(reEnabled == .active)
    #expect(machine.routerActive)
  }

  @Test("routerActive is not gated on isEnabled — the router forces false when disabled itself")
  func routerActive_ignoresIsEnabled() {
    var machine = CenterStageStateMachine(debounceMs: debounceMs)
    _ = machine.update(signal: .active, isEnabled: false, now: 0)
    _ = machine.update(signal: .active, isEnabled: false, now: debounceSeconds)
    #expect(machine.routerActive)
  }
}
