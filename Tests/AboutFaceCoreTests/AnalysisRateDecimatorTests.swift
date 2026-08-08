import CoreMedia
import Testing

@testable import AboutFaceCore

/// `AnalysisRateDecimator` (§5.2): pure, timestamp-driven decision of which
/// frames get analyzed. No `CaptureSource`, no `AnalysisEngine`, no
/// `Task.sleep` — every test hands in a scripted sequence of `CMTime`
/// timestamps and reads back exactly which ones were selected, per the type's
/// own "injectable clock" doc comment.
struct AnalysisRateDecimatorTests {

  /// 30 timestamps one 1/30s frame apart, matching §5.1 Setup's capture
  /// cadence — the input every test below decimates down from.
  private func thirtyHzTimestamps(count: Int = 30) -> [CMTime] {
    (0..<count).map { CMTime(value: CMTimeValue($0), timescale: 30) }
  }

  @Test("nil target Hz analyzes every frame (Setup's behavior)")
  func nilTargetAnalyzesEverything() {
    var decimator = AnalysisRateDecimator(targetHz: nil)
    let results = thirtyHzTimestamps().map { decimator.shouldAnalyze(at: $0) }
    #expect(results == Array(repeating: true, count: results.count))
  }

  @Test("Zero or negative target Hz analyzes every frame, same as nil")
  func nonPositiveTargetAnalyzesEverything() {
    for target: Double in [0, -1, -5] {
      var decimator = AnalysisRateDecimator(targetHz: target)
      let results = thirtyHzTimestamps().map { decimator.shouldAnalyze(at: $0) }
      #expect(results == Array(repeating: true, count: results.count), "target \(target)")
    }
  }

  @Test("5Hz target against a 30Hz stream (§5.2) selects every 6th frame: 5 of 30")
  func fiveHzAgainstThirtyHzStream() {
    var decimator = AnalysisRateDecimator(targetHz: 5)
    let results = thirtyHzTimestamps().map { decimator.shouldAnalyze(at: $0) }
    // Frame 0 always analyzed (no prior reference); the next analyzed frame
    // is the first one at least 1/5s = 6 frames later, i.e. frame indices
    // 0, 6, 12, 18, 24 — five frames out of thirty.
    let selectedIndices = results.enumerated().filter { $0.element }.map { $0.offset }
    #expect(selectedIndices == [0, 6, 12, 18, 24])
  }

  @Test("15Hz capture decimated to 5Hz (§5.2's actual configuration): every 3rd frame")
  func fifteenHzCaptureDecimatedToFiveHz() {
    let timestamps = (0..<15).map { CMTime(value: CMTimeValue($0), timescale: 15) }
    var decimator = AnalysisRateDecimator(targetHz: 5)
    let results = timestamps.map { decimator.shouldAnalyze(at: $0) }
    let selectedIndices = results.enumerated().filter { $0.element }.map { $0.offset }
    #expect(selectedIndices == [0, 3, 6, 9, 12])
  }

  @Test("Boundary is inclusive: a frame exactly one target-period later IS analyzed")
  func boundaryIsInclusive() {
    var decimator = AnalysisRateDecimator(targetHz: 5)  // 1/5s = 0.2s minimum interval
    let first = CMTime(seconds: 0, preferredTimescale: 600)
    let exactlyOnePeriodLater = CMTime(seconds: 0.2, preferredTimescale: 600)
    #expect(decimator.shouldAnalyze(at: first) == true)
    #expect(decimator.shouldAnalyze(at: exactlyOnePeriodLater) == true)
  }

  /// This test used to assert the opposite — that a frame 1 ms under the
  /// period is REJECTED — and that strict boundary was the bug. Measured
  /// 2026-08-07: a camera asked for 15fps delivering 15.01 leaves three frame
  /// intervals 0.13 ms short of 200 ms, so the third frame was rejected, the
  /// fourth taken, and Monitor analyzed at 3.75 Hz instead of the configured
  /// 5 for three phases. See `AnalysisRateDecimator`'s doc comment.
  ///
  /// The question the decimator answers is now "is this the frame NEAREST the
  /// moment analysis was due," so a frame a hair early is accepted — the
  /// long-run rate is protected by the ideal schedule, not by the boundary.
  @Test("A frame a hair under the period is accepted: it is the nearest frame to the due time")
  func slightlyEarlyFrameIsAccepted() {
    var decimator = AnalysisRateDecimator(targetHz: 5)  // 0.2s minimum interval
    #expect(decimator.shouldAnalyze(at: CMTime(seconds: 0, preferredTimescale: 600)) == true)
    #expect(decimator.shouldAnalyze(at: CMTime(seconds: 0.199, preferredTimescale: 600)) == true)
  }

