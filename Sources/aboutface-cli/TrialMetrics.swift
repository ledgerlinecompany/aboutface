import Foundation

/// Pure, dependency-light metric functions for `aboutface-cli trial` (the
/// convergence-trial harness): everything here is a plain value type or a
/// free function of its inputs — no camera, no audio, no clock reads, no
/// `AboutFaceCore` types. That is deliberate: this file is the part of the
/// harness whose correctness can be checked with hand-computed scripted
/// sequences (see `TrialSelfTest.swift`, run via `trial --self-test-metrics`)
/// rather than only by listening to a live session, mirroring the way
/// `AnalysisEngine`'s determinism is what makes corpus regression (§14)
/// meaningful.
///
/// ## Convergence protocol this implements
///
/// The task brief's per-trial protocol: once live feedback starts, track the
/// first frame the smoothed error enters the dead zone (`tEnter`), then
/// declare SETTLED the first instant the error has stayed continuously
/// in-zone for `settleSeconds` (default 2s) — `tSettled` is that instant
/// (i.e. it already includes the settle-confirmation dwell, not just the
/// moment of first entry). Leaving the zone at any point resets the
/// continuous-run clock; `tEnter` itself, once set, never resets — "first
/// entry into the dead zone" is a one-time event for the whole trial, per
/// the task brief.

/// One frame's contribution to overshoot counting on a single axis: a sign
/// reversal of the axis's error value while genuinely outside that axis's
/// dead-zone threshold. Samples with `|value| <= threshold` are ignored
/// entirely (both for detecting a reversal and for updating the tracked
/// sign) — a sign flip while already settling inside the dead band is noise
/// around zero, not an overshoot past the target.
enum OvershootCounting {
  /// Returns `true` exactly when this sample is an overshoot (a reversal
  /// relative to the last out-of-band sign seen), and advances `lastSign`
  /// in place. Free function taking `lastSign` by `inout` (rather than a
  /// stateful type) so `ConvergenceTracker` can drive one call per axis per
  /// frame from plain stored properties.
  static func step(value: Float, threshold: Float, lastSign: inout Float?) -> Bool {
    guard abs(value) > threshold else { return false }
    let sign: Float = value > 0 ? 1 : -1
    defer { lastSign = sign }
    guard let lastSign, lastSign != sign else { return false }
    return true
  }
}

/// Whether a frame's smoothed error is "well out of position" enough to
/// start a trial from (task brief: "requiring |error| > a displacement
/// threshold before the go"). `threshold` is derived by the caller from the
/// live `Config`'s dead zone (see `Trial.displacementThresholdMagnitude`),
/// not hardcoded here — this function just compares a magnitude to a
/// threshold.
enum DisplacementCheck {
  static func isDisplaced(errorX: Float, errorY: Float, threshold: Float) -> Bool {
    Double(hypot(errorX, errorY)) > Double(threshold)
  }
}

/// One trial's final metrics, as reported in speech and logged to JSON.
struct TrialOutcomeMetrics: Equatable {
  /// Seconds from live-feedback start to first dead-zone entry. `nil` only
  /// if the trial timed out before ever entering the zone.
  let tEnterSeconds: Double?
  /// Seconds from live-feedback start to SETTLED. `nil` on timeout.
  let tSettledSeconds: Double?
  let overshootsX: Int
  let overshootsY: Int
  /// Integral of |error| over elapsed time (face-lost pauses excluded) —
  /// "path efficiency" per the task brief: a straighter, faster correction
  /// accumulates less area than one that wanders before converging.
  let pathIntegral: Double
  /// Mean |error| over the continuous in-zone run that produced SETTLED
  /// (the "steadiness" measure) — `nil` on timeout, since there is no such
  /// run.
  let meanAbsErrorDuringSettle: Double?
  let timedOut: Bool

  var overshootsTotal: Int { overshootsX + overshootsY }
}

/// Incremental convergence-detection state machine: one instance per trial,
/// fed one frame at a time via `ingest(elapsedSeconds:errorX:errorY:inDeadZone:)`
/// in elapsed-time order. Deliberately NOT a batch function over a
/// pre-collected array — the live `trial` command needs to know the instant
/// SETTLED fires (to stop the tone and stop the trial), not just the final
/// answer after the fact, so the incremental reducer IS the pure,
/// unit-testable function (see `TrialSelfTest.swift`), not a convenience
/// wrapper around one.
struct ConvergenceTracker {
  let settleSeconds: Double
  let deadZoneX: Float
  let deadZoneY: Float

  private(set) var tEnterSeconds: Double?
  private(set) var isSettled = false
  private(set) var tSettledSeconds: Double?
  private(set) var overshootsX = 0
  private(set) var overshootsY = 0
  private(set) var pathIntegral: Double = 0

  private var continuousRunStart: Double?
  private var lastSignX: Float?
  private var lastSignY: Float?
  private var lastSampleTime: Double?
  private var settleWindowErrorSum: Double = 0
  private var settleWindowSampleCount = 0

  init(settleSeconds: Double, deadZoneX: Float, deadZoneY: Float) {
    self.settleSeconds = settleSeconds
    self.deadZoneX = deadZoneX
    self.deadZoneY = deadZoneY
  }

