/// §5.3 Query mode's pure aggregation logic: turns a burst of `EngineOutput`
/// (see `FeedbackRouter+Query.swift` for where the burst comes from) into a
/// fixed-order `Summary` of `Lexicon.State` phrases. Deliberately a free
/// function over a plain `[EngineOutput]` — no `FeedbackRouter` state, no
/// dwell/N-frame/rate-limit machinery, no async — so it is directly
/// unit-testable against hand-built bursts (`QueryComposerTests`) and so the
/// CLI's `replay --query-at` can exercise the exact same aggregation a real
/// hotkey press would.
///
/// ## Fixed field order (§5.3)
///
/// "Fixed field order, always: framing, lighting, gaze, other people. Not
/// 'most urgent first.'" `Summary.orderedPhrases` concatenates the four
/// fields in exactly that order — see its doc comment.
///
/// ## Aggregation, per field (§5.3: "aggregation... so one blink frame
/// can't lie")
///
/// - **Overall signal state** (gates which fields are even meaningful):
///   majority vote across the burst, four-way tie broken toward the more
///   severe state (`noSignal` > `noFace` > `lowConfidence` > `ok`) — safer
///   to over-report a problem than to let a tied vote mask one in a
///   one-shot summary the user cannot ask to re-check mid-utterance.
/// - **Framing** (in dead zone, and if not, which axis): `inDeadZone` is a
///   majority-of-problem vote (see `majorityIsProblem(_:)`); the reported
///   axis, when out of the zone, is picked from the MEDIAN of each burst
///   frame's `error.x`/`error.y`/`distanceError` (median, not mean: robust
///   to a single outlier frame the way §5.3's "one blink frame" language
///   asks for generally).
/// - **Lighting**: derived from the same overall signal-state vote —
///   `.lowConfidence` is §6.1's own "often = too dark" case, so there is no
///   separate lighting-severity classification to build for this round (see
///   `FeedbackCondition`'s own doc comment: rung 4, `.lightingCritical`, is
///   still an unwired stub with no threshold in `Config` yet).
/// - **Gaze** (merged with tilt this round — `FramingState.headLevel`):
///   `gazeOnCamera`/`headLevel` are each their own majority-of-problem vote,
///   independent of each other, so a burst can report EITHER, BOTH, or
///   NEITHER — see `Summary.gaze`'s doc comment for why this field can carry
///   up to two phrases where every other field carries at most one.
/// - **Other people**: majority-of-problem vote of `faceCount > 1` across
///   the whole burst (not just frames with `framing` — `faceCount` is
///   defined on every frame, including a stray `noFace` frame inside an
///   otherwise `.ok` burst, where it correctly contributes `0` → "no
///   evidence of others here").
///
/// See `majorityIsProblem(_:)` for the shared tie-breaking rule every
/// boolean vote above uses.
public enum QueryComposer {
  /// One Query answer, already split into `Lexicon.Phrase`s along §5.3's
  /// four fields. Each field is an array (not a single optional `Phrase`)
  /// because `gaze` can legitimately carry two independent phrases at once
  /// (gaze-off AND head-tilted) — see that field's own doc comment; every
  /// other field only ever holds zero or one.
  public struct Summary: Sendable, Equatable {
    public let framing: [Lexicon.Phrase]
    public let lighting: [Lexicon.Phrase]
    /// Merged gaze + tilt field (task brief: "Gaze field now covers tilt
    /// too"). Holds, independently: `Lexicon.State.gazeOff` if the burst's
    /// gaze-on-camera majority is "off," `Lexicon.State.headTilted` if the
    /// head-level majority is "not level" — both, either, or (outside
    /// `problemsOnly`) neither, in which case it instead holds the two
    /// "fine" phrases `gazeOn` + `headLevel` together, mirroring how a
    /// held tilt while otherwise well-placed is ALREADY treated as an
    /// independent advisory rather than a placement problem elsewhere in
    /// this codebase (see `FramingState.headLevel`'s own doc comment).
    public let gaze: [Lexicon.Phrase]
    public let otherPeople: [Lexicon.Phrase]

    public init(
      framing: [Lexicon.Phrase], lighting: [Lexicon.Phrase], gaze: [Lexicon.Phrase],
      otherPeople: [Lexicon.Phrase]
    ) {
      self.framing = framing
      self.lighting = lighting
      self.gaze = gaze
      self.otherPeople = otherPeople
    }

    /// The four fields concatenated in §5.3's fixed order — "framing,
    /// lighting, gaze, other people" — ready to hand to `Lexicon.compose(_:)`
    /// for a single spoken utterance, or to assert against directly in
    /// tests that want to pin the exact field order down.
    public var orderedPhrases: [Lexicon.Phrase] {
      framing + lighting + gaze + otherPeople
    }
  }

