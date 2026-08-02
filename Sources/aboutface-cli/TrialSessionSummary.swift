import AboutFaceCore
import Foundation

/// `Trial`'s `--json` persistence and end-of-session speech — split out of
/// `TrialProtocol.swift` purely to keep each file a manageable size.
extension Trial {
  func makeSessionRecord(
    config: Config, label: String, displacementThreshold: Double
  ) -> TrialSessionLog.SessionRecord {
    TrialSessionLog.SessionRecord(
      label: label,
      configSource: configPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "defaults",
      configHash: TrialSessionStore.configHash(config),
      dateISO8601: ISO8601DateFormatter().string(from: Date()),
      settleSeconds: settleSeconds,
      timeoutSeconds: timeoutSeconds,
      displacementThreshold: displacementThreshold,
      trials: [],
      aggregate: nil
    )
  }

  /// Best-effort write: a disk failure here must not abort an in-progress
  /// session (the trial itself already happened and was already
  /// spoken/printed) — it prints a warning once and the session continues,
  /// matching this harness's general posture that hardware/IO problems
  /// degrade gracefully rather than crash a maintainer's ear-tuning
  /// session. This IS still the task brief's "flushed per completed
  /// trial" behavior — the write is attempted synchronously right after
  /// each trial, not batched to session end.
  func persist(_ log: TrialSessionLog, to url: URL) {
    do {
      try TrialSessionStore.write(log, to: url)
    } catch {
      print("Warning: could not write --json log to \(url.path): \(error)")
    }
  }

  func speakSessionSummary(
    outcomes: [TrialOutcomeMetrics], log: TrialSessionLog, currentLabel: String, speech: Speech
  ) async {
    let aggregate = TrialStats.aggregate(from: outcomes)
    await announce(Self.summarySentence(aggregate), speech: speech)

    guard let previous = Self.mostRecentOtherSession(in: log, excludingLabel: currentLabel),
      let sentence = Self.comparisonSentence(current: aggregate, previous: previous)
    else { return }
    await announce(sentence, speech: speech)
  }

  /// The most recently logged prior session under a DIFFERENT label than
  /// the one just run — `dropLast()` excludes the session this run itself
  /// just appended to `log.sessions`. Task brief: "if the JSON log already
  /// holds prior sessions with different labels" — same-label reruns
  /// (e.g. re-running the same profile to check repeatability) are not a
  /// meaningful A/B comparison, so they are skipped in favor of the most
  /// recent genuinely different one.
  static func mostRecentOtherSession(
    in log: TrialSessionLog, excludingLabel currentLabel: String
  ) -> TrialSessionLog.SessionRecord? {
    log.sessions.dropLast().last(where: { $0.label != currentLabel })
  }

  static func summarySentence(_ aggregate: TrialAggregate) -> String {
    let trialWord = aggregate.trialCount == 1 ? "trial" : "trials"
    var parts = ["\(aggregate.trialCount) \(trialWord)."]

    if let median = aggregate.medianSettledSeconds {
      parts.append("Median time to settle: \(formatSeconds(median)) seconds.")
    } else {
      parts.append("No trial settled.")
    }
    parts.append("Total overshoots: \(aggregate.totalOvershoots).")
    if let stddev = aggregate.stddevSettledSeconds {
      parts.append("Consistency: plus or minus \(formatSeconds(stddev)) seconds.")
    }
    if aggregate.timeoutCount > 0 {
      let word = aggregate.timeoutCount == 1 ? "trial" : "trials"
      parts.append("\(aggregate.timeoutCount) \(word) timed out.")
    }
    return parts.joined(separator: " ")
  }

  /// "Versus session '<label>': median <X> seconds — faster/slower by <Y>
  /// seconds; <N> fewer/more overshoots." Kept deliberately to just the
  /// two numbers the task brief calls out (median settle time, total
  /// overshoots) rather than a full statistical comparison. `nil` if
  /// either session has no settled trials to compare (a session that
  /// timed out every trial has nothing meaningful to say here).
  static func comparisonSentence(
    current: TrialAggregate, previous: TrialSessionLog.SessionRecord
  ) -> String? {
    guard let previousAggregate = previous.aggregate,
      let previousMedian = previousAggregate.medianSettledSeconds,
      let currentMedian = current.medianSettledSeconds
    else { return nil }

    let delta = previousMedian - currentMedian
    let speedDescription =
      delta >= 0
      ? "faster by \(formatSeconds(abs(delta))) seconds"
      : "slower by \(formatSeconds(abs(delta))) seconds"
    let overshootDescription = overshootComparison(
      previous: previousAggregate.totalOvershoots, current: current.totalOvershoots)

    return
      "Versus session '\(previous.label)': median \(formatSeconds(previousMedian)) seconds — "
      + "\(speedDescription); \(overshootDescription)."
  }

  private static func overshootComparison(previous: Int, current: Int) -> String {
    let delta = previous - current
    if delta > 0 { return "\(delta) fewer overshoots" }
    if delta < 0 { return "\(-delta) more overshoots" }
    return "the same overshoot count"
  }

  static func formatSeconds(_ value: Double) -> String {
    String(format: "%.1f", value)
  }
}
