import AboutFaceCore
import Foundation

/// The actual scripted checks for `TrialSelfTest` — see that file's doc
/// comment for the overall coverage statement and the reason for this
/// file split.
extension TrialSelfTest {
  // MARK: - ConvergenceTracker

  /// One scripted frame for `checkConvergenceTracker` — a named struct
  /// rather than a 4-element tuple (SwiftLint's `large_tuple`, same
  /// reasoning `AudioCLISupport.FeedbackChain`'s doc comment gives).
  private struct ScriptStep {
    let t: Double
    let x: Float
    let y: Float
    let inZone: Bool
  }

  /// Scripted sequence, dead zone (0.1, 0.1), settle window 2.0s, one
  /// sample per second:
  ///
  ///   t=0  err=(+0.3,+0.4) mag 0.5  outside          (no dt yet)
  ///   t=1  err=(-0.3,+0.4) mag 0.5  outside — x flips sign  → overshootX 1
  ///   t=2  err=(+0.3,-0.4) mag 0.5  outside — x and y flip  → overshootX 2, overshootY 1
  ///   t=3  err=(0.05,0.05) mag 0.070710678  IN ZONE → tEnter=3, run starts
  ///   t=4  err=(0.05,0.05)          IN ZONE, run=1s < 2s
  ///   t=5  err=(0.05,0.05)          IN ZONE, run=2s >= 2s → SETTLED, tSettled=5
  ///
  /// Hand-computed path integral (rectangle rule, dt=1 between each
  /// consecutive pair, using the arriving sample's magnitude — see
  /// `ConvergenceTracker.accumulatePathIntegral`): the t=0 sample
  /// contributes nothing (no previous sample to measure dt from); then
  /// 0.5 + 0.5 + 0.070710678 + 0.070710678 + 0.070710678
  ///   = 1.0 + 3 * 0.070710678 = 1.212132034.
  ///
  /// Hand-computed settle-window mean: the in-zone run (t=3,4,5) is three
  /// samples of identical magnitude 0.070710678, so the mean is that same
  /// value.
  static func checkConvergenceTracker(_ failures: inout [Failure]) {
    var tracker = ConvergenceTracker(settleSeconds: 2.0, deadZoneX: 0.1, deadZoneY: 0.1)
    let script: [ScriptStep] = [
      ScriptStep(t: 0, x: 0.3, y: 0.4, inZone: false),
      ScriptStep(t: 1, x: -0.3, y: 0.4, inZone: false),
      ScriptStep(t: 2, x: 0.3, y: -0.4, inZone: false),
      ScriptStep(t: 3, x: 0.05, y: 0.05, inZone: true),
      ScriptStep(t: 4, x: 0.05, y: 0.05, inZone: true),
      ScriptStep(t: 5, x: 0.05, y: 0.05, inZone: true),
    ]  // swiftlint:disable:previous trailing_comma
    var settledOn: Double?
    for sample in script {
      let settled = tracker.ingest(
        elapsedSeconds: sample.t, errorX: sample.x, errorY: sample.y, inDeadZone: sample.inZone)
      if settled { settledOn = sample.t }
    }

    expect(settledOn, equals: 5.0, name: "ConvergenceTracker.settledOn", failures: &failures)
    expect(
      tracker.tEnterSeconds, equals: 3.0, name: "ConvergenceTracker.tEnterSeconds",
      failures: &failures)
    expect(
      tracker.tSettledSeconds, equals: 5.0, name: "ConvergenceTracker.tSettledSeconds",
      failures: &failures)
    expect(
      tracker.overshootsX, equalsInt: 2, name: "ConvergenceTracker.overshootsX",
      failures: &failures)
    expect(
      tracker.overshootsY, equalsInt: 1, name: "ConvergenceTracker.overshootsY",
      failures: &failures)
    expect(
      tracker.pathIntegral, equals: 1.212_132_034, name: "ConvergenceTracker.pathIntegral",
      tolerance: 1e-6, failures: &failures)

    let metrics = tracker.snapshot(timedOut: false)
    expect(
      metrics.meanAbsErrorDuringSettle, equals: 0.070_710_678,
      name: "ConvergenceTracker.meanAbsErrorDuringSettle", tolerance: 1e-6, failures: &failures)
    expect(
      metrics.overshootsTotal, equalsInt: 3, name: "ConvergenceTracker.overshootsTotal",
      failures: &failures)

    checkTimeout(&failures)
  }

