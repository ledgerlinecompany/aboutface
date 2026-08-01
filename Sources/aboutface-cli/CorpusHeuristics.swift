import AboutFaceCore
import Foundation

/// `verify-corpus`'s per-clip triage result. This is COARSE — triage for a
/// human reviewer, not a CI pass/fail gate (task brief) — so there is no
/// "FAIL": `.look` means either the heuristic did not match, or (side-lit,
/// glare) that no single scalar can settle it and a still-frame look is
/// always warranted.
enum ReviewStatus: String, Sendable, Equatable {
  case check = "CHECK"
  case look = "LOOK"
}

/// Coarse expected-vs-observed checks, one per `manifest.json`
/// `expectedCondition` value (see `Fixtures/corpus/manifest.json`'s notes
/// for the human-readable version of each of these).
enum CorpusHeuristics {
  /// One handler per `manifest.json` `expectedCondition` value, dispatched
  /// via dictionary lookup rather than a single giant `switch` — the
  /// `switch` version tripped SwiftLint's cyclomatic-complexity limit, and
  /// a lookup table reads just as clearly for a 1:1 string-to-check
  /// mapping like this one.
  private static let checks: [String: @Sendable (ClipStats) -> (ReviewStatus, String)] = [
    "ok": referenceCheck,
    "lighting-backlit": backlitCheck,
    "lighting-hard-side": { _ in
      (
        .look,
        "No single scalar reliably distinguishes hard side-lighting — always flagged for a "
          + "still-frame review."
      )
    },
    "lowConfidence": dimCheck,
    "framing-too-close": { distanceCheck($0, expectPositive: true) },
    "framing-too-far": { distanceCheck($0, expectPositive: false) },
    "framing-left": { errorXCheck($0, expectNegative: true) },
    "framing-right": { errorXCheck($0, expectNegative: false) },
    "framing-too-high": { errorYCheck($0, expectPositive: true) },
    "framing-too-low": { errorYCheck($0, expectPositive: false) },
    "gaze-off-camera": gazeOffCheck,
    "pose-roll": rollCheck,
    "multi-face-transient": { multiFaceCheck($0, sustained: false) },
    "multi-face-sustained": { multiFaceCheck($0, sustained: true) },
    "lighting-glare": glareCheck,
    "noSignal": lensCoveredCheck,
    "suppressed-no-announcement": suppressionCheck,
    "face-lost-escalation-and-recovery": leaveReturnCheck,
  ]  // swiftlint:disable:previous trailing_comma

  static func evaluate(entry: ManifestEntry, stats: ClipStats) -> (ReviewStatus, String) {
    guard let check = checks[entry.expectedCondition] else {
      return (
        .look,
        "No heuristic wired up for expectedCondition \"\(entry.expectedCondition)\" — manual "
          + "review needed."
      )
    }
    return check(stats)
  }

  // MARK: - Individual checks

  private static func referenceCheck(_ stats: ClipStats) -> (ReviewStatus, String) {
    guard stats.frameCount > 0 else { return (.look, "no frames") }
    let okFraction = Double(stats.stateHistogram["ok", default: 0]) / Double(stats.frameCount)
    let meanAbsX = ClipStats.mean(stats.errorXs.map(abs))
    let meanAbsY = ClipStats.mean(stats.errorYs.map(abs))
    let gazeFraction =
      stats.gazeSampledCount > 0
      ? Double(stats.gazeOnFrameCount) / Double(stats.gazeSampledCount) : 0

    // "Small" error is judged against Config.defaults.deadZone: twice the
    // dead-zone half-width is clearly outside "in the dead zone," but still
    // a loose bound appropriate for coarse triage, not a tuned gate.
    let xBound = Float(Config.defaults.deadZone.horizontal * 2)
    let yBound = Float(Config.defaults.deadZone.vertical * 2)
    let errorSmall = (meanAbsX ?? .infinity) < xBound && (meanAbsY ?? .infinity) < yBound

    let status: ReviewStatus =
      (okFraction >= 0.9 && errorSmall && gazeFraction >= 0.8) ? .check : .look
    return (
      status,
      "ok=\(pct(okFraction)) meanAbsErr=(\(fmt(meanAbsX)),\(fmt(meanAbsY))) gazeOn=\(pct(gazeFraction))"
    )
  }

