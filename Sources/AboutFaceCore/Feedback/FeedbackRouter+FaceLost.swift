/// §7.3's face-lost escalation ladder in full — all four rungs (0 nothing,
/// 1 the earcon, 2 the spoken "No face.", 3 the STOP) — plus the recovery
/// phrase resolution used when an episode that reached rung 3 ends. Split
/// out of `FeedbackRouter+Announcements.swift` once Phase 4 grew this past
/// rung 1: that file was already close to SwiftLint's `file_length` ceiling
/// (§13 Phase 3 shipped only rungs 0–1 there), same reasoning
/// `FeedbackRouter+GoodZoneAdvisories.swift` gives for its own split.
/// Everything here is still `FeedbackRouter`'s own implementation.
///
/// `tickFaceLostLadder(from:at:)` is called exclusively from
/// `tickAnnouncements(output:at:)`'s `.problem(.faceLost)` case
/// (`FeedbackRouter+Announcements.swift`); `faceLostRecoveryPhrase(for:
/// output:)` is called exclusively from `onConfirmedStateChanged`'s own
/// `.problem(.faceLost)` reacquisition branch in that same file. Neither is
/// `private` for exactly that reason — `private` on a member declared
/// inside an `extension` is scoped to that extension's lexical body, not
/// the whole type, so a cross-file caller within the same conformance needs
/// at least `internal` (the implicit default used here).
extension FeedbackRouter {
  /// §7.3 face-lost escalation ladder: "A single aggressive alert is either
  /// too slow or too jumpy. Escalate." `elapsedMs` is measured once, from
  /// `confirmedStateStart` (the frame the CURRENT face-lost episode was
  /// N-frame-confirmed, per `FeedbackRouter.ingest(_:at:)`) to `time` (the
  /// frame under evaluation right now) — every rung below reads the exact
  /// same clock, so a rung can never see a smaller elapsed time than the
  /// one before it already required.
  ///
  /// - **Rung 1** (`faceLostEarconDelayMs`, MODE-SELECTED — 500ms Setup /
  ///   1500ms Monitor defaults; see that computed property's doc comment
  ///   for the app field finding that split it): a distinct, non-positional
  ///   earcon (`AudioEvent.faceLost`).
  /// - **Rung 2** (`feedbackConfig.faceLostSpeechDelayMs`, ~5s default):
  ///   spoken "No face." (`Lexicon.Instruction.noFace`). §5.2 carves out
  ///   "earcons only by default [in Monitor]... except face-lost which
  ///   escalates to speech" as a named exception — this is that exception,
  ///   so unlike every OTHER dwell-fired phrase in this codebase
  ///   (`tickGenericDwell`, `tickGoodZoneGaze`, `tickGoodZoneRoll`, all of
  ///   which resolve `mode == .setup ? phrase : nil`), the phrase here is
  ///   NOT gated on `mode` at all — it speaks in both. It IS gated on
  ///   `feedbackConfig.faceLostSpeechEnabled` (maintainer decision,
  ///   2026-08-03: "speak and earcon by default, but turning off the
  ///   speech is a choice on both sides" — see that field's own doc
  ///   comment): `false` resolves the phrase to `nil` while the rung
  ///   TRANSITION still happens on schedule, so `faceLostRung` still
  ///   advances to 2 and rung 3 stays reachable. The toggle changes what
  ///   you hear, never the state machine.
  /// - **Rung 3** (`feedbackConfig.faceLostStopDelayMs`, ~30s default): "the
  ///   requirement an implementer will forget." Sets `userLikelyAway` and
  ///   fires NOTHING — no earcon, no phrase, not even a distinct "going
  ///   quiet now" cue, because §7.3 is explicit that the failure mode this
  ///   guards against is a tool that keeps making noise at an empty desk;
  ///   any sound at all on the way into rung 3 would be exactly that. Once
  ///   `faceLostRung` reaches 3 this method has nothing left to do on any
  ///   later frame — `userLikelyAway` (set once, here) plus `fire`'s and
  ///   `updateContinuousSonification`'s own blanket guards on it are what
  ///   keep the silence total from here on, not a repeated no-op check in
  ///   this method.
  ///
  /// Every rung transition bypasses the §5.2 Monitor rate limit
  /// deliberately: §7.3 frames BOTH the escalation and the 30s stop as
  /// safety-critical behavior ("a tool that nags at an empty chair... gets
  /// uninstalled" cuts both ways — silence must be exactly as reliable as
  /// the alert was), so no face-lost rung may ever be silently dropped
  /// because an unrelated condition just consumed the rate-limit budget,
  /// and the STOP itself cannot be a "maybe" gated on a budget it doesn't
  /// even consume (rung 3 fires no announcement to rate-limit).
  func tickFaceLostLadder(
    from start: ContinuousClock.Instant, at time: ContinuousClock.Instant
  ) async {
    let elapsedMs = Self.milliseconds(from: start, to: time)

    if faceLostRung < 1 {
      guard elapsedMs >= faceLostEarconDelayMs else { return }
      faceLostRung = 1
      await fire(event: .faceLost, phrase: nil, key: nil, at: time, bypassRateLimit: true)
      return
    }

    if faceLostRung == 1 {
      guard elapsedMs >= feedbackConfig.faceLostSpeechDelayMs else { return }
      faceLostRung = 2
      // The rung transition above happens unconditionally; only the PHRASE
      // is gated on the toggle. `fire` already no-ops when both `event`
      // and `phrase` are `nil`, so `faceLostSpeechEnabled == false` makes
      // this call produce zero renderer calls while `faceLostRung` still
      // advanced — rung 3 stays reachable exactly as if speech were on.
      let phrase = feedbackConfig.faceLostSpeechEnabled ? Lexicon.Instruction.noFace : nil
      await fire(event: nil, phrase: phrase, key: nil, at: time, bypassRateLimit: true)
      return
    }

    if faceLostRung == 2 {
      guard elapsedMs >= feedbackConfig.faceLostStopDelayMs else { return }
      faceLostRung = 3
      userLikelyAway = true
      return
    }

    // faceLostRung == 3: rung 3 already fired (silently) on an earlier
    // frame. Nothing to evaluate, nothing to fire — see the method doc
    // comment above for why the silence from here on is guaranteed
    // elsewhere (`userLikelyAway`), not by an ever-growing set of guards in
    // this function.
  }