  /// A trial that never enters the dead zone at all: `tEnter`/`tSettled`
  /// must both stay `nil`, and `snapshot(timedOut: true)` must record that.
  private static func checkTimeout(_ failures: inout [Failure]) {
    var tracker = ConvergenceTracker(settleSeconds: 2.0, deadZoneX: 0.1, deadZoneY: 0.1)
    for t in stride(from: 0.0, through: 5.0, by: 1.0) {
      tracker.ingest(elapsedSeconds: t, errorX: 0.5, errorY: 0.5, inDeadZone: false)
    }
    let metrics = tracker.snapshot(timedOut: true)
    expect(metrics.tEnterSeconds, equals: nil, name: "timeout.tEnterSeconds", failures: &failures)
    expect(
      metrics.tSettledSeconds, equals: nil, name: "timeout.tSettledSeconds", failures: &failures)
    expect(metrics.timedOut, equalsBool: true, name: "timeout.timedOut", failures: &failures)
  }

  // MARK: - TrialStats

  static func checkTrialStats(_ failures: inout [Failure]) {
    // Odd count: mean=6, median=6, sample stddev = sqrt(((4-6)^2+(6-6)^2+(8-6)^2)/2) = sqrt(4) = 2.
    expect(
      TrialStats.mean([4, 6, 8]), equals: 6.0, name: "TrialStats.mean(odd)", failures: &failures)
    expect(
      TrialStats.median([4, 6, 8]), equals: 6.0, name: "TrialStats.median(odd)",
      failures: &failures)
    expect(
      TrialStats.stddev([4, 6, 8]), equals: 2.0, name: "TrialStats.stddev(odd)",
      tolerance: 1e-9, failures: &failures)

    // Even count: mean=6, median=(5+7)/2=6, sample stddev = sqrt(((5-6)^2+(7-6)^2)/1) = sqrt(2).
    expect(
      TrialStats.median([5, 7]), equals: 6.0, name: "TrialStats.median(even)", failures: &failures)
    expect(
      TrialStats.stddev([5, 7]), equals: 2.0.squareRoot(), name: "TrialStats.stddev(even)",
      tolerance: 1e-9, failures: &failures)

    expect(
      TrialStats.stddev([5]), equals: nil, name: "TrialStats.stddev(singleton)",
      failures: &failures)
    expect(
      TrialStats.median([]), equals: nil, name: "TrialStats.median(empty)", failures: &failures)

    checkAggregate(&failures)
  }

  /// Three synthetic trials — two settled (5s, 7s), one timed out —
  /// exercising `TrialStats.aggregate`'s exclusion of timed-out trials from
  /// the settled-seconds statistics while still counting their overshoots.
  /// Hand-computed: settled = [5,7] → median 6, mean 6, stddev sqrt(2);
  /// totalOvershoots = (1+1) + (0+2) + (2+0) = 6; timeoutCount = 1.
  private static func checkAggregate(_ failures: inout [Failure]) {
    let firstTrial = TrialOutcomeMetrics(
      tEnterSeconds: 1, tSettledSeconds: 5, overshootsX: 1, overshootsY: 1, pathIntegral: 0,
      meanAbsErrorDuringSettle: 0, timedOut: false)
    let secondTrial = TrialOutcomeMetrics(
      tEnterSeconds: 2, tSettledSeconds: 7, overshootsX: 0, overshootsY: 2, pathIntegral: 0,
      meanAbsErrorDuringSettle: 0, timedOut: false)
    let thirdTrial = TrialOutcomeMetrics(
      tEnterSeconds: nil, tSettledSeconds: nil, overshootsX: 2, overshootsY: 0, pathIntegral: 0,
      meanAbsErrorDuringSettle: nil, timedOut: true)
    let aggregate = TrialStats.aggregate(from: [firstTrial, secondTrial, thirdTrial])

    expect(aggregate.trialCount, equalsInt: 3, name: "aggregate.trialCount", failures: &failures)
    expect(
      aggregate.medianSettledSeconds, equals: 6.0, name: "aggregate.medianSettledSeconds",
      failures: &failures)
    expect(
      aggregate.meanSettledSeconds, equals: 6.0, name: "aggregate.meanSettledSeconds",
      failures: &failures)
    expect(
      aggregate.stddevSettledSeconds, equals: 2.0.squareRoot(),
      name: "aggregate.stddevSettledSeconds", tolerance: 1e-9, failures: &failures)
    expect(
      aggregate.totalOvershoots, equalsInt: 6, name: "aggregate.totalOvershoots",
      failures: &failures)
    expect(
      aggregate.timeoutCount, equalsInt: 1, name: "aggregate.timeoutCount", failures: &failures)
  }

