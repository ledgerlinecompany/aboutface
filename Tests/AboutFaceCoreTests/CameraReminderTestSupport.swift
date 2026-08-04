import Testing

@testable import AboutFaceCore

// Shared fixtures for `CameraReminderStateMachineTests` and
// `CameraReminderDelayTests`. Split into its own file (same convention as
// `FeedbackRouterTestSupport.swift`/`AnalysisEngineTestSupport.swift`) when
// the delay tests pushed the single test file past SwiftLint's
// `file_length` limit — the two suites genuinely share this setup, so
// duplicating it into both would be worse than a third file.
//
// Deliberately `internal` rather than `private`: `private` at file scope
// means exactly that, so these would be invisible to the sibling suite.
// Names carry a `reminder` prefix to avoid colliding with other test
// files' fixtures in the same module.

// MARK: - Shared fixtures

let reminderDebounceMs = 500
let reminderDelayMs = 1000
var reminderDebounceSeconds: Double { Double(reminderDebounceMs) / 1000 }
var reminderDelaySeconds: Double { Double(reminderDelayMs) / 1000 }

/// Feeds `busy` starting at `startingAt`, then again after the debounce
/// window has fully elapsed, returning whatever the second call yields —
/// the settled outcome of a signal that transitions once and then holds,
/// WITHOUT crossing the reminder delay's deadline.
@discardableResult
func settleEdge(
  _ machine: inout CameraReminderStateMachine,
  busy: Bool,
  isCapturing: Bool = false,
  isSilenced: Bool = false,
  isEnabled: Bool = true,
  startingAt: Double = 0
) -> CameraReminderStateMachine.Outcome {
  _ = machine.update(
    busy: busy, isCapturing: isCapturing, isSilenced: isSilenced, isEnabled: isEnabled,
    now: startingAt)
  return machine.update(
    busy: busy, isCapturing: isCapturing, isSilenced: isSilenced, isEnabled: isEnabled,
    now: startingAt + reminderDebounceSeconds)
}

/// Settles a favorable-gates rising edge (`busy: true`, all three gates
/// passing) and asserts it armed a pending fire, returning that fire's
/// deadline for the caller to advance a fake clock to. Fails the test via
/// `Issue.record` if the edge did not arm — every caller of this helper is
/// asserting a successful arm, so callers testing an edge-time DROP use
/// `settleEdge` directly instead.
@discardableResult
func arm(
  _ machine: inout CameraReminderStateMachine,
  startingAt: Double = 0
) -> Double {
  let outcome = settleEdge(&machine, busy: true, startingAt: startingAt)
  guard case .pending(let deadline) = outcome else {
    Issue.record("expected a favorable-gates rising edge to arm a pending fire, got \(outcome)")
    return startingAt + reminderDebounceSeconds + reminderDelaySeconds
  }
  return deadline
}
