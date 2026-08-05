/// Judges a recorded §13 Phase 4 acceptance session (see
/// `aboutface-cli acceptance`) against §7.3's expected
/// escalate-then-stop-then-recover shape. Pure and synchronous — no I/O, no
/// real clock, no `FeedbackRouter` — so it is exactly as testable against a
/// hand-built `[AcceptanceEvent]` fixture as against a real 30-minute log.
///
/// ## Matching strategy: "first eligible occurrence after the previous rung"
///
/// For each of §7.3's four markers, in order, this scans the (assumed
/// chronologically ordered) event list for the first UNCONSUMED event of
/// the right kind whose `elapsedMs` is STRICTLY AFTER the previous rung's
/// own matched time (or, for rung 1, after an explicit `episodeStartMs` if
/// one was given) — see `Matcher.firstMatch(after:kind:)` below. An
/// occurrence that exists but falls at or before that cursor is invisible to
/// the search — it is never consumed, and therefore surfaces in
/// `AcceptanceReport.unexplainedEvents` instead of silently standing in for
/// a rung it arrived too early to be. This is what makes "events out of
/// order are not silently accepted" true structurally, rather than as a rule
/// this function has to remember to enforce case-by-case.
///
/// ## Why absolute timing is sometimes unverifiable
///
/// Rung 1's own "after the mode's delay" claim needs a reference point for
/// when the face-lost condition actually BEGAN — but this instrument has no
/// way to observe that directly (it only sees `FeedbackRouter`'s discrete
/// outputs, never `AnalysisEngine`'s raw per-frame signal, and even that
/// would only show the RAW loss, not the N-frame-confirmed one the ladder
/// timer actually starts from). A caller that knows the true onset (e.g. a
/// unit test constructing a synthetic episode) can supply it via
/// `Input.episodeStartMs`; a real recording of an unattended session cannot,
/// since nobody was watching when the user actually stood up. When it is
/// `nil`, this reconstructs a PRESUMED onset from rung 1's own observed time
/// minus its configured delay — good enough to check rungs 2 and 3's
/// RELATIVE spacing, but the report says explicitly that the value is
/// inferred, never presenting a guess with the same confidence as a
/// measurement (see `AcceptanceReport.referenceEpisodeStartIsInferred`).
public enum AcceptanceEvaluator {
  public struct Input: Sendable {
    /// The recorder's log. Assumed already in chronological order (a
    /// recorder appends as events happen); this does not re-sort it, so a
    /// caller handing in an unsorted array is itself exercising the
    /// out-of-order path, not a supported normal case.
    public var events: [AcceptanceEvent]
    public var feedbackConfig: FeedbackConfig
    /// `.monitor` for the real acceptance run (§5.2); a unit test MAY use
    /// `.setup` to exercise the mode-selected rung-1 delay.
    public var mode: FeedbackMode
    public var tolerances: AcceptanceTolerances
    /// See the type-level doc comment's "Why absolute timing is sometimes
    /// unverifiable" section. `nil` for a real recording.
    public var episodeStartMs: Int?

    public init(
      events: [AcceptanceEvent], feedbackConfig: FeedbackConfig, mode: FeedbackMode = .monitor,
      tolerances: AcceptanceTolerances, episodeStartMs: Int? = nil
    ) {
      self.events = events
      self.feedbackConfig = feedbackConfig
      self.mode = mode
      self.tolerances = tolerances
      self.episodeStartMs = episodeStartMs
    }
  }