  // swift-format requires the brace on its own line after a wrapped
  // function signature; swiftlint's opening_brace rule disagrees. Format
  // wins (see FeedbackRouter.swift for the same disagreement).
  // swiftlint:disable opening_brace
  /// §7.3 recovery: "On face reacquisition while `userLikelyAway`: announce
  /// recovery once ('Back, centered' — or the problem, if there is one)."
  /// `next` is the `DiscreteState` the router just confirmed on the
  /// reacquisition frame (already computed by
  /// `FeedbackRouter.discreteState(for:)` before `onConfirmedStateChanged`
  /// runs); `output` is that same frame's `EngineOutput`, needed only for
  /// the `.problem` branch below.
  ///
  /// Deliberately reuses `announcementPayload(for:output:)` — the SAME
  /// function `tickGenericDwell` calls for an ordinary dwell-fired
  /// announcement — rather than a parallel "what does this problem sound
  /// like" switch: the spec's "or the problem, if there is one" is
  /// describing the SAME instruction vocabulary a live episode of that
  /// problem would already speak, not a distinct recovery-specific phrase
  /// per condition, and keeping one function as the source of truth means
  /// the two can never drift apart (e.g. `Instruction.left`/`.right`'s sign
  /// convention changing in one place and not the other).
  static func faceLostRecoveryPhrase(for next: DiscreteState, output: EngineOutput)
    -> Lexicon.Phrase?
  {
    // swiftlint:enable opening_brace
    switch next {
    case .goodZone:
      return Lexicon.Instruction.recovered
    case .problem(let condition):
      return announcementPayload(for: condition, output: output).1
    case .indeterminate:
      // Defensive fallback only (see `FeedbackRouter.discreteState(for:)`'s
      // own doc comment on when `.indeterminate` is even reachable — a
      // contract violation by `AnalysisEngine`, not a real user state).
      // Neither "Back, centered" nor a specific problem instruction is
      // honest here, so this stays silent rather than guess.
      return nil
    }
  }

