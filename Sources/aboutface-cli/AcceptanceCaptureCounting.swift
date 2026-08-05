import AboutFaceCore
import CoreMedia

/// A `CaptureSource` decorator that counts every RAW frame `underlying`
/// delivers, before `AnalysisEngine.stream(from:targetAnalysisHz:)`'s
/// `AnalysisRateDecimator` ever sees it — the only way `aboutface-cli
/// acceptance` can report the delivered CAPTURE frame rate separately from
/// the ANALYSIS rate.
///
/// ## Why this has to sit below the decimator, not read `EngineOutput`
///
/// §5.2 requests Monitor's capture at 15fps but analyzes at only 5Hz
/// (`Config.Camera.monitor.analysisHz`); `AnalysisRateDecimator` drops the
/// other two-thirds of frames BEFORE the backend ever runs. Issue #67
/// ("Continuity Camera ignores a 15fps request and delivers 30") is
/// invisible from the ANALYZED stream by construction — `engine.stream(from:
/// targetAnalysisHz: 5)` yields at very close to 5Hz whether the camera is
/// actually delivering 15fps or 30fps underneath, since the decimator's job
/// is exactly to normalize that away. Detecting the bug needs a count taken
/// BEFORE decimation, which means tapping `CaptureSource.frames` directly.
///
/// ## Why a decorator, not a change to `AnalysisEngine`
///
/// `CaptureSource`'s protocol doc comment says a conformance's `frames`
/// stream is built "once, in `init`," so `AnalysisEngine.stream(from:)`
/// (unmodified) can consume this type exactly as it would a real
/// `CameraCaptureSource` — the acceptance command exercises Monitor mode
/// "as shipped," per the PR brief, by handing `engine.stream(from:)` a
/// transparent wrapper instead of changing what that method or
/// `AboutFaceCore` do.
final class AcceptanceCountingCaptureSource: CaptureSource, Sendable {
  let mirrorState: MirrorState
  let frames: AsyncStream<CapturedFrame>

  private let underlying: CameraCaptureSource
  private let forwardTask: Task<Void, Never>

  init(wrapping underlying: CameraCaptureSource, counter: RawFrameArrivalCounter) {
    self.underlying = underlying
    self.mirrorState = underlying.mirrorState
    let underlyingFrames = underlying.frames

    var continuation: AsyncStream<CapturedFrame>.Continuation!
    self.frames = AsyncStream { continuation = $0 }
    self.forwardTask = Task {
      for await frame in underlyingFrames {
        await counter.record(timestamp: frame.timestamp)
        continuation.yield(frame)
      }
      continuation.finish()
    }
  }

  func start() async throws {
    try await underlying.start()
  }

  func stop() async {
    await underlying.stop()
    // Draining `underlying.frames` to completion is what lets
    // `forwardTask`'s `for await` loop exit and `continuation.finish()`
    // run; `stop()` awaiting that here means a caller that has stopped
    // this source can trust `frames` has also finished, same "stop()
    // finishes the stream" contract `CaptureSource`'s protocol doc comment
    // promises for every conformance.
    await forwardTask.value
  }
}

/// Counts raw frame ARRIVALS and spans first-to-last timestamp, for
/// `AcceptanceCountingCaptureSource` to report an achieved capture fps
/// independent of `AnalysisRateDecimator`. An actor: `record(timestamp:)`
/// is called from the wrapper's forwarding `Task`, concurrently with
/// whatever reads `snapshot()` at the end of the run.
actor RawFrameArrivalCounter {
  private var count = 0
  private var firstTimestamp: CMTime?
  private var lastTimestamp: CMTime?

  func record(timestamp: CMTime) {
    count += 1
    if firstTimestamp == nil {
      firstTimestamp = timestamp
    }
    lastTimestamp = timestamp
  }

  /// `achievedFps` is `nil` when fewer than two frames arrived (no interval
  /// to measure a rate over) — never a divide-by-zero `0.0` masquerading as
  /// "zero frames per second."
  func snapshot() -> (count: Int, achievedFps: Double?) {
    guard count >= 2, let firstTimestamp, let lastTimestamp else {
      return (count, nil)
    }
    let spanSeconds = CMTimeGetSeconds(lastTimestamp - firstTimestamp)
    guard spanSeconds > 0 else { return (count, nil) }
    return (count, Double(count - 1) / spanSeconds)
  }
}