  public static func evaluate(_ input: Input) -> AcceptanceReport {
    var matcher = Matcher(events: input.events)
    let delays = LadderDelays(feedbackConfig: input.feedbackConfig, mode: input.mode)

    let earcon = matcher.firstMatch(after: input.episodeStartMs, kind: .earcon)
    let reference = Self.resolveReferenceStart(
      episodeStartMs: input.episodeStartMs, earcon: earcon, earconDelayMs: delays.earconDelayMs)
    let rung1 = timedRungResult(
      rung: .earcon, match: earcon,
      expected: input.episodeStartMs.map { $0 + delays.earconDelayMs },
      toleranceMs: input.episodeStartMs != nil ? input.tolerances.rungTimingToleranceMs : nil)

    let spokenNoFace = matcher.firstMatch(
      after: earcon?.elapsedMs ?? input.episodeStartMs, kind: .spokenNoFace)
    let rung2 = timedRungResult(
      rung: .spokenNoFace, match: spokenNoFace,
      expected: reference.startMs.map { $0 + delays.speechDelayMs },
      toleranceMs: reference.startMs != nil ? input.tolerances.rungTimingToleranceMs : nil)

    // §7.3's rung 3 fires no sound (see `AcceptanceEvent.Kind.userLikelyAway`'s
    // doc comment), so its tolerance also absorbs the recorder's own poll
    // interval, on top of the ordinary rung slack.
    let stop = matcher.firstMatch(
      after: spokenNoFace?.elapsedMs ?? earcon?.elapsedMs ?? input.episodeStartMs, kind: .stop)
    let rung3ToleranceMs: Int? =
      reference.startMs != nil
      ? input.tolerances.rungTimingToleranceMs + input.tolerances.awayPollIntervalMs : nil
    let rung3 = timedRungResult(
      rung: .stop, match: stop, expected: reference.startMs.map { $0 + delays.stopDelayMs },
      toleranceMs: rung3ToleranceMs)

    let recoveryCursor = stop?.elapsedMs ?? spokenNoFace?.elapsedMs ?? earcon?.elapsedMs
    let recovery = matcher.firstMatch(after: recoveryCursor, kind: .recovery)
    // Non-consuming: a duplicate must still surface in `unexplainedEvents`
    // (the recovery rung's own note points there), not be swallowed here.
    let hasDuplicateRecovery =
      recovery != nil && matcher.peekMatch(after: recovery!.elapsedMs, kind: .recovery) != nil
    let rung4 = recoveryRungResult(match: recovery, duplicateFound: hasDuplicateRecovery)

    let unexplained = matcher.unconsumedEvents()
    let strayDuringStop = Self.strayRendererActivity(
      unexplained: unexplained, stopElapsedMs: stop?.elapsedMs,
      recoveryElapsedMs: recovery?.elapsedMs)

    return AcceptanceReport(
      rungs: [rung1, rung2, rung3, rung4],
      unexplainedEvents: unexplained,
      strayRendererActivityDuringStop: strayDuringStop,
      referenceEpisodeStartMs: reference.startMs,
      referenceEpisodeStartIsInferred: reference.isInferred)
  }

  /// The three §7.3-configured ladder delays, mode-selecting rung 1's the
  /// same way `FeedbackRouter.faceLostEarconDelayMs` does (see that computed
  /// property's own doc comment).
  private struct LadderDelays {
    let earconDelayMs: Int
    let speechDelayMs: Int
    let stopDelayMs: Int

    init(feedbackConfig: FeedbackConfig, mode: FeedbackMode) {
      earconDelayMs =
        mode == .setup
        ? feedbackConfig.faceLostEarconDelaySetupMs : feedbackConfig.faceLostEarconDelayMonitorMs
      speechDelayMs = feedbackConfig.faceLostSpeechDelayMs
      stopDelayMs = feedbackConfig.faceLostStopDelayMs
    }
  }

  private struct ReferenceStart {
    let startMs: Int?
    let isInferred: Bool
  }

  /// See the type-level doc comment's "Why absolute timing is sometimes
  /// unverifiable" section.
  private static func resolveReferenceStart(
    episodeStartMs: Int?, earcon: (index: Int, elapsedMs: Int)?, earconDelayMs: Int
  ) -> ReferenceStart {
    if let episodeStartMs {
      return ReferenceStart(startMs: episodeStartMs, isInferred: false)
    }
    if let earcon {
      return ReferenceStart(startMs: earcon.elapsedMs - earconDelayMs, isInferred: true)
    }
    return ReferenceStart(startMs: nil, isInferred: false)
  }

  /// §7.3: "Once `faceLostRung` reaches 3 ... nothing left to do on any
  /// later frame." Any RENDERER (audio/speech — `userLikelyAway` samples are
  /// silent bookkeeping, not sound) activity strictly between the STOP and
  /// recovery is evidence the silence was not actually total. When recovery
  /// was never found, the window stays open to the end of the log — an
  /// unattended session that never came back is exactly the case where any
  /// later noise matters most.
  private static func strayRendererActivity(
    unexplained: [AcceptanceEvent], stopElapsedMs: Int?, recoveryElapsedMs: Int?
  ) -> [AcceptanceEvent] {
    guard let stopElapsedMs else { return [] }
    let upperBoundMs = recoveryElapsedMs ?? Int.max
    return unexplained.filter { event in
      guard event.elapsedMs > stopElapsedMs, event.elapsedMs < upperBoundMs else { return false }
      switch event.kind {
      case .audioEvent, .spokenPhrase: return true
      case .userLikelyAway: return false
      }
    }
  }