  // swift-format requires the brace on its own line after a wrapped
  // function signature; swiftlint's opening_brace rule disagrees. Format
  // wins (see FeedbackRouter.swift's `milliseconds(from:to:)` for the same
  // disagreement noted elsewhere in this codebase).
  // swiftlint:disable opening_brace
  /// Summarizes `burst` per this type's doc comment. Returns `nil` only when
  /// `burst` is empty — nothing has been analyzed yet to summarize (see
  /// `FeedbackRouter.performQuery(at:)`'s handling of that case).
  ///
  /// §12.5 `centerStageActive`: when `true`, the FRAMING field becomes
  /// `Lexicon.State.centerStageOn` instead of the ordinary
  /// `framingField(framings:problemsOnly:)` result — deliberately
  /// INCLUDING when `problemsOnly` is also `true`. Every other
  /// `problemsOnly` field is free to go silent when it's fine (that's the
  /// whole point of the variant), but framing is never merely "fine" here —
  /// it is being reported by a DIFFERENT system, and omitting the field
  /// entirely would read as "framing is fine," which is not the same claim
  /// and not one this app can back up while Center Stage owns the crop.
  /// Lighting/gaze/other-people are untouched — same PR-brief reasoning as
  /// `FeedbackRouter+Announcements.swift`'s `announcementPayload`: Center
  /// Stage re-aims the crop, it does not fix light, gaze, or headcount.
  /// This intentionally does NOT apply to the `.noSignal`/`.noFace`
  /// early-collapse above: with no face at all, "No face detected." is the
  /// honest answer regardless of Center Stage, so that branch returns
  /// before this parameter is ever consulted.
  ///
  /// Defaults to `false` so every pre-existing call site (`QueryComposerTests
  /// .swift`'s ~20 hand-built bursts, none of which exercise Center Stage
  /// at all) keeps compiling unchanged — this is an additive parameter for
  /// a genuinely new axis of behavior, not a revision of what the existing
  /// tests already pin down.
  public static func summarize(
    burst: [EngineOutput], problemsOnly: Bool, centerStageActive: Bool = false
  )
    -> Summary?
  {
    // swiftlint:enable opening_brace
    guard !burst.isEmpty else { return nil }

    let overallState = majoritySignalState(burst.map(\.analysis.signalState))

    // A frame-level problem (no face at all, or no signal whatsoever) makes
    // lighting/gaze/other-people unanswerable — there is no face to measure
    // any of them from — so the whole summary collapses to that one
    // problem, regardless of `problemsOnly` (it IS a problem, never a "fine"
    // field to omit). This mirrors §7.4's priority-ladder judgment that
    // these two states outrank everything else, applied here to Query's
    // fixed field order rather than to Monitor's single "announce only the
    // top one" rule.
    switch overallState {
    case .noSignal:
      return Summary(framing: [Lexicon.State.noSignal], lighting: [], gaze: [], otherPeople: [])
    case .noFace:
      return Summary(framing: [Lexicon.State.noFace], lighting: [], gaze: [], otherPeople: [])
    case .ok, .lowConfidence:
      break
    }

    let framings = burst.compactMap(\.framing)
    let framingPhrases =
      centerStageActive
      ? [Lexicon.State.centerStageOn]
      : framingField(framings: framings, problemsOnly: problemsOnly)
    let summary = Summary(
      framing: framingPhrases,
      lighting: lightingField(
        isLowConfidence: overallState == .lowConfidence, problemsOnly: problemsOnly),
      gaze: gazeField(framings: framings, problemsOnly: problemsOnly),
      otherPeople: otherPeopleField(burst: burst, problemsOnly: problemsOnly)
    )

    // §6.1's silence-ambiguity principle, applied to Query: a `problemsOnly`
    // summary that finds literally nothing wrong must still say SOMETHING,
    // or an explicit hotkey press produces total silence indistinguishable
    // from the hotkey not having registered at all. Not spec-mandated text
    // (§5.3 doesn't address this case), but the smallest fix consistent
    // with §6.1's own reasoning applied one level up.
    guard problemsOnly, summary.orderedPhrases.isEmpty else { return summary }
    return Summary(framing: [Lexicon.State.allClear], lighting: [], gaze: [], otherPeople: [])
  }

  // MARK: - Per-field aggregation

