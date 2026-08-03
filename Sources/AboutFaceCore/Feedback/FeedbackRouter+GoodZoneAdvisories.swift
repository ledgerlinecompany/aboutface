/// The two in-zone advisory sub-machines that run from WITHIN a confirmed
/// `.goodZone` episode: gaze-off (§7.4 rung 6's redesign) and its roll
/// sibling (§4 extension, "Agreed, it's part of gaze"). Split out of
/// `FeedbackRouter+Announcements.swift` purely to keep each file a
/// manageable size (SwiftLint's `file_length`), same reasoning
/// `AnalysisEngine`'s file split uses; everything here is still
/// `FeedbackRouter`'s own implementation, called exclusively from
/// `tickGoodZone(output:from:at:)` in that file.
extension FeedbackRouter {
  /// §7.4 rung 6, redesigned (app field finding, 2026-08-02 — see
  /// `FeedbackCondition.gazeOff`'s doc comment for the full story): gaze is
  /// no longer part of `.goodZone` classification, so it cannot block the
  /// `enteredGoodZone` earcon. Instead, once already inside a confirmed
  /// good-zone episode (only ever called from `tickGoodZone` after its own
  /// entry dwell has fired — see that method's doc comment for the ordering
  /// guarantee), this tracks `!framing.gazeOnCamera` — `Gates.evaluate(
  /// .gazeOff, output:)`'s new, simpler meaning — through the SAME
  /// two-stage discipline every other condition gets:
  ///
  /// 1. **§7.2 N-frame filter** (`nFrameThreshold`, mode-selected): a raw
  ///    gaze-off reading must hold for this many CONSECUTIVE frames before
  ///    it is "confirmed," so a blink or a momentary glance at a second
  ///    screen triggers nothing.
  /// 2. **§7.1 800ms dwell** (`Config.dwellMs`), timed from the
  ///    CONFIRMATION frame (matching `FeedbackRouterNFrameTests`' documented
  ///    idiom for the top-level pipeline, reused here rather than
  ///    reinvented).
  ///
  /// Once both are satisfied, speaks `Lexicon.Instruction.lookAtCamera` at
  /// most once per good-zone episode (`gazeAnnouncedForEpisode`, reset on
  /// zone exit by `onConfirmedStateChanged`) — subject to the mode's rate
  /// limits like any other dwell-fired announcement (`fire` is called
  /// WITHOUT `bypassRateLimit`, unlike the heartbeat/face-lost-ladder/
  /// face-reacquired call sites). No `AudioEvent`: gaze has no earcon
  /// (`Lexicon.swift`'s "tones never mean look" contract), so — mirroring
  /// every other condition's `mode == .setup ? instruction : nil` shape in
  /// `tickGenericDwell` — Monitor mode's phrase resolves to `nil` and this
  /// call is a no-op there (§5.2: earcons only by default).
  ///
  /// A single frame reporting gaze back on camera resets BOTH stages
  /// immediately, no N-frame grace period on the way back: this is an
  /// advisory nested inside an already-good state, not a competing
  /// top-level condition, so there is no risk of a recovered glance being
  /// mistaken for a still-open problem the way a blip could confuse the
  /// exclusive ladder above.
  func tickGoodZoneGaze(output: EngineOutput, at time: ContinuousClock.Instant) async {
    guard !gazeAnnouncedForEpisode else { return }

    guard Gates.evaluate(.gazeOff, output: output) else {
      gazeOffPendingStreak = 0
      gazeOffConfirmedStart = nil
      return
    }

    gazeOffPendingStreak += 1
    guard let confirmedStart = gazeOffConfirmedStart else {
      guard gazeOffPendingStreak >= nFrameThreshold else { return }
      gazeOffConfirmedStart = time
      return
    }

    let elapsedMs = Self.milliseconds(from: confirmedStart, to: time)
    guard elapsedMs >= config.dwellMs else { return }
    gazeAnnouncedForEpisode = true
    let phrase: Lexicon.Phrase? = mode == .setup ? Lexicon.Instruction.lookAtCamera : nil
    await fire(event: nil, phrase: phrase, key: .condition(.gazeOff), at: time)
  }

  /// §4 extension, roll joins the gaze advisory (maintainer, 2026-08-02:
  /// "Agreed, it's part of gaze"): structurally identical to
  /// `tickGoodZoneGaze` immediately above, tracking
  /// `FramingState.headLevel` instead of `gazeOnCamera` and its own,
  /// entirely separate streak/dwell/latch state
  /// (`headTiltPendingStreak`/`headTiltConfirmedStart`/
  /// `headTiltAnnouncedForEpisode`). Head tilt is a POSE problem, not a
  /// placement one — `AnalysisEngine+Framing.swift` deliberately keeps
  /// `headLevel` out of `inDeadZone` (the beacon has no rotational axis to
  /// guide a tilt correction with), so, like gaze, this can only ever run
  /// from WITHIN an already-confirmed `.goodZone` episode (only ever called
  /// from `tickGoodZone`, after its own entry dwell has fired), never block
  /// `enteredGoodZone`.
  ///
  /// Same two-stage discipline as `tickGoodZoneGaze`:
  ///
  /// 1. §7.2 N-frame filter (`nFrameThreshold`, mode-selected).
  /// 2. §7.1 800ms dwell (`Config.dwellMs`), timed from the confirmation
  ///    frame.
  ///
  /// Once both are satisfied, speaks `Lexicon.Instruction.level` at most
  /// once per good-zone episode (reset on zone exit by
  /// `onConfirmedStateChanged`), Setup-mode only (`mode == .setup ? ... :
  /// nil`, same shape as every other condition), subject to the mode's
  /// rate limits like any other dwell-fired announcement (`fire` is called
  /// WITHOUT `bypassRateLimit`). No `AudioEvent` — same "tones never mean
  /// look/tilt" contract `tickGoodZoneGaze` already keeps.
  ///
  /// **Independent of `tickGoodZoneGaze`, not sequenced against it:** both
  /// run every frame `tickGoodZone` reaches this stage, so if gaze and
  /// roll are BOTH pending at once, whichever's own N-frame+dwell timer
  /// completes first speaks first — there is no priority between them,
  /// only whichever confirms sooner. In Monitor mode neither ever speaks
  /// (`phrase` resolves to `nil` there, and there is no `AudioEvent`), so
  /// the rate limit never actually has to arbitrate a collision in
  /// practice; it is consulted (via `fire`) for parity with every other
  /// dwell-fired condition regardless.
  ///
  /// A single frame reporting the head level again resets BOTH stages
  /// immediately, no N-frame grace period on the way back — same reasoning
  /// as `tickGoodZoneGaze`'s own recovery-is-instant design.
  func tickGoodZoneRoll(output: EngineOutput, at time: ContinuousClock.Instant) async {
    guard !headTiltAnnouncedForEpisode else { return }

    guard Gates.evaluate(.headTilt, output: output) else {
      headTiltPendingStreak = 0
      headTiltConfirmedStart = nil
      return
    }

    headTiltPendingStreak += 1
    guard let confirmedStart = headTiltConfirmedStart else {
      guard headTiltPendingStreak >= nFrameThreshold else { return }
      headTiltConfirmedStart = time
      return
    }

    let elapsedMs = Self.milliseconds(from: confirmedStart, to: time)
    guard elapsedMs >= config.dwellMs else { return }
    headTiltAnnouncedForEpisode = true
    let phrase: Lexicon.Phrase? = mode == .setup ? Lexicon.Instruction.level : nil
    await fire(event: nil, phrase: phrase, key: .condition(.headTilt), at: time)
  }
}