  /// Builds one of the three TIMED rungs' result (earcon / spokenNoFace /
  /// stop) — `recoveryRungResult(match:duplicateFound:)` below handles
  /// `.recovery` separately since it has no fixed schedule to compare
  /// against.
  private static func timedRungResult(
    rung: AcceptanceReport.Rung, match: (index: Int, elapsedMs: Int)?, expected: Int?,
    toleranceMs: Int?
  ) -> AcceptanceReport.RungResult {
    guard let match else {
      return AcceptanceReport.RungResult(
        rung: rung, matched: false, observedElapsedMs: nil, expectedElapsedMs: expected,
        toleranceMs: toleranceMs,
        note: "missing: never observed (in the correct chronological position).")
    }
    guard let expected, let toleranceMs else {
      return AcceptanceReport.RungResult(
        rung: rung, matched: true, observedElapsedMs: match.elapsedMs, expectedElapsedMs: nil,
        toleranceMs: nil,
        note:
          "found at \(match.elapsedMs)ms; no reference episode start was available to check "
          + "absolute timing, so this is verified for order only, not schedule.")
    }
    let deviation = match.elapsedMs - expected
    let withinTolerance = abs(deviation) <= toleranceMs
    let scheduleNote =
      withinTolerance
      ? "on schedule" : "OFF SCHEDULE by \(deviation > 0 ? "+" : "")\(deviation)ms"
    return AcceptanceReport.RungResult(
      rung: rung, matched: withinTolerance, observedElapsedMs: match.elapsedMs,
      expectedElapsedMs: expected, toleranceMs: toleranceMs,
      note:
        "found at \(match.elapsedMs)ms, expected \(expected)ms ± \(toleranceMs)ms: \(scheduleNote)."
    )
  }

  private static func recoveryRungResult(
    match: (index: Int, elapsedMs: Int)?, duplicateFound: Bool
  ) -> AcceptanceReport.RungResult {
    guard let match else {
      return AcceptanceReport.RungResult(
        rung: .recovery, matched: false, observedElapsedMs: nil, expectedElapsedMs: nil,
        toleranceMs: nil,
        note:
          "missing: no faceReacquired observed after the STOP (in the correct chronological position)."
      )
    }
    if duplicateFound {
      return AcceptanceReport.RungResult(
        rung: .recovery, matched: false, observedElapsedMs: match.elapsedMs, expectedElapsedMs: nil,
        toleranceMs: nil,
        note:
          "found at \(match.elapsedMs)ms, but faceReacquired fired AGAIN afterward — expected "
          + "exactly once; see unexplainedEvents for the extra occurrence(s).")
    }
    return AcceptanceReport.RungResult(
      rung: .recovery, matched: true, observedElapsedMs: match.elapsedMs, expectedElapsedMs: nil,
      toleranceMs: nil, note: "found at \(match.elapsedMs)ms, exactly once, as expected.")
  }

}

/// Scans `AcceptanceEvaluator`'s input events for §7.3's four marker kinds,
/// tracking which INDICES have been consumed so the same event can never
/// satisfy two rungs and an out-of-order occurrence is simply invisible to a
/// later search (see `AcceptanceEvaluator`'s type-level doc comment's
/// matching-strategy section). File-scoped rather than nested inside
/// `AcceptanceEvaluator` purely so `MarkerKind` stays within SwiftLint's
/// one-level `nesting` limit — nesting it inside `AcceptanceEvaluator`
/// directly would already be one level deep, leaving no room for this type's
/// own nested enum.
private struct Matcher {
  enum MarkerKind {
    case earcon
    case spokenNoFace
    case stop
    case recovery
  }

  let events: [AcceptanceEvent]
  private var consumed: Set<Int> = []

  init(events: [AcceptanceEvent]) {
    self.events = events
  }

  // swift-format requires the brace on its own line after a wrapped
  // function signature; swiftlint's opening_brace rule disagrees. Format
  // wins (see FeedbackRouter.swift for the same disagreement).
  // swiftlint:disable opening_brace
  /// Finds and CONSUMES the first unconsumed, in-order match — the normal
  /// path for claiming one of the four canonical rung markers.
  mutating func firstMatch(after cursorMs: Int?, kind: MarkerKind) -> (index: Int, elapsedMs: Int)?
  {
    // swiftlint:enable opening_brace
    guard let found = locate(after: cursorMs, kind: kind) else { return nil }
    consumed.insert(found.index)
    return found
  }

  /// Same search, WITHOUT consuming — used only to detect a duplicate
  /// recovery event that must remain visible in `unexplainedEvents`.
  func peekMatch(after cursorMs: Int?, kind: MarkerKind) -> (index: Int, elapsedMs: Int)? {
    locate(after: cursorMs, kind: kind)
  }

  func unconsumedEvents() -> [AcceptanceEvent] {
    events.enumerated().filter { !consumed.contains($0.offset) }.map(\.element)
  }

  private func locate(after cursorMs: Int?, kind: MarkerKind) -> (index: Int, elapsedMs: Int)? {
    for (index, event) in events.enumerated() {
      guard !consumed.contains(index) else { continue }
      if let cursorMs, event.elapsedMs <= cursorMs { continue }
      guard Self.matches(event.kind, kind) else { continue }
      return (index, event.elapsedMs)
    }
    return nil
  }

  private static func matches(_ eventKind: AcceptanceEvent.Kind, _ marker: MarkerKind) -> Bool {
    switch (eventKind, marker) {
    case (.audioEvent(.faceLost), .earcon): return true
    case (.spokenPhrase(Lexicon.Instruction.noFace), .spokenNoFace): return true
    case (.userLikelyAway(true), .stop): return true
    case (.audioEvent(.faceReacquired), .recovery): return true
    default: return false
    }
  }
}
