import AboutFaceCore

/// Aggregated statistics from replaying one clip through `AnalysisEngine`,
/// consumed by `CorpusHeuristics`'s per-clip triage checks.
///
/// `SignalState` (`AboutFaceCore`) is `Equatable` but not `Hashable`, so
/// states are tracked here by their string description (`"\(state)"`) — the
/// same convention `OutputLine`/`Replay` already use for the same reason.
struct ClipStats: Sendable {
  /// Per-clip arrays are appended in replay order, so `.first`/`[count /
  /// 2]`/`.last` on any of these give the first/middle/last sampled value —
  /// the "first/middle/last-frame values" a reviewer wants without opening
  /// a video player. Note these only include frames that actually had the
  /// relevant signal (e.g. `yaws` skips no-face frames), so "middle" is the
  /// temporal middle of the SAMPLED frames, not necessarily of the whole
  /// clip — a fine approximation for triage.
  private(set) var frameCount = 0
  private(set) var stateHistogram: [String: Int] = [:]
  private(set) var stateSequence: [String] = []
  private(set) var errorXs: [Float] = []
  private(set) var errorYs: [Float] = []
  private(set) var distanceErrors: [Float] = []
  private(set) var faceLumas: [Float] = []
  private(set) var backgroundLumas: [Float] = []
  private(set) var backlightDeltas: [Float] = []
  private(set) var clippedHighlightFractions: [Float] = []
  private(set) var yaws: [Float] = []
  private(set) var pitches: [Float] = []
  private(set) var rolls: [Float] = []
  private(set) var multiFaceFrameCount = 0
  private(set) var gazeOnFrameCount = 0
  private(set) var gazeSampledCount = 0

  mutating func record(_ output: EngineOutput) {
    frameCount += 1
    let stateText = "\(output.analysis.signalState)"
    stateHistogram[stateText, default: 0] += 1
    stateSequence.append(stateText)

    let lighting = output.analysis.lighting
    faceLumas.append(lighting.faceLuma)
    backgroundLumas.append(lighting.backgroundLuma)
    backlightDeltas.append(lighting.backlightDelta)
    clippedHighlightFractions.append(lighting.clippedHighlightFraction)

    if output.analysis.faceCount > 1 {
      multiFaceFrameCount += 1
    }

    if let framing = output.framing {
      errorXs.append(framing.error.x)
      errorYs.append(framing.error.y)
      distanceErrors.append(framing.distanceError)
      gazeSampledCount += 1
      if framing.gazeOnCamera {
        gazeOnFrameCount += 1
      }
    }

    if let primary = output.analysis.primary {
      yaws.append(primary.yaw)
      pitches.append(primary.pitch)
      rolls.append(primary.roll)
    }
  }

  // MARK: - Sequence analysis helpers

  /// Longest run of consecutive frames in `sequence` equal to `state`, and
  /// the index it starts at. `nil` if `state` never occurs.
  static func longestStreak(of state: String, in sequence: [String]) -> (
    length: Int, startIndex: Int
  )? {
    var bestLength = 0
    var bestStart = -1
    var currentLength = 0
    var currentStart = -1
    for (index, value) in sequence.enumerated() {
      if value == state {
        if currentLength == 0 { currentStart = index }
        currentLength += 1
        if currentLength > bestLength {
          bestLength = currentLength
          bestStart = currentStart
        }
      } else {
        currentLength = 0
      }
    }
    guard bestLength > 0 else { return nil }
    return (bestLength, bestStart)
  }

  /// Count of frame-to-frame `SignalState` changes — a proxy for "chatter";
  /// low counts are what §7's dwell/hysteresis is meant to guarantee on a
  /// suppression clip (blink/fidget, hand-raised).
  static func transitionCount(_ sequence: [String]) -> Int {
    guard sequence.count > 1 else { return 0 }
    var count = 0
    for index in 1..<sequence.count where sequence[index] != sequence[index - 1] {
      count += 1
    }
    return count
  }

  /// True if `sequence` contains a `noSignal` run of at least
  /// `sequence.count / 10` frames that starts and ends away from the very
  /// first/last 5% of the clip — the "lens covered mid-clip" shape (clip
  /// 17: covered for ~8s in the middle of a 15s clip).
  static func hasMidClipNoSignalStreak(_ sequence: [String]) -> (found: Bool, length: Int) {
    guard let streak = longestStreak(of: "noSignal", in: sequence) else { return (false, 0) }
    let total = sequence.count
    let minLength = max(1, total / 10)
    let margin = max(1, total / 20)
    let notAtStart = streak.startIndex > margin
    let notAtEnd = (streak.startIndex + streak.length) < (total - margin)
    return (streak.length >= minLength && notAtStart && notAtEnd, streak.length)
  }

  /// True if `sequence` shows an `ok` run, then a `noFace` run of at least
  /// `minNoFaceRun` frames, then another `ok` run — the "subject leaves and
  /// returns" shape (clip 20).
  static func hasOkNoFaceOkPattern(_ sequence: [String], minNoFaceRun: Int) -> Bool {
    guard let streak = longestStreak(of: "noFace", in: sequence), streak.length >= minNoFaceRun
    else { return false }
    let streakEnd = streak.startIndex + streak.length - 1
    let hasOkBefore = sequence[0..<streak.startIndex].contains("ok")
    let hasOkAfter =
      streakEnd + 1 < sequence.count && sequence[(streakEnd + 1)...].contains("ok")
    return hasOkBefore && hasOkAfter
  }

  static func mean(_ values: [Float]) -> Float? {
    guard !values.isEmpty else { return nil }
    return values.reduce(0, +) / Float(values.count)
  }

  static func median(_ values: [Float]) -> Float? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let mid = sorted.count / 2
    if sorted.count.isMultiple(of: 2) {
      return (sorted[mid - 1] + sorted[mid]) / 2
    }
    return sorted[mid]
  }
}
