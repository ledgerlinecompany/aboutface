import Testing

@testable import AboutFaceCore

/// `CameraMismatchStateMachine` (§12.3): debounce of the raw
/// `CameraMismatchClassification` into a settled value, the live
/// `isEnabled` gate, and the dismiss/re-arm discipline ("re-arms only when
/// the condition clears and recurs" — see that type's doc comment). Same
/// fully-controlled-fake-clock shape as `CameraReminderStateMachineTests`
/// (no real sleeps; this type imports neither `AVFoundation` nor
/// `CoreMediaIO`, so nothing here needs a live camera).
struct CameraMismatchStateMachineTests {
  private let debounceMs = 500
  private var debounceSeconds: Double { Double(debounceMs) / 1000 }

  // MARK: - Debounce

  @Test("A settling mismatch is not shown before the debounce window elapses")
  func mismatch_notShownBeforeDebounceElapses() {
    var machine = CameraMismatchStateMachine(debounceMs: debounceMs)

    let tooSoon = machine.update(classification: .mismatch, isEnabled: true, now: 0)
    #expect(tooSoon == .noNotice)

    let stillTooSoon = machine.update(
      classification: .mismatch, isEnabled: true, now: debounceSeconds - 0.01)
    #expect(stillTooSoon == .noNotice)
  }

  @Test("A settled mismatch (debounce elapsed) shows .notice(.mismatch)")
  func mismatch_shownAfterDebounceElapses() {
    var machine = CameraMismatchStateMachine(debounceMs: debounceMs)
    _ = machine.update(classification: .mismatch, isEnabled: true, now: 0)
    let settled = machine.update(classification: .mismatch, isEnabled: true, now: debounceSeconds)
    #expect(settled == .notice(.mismatch))
  }

  @Test("A settled unreliable classification shows .notice(.unreliable)")
  func unreliable_shownAfterDebounceElapses() {
    var machine = CameraMismatchStateMachine(debounceMs: debounceMs)
    _ = machine.update(classification: .unreliable, isEnabled: true, now: 0)
    let settled = machine.update(
      classification: .unreliable, isEnabled: true, now: debounceSeconds)
    #expect(settled == .notice(.unreliable))
  }

  @Test("Flapping between clear and mismatch faster than the debounce window never shows anything")
  func flapping_neverShows() {
    var machine = CameraMismatchStateMachine(debounceMs: debounceMs)
    var now = 0.0
    for _ in 0..<20 {
      let a = machine.update(classification: .mismatch, isEnabled: true, now: now)
      #expect(a == .noNotice)
      now += debounceSeconds / 4
      let b = machine.update(classification: .clear, isEnabled: true, now: now)
      #expect(b == .noNotice)
      now += debounceSeconds / 4
    }
  }

  @Test("Clear never shows a notice, even once settled")
  func clear_neverShowsANotice() {
    var machine = CameraMismatchStateMachine(debounceMs: debounceMs)
    _ = machine.update(classification: .clear, isEnabled: true, now: 0)
    let settled = machine.update(classification: .clear, isEnabled: true, now: debounceSeconds)
    #expect(settled == .noNotice)
  }

  // MARK: - Dismiss / re-arm

  @Test("Dismissing a shown notice hides it immediately, same classification held")
  func dismiss_hidesImmediately() {
    var machine = CameraMismatchStateMachine(debounceMs: debounceMs)
    let deadline = settleMismatch(&machine)
    #expect(
      machine.update(classification: .mismatch, isEnabled: true, now: deadline)
        == .notice(.mismatch))

    machine.dismiss()
    #expect(
      machine.update(classification: .mismatch, isEnabled: true, now: deadline + 1) == .noNotice)
    #expect(
      machine.update(classification: .mismatch, isEnabled: true, now: deadline + 100) == .noNotice)
  }

  @Test("A dismissed notice does not reappear just because the classification flips kind")
  func dismiss_survivesMismatchToUnreliableFlip() {
    var machine = CameraMismatchStateMachine(debounceMs: debounceMs)
    let deadline = settleMismatch(&machine)
    #expect(
      machine.update(classification: .mismatch, isEnabled: true, now: deadline)
        == .notice(.mismatch))
    machine.dismiss()

    // Flip to .unreliable without ever passing through .clear.
    var now = deadline + 1
    _ = machine.update(classification: .unreliable, isEnabled: true, now: now)
    now += debounceSeconds
    let afterFlip = machine.update(classification: .unreliable, isEnabled: true, now: now)
    #expect(afterFlip == .noNotice)
  }

  @Test("Re-arms once the condition clears and a fresh episode settles")
  func dismiss_reArmsAfterClearing() {
    var machine = CameraMismatchStateMachine(debounceMs: debounceMs)
    let deadline = settleMismatch(&machine)
    _ = machine.update(classification: .mismatch, isEnabled: true, now: deadline)
    machine.dismiss()

    // Condition clears.
    var now = deadline + 1
    _ = machine.update(classification: .clear, isEnabled: true, now: now)
    now += debounceSeconds
    #expect(machine.update(classification: .clear, isEnabled: true, now: now) == .noNotice)

    // A fresh mismatch episode begins — shows again without any explicit
    // un-dismiss call, per this type's documented re-arm rule.
    now += 1
    _ = machine.update(classification: .mismatch, isEnabled: true, now: now)
    now += debounceSeconds
    #expect(
      machine.update(classification: .mismatch, isEnabled: true, now: now) == .notice(.mismatch))
  }

  @Test("Dismissing while nothing is showing is a harmless no-op")
  func dismiss_whileClear_isNoOp() {
    var machine = CameraMismatchStateMachine(debounceMs: debounceMs)
    machine.dismiss()
    let deadline = settleMismatch(&machine)
    #expect(
      machine.update(classification: .mismatch, isEnabled: true, now: deadline)
        == .notice(.mismatch))
  }

  // MARK: - `isEnabled`: a live gate, not part of the episode

  @Test("Disabled suppresses an otherwise-settled notice")
  func disabled_suppressesNotice() {
    var machine = CameraMismatchStateMachine(debounceMs: debounceMs)
    let deadline = settleMismatch(&machine)
    #expect(machine.update(classification: .mismatch, isEnabled: false, now: deadline) == .noNotice)
  }

  @Test(
    "Re-enabling shows the current truth immediately — no retroactive suppression, unlike dismiss")
  func reEnabling_showsCurrentTruthImmediately() {
    var machine = CameraMismatchStateMachine(debounceMs: debounceMs)
    let deadline = settleMismatch(&machine)
    #expect(machine.update(classification: .mismatch, isEnabled: false, now: deadline) == .noNotice)

    // Same classification, still held — re-enabling shows it right away,
    // with no fresh debounce/episode required.
    #expect(
      machine.update(classification: .mismatch, isEnabled: true, now: deadline + 0.001)
        == .notice(.mismatch))
  }

  // MARK: - Helpers

  /// Settles a `.mismatch` classification and returns the `now` at which it
  /// first becomes visible (i.e. `now: debounceSeconds` from a start of 0).
  private func settleMismatch(_ machine: inout CameraMismatchStateMachine) -> Double {
    _ = machine.update(classification: .mismatch, isEnabled: true, now: 0)
    return debounceSeconds
  }
}