  /// Called from `onConfirmedStateChanged` (`FeedbackRouter+Announcements
  /// .swift`) on EVERY confirmed-state transition — a no-op unless
  /// `previous` was face-lost. Split out into its own function (rather than
  /// left inline in `onConfirmedStateChanged`) for the same reason the rest
  /// of this file exists: it is the face-lost ladder's own bookkeeping, and
  /// keeping it here alongside `tickFaceLostLadder`/`faceLostRecoveryPhrase`
  /// means the whole §7.3 lifecycle — escalate, STOP, recover — lives in
  /// one file instead of split across two.
  ///
  /// §7.3: "On face reacquisition... announce recovery once." Recovery
  /// fires whenever the ladder had escalated at least to the rung-1 earcon
  /// before reacquisition — a face-lost episode that never reached rung 1
  /// (reacquired inside the grace window) is, by §7.3's own design, meant
  /// to be inaudible in both directions: nothing on the way down, nothing
  /// on the way back up (see `briefLossBeforeEarconIsSilentBothWays` in
  /// `FeedbackRouterFaceLostTests.swift`).
  func handleFaceLostReacquisition(
    from previous: DiscreteState?,
    to next: DiscreteState,
    output: EngineOutput,
    at time: ContinuousClock.Instant
  ) async {
    guard case .problem(.faceLost) = previous, next != previous else { return }

    let hadEscalated = faceLostRung >= 1
    // Rung 3 ("STOP") is a STRICT superset of "escalated" — it can only be
    // reached after passing through rungs 1 and 2 — so `wasAway` implies
    // `hadEscalated` and this branch never has to reconcile the two
    // independently. Captured BEFORE the unconditional clear two lines
    // down, since that's what decides whether to speak a recovery phrase.
    let wasAway = userLikelyAway
    faceLostRung = 0
    // Clear UNCONDITIONALLY, not only inside `if wasAway` below. The
    // `wasAway` implication above is an invariant held by ARGUMENT, not by
    // the type system — if it is ever wrong (a future edit to the ladder, a
    // bug elsewhere), leaving this clear gated on `wasAway` would mean the
    // router goes permanently, silently mute with no path back to sound,
    // ever. Clearing it a frame too eagerly costs nothing (it is already
    // `false` in the overwhelmingly common case); not clearing it costs
    // total loss of function. Belt-and-braces against the worse failure,
    // structurally rather than by reasoning.
    userLikelyAway = false

    // For an episode that escalated only to rung 1 or 2, today's behavior
    // is unchanged: the earcon alone, no speech (`recoveryPhrase` stays
    // `nil`). Only an episode that reached rung 3 gets the §7.3 spoken
    // recovery ("Back, centered" — or the live problem, if there is one)
    // layered onto the SAME `fire` call, so "announce recovery once" is
    // structural (one call site) rather than a rule callers have to
    // remember to honor. `if hadEscalated` (not `guard ... else return`) on
    // purpose: this is a decision scoped to the face-lost reacquisition
    // branch, not to the whole function — a `return` here would also skip
    // any bookkeeping a LATER block in this method acquires in the future,
    // silently, on every non-escalated reacquisition. Nothing else follows
    // this block today, but the scope of the decision should match the
    // scope of its effect regardless of what "today" happens to be true.
    if hadEscalated {
      var recoveryPhrase: Lexicon.Phrase?
      // `wasAway` gates whether recovery HAS a phrase to speak at all
      // (rung 1/2-only episodes never do); `faceLostRecoverySpeechEnabled`
      // (maintainer decision, 2026-08-03 — see that field's own doc
      // comment) then independently gates whether it's ACTUALLY spoken.
      // Neither gate touches the `.faceReacquired` earcon below or the
      // unconditional clear above: "both sides" of the toggle govern
      // speech only, never the state machine or the exit from silence.
      if wasAway, feedbackConfig.faceLostRecoverySpeechEnabled {
        recoveryPhrase = Self.faceLostRecoveryPhrase(for: next, output: output)
      }
      // §5.2's Monitor earcon-only default does NOT gate `recoveryPhrase`
      // here — same carve-out §7.3 already gives rung 2's "No face.": both
      // are safety-relevant enough to speak in either mode. Bypasses the
      // rate limit for the same reason every other ladder firing does (see
      // `tickFaceLostLadder`'s doc comment above).
      await fire(
        event: .faceReacquired, phrase: recoveryPhrase, key: nil, at: time, bypassRateLimit: true)
    }
  }
}
