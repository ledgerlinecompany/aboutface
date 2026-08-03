import AboutFaceCore
import Accessibility

/// "Capture current position as target" (§4). Split out of
/// `PipelineModel.swift` purely to keep each file a manageable size (see
/// that file's doc comment); this is still `PipelineModel`'s own
/// implementation, not a separate public surface.
extension PipelineModel {

  /// "Capture current position as target" (§4's v1 primitive; global ⌘⌃⇧T
  /// arrives with the §8 hotkey work — for now it is a Setup-window button): copies the
  /// **current smoothed** eye midpoint and interocular distance into
  /// `Config.targetFraming`.
  ///
  /// `AnalysisEngine` does not expose a smoothed eye midpoint directly — it
  /// only smooths `FramingState.error` and `.distanceError` (§4). But
  /// those ARE the current position, expressed relative to the *current*
  /// target, so the new target is recoverable algebraically without ever
  /// touching a raw per-frame reading:
  ///
  /// - Horizontal: `error.x = eyeMidpoint.x - target.eyeMidpointX` (both
  ///   already egocentric, §3.4), so the subject's current smoothed
  ///   egocentric X is `target.eyeMidpointX + error.x` — that becomes the
  ///   new `eyeMidpointX` directly (`Config.TargetFraming.eyeMidpointX` is
  ///   in the same egocentric-X, fraction-of-width convention as
  ///   `eyeMidpoint.x`).
  /// - Vertical: `AnalysisEngine+Framing.swift`'s `verticalError(_:_:)`
  ///   computes `error.y = eyeMidpoint.y(bottom-left) - (1 -
  ///   target.eyeMidpointY(from top))`. Solving for the subject's current
  ///   smoothed Y in the bottom-left convention and then converting back to
  ///   `Config.TargetFraming.eyeMidpointY`'s documented "from top"
  ///   convention collapses to `target.eyeMidpointY - error.y` — the sign
  ///   flip is exactly the top/bottom-origin conversion, not a bug.
  /// - Distance: `distanceError = interocularDistance -
  ///   target.interocularWidth` (§4), so the subject's current smoothed
  ///   interocular distance is `target.interocularWidth + distanceError`.
  ///
  /// Returns `false` (and posts nothing) if there is no face currently
  /// detected to capture a position from.
  @discardableResult
  public func captureCurrentPositionAsTarget() -> Bool {
    guard let framing = latestOutput?.framing else {
      return false
    }

    var updated = config
    updated.targetFraming.eyeMidpointX += Double(framing.error.x)
    updated.targetFraming.eyeMidpointY -= Double(framing.error.y)
    updated.targetFraming.interocularWidth += Double(framing.distanceError)
    // §4 extension (2026-08-01): capture the current pose as the neutral
    // baseline too. Pose is camera-ray-relative and laptop cameras sit off
    // the natural eyeline, so gaze judgments measure deviation from THIS
    // pose, not from absolute zero. Instantaneous (unsmoothed) geometry is
    // fine here: the user is deliberately holding their natural position.
    if let geometry = latestOutput?.analysis.primary {
      updated.targetFraming.neutralYawDegrees = Double(geometry.yaw)
      updated.targetFraming.neutralPitchDegrees = Double(geometry.pitch)
      updated.targetFraming.neutralRollDegrees = Double(geometry.roll)
    }
    // §16.4's "app configured" marker (`Config.isConfigured`) — this is the
    // one and only place it is set `true`. See `Config.TargetFraming
    // .captured`'s doc comment for why it is an explicit flag rather than
    // inferred from these values differing from `Config.defaults
    // .targetFraming`.
    updated.targetFraming.captured = true
    updateConfig(updated)

    AccessibilityNotification.Announcement("Target captured").post()
    return true
  }
}
