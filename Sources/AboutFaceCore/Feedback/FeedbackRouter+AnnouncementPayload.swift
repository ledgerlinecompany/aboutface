/// `announcementPayload(for:output:centerStageActive:)` plus its
/// `framingInstruction(for:)` helper — split out of
/// `FeedbackRouter+Announcements.swift` once §12.5's `centerStageActive`
/// parameter and doc comment pushed that file past the point where adding a
/// third call site (`FeedbackRouter+FaceLost.swift`'s
/// `faceLostRecoveryPhrase(for:output:centerStageActive:)`, unchanged by
/// this split) would keep it comfortably under SwiftLint's `file_length`
/// ceiling. Same reasoning every other `FeedbackRouter+*.swift` split in
/// this codebase gives for its own: proactive, not a last-minute trim of
/// comments to fit. Everything here is still `FeedbackRouter`'s own
/// implementation, and both functions stay free of `self`/actor state —
/// pure classifiers over their explicit parameters, called from
/// `tickGenericDwell` (`FeedbackRouter+Announcements.swift`) and
/// `faceLostRecoveryPhrase` (`FeedbackRouter+FaceLost.swift`).
extension FeedbackRouter {
  /// The (`AudioEvent`, `Lexicon.Instruction`) pair for a dwell-fired
  /// condition. `.framingError` has no `AudioEvent` — its feedback in
  /// Monitor mode is entirely the continuous tone
  /// (`updateContinuousSonification`, not gated by dwell at all), so in
  /// Monitor mode a dwell-fired `.framingError` produces no renderer call
  /// whatsoever (`fire` no-ops when both `event` and `phrase` are `nil`;
  /// see `FeedbackRouter+Announcements.swift`). `.partiallyOutOfFrame`/
  /// `.lightingCritical` are unreachable this phase (their gates always
  /// return `false`) but are still listed for switch exhaustiveness and to
  /// mark where Phase 4 fills in a real payload. `.gazeOff`/`.headTilt` are
  /// ALSO unreachable here now (`FeedbackRouter.discreteState(for:)`
  /// excludes both from the ladder walk that produces a `.problem(condition)`
  /// in the first place — see their own doc comments); their real payloads
  /// live in `tickGoodZoneGaze(output:at:)`/`tickGoodZoneRoll(output:at:)`
  /// (`FeedbackRouter+GoodZoneAdvisories.swift`), the good-zone-internal
  /// advisories that replaced them. Kept here only for switch exhaustiveness.
  ///
  /// Not `private`: `FeedbackRouter+FaceLost.swift`'s
  /// `faceLostRecoveryPhrase(for:output:centerStageActive:)` calls this
  /// directly (§7.3 recovery: "the problem, if there is one" reuses this
  /// SAME payload resolution rather than a parallel classifier) — `private`
  /// in an extension is scoped to the extension body, not the whole type, so
  /// a cross-file caller needs at least `internal`, the implicit default
  /// here.
  ///
  /// `centerStageActive` is an explicit parameter, not read from `self`, on
  /// purpose (task brief: "Keep the method `static` and pass the flag in;
  /// do NOT convert it to an instance method") — both call sites already
  /// hold the router's current `centerStageActive` and pass it through,
  /// which keeps this classifier pure and independently testable against
  /// hand-picked flag values, the same reason it takes `output` as a
  /// parameter rather than reading `recentOutputs` itself.
  ///
  /// §12.5: "silently reporting a framing problem the OS is already
  /// correcting is worse than reporting nothing" — spoken framing
  /// suppresses under Center Stage exactly like the beacon does
  /// (`FeedbackRouter+Continuous.swift`), but ONLY `.framingError`'s phrase.
  /// Every other condition's payload is untouched: lighting
  /// (`.lowConfidence`), face-lost (`.noSignal`, and `.faceLost` itself,
  /// handled elsewhere), gaze/roll, and other-people all keep working
  /// normally, per the PR brief's maintainer decision #3 — "Center Stage
  /// re-aims the crop; it does not turn your head, light the room, or make
  /// you present."
  static func announcementPayload(
    for condition: FeedbackCondition,
    output: EngineOutput,
    centerStageActive: Bool
  ) -> (AudioEvent?, Lexicon.Phrase?) {
    switch condition {
    case .noSignal:
      return (.noSignal, Lexicon.Instruction.noSignal)
    case .faceLost:
      // Handled entirely by `tickFaceLostLadder`; never reaches here.
      return (nil, nil)
    case .partiallyOutOfFrame, .lightingCritical:
      return (nil, nil)
    case .lowConfidence:
      return (.lowConfidence, Lexicon.Instruction.tooDark)
    case .framingError:
      return (nil, centerStageActive ? nil : framingInstruction(for: output))
    case .gazeOff, .headTilt:
      // Unreachable — see the method doc comment above.
      return (nil, nil)
    }
  }

  /// Picks the single largest-magnitude framing error (horizontal,
  /// vertical, or distance) and returns its instruction phrase. §6.3:
  /// terse to the point of rude, "not 'you are currently positioned
  /// slightly to the left of frame center'" — one instruction per dwell
  /// episode, not a fused sentence describing every axis at once.
  ///
  /// Sign conventions from `FramingState.error`'s own doc comment: `x`
  /// positive = subject is RIGHT of target (correct by moving left);
  /// `y` positive = subject is ABOVE target (correct by moving down);
  /// `distanceError` positive = too close (correct by moving back).
  private static func framingInstruction(for output: EngineOutput) -> Lexicon.Phrase? {
    guard let framing = output.framing else { return nil }
    // swift-format wants a trailing comma on the last element of a
    // multiline collection literal; swiftlint's (default-on)
    // trailing_comma rule forbids one. Same tool disagreement noted
    // elsewhere in this codebase (see SignalFormatter.swift) — format
    // wins.
    // swiftlint:disable trailing_comma
    let candidates: [(magnitude: Float, phrase: Lexicon.Phrase)] = [
      (
        abs(framing.error.x),
        framing.error.x > 0 ? Lexicon.Instruction.left : Lexicon.Instruction.right
      ),
      (
        abs(framing.error.y),
        framing.error.y > 0 ? Lexicon.Instruction.down : Lexicon.Instruction.up
      ),
      (
        abs(framing.distanceError),
        framing.distanceError > 0 ? Lexicon.Instruction.back : Lexicon.Instruction.closer
      ),
    ]
    // swiftlint:enable trailing_comma
    return candidates.max(by: { $0.magnitude < $1.magnitude })?.phrase
  }
}