  // swift-format requires the brace on its own line after a wrapped
  // function signature; swiftlint's opening_brace rule disagrees. Format
  // wins (see FeedbackRouter.swift's `milliseconds(from:to:)` for the same
  // disagreement noted elsewhere in this codebase).
  // swiftlint:disable opening_brace
  private static func framingField(framings: [FramingState], problemsOnly: Bool) -> [Lexicon.Phrase]
  {
    // swiftlint:enable opening_brace
    guard !framings.isEmpty else { return [] }
    let notInZone = majorityIsProblem(framings.map { !$0.inDeadZone })
    guard notInZone else {
      return problemsOnly ? [] : [Lexicon.State.centered]
    }

    let medianX = median(framings.map { $0.error.x })
    let medianY = median(framings.map { $0.error.y })
    let medianDistance = median(framings.map(\.distanceError))

    // Sign conventions from `FramingState.error`'s own doc comment: `x`
    // positive = subject RIGHT of target; `y` positive = subject ABOVE
    // target; `distanceError` positive = too close. The State register
    // describes where the user IS (not how to correct it, unlike
    // `FeedbackRouter+Announcements.swift`'s `framingInstruction`), so the
    // mapping below is the direct, non-inverted reading of each sign.
    // swiftlint:disable trailing_comma
    let candidates: [(magnitude: Float, phrase: Lexicon.Phrase)] = [
      (abs(medianX), medianX > 0 ? Lexicon.State.right : Lexicon.State.left),
      (abs(medianY), medianY > 0 ? Lexicon.State.high : Lexicon.State.low),
      (abs(medianDistance), medianDistance > 0 ? Lexicon.State.close : Lexicon.State.far),
    ]
    // swiftlint:enable trailing_comma
    guard let picked = candidates.max(by: { $0.magnitude < $1.magnitude }) else { return [] }
    return [picked.phrase]
  }

  private static func lightingField(isLowConfidence: Bool, problemsOnly: Bool) -> [Lexicon.Phrase] {
    if isLowConfidence { return [Lexicon.State.tooDark] }
    return problemsOnly ? [] : [Lexicon.State.lightingFine]
  }

  private static func gazeField(framings: [FramingState], problemsOnly: Bool) -> [Lexicon.Phrase] {
    guard !framings.isEmpty else { return [] }
    let gazeOffMajority = majorityIsProblem(framings.map { !$0.gazeOnCamera })
    let headTiltMajority = majorityIsProblem(framings.map { !$0.headLevel })

    var phrases: [Lexicon.Phrase] = []
    if gazeOffMajority { phrases.append(Lexicon.State.gazeOff) }
    if headTiltMajority { phrases.append(Lexicon.State.headTilted) }

    guard phrases.isEmpty else { return phrases }
    return problemsOnly ? [] : [Lexicon.State.gazeOn, Lexicon.State.headLevel]
  }

  // swiftlint:disable opening_brace
  private static func otherPeopleField(burst: [EngineOutput], problemsOnly: Bool) -> [Lexicon
    .Phrase]
  {
    // swiftlint:enable opening_brace
    let othersPresent = majorityIsProblem(burst.map { $0.analysis.faceCount > 1 })
    if othersPresent { return [Lexicon.State.otherPeoplePresent] }
    return problemsOnly ? [] : [Lexicon.State.otherPeopleNone]
  }

  // MARK: - Shared aggregation primitives

  /// Majority vote over a burst of per-frame "is this a problem" booleans,
  /// TIE-BROKEN TOWARD `true` (report the problem): safer to over-report
  /// than to let an exact split (a real possibility at the default 10-frame
  /// burst size) silently suppress something. Every call site above passes
  /// an array already phrased as "is a problem," specifically so this one
  /// rule can be applied uniformly regardless of which underlying signal's
  /// polarity happens to mean "good."
  static func majorityIsProblem(_ problemFlags: [Bool]) -> Bool {
    guard !problemFlags.isEmpty else { return false }
    let problemCount = problemFlags.lazy.filter { $0 }.count
    return problemCount * 2 >= problemFlags.count
  }

  /// Four-way majority vote over the burst's `SignalState`s, tie-broken
  /// toward the more severe state (§7.4-style severity ordering) — see the
  /// type-level doc comment's "Overall signal state" bullet.
  static func majoritySignalState(_ states: [SignalState]) -> SignalState {
    var counts: [SignalState: Int] = [:]
    for state in states { counts[state, default: 0] += 1 }
    let maxCount = counts.values.max() ?? 0
    let severityOrder: [SignalState] = [.noSignal, .noFace, .lowConfidence, .ok]
    // `states` is non-empty (guarded by the only caller), so `counts` is
    // non-empty and some state in `severityOrder` always matches `maxCount`
    // — `.ok` is only a defensive fallback for an unreachable empty input.
    return severityOrder.first { counts[$0] == maxCount } ?? .ok
  }

  /// Standard median (average of the two middle elements on an even count).
  /// Returns `0` for an empty input — only ever called with a non-empty
  /// `framings` array by this file's own call sites (guarded above), so
  /// `0` is a defensive fallback, never a real answer.
  static func median(_ values: [Float]) -> Float {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let mid = sorted.count / 2
    if sorted.count.isMultiple(of: 2) {
      return (sorted[mid - 1] + sorted[mid]) / 2
    }
    return sorted[mid]
  }
}