  // MARK: - DisplacementCheck

  static func checkDisplacementCheck(_ failures: inout [Failure]) {
    // hypot(0.1, 0.1) = 0.14142135... < 0.15 threshold -> not displaced.
    expect(
      DisplacementCheck.isDisplaced(errorX: 0.1, errorY: 0.1, threshold: 0.15),
      equalsBool: false, name: "DisplacementCheck.belowThreshold", failures: &failures)
    // hypot(0.11, 0.11) = 0.15556... > 0.15 -> displaced.
    expect(
      DisplacementCheck.isDisplaced(errorX: 0.11, errorY: 0.11, threshold: 0.15),
      equalsBool: true, name: "DisplacementCheck.aboveThreshold", failures: &failures)
  }

  // MARK: - Config hash + JSON schema

  static func checkConfigHash(_ failures: inout [Failure]) {
    let hashA = TrialSessionStore.configHash(.defaults)
    let hashARepeat = TrialSessionStore.configHash(.defaults)
    expect(
      hashA == hashARepeat, equalsBool: true, name: "configHash.deterministic",
      failures: &failures)

    var modified = Config.defaults
    modified.dwellMs += 1
    let hashB = TrialSessionStore.configHash(modified)
    expect(
      hashA == hashB, equalsBool: false, name: "configHash.sensitiveToChange", failures: &failures)
  }

  /// A fabricated two-trial session (one settled, one timed out) used both
  /// by `checkSessionLogRoundTrip` below and by `trial --self-test-metrics
  /// --json <path>` to demonstrate the on-disk schema without needing a
  /// camera (task brief's headless-smoke "JSON schema of an empty/synthetic
  /// session").
  static func syntheticSession() -> TrialSessionLog.SessionRecord {
    let settled = TrialOutcomeMetrics(
      tEnterSeconds: 1.1, tSettledSeconds: 5.2, overshootsX: 1, overshootsY: 1, pathIntegral: 3.4,
      meanAbsErrorDuringSettle: 0.02, timedOut: false)
    let timedOut = TrialOutcomeMetrics(
      tEnterSeconds: nil, tSettledSeconds: nil, overshootsX: 0, overshootsY: 0, pathIntegral: 9.9,
      meanAbsErrorDuringSettle: nil, timedOut: true)
    let aggregate = TrialStats.aggregate(from: [settled, timedOut])
    let trialRecords = [
      TrialSessionLog.TrialRecord(index: 1, metrics: settled),
      TrialSessionLog.TrialRecord(index: 2, metrics: timedOut),
    ]  // swiftlint:disable:previous trailing_comma
    return TrialSessionLog.SessionRecord(
      label: "self-test-synthetic", configSource: "defaults",
      configHash: TrialSessionStore.configHash(.defaults), dateISO8601: "2026-08-02T00:00:00Z",
      settleSeconds: 2.0, timeoutSeconds: 45.0, displacementThreshold: 0.15,
      trials: trialRecords, aggregate: TrialSessionLog.AggregateRecord(aggregate))
  }

  /// Encodes a synthetic session and decodes it back, checking field-for-
  /// field equality — the schema round-trip the task brief's headless smoke
  /// test calls for ("JSON schema of an empty/synthetic session").
  static func checkSessionLogRoundTrip(_ failures: inout [Failure]) {
    let session = syntheticSession()
    let log = TrialSessionLog(sessions: [session])

    guard let data = try? JSONEncoder().encode(log) else {
      failures.append(Failure(name: "sessionLog.encode", detail: "encoding threw"))
      return
    }
    guard let decoded = try? JSONDecoder().decode(TrialSessionLog.self, from: data) else {
      failures.append(Failure(name: "sessionLog.decode", detail: "decoding threw"))
      return
    }
    expect(
      decoded.sessions.first?.trials.count, equalsInt: 2, name: "sessionLog.trialCount",
      failures: &failures)
    expect(
      decoded.sessions.first?.trials.first?.tSettledSeconds, equals: 5.2,
      name: "sessionLog.tSettledSeconds", failures: &failures)
    expect(
      decoded.sessions.first?.aggregate?.timeoutCount, equalsInt: 1,
      name: "sessionLog.aggregate.timeoutCount", failures: &failures)
  }

