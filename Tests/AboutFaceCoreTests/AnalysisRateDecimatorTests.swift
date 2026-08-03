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

  @Test("Just under the boundary is rejected; just at/over it is accepted")
  func justUnderBoundaryRejected() {
    var decimator = AnalysisRateDecimator(targetHz: 5)  // 0.2s minimum interval
    let first = CMTime(seconds: 0, preferredTimescale: 600)
    let justUnder = CMTime(seconds: 0.199, preferredTimescale: 600)
    let justOver = CMTime(seconds: 0.201, preferredTimescale: 600)
    #expect(decimator.shouldAnalyze(at: first) == true)
    #expect(decimator.shouldAnalyze(at: justUnder) == false)
    // The reference point is still `first` (the rejected frame above did not
    // move it), so `justOver` is compared against `first`, not `justUnder`.
    #expect(decimator.shouldAnalyze(at: justOver) == true)
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
