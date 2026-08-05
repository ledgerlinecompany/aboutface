/// Pure classification for §12.5's app-side Center Stage wiring: collapses a
/// raw `CenterStageDeviceReading` (found/deviceNotFound) into the three-way
/// `CenterStageSignal` distinction the rest of this feature's decision logic
/// is built on. Split out of `CenterStageStateMachine.swift`, same
/// classifier/state-machine/monitor three-file shape §12.3 established
/// (`CameraMismatchClassifier` → `CameraMismatchStateMachine` →
/// `CameraMismatchMonitor`) — this file has no notion of time or of a
/// previous call, so it is testable as a plain pure function over a
/// synthetic `CenterStageDeviceReading`.
///
/// ## The critical design point: `.deviceNotFound` must not read as "active"
///
/// An unreadable device must never be reported as "Center Stage active" —
/// see `CenterStageSignal.unknown`'s doc comment for the full argument, the
/// same "which direction is safe to be wrong in" reasoning
/// `CenterStageReading.automaticFramingInEffect`'s own doc comment gives for
/// why `deviceReportsActive` alone is authoritative there. But collapsing
/// `.deviceNotFound` straight onto `.notActive` here would repeat exactly
/// the mistake §12.2's finding warns about, and that §12.3's own classifier
/// explicitly avoids with `CameraMismatchClassification.unreliable`: a
/// signal that "worked" (returned a plausible, non-alarming value) while
/// silently uncertain. So `.unknown` stays distinguishable from `.notActive`
/// all the way out to the Setup window's notice — only the router-facing
/// boolean (`CenterStageStateMachine.routerActive`) ever collapses the two,
/// because `FeedbackRouter.setCenterStageActive` only accepts a `Bool`, and
/// "not confidently active" is the one safe reading for either case.
public enum CenterStageSignal: Sendable, Equatable {
  /// The device resolved and `CenterStageReading.automaticFramingInEffect`
  /// read `true`.
  case active
  /// The device resolved and read successfully, with
  /// `automaticFramingInEffect == false`.
  case notActive
  /// `CenterStageDeviceReading.deviceNotFound` — the device could not be
  /// resolved at all (disconnected, or a stale `uniqueID`). Deliberately NOT
  /// folded into `.notActive` — see this file's doc comment.
  case unknown
}

/// Namespace for the one pure classification function — mirrors
/// `CameraMismatchClassifier`'s enum-namespace shape (no instance state, one
/// static entry point).
public enum CenterStageClassifier {
  /// - Parameter reading: One `CenterStageReader.read(forUniqueID:)` result
  ///   for the currently selected camera, at one instant.
  public static func classify(_ reading: CenterStageDeviceReading) -> CenterStageSignal {
    switch reading {
    case .found(let value):
      return value.automaticFramingInEffect ? .active : .notActive
    case .deviceNotFound:
      return .unknown
    }
  }
}