  private static func backlitCheck(_ stats: ClipStats) -> (ReviewStatus, String) {
    guard let meanDelta = ClipStats.mean(stats.backlightDeltas) else { return (.look, "no frames") }
    let status: ReviewStatus = meanDelta > 0.05 ? .check : .look
    return (status, "meanBacklightDelta=\(fmt(meanDelta))")
  }

  private static func dimCheck(_ stats: ClipStats) -> (ReviewStatus, String) {
    guard let meanFaceLuma = ClipStats.mean(stats.faceLumas) else { return (.look, "no frames") }
    let lowConfidenceFraction =
      stats.frameCount > 0
      ? Double(stats.stateHistogram["lowConfidence", default: 0]) / Double(stats.frameCount) : 0
    let status: ReviewStatus = (meanFaceLuma < 0.25 || lowConfidenceFraction > 0.5) ? .check : .look
    return (
      status, "meanFaceLuma=\(fmt(meanFaceLuma)) lowConfidence=\(pct(lowConfidenceFraction))"
    )
  }

  private static func distanceCheck(_ stats: ClipStats, expectPositive: Bool) -> (
    ReviewStatus, String
  ) {
    guard let meanDistance = ClipStats.mean(stats.distanceErrors) else {
      return (.look, "no frames with a detected face")
    }
    let status: ReviewStatus =
      expectPositive
      ? (meanDistance > 0.02 ? .check : .look) : (meanDistance < -0.02 ? .check : .look)
    return (status, "meanDistanceError=\(fmt(meanDistance))")
  }

  /// §3.4 egocentric reasoning (spelled out per manifest.json clip 7's own
  /// note, and CLAUDE.md's "inverted directions are the single worst
  /// failure mode"): `FramingState.error.x` is "+ = subject is right of
  /// target" in EGOCENTRIC terms — the subject's OWN right, after the
  /// mirror transform already applied upstream in `AnalysisEngine`. A
  /// subject staged off to their own left therefore produces `error.x < 0`,
  /// and off to their own right produces `error.x > 0`. This must be
  /// reasoned from the subject's point of view, never the camera's or a
  /// viewer's.
  private static func errorXCheck(_ stats: ClipStats, expectNegative: Bool) -> (
    ReviewStatus, String
  ) {
    guard let meanX = ClipStats.mean(stats.errorXs) else {
      return (.look, "no frames with a detected face")
    }
    let status: ReviewStatus =
      expectNegative ? (meanX < 0 ? .check : .look) : (meanX > 0 ? .check : .look)
    return (status, "meanErrorX=\(fmt(meanX))")
  }

  /// `FramingState.error.y` is "+ = subject is above target" — too high in
  /// frame means the subject is above target, i.e. `error.y > 0`.
  private static func errorYCheck(_ stats: ClipStats, expectPositive: Bool) -> (
    ReviewStatus, String
  ) {
    guard let meanY = ClipStats.mean(stats.errorYs) else {
      return (.look, "no frames with a detected face")
    }
    let status: ReviewStatus =
      expectPositive ? (meanY > 0 ? .check : .look) : (meanY < 0 ? .check : .look)
    return (status, "meanErrorY=\(fmt(meanY))")
  }