  /// Feeds one frame. Returns `true` exactly on the call where SETTLED
  /// fires (once `isSettled` is `true`, every further call is a no-op that
  /// returns `false` — a trial settles at most once).
  @discardableResult
  mutating func ingest(
    elapsedSeconds: Double, errorX: Float, errorY: Float, inDeadZone: Bool
  ) -> Bool {
    guard !isSettled else { return false }

    accumulatePathIntegral(elapsedSeconds: elapsedSeconds, errorX: errorX, errorY: errorY)
    countOvershoots(errorX: errorX, errorY: errorY)

    guard inDeadZone else {
      continuousRunStart = nil
      return false
    }
    return enterOrExtendZone(elapsedSeconds: elapsedSeconds, errorX: errorX, errorY: errorY)
  }

  // swift-format requires the brace on its own line after a wrapped
  // function signature; swiftlint's opening_brace rule disagrees. Format
  // wins (see FeedbackRouter+Announcements.swift for the same
  // disagreement over multiline conditions).
  // swiftlint:disable opening_brace
  private mutating func accumulatePathIntegral(elapsedSeconds: Double, errorX: Float, errorY: Float)
  {
    // swiftlint:enable opening_brace
    if let lastSampleTime {
      let dt = max(0, elapsedSeconds - lastSampleTime)
      pathIntegral += Double(hypot(errorX, errorY)) * dt
    }
    lastSampleTime = elapsedSeconds
  }

  private mutating func countOvershoots(errorX: Float, errorY: Float) {
    if OvershootCounting.step(value: errorX, threshold: deadZoneX, lastSign: &lastSignX) {
      overshootsX += 1
    }
    if OvershootCounting.step(value: errorY, threshold: deadZoneY, lastSign: &lastSignY) {
      overshootsY += 1
    }
  }

  // swiftlint:disable opening_brace
  private mutating func enterOrExtendZone(elapsedSeconds: Double, errorX: Float, errorY: Float)
    -> Bool
  {
    // swiftlint:enable opening_brace
    if tEnterSeconds == nil {
      tEnterSeconds = elapsedSeconds
    }
    if continuousRunStart == nil {
      continuousRunStart = elapsedSeconds
      settleWindowErrorSum = 0
      settleWindowSampleCount = 0
    }
    settleWindowErrorSum += Double(hypot(errorX, errorY))
    settleWindowSampleCount += 1

    guard let runStart = continuousRunStart, elapsedSeconds - runStart >= settleSeconds else {
      return false
    }
    isSettled = true
    tSettledSeconds = elapsedSeconds
    return true
  }

  private var meanAbsErrorDuringSettle: Double? {
    guard settleWindowSampleCount > 0 else { return nil }
    return settleWindowErrorSum / Double(settleWindowSampleCount)
  }

  /// Snapshots the current state as a `TrialOutcomeMetrics`. `timedOut` is
  /// supplied by the caller (the live loop knows whether it stopped because
  /// `isSettled` fired or because the timeout elapsed first) rather than
  /// inferred here, since a tracker that simply stopped receiving frames
  /// partway through is indistinguishable from one that timed out without
  /// that external fact.
  func snapshot(timedOut: Bool) -> TrialOutcomeMetrics {
    TrialOutcomeMetrics(
      tEnterSeconds: tEnterSeconds,
      tSettledSeconds: tSettledSeconds,
      overshootsX: overshootsX,
      overshootsY: overshootsY,
      pathIntegral: pathIntegral,
      meanAbsErrorDuringSettle: meanAbsErrorDuringSettle,
      timedOut: timedOut
    )
  }
}

/// Across-trials aggregate — the "consistency measure the maintainer asked
/// for" (task brief).
struct TrialAggregate: Equatable {
  let trialCount: Int
  let medianSettledSeconds: Double?
  let meanSettledSeconds: Double?
  /// Sample standard deviation of settled trials' `tSettledSeconds`; `nil`
  /// with fewer than two settled trials (consistency is undefined for a
  /// single sample).
  let stddevSettledSeconds: Double?
  let totalOvershoots: Int
  let timeoutCount: Int
}

enum TrialStats {
  static func median(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let mid = sorted.count / 2
    if sorted.count.isMultiple(of: 2) {
      return (sorted[mid - 1] + sorted[mid]) / 2
    }
    return sorted[mid]
  }

  static func mean(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    return values.reduce(0, +) / Double(values.count)
  }

  /// Sample standard deviation (N-1 denominator, Bessel's correction) —
  /// the conventional choice when the trials in hand are a sample of a
  /// hypothetical larger population of attempts, not the entire population.
  static func stddev(_ values: [Double]) -> Double? {
    guard values.count > 1, let meanValue = mean(values) else { return nil }
    let sumSquaredDiffs = values.reduce(0.0) { $0 + ($1 - meanValue) * ($1 - meanValue) }
    return (sumSquaredDiffs / Double(values.count - 1)).squareRoot()
  }

  /// `trials.timedOut` entries are excluded from the settled-seconds
  /// statistics (there is no `tSettledSeconds` to include) but still count
  /// toward `overshoots`/`timeoutCount`.
  static func aggregate(from trials: [TrialOutcomeMetrics]) -> TrialAggregate {
    let settledSeconds = trials.compactMap { $0.timedOut ? nil : $0.tSettledSeconds }
    let totalOvershoots = trials.reduce(0) { $0 + $1.overshootsTotal }
    let timeoutCount = trials.filter(\.timedOut).count
    return TrialAggregate(
      trialCount: trials.count,
      medianSettledSeconds: median(settledSeconds),
      meanSettledSeconds: mean(settledSeconds),
      stddevSettledSeconds: stddev(settledSeconds),
      totalOvershoots: totalOvershoots,
      timeoutCount: timeoutCount
    )
  }
}
