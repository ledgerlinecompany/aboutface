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
/// ## Why a tolerance, and why half a frame (field finding, 2026-08-07)
///
/// The original rule was "analyze when `timestamp - lastAnalyzed >=
/// 1/targetHz`." That is correct in exact arithmetic and wrong against real
/// hardware. Measured on the maintainer's machine: Monitor requests 640×480
/// @15fps and the camera delivers **15.01** fps, so three frame intervals
/// span 199.87 ms against a 200 ms threshold. The third frame misses by
/// 0.13 ms, the fourth is taken instead, and the analysis rate settles at
/// 15.01 ÷ 4 = **3.75 Hz instead of the configured 5** — a 25% shortfall that
/// held for three phases, through every tuning session and both Phase 4
/// acceptance runs, because nothing ever read the achieved rate back.
/// Identical in debug and release builds, which is what proved it arithmetic
/// rather than Vision saturating.
///
/// So the question is not "has a full period elapsed" but "is this the frame
/// NEAREST the moment analysis was due." A frame 0.13 ms early is obviously
/// that frame. Half the observed frame interval is the rounding boundary that
/// question implies — not a tuned constant (§0) but the midpoint between two
/// candidate frames, which is where "nearest" changes its answer.
///
/// Two further properties this shape needs:
///
/// - **The schedule advances by the ideal period, not from the frame actually
///   taken.** Anchoring on the analyzed frame lets each period's leftover
///   accumulate; anchoring on the due time keeps the long-run rate exact.
/// - **A stalled camera resyncs rather than bursting.** If frames stop for a
///   while, the due time falls far behind, and catching up would analyze
///   several frames back to back — precisely the CPU spike §5.2's decimation
///   exists to prevent. Falling more than one full period behind restarts the
///   schedule from the present instead.
public struct AnalysisRateDecimator: Sendable, Equatable {
  private let minimumInterval: CMTime?
  private var lastAnalyzedTimestamp: CMTime?
  /// The ideal moment the next analysis is due — advanced by exactly
  /// `minimumInterval` each time, so per-period rounding cannot accumulate.
  private var nextDueTimestamp: CMTime?
  /// Previous frame's timestamp, used only to observe the capture interval
  /// that sets the rounding tolerance. Read from the frames themselves rather
  /// than from `Config`'s REQUESTED frame rate, deliberately: the requested
  /// rate is exactly the thing this file cannot trust (§12.4/§12.5, and the
  /// 15.01-vs-15 measurement above).
  private var previousFrameTimestamp: CMTime?

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
    let tolerance = roundingTolerance(at: timestamp, minimumInterval: minimumInterval)
    previousFrameTimestamp = timestamp

    guard let due = nextDueTimestamp else {
      // First frame: start the schedule here.
      lastAnalyzedTimestamp = timestamp
      nextDueTimestamp = timestamp + minimumInterval
      return true
    }

    guard (timestamp + tolerance) >= due else { return false }

    // Advance the IDEAL schedule, except when the stream has fallen more than
    // a full period behind (a stalled or re-timed camera) — then restart from
    // now rather than analyzing several frames back to back to catch up.
    let hasFallenBehind = timestamp > (due + minimumInterval)
    nextDueTimestamp = hasFallenBehind ? timestamp + minimumInterval : due + minimumInterval
    lastAnalyzedTimestamp = timestamp
    return true
  }

  /// Half the most recently observed capture interval — the midpoint between
  /// two candidate frames, i.e. exactly where "which frame is nearest the due
  /// time" changes its answer. See this type's doc comment.
  ///
  /// Capped at half of `minimumInterval` so that a capture rate SLOWER than
  /// the target cannot pull analysis meaningfully ahead of schedule; and zero
  /// before a second frame has been seen, since no interval has been observed
  /// yet and guessing one would be inventing data.
  private func roundingTolerance(at timestamp: CMTime, minimumInterval: CMTime) -> CMTime {
    guard let previous = previousFrameTimestamp else { return .zero }
    let observedInterval = timestamp - previous
    guard observedInterval > .zero else { return .zero }
    let half = CMTimeMultiplyByFloat64(observedInterval, multiplier: 0.5)
    let cap = CMTimeMultiplyByFloat64(minimumInterval, multiplier: 0.5)
    return min(half, cap)
  }
}