  /// Covers both "looking down" (pitch) and "looking off to the side"
  /// (yaw) clips, which share the manifest's `gaze-off-camera`
  /// `expectedCondition`: measures each axis's deviation from its
  /// first-sampled-frame baseline (§4 extension note in `Config.swift`:
  /// pose is measured relative to the camera ray, not an absolute
  /// eyeline, so a captured neutral baseline is the meaningful reference)
  /// and reports whichever axis deviates more, rather than assuming which
  /// clip this is from the expectedCondition string alone.
  private static func gazeOffCheck(_ stats: ClipStats) -> (ReviewStatus, String) {
    guard let baselineYaw = stats.yaws.first, let baselinePitch = stats.pitches.first else {
      return (.look, "no frames with a detected face")
    }
    let meanYawDeviation = ClipStats.mean(stats.yaws.map { abs($0 - baselineYaw) }) ?? 0
    let meanPitchDeviation = ClipStats.mean(stats.pitches.map { abs($0 - baselinePitch) }) ?? 0
    let dominant = max(meanYawDeviation, meanPitchDeviation)
    let axis = meanYawDeviation >= meanPitchDeviation ? "yaw" : "pitch"
    let gazeOffFraction =
      stats.gazeSampledCount > 0
      ? Double(stats.gazeSampledCount - stats.gazeOnFrameCount) / Double(stats.gazeSampledCount)
      : 0
    let status: ReviewStatus = (dominant > 15 && gazeOffFraction > 0.5) ? .check : .look
    return (
      status,
      "dominantAxis=\(axis) meanDeviation=\(fmt(dominant))deg gazeOff=\(pct(gazeOffFraction))"
    )
  }

  private static func rollCheck(_ stats: ClipStats) -> (ReviewStatus, String) {
    guard let baselineRoll = stats.rolls.first else {
      return (.look, "no frames with a detected face")
    }
    guard let meanDeviation = ClipStats.mean(stats.rolls.map { abs($0 - baselineRoll) }) else {
      return (.look, "no frames with a detected face")
    }
    let status: ReviewStatus = meanDeviation > 15 ? .check : .look
    return (status, "meanRollDeviation=\(fmt(meanDeviation))deg")
  }

  private static func multiFaceCheck(
    _ stats: ClipStats, sustained: Bool
  ) -> (ReviewStatus, String) {
    guard stats.frameCount > 0 else { return (.look, "no frames") }
    let fraction = Double(stats.multiFaceFrameCount) / Double(stats.frameCount)
    let status: ReviewStatus =
      sustained
      ? (fraction > 0.5 ? .check : .look) : (fraction > 0 && fraction < 0.5 ? .check : .look)
    return (status, "multiFaceFraction=\(pct(fraction))")
  }

  private static func glareCheck(_ stats: ClipStats) -> (ReviewStatus, String) {
    guard let meanHighlight = ClipStats.mean(stats.clippedHighlightFractions) else {
      return (.look, "no frames")
    }
    let status: ReviewStatus = meanHighlight > 0.02 ? .check : .look
    return (
      status,
      "meanClippedHighlightFraction=\(fmt(meanHighlight)) (approximate — glare is localized "
        + "near the eyes; review stills)"
    )
  }

  private static func lensCoveredCheck(_ stats: ClipStats) -> (ReviewStatus, String) {
    let (found, length) = ClipStats.hasMidClipNoSignalStreak(stats.stateSequence)
    let status: ReviewStatus = found ? .check : .look
    return (status, "longestMidClipNoSignalStreak=\(length) of \(stats.frameCount) frames")
  }

  private static func suppressionCheck(_ stats: ClipStats) -> (ReviewStatus, String) {
    guard stats.frameCount > 0 else { return (.look, "no frames") }
    let okFraction = Double(stats.stateHistogram["ok", default: 0]) / Double(stats.frameCount)
    let transitions = ClipStats.transitionCount(stats.stateSequence)
    let status: ReviewStatus = (okFraction > 0.8 && transitions <= 8) ? .check : .look
    return (status, "ok=\(pct(okFraction)) stateTransitions=\(transitions)")
  }

  private static func leaveReturnCheck(_ stats: ClipStats) -> (ReviewStatus, String) {
    let minRun = max(1, stats.frameCount / 20)
    let found = ClipStats.hasOkNoFaceOkPattern(stats.stateSequence, minNoFaceRun: minRun)
    let status: ReviewStatus = found ? .check : .look
    return (
      status, "ok-then-noFace-then-ok pattern \(found ? "found" : "not found") (minRun=\(minRun))"
    )
  }

  // MARK: - Formatting

  private static func fmt(_ value: Float?) -> String {
    value.map { String(format: "%.4f", $0) } ?? "-"
  }

  private static func pct(_ value: Double) -> String {
    String(format: "%.0f%%", value * 100)
  }
}
