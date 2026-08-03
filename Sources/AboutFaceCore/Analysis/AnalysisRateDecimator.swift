import CoreMedia

/// Decides which captured frames get handed to `AnalysisEngine.process(_:)`
/// (and therefore to the backend's Vision-equivalent inference) when the
/// target analysis rate is lower than the capture rate — §5.2's "Analysis at
/// 5 Hz. Capture format 640×480 @ 15fps."
///
/// ## Why time-based, not "every Nth frame"
///
/// A frame-counter decimator ("keep every 3rd frame") is only correct if the
/// capture source actually delivers at the rate it was asked for. §12.4
/// (virtual cameras) and §12.5 (Center Stage) both warn that this is not
/// guaranteed — a virtual camera can silently re-time frames, and Center
/// Stage's cropping/tracking runs as its own per-session pipeline. If the
/// camera delivers at, say, 12fps instead of the requested 15fps, "every 3rd
/// frame" analyzes at 4Hz instead of 5Hz with no way to notice; a minimum
/// wall-clock (well, frame-timestamp) interval between analyzed frames stays
/// correct at whatever rate frames actually arrive.
///
/// ## What "injectable clock" means here
///
/// This type reads no wall clock of its own (`Date()`, `ContinuousClock.now`)
/// — every decision is a pure function of the frame timestamps it is handed,
/// via `shouldAnalyze(at:)`. The caller's sequence of `CMTime` values IS the
/// injected clock, exactly like `FeedbackRouter.ingest(_:at:)` takes an
/// explicit `ContinuousClock.Instant` instead of reading time internally
/// (see that type's "Time is injected, always" doc comment) — the same
/// reasoning applies here: it is what makes this type's tests deterministic
/// and replayable, with no `Task.sleep` needed to prove the boundary is
/// right.
///
/// ## Seam
///
/// Used from `AnalysisEngine.stream(from:targetAnalysisHz:)`, BEFORE
/// `process(_:)` is called — a skipped frame never reaches the backend at
/// all. §5.2's whole rationale is CPU and thermals across a two-hour call;
/// analyzing every frame and discarding the output would defeat that while
/// looking correct in every test that only checks output rate.
public struct AnalysisRateDecimator: Sendable, Equatable {
  private let minimumInterval: CMTime?
  private var lastAnalyzedTimestamp: CMTime?

  /// - Parameter targetHz: Desired analysis rate. `nil` or `<= 0` means
  ///   "analyze every frame" (Setup's behavior, §5.1 — capture and analysis
  ///   rate are already the same, so no decimation is needed or performed).
  public init(targetHz: Double?) {
    if let targetHz, targetHz > 0 {
      minimumInterval = CMTime(seconds: 1.0 / targetHz, preferredTimescale: 600)
    } else {
      minimumInterval = nil
    }
  }

  /// Whether the frame at `timestamp` should be analyzed. When it returns
  /// `true`, `timestamp` becomes the new reference point for the next
  /// decision — so calling this out of order (timestamps not monotonically
  /// increasing) produces a well-defined but not especially meaningful
  /// result; every real `CaptureSource` delivers frames in timestamp order
  /// (§3.1), so callers are not expected to need that case.
  ///
  /// The boundary is inclusive: a frame exactly `1/targetHz` after the last
  /// analyzed one IS analyzed (`>=`, not `>`) — a decimator that excluded the
  /// boundary would silently analyze at a hair under the requested rate.
  public mutating func shouldAnalyze(at timestamp: CMTime) -> Bool {
    guard let minimumInterval else { return true }
    if let last = lastAnalyzedTimestamp, (timestamp - last) < minimumInterval {
      return false
    }
    lastAnalyzedTimestamp = timestamp
    return true
  }
}
