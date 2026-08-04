import AboutFaceCore

/// The per-frame throttle (spec §9's two-rate contract) that drives
/// `PipelineModel.visualOutput`/`.accessibilitySnapshot`/`.signalStateLine`.
/// Split out of `PipelineModel.swift` purely to keep each file a manageable
/// size (see that file's doc comment); everything here is still
/// `PipelineModel`'s own implementation, not a separate public surface.
extension PipelineModel {

  // Not `private`: Swift's `private` scopes to the declaring *file*, not
  // the whole type (see `PipelineModel.config`'s doc comment for the same
  // note) — `beginConsuming(engine:source:targetAnalysisHz:)` in
  // `PipelineModel+Mode.swift` calls this from its consume loop, same as
  // `start()` (`PipelineModel.swift`) does.
  func ingest(_ output: EngineOutput) {
    latestOutput = output

    // Latches on the FIRST real frame of the session and never overwrites
    // after that — `actualCaptureDimensions`'s doc comment has the full
    // rationale. Deliberately unthrottled (unlike `visualOutput`/
    // `accessibilitySnapshot` below): the point is to catch the confirmed
    // format as early as possible, not on whatever frame happens to land on
    // a throttle boundary, and after the first non-nil write this is a
    // cheap no-op on every subsequent frame.
    if actualCaptureDimensions == nil, let dimensions = output.capturedPixelDimensions {
      actualCaptureDimensions = dimensions
    }

    let now = ContinuousClock.now
    if now - lastVisualUpdate >= visualInterval {
      lastVisualUpdate = now
      visualOutput = output
      signalStateLine = Self.words(for: output.analysis.signalState)
    }
    if now - lastAccessibilityUpdate >= accessibilityInterval {
      lastAccessibilityUpdate = now
      accessibilitySnapshot = AccessibilitySnapshot(
        rows: SignalFormatter.snapshot(
          output: output,
          backendName: backendDisplayName,
          captureFormat: captureFormat,
          actualCaptureDimensions: actualCaptureDimensions,
          mirrorState: mirrorState,
          display: config.display
        )
      )
    }
  }

  private static func words(for state: SignalState) -> String {
    switch state {
    case .ok: return "OK"
    case .lowConfidence: return "Low confidence"
    case .noFace: return "No face"
    case .noSignal: return "No signal"
    }
  }
}