  // MARK: - Session summary + cross-session comparison

  /// Matches the task brief's own worked example verbatim: a current
  /// session with median 6.1s vs. a prior "scheme-a-only" session with
  /// median 7.4s should read "faster by 1.3 seconds" (7.4 - 6.1 = 1.3).
  /// Also checks `mostRecentOtherSession` correctly skips a same-label
  /// session and finds the most recent differently-labeled one.
  static func checkSessionSummary(_ failures: inout [Failure]) {
    let currentAggregate = TrialAggregate(
      trialCount: 5, medianSettledSeconds: 6.1, meanSettledSeconds: 6.3,
      stddevSettledSeconds: 1.9, totalOvershoots: 7, timeoutCount: 0)
    let summary = Trial.summarySentence(currentAggregate)
    expect(summary, contains: "5 trials.", name: "summarySentence.count", failures: &failures)
    expect(
      summary, contains: "Median time to settle: 6.1 seconds.", name: "summarySentence.median",
      failures: &failures)
    expect(
      summary, contains: "Consistency: plus or minus 1.9 seconds.",
      name: "summarySentence.consistency", failures: &failures)

    let previousAggregate = TrialSessionLog.AggregateRecord(
      TrialAggregate(
        trialCount: 5, medianSettledSeconds: 7.4, meanSettledSeconds: 7.6,
        stddevSettledSeconds: 2.1, totalOvershoots: 9, timeoutCount: 0))
    let previousSession = TrialSessionLog.SessionRecord(
      label: "scheme-a-only", configSource: "scheme-a.json", configHash: "abc",
      dateISO8601: "2026-08-01T00:00:00Z", settleSeconds: 2.0, timeoutSeconds: 45.0,
      displacementThreshold: 0.15, trials: [], aggregate: previousAggregate)

    guard
      let comparison = Trial.comparisonSentence(
        current: currentAggregate, previous: previousSession)
    else {
      failures.append(
        Failure(
          name: "comparisonSentence.nonNil", detail: "expected a comparison sentence, got nil"))
      return
    }
    expect(
      comparison, contains: "Versus session 'scheme-a-only'", name: "comparisonSentence.label",
      failures: &failures)
    expect(
      comparison, contains: "faster by 1.3 seconds", name: "comparisonSentence.delta",
      failures: &failures)
    expect(
      comparison, contains: "2 fewer overshoots", name: "comparisonSentence.overshoots",
      failures: &failures)

    checkMostRecentOtherSession(previousSession: previousSession, &failures)
  }

  private static func checkMostRecentOtherSession(
    previousSession: TrialSessionLog.SessionRecord, _ failures: inout [Failure]
  ) {
    let currentSession = TrialSessionLog.SessionRecord(
      label: "scheme-b-only", configSource: "scheme-b.json", configHash: "def",
      dateISO8601: "2026-08-02T00:00:00Z", settleSeconds: 2.0, timeoutSeconds: 45.0,
      displacementThreshold: 0.15, trials: [], aggregate: nil)
    let logWithDifferentLabels = TrialSessionLog(sessions: [previousSession, currentSession])
    let found = Trial.mostRecentOtherSession(
      in: logWithDifferentLabels, excludingLabel: "scheme-b-only")
    expect(
      found?.label == "scheme-a-only", equalsBool: true,
      name: "mostRecentOtherSession.findsDifferentLabel", failures: &failures)

    let logWithSameLabelOnly = TrialSessionLog(sessions: [currentSession, currentSession])
    let notFound = Trial.mostRecentOtherSession(
      in: logWithSameLabelOnly, excludingLabel: "scheme-b-only")
    expect(
      notFound == nil, equalsBool: true, name: "mostRecentOtherSession.skipsSameLabel",
      failures: &failures)
  }
}
