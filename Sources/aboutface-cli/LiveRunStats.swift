import AboutFaceCore

/// Per-FRAME accumulation for `aboutface-cli live` — everything its summary
/// reports beyond the raw frame count. Split out of `LiveCommand.swift` when
/// §12.5's measurement work pushed that file past SwiftLint's `file_length`
/// limit and `runLoop` past its complexity limit; the house rule is to split
/// proactively rather than compress the comments that carry field findings.
///
/// ## Why per-frame, when `live` already printed a status line each second
///
/// It printed the state of ONE frame per second and nothing about the other
/// ~25. Asked whether Center Stage was making the app lose the user's face,
/// that instrument answered "state=ok" twenty-five times while a quarter of
/// all frames had no face in them at all (§12.5, 2026-08-05). A sampling
/// instrument cannot see an event shorter than its sampling interval, and
/// §7.3's rung 1 fires at 500ms — half a sample. The tool could not answer
/// the question it was being asked, which is its own kind of silent failure,
/// and the same one §12.2 and PR #57 each cost a session to learn.
struct LiveRunStats {
  private(set) var frameCount = 0
  private(set) var stateCounts: [SignalState: Int] = [:]
  private(set) var faceLostEpisodes = 0
  private(set) var longestFaceLostMs = 0
  private(set) var totalFaceLostMs = 0
  /// First frame's dimensions — the existing requested-vs-actual summary line.
  private(set) var firstDimensions: PixelDimensions?
  /// Every DISTINCT set seen, in order. More than one means the delivered
  /// format changed mid-stream, which `AVCaptureDevice.h` says Center Stage
  /// can force (it restricts the device's zoom and frame-rate ranges while
  /// active). Nothing previously read the format back after the first frame —
  /// the same "latch it once" assumption PR #57's bug was made of.
  private(set) var observedDimensions: [PixelDimensions] = []

  private var faceLostStart: ContinuousClock.Instant?

  /// Folds one analyzed frame in. `now` is injected rather than read here so
  /// the caller's single clock governs every timestamp in the run.
  mutating func record(_ output: EngineOutput, at now: ContinuousClock.Instant) {
    frameCount += 1

    if let dimensions = output.capturedPixelDimensions {
      if firstDimensions == nil {
        firstDimensions = dimensions
      }
      if !observedDimensions.contains(dimensions) {
        observedDimensions.append(dimensions)
      }
    }

    let state = output.analysis.signalState
    stateCounts[state, default: 0] += 1

    // §7.3 escalates on "no face available at all" — `.lowConfidence` is a
    // face that WAS found, so it belongs in the tally above but never opens
    // an episode here.
    let faceMissing = state == .noFace || state == .noSignal
    switch (faceMissing, faceLostStart) {
    case (true, nil):
      faceLostStart = now
    case (false, .some(let episodeStart)):
      closeEpisode(from: episodeStart, to: now)
      faceLostStart = nil
    default:
      break
    }
  }

  /// Closes an episode still open when the run ended. A run that STOPS
  /// mid-dropout still had one; discarding it would let "the face was gone
  /// when we stopped looking" read as "no episodes."
  mutating func finish(at now: ContinuousClock.Instant) {
    guard let episodeStart = faceLostStart else { return }
    closeEpisode(from: episodeStart, to: now)
    faceLostStart = nil
  }

  private mutating func closeEpisode(
    from episodeStart: ContinuousClock.Instant, to now: ContinuousClock.Instant
  ) {
    let durationMs = Self.milliseconds(now - episodeStart)
    faceLostEpisodes += 1
    totalFaceLostMs += durationMs
    longestFaceLostMs = max(longestFaceLostMs, durationMs)
  }

  /// Whole milliseconds in `duration`. Same exact-integer approach
  /// `FeedbackRouter.milliseconds(from:to:)` uses (1ms = 1e15 attoseconds)
  /// rather than going through `Double` seconds.
  static func milliseconds(_ duration: Duration) -> Int {
    let (seconds, attoseconds) = duration.components
    return Int(seconds * 1000) + Int(attoseconds / 1_000_000_000_000_000)
  }
}