  /// The regression that motivated the tolerance, in the exact shape it was
  /// measured: 15.01fps capture, 5 Hz target. Must select every THIRD frame
  /// (≈5.0 Hz), not every fourth (3.75 Hz).
  @Test("A camera delivering 15.01fps against a 5Hz target still analyzes every third frame")
  func slightlyFastCaptureStillHitsTargetRate() {
    var decimator = AnalysisRateDecimator(targetHz: 5)
    let frameInterval = 1.0 / 15.01
    var analyzed = 0
    let frameCount = 150  // ~10 seconds
    for index in 0..<frameCount {
      let timestamp = CMTime(seconds: Double(index) * frameInterval, preferredTimescale: 600)
      if decimator.shouldAnalyze(at: timestamp) { analyzed += 1 }
    }
    // 150 frames at 15.01fps is 9.993s; at a true 5Hz that is 50 analyses.
    // The old strict boundary produced 38.
    #expect(analyzed >= 49 && analyzed <= 51, "analyzed \(analyzed) of \(frameCount)")
  }

  /// The guarantee the tolerance must NOT give away: over a long run the
  /// achieved rate never exceeds the configured target. The ideal schedule
  /// (advanced by exactly one period per analysis) is what preserves this,
  /// which is why the tolerance can be generous without the rate drifting up.
  @Test("Tolerance never lets the long-run rate exceed the target")
  func longRunRateNeverExceedsTarget() {
    var decimator = AnalysisRateDecimator(targetHz: 5)
    let frameInterval = 1.0 / 30.0  // plenty of candidate frames
    var analyzed = 0
    let seconds = 20.0
    let frameCount = Int(seconds * 30)
    for index in 0..<frameCount {
      let timestamp = CMTime(seconds: Double(index) * frameInterval, preferredTimescale: 600)
      if decimator.shouldAnalyze(at: timestamp) { analyzed += 1 }
    }
    // 20s at 5Hz is 100 analyses; allow the single boundary frame either way.
    #expect(analyzed <= 101, "analyzed \(analyzed) in \(seconds)s — faster than the 5Hz target")
  }

  /// A stalled camera must not produce a catch-up burst when frames resume —
  /// several back-to-back analyses is exactly the CPU spike §5.2's decimation
  /// exists to prevent.
  @Test("A stall does not cause a catch-up burst when frames resume")
  func stallDoesNotBurst() {
    var decimator = AnalysisRateDecimator(targetHz: 5)
    #expect(decimator.shouldAnalyze(at: CMTime(seconds: 0, preferredTimescale: 600)) == true)
    // Ten seconds of nothing, then frames resume at 15fps.
    var analyzedInFirstSecond = 0
    for index in 0..<15 {
      let timestamp = CMTime(seconds: 10.0 + Double(index) / 15.0, preferredTimescale: 600)
      if decimator.shouldAnalyze(at: timestamp) { analyzedInFirstSecond += 1 }
    }
    #expect(analyzedInFirstSecond <= 6, "burst of \(analyzedInFirstSecond) analyses after a stall")
  }

  @Test("An accepted frame becomes the new reference point, not the original start")
  func acceptedFrameBecomesNewReference() {
    var decimator = AnalysisRateDecimator(targetHz: 5)  // 0.2s minimum interval
    #expect(decimator.shouldAnalyze(at: CMTime(seconds: 0, preferredTimescale: 600)) == true)
    #expect(decimator.shouldAnalyze(at: CMTime(seconds: 0.2, preferredTimescale: 600)) == true)
    // Only 0.1s after the SECOND accepted frame (0.2s) — must be rejected,
    // even though it is 0.3s after the original start.
    #expect(decimator.shouldAnalyze(at: CMTime(seconds: 0.3, preferredTimescale: 600)) == false)
  }

  @Test("A slower-than-requested capture rate still analyzes at the target rate (§12.4/§12.5)")
  func slowerThanRequestedCaptureRateStillHitsTarget() {
    // Camera requested at 15fps but (virtual camera / Center Stage
    // re-timing) actually delivers at 10fps — a frame-COUNT decimator tuned
    // for "every 3rd of 15fps" would silently drift off 5Hz here; the
    // time-based decimator does not.
    let timestamps = (0..<10).map { CMTime(value: CMTimeValue($0), timescale: 10) }
    var decimator = AnalysisRateDecimator(targetHz: 5)
    let results = timestamps.map { decimator.shouldAnalyze(at: $0) }
    let selectedIndices = results.enumerated().filter { $0.element }.map { $0.offset }
    #expect(selectedIndices == [0, 2, 4, 6, 8])
  }
}
