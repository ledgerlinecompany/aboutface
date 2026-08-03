/// Turns a confirmed `DiscreteState` (§7.2's N-frame filter has already
/// run by the time anything here executes — see `FeedbackRouter.ingest(_:
/// at:)`) into §7's dwell/ladder-gated announcements. Split out of
/// `FeedbackRouter.swift` purely to keep each file a manageable size, same
/// reasoning as `AnalysisEngine`'s file split; everything here is still
/// `FeedbackRouter`'s own implementation.
extension FeedbackRouter {
  /// Rate-limit + announcement-identity key. `AudioEvent`-only firings that
  /// are exempt from rate limiting (heartbeat, face-lost ladder rungs,
  /// face-reacquired — see `fire(event:phrase:key:at:bypassRateLimit:)`)
  /// still pass one of these for clarity/future use even though the
  /// bypassed path never consults `lastAnnouncementAtByCondition` for them.
  enum AnnouncementKey: Hashable, Sendable {
    case condition(FeedbackCondition)
    case goodZoneEntered
  }

  /// Called exactly once, on the frame where `confirmedState` actually
  /// changes (after §7.2's N-frame confirmation) — never on every frame
  /// that merely continues to match the current `confirmedState`. Resets
  /// the per-episode "already fired" bookkeeping so a brand new confirmed
  /// episode always gets its own fresh dwell window, and handles the two
  /// state-exit side effects that don't belong inside `tickAnnouncements`:
  /// canceling the good-zone heartbeat schedule, and firing the §7.3
  /// face-reacquired recovery event.
  func onConfirmedStateChanged(
    from previous: DiscreteState?,
    to next: DiscreteState,
    at time: ContinuousClock.Instant
  ) async {
    dwellFiredForCurrentEpisode = false

    if case .goodZone = previous, next != .goodZone {
      goodZoneConfirmedAt = nil
      nextHeartbeatAt = nil
      // Tuning round 5 gaze trim: reset the deviation EMA so a later
      // placement never inherits a stale trend from this episode — see
      // `FeedbackRouter.smoothedYawDeviationDegrees`'s doc comment.
      smoothedYawDeviationDegrees = nil
      smoothedPitchDeviationDegrees = nil
      // §7.4 rung 6 gaze-off-in-good-zone advisory: reset its N-frame +
      // dwell tracking and "already announced" latch so the NEXT good-zone
      // episode always gets a fresh gaze-off announcement opportunity,
      // never inheriting a stale streak/latch from this one — see
      // `FeedbackRouter.gazeOffPendingStreak`'s doc comment.
      gazeOffPendingStreak = 0
      gazeOffConfirmedStart = nil
      gazeAnnouncedForEpisode = false
    }

    if case .problem(.faceLost) = previous, next != previous {
      // §7.3: "On face reacquisition... announce recovery once." Phase 3
      // only models rungs 0–1 (nothing, then the 1.5s earcon) — there is no
      // `userLikelyAway` flag yet to gate this on (that lands with rungs
      // 2–3 in Phase 4), so the Phase-3-scoped rule is: recovery fires
      // whenever the ladder had escalated at least to the earcon (rung 1)
      // before reacquisition. A face-lost episode that never reached rung 1
      // (reacquired inside the 1.5s grace window) is, by §7.3's own design,
      // meant to be inaudible in both directions — nothing on the way down,
      // nothing on the way back up.
      let hadEscalated = faceLostRung >= 1
      faceLostRung = 0
      if hadEscalated {
        await fire(event: .faceReacquired, phrase: nil, key: nil, at: time, bypassRateLimit: true)
      }
    }
  }

  /// Checks the CURRENT `confirmedState` against its elapsed-time timers
  /// every frame (not just on change) and fires whatever timer has come
  /// due. Three shapes, one per `DiscreteState` case:
  func tickAnnouncements(output: EngineOutput, at time: ContinuousClock.Instant) async {
    guard let confirmedState, let confirmedStateStart else { return }

    switch confirmedState {
    case .problem(.faceLost):
      await tickFaceLostLadder(from: confirmedStateStart, at: time)

    case .goodZone:
      await tickGoodZone(output: output, from: confirmedStateStart, at: time)

    case .problem(let condition):
      await tickGenericDwell(
        condition: condition, output: output, from: confirmedStateStart, at: time)

    case .indeterminate:
      break
    }
  }

  /// §7.3 face-lost escalation ladder. Phase 3 ships rung 0 (nothing) and
  /// rung 1 (a distinct, non-positional earcon), at a MODE-SELECTED delay —
  /// `FeedbackRouter.faceLostEarconDelayMs` (500ms Setup / 1500ms Monitor
  /// defaults — see that property's doc comment for the app field finding
  /// that split it). `feedbackConfig.faceLostSpeechDelayMs` (rung 2, ~5s,
  /// spoken "No face.") and `faceLostStopDelayMs` (rung 3, ~30s, STOP +
  /// `userLikelyAway`) are reserved config fields already — Phase 4 adds
  /// `faceLostRung == 1 && elapsed >= faceLostSpeechDelayMs` and
  /// `faceLostRung == 2 && elapsed >= faceLostStopDelayMs` cases right
  /// here, each bumping `faceLostRung` the same way rung 1 does below.
  ///
  /// Bypasses the §5.2 Monitor rate limit deliberately: §5.2 carves out
  /// "earcons only by default... except face-lost which escalates to
  /// speech" as a special case, and §7.3 frames the 30s stop as a
  /// safety-critical behavior ("a tool that nags at an empty chair... gets
  /// uninstalled" cuts both ways — silence must be equally reliable). A
  /// face-lost rung must never be silently dropped by an unrelated
  /// condition having just consumed the rate-limit budget.
  private func tickFaceLostLadder(
    from start: ContinuousClock.Instant, at time: ContinuousClock.Instant
  ) async {
    guard faceLostRung < 1 else { return }
    let elapsedMs = Self.milliseconds(from: start, to: time)
    guard elapsedMs >= faceLostEarconDelayMs else { return }
    faceLostRung = 1
    await fire(event: .faceLost, phrase: nil, key: nil, at: time, bypassRateLimit: true)
  }

  // swiftlint:disable opening_brace
  /// §6.1 good-zone handling: the `.enteredGoodZone` confirmation fires at
  /// N-frame-confirmed zone entry plus `goodZoneChimeDelayMs` (default 0 —
  /// see that field's doc comment for the atomic-arrival rationale; the
  /// continuous beacon keeps playing until this fires, so the cut and the
  /// chime land together), then — on every later frame this episode — the
  /// gaze-off advisory (`tickGoodZoneGaze`) and the 7s-cadence liveness
  /// heartbeat, both independent of each other. Setup mode additionally
  /// speaks `Lexicon.Instruction.centered` on entry (§5.1: Setup speaks
  /// instructions); Monitor stays earcon-only (§5.2).
  ///
  /// The early `return` right after firing `enteredGoodZone` is what
  /// guarantees `tickGoodZoneGaze` — and therefore any `lookAtCamera`
  /// announcement — can never run on the SAME frame the entry earcon fires:
  /// `tickGoodZoneGaze` only ever runs once `dwellFiredForCurrentEpisode`
  /// is already `true`, i.e. strictly on a later frame, and even then it
  /// needs its own N-frame+800ms dwell on top of that. See
  /// `FeedbackCondition.gazeOff`'s doc comment for why gaze moved here from
  /// the exclusive classification ladder.
  private func tickGoodZone(
    output: EngineOutput, from start: ContinuousClock.Instant, at time: ContinuousClock.Instant
  )
    async
  {
    // swiftlint:enable opening_brace
    if !dwellFiredForCurrentEpisode {
      let elapsedMs = Self.milliseconds(from: start, to: time)
      guard elapsedMs >= feedbackConfig.goodZoneChimeDelayMs else { return }
      dwellFiredForCurrentEpisode = true
      goodZoneConfirmedAt = time
      nextHeartbeatAt = time.advanced(by: .milliseconds(feedbackConfig.heartbeatIntervalMs))
      let phrase: Lexicon.Phrase? = mode == .setup ? Lexicon.Instruction.centered : nil
      await fire(event: .enteredGoodZone, phrase: phrase, key: .goodZoneEntered, at: time)
      return
    }

    await tickGoodZoneGaze(output: output, at: time)

    guard let nextHeartbeatAt, time >= nextHeartbeatAt else { return }
    self.nextHeartbeatAt = nextHeartbeatAt.advanced(
      by: .milliseconds(feedbackConfig.heartbeatIntervalMs))
    // §6.1: "The heartbeat is not optional" — exempt from rate limiting for
    // the same reason face-lost is: it is the mechanism that makes "good"
    // distinguishable from "the app crashed," not a discretionary
    // announcement §5.2's budget is meant to ration.
    await fire(event: .livenessHeartbeat, phrase: nil, key: nil, at: time, bypassRateLimit: true)
  }

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
  /// `tickGenericDwell` below — Monitor mode's phrase resolves to `nil` and
  /// this call is a no-op there (§5.2: earcons only by default).
  ///
  /// A single frame reporting gaze back on camera resets BOTH stages
  /// immediately, no N-frame grace period on the way back: this is an
  /// advisory nested inside an already-good state, not a competing
  /// top-level condition, so there is no risk of a recovered glance being
  /// mistaken for a still-open problem the way a blip could confuse the
  /// exclusive ladder above.
  private func tickGoodZoneGaze(output: EngineOutput, at time: ContinuousClock.Instant) async {
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

  /// §7.1 generic dwell: any `FeedbackCondition` other than `.faceLost`
  /// fires (at most) once per confirmed episode, 800ms
  /// (`Config.dwellMs`) after `confirmedStateStart`, subject to §5.2's
  /// per-mode rate limit. `announcementPayload(for:output:)` decides what
  /// (if anything) that firing actually says.
  private func tickGenericDwell(
    condition: FeedbackCondition,
    output: EngineOutput,
    from start: ContinuousClock.Instant,
    at time: ContinuousClock.Instant
  ) async {
    guard !dwellFiredForCurrentEpisode else { return }
    let elapsedMs = Self.milliseconds(from: start, to: time)
    guard elapsedMs >= config.dwellMs else { return }
    dwellFiredForCurrentEpisode = true

    let (event, instruction) = Self.announcementPayload(for: condition, output: output)
    let phrase: Lexicon.Phrase? = mode == .setup ? instruction : nil
    await fire(event: event, phrase: phrase, key: .condition(condition), at: time)
  }

  /// The (`AudioEvent`, `Lexicon.Instruction`) pair for a dwell-fired
  /// condition. `.framingError` has no `AudioEvent` — its feedback in
  /// Monitor mode is entirely the continuous tone
  /// (`updateContinuousSonification`, not gated by dwell at all), so in
  /// Monitor mode a dwell-fired `.framingError` produces no renderer call
  /// whatsoever (`fire` no-ops when both `event` and `phrase` are `nil`;
  /// see below). `.partiallyOutOfFrame`/`.lightingCritical` are
  /// unreachable this phase (their gates always return `false`) but are
  /// still listed for switch exhaustiveness and to mark where Phase 4
  /// fills in a real payload. `.gazeOff` is ALSO unreachable here now
  /// (`FeedbackRouter.discreteState(for:)` excludes it from the ladder
  /// walk that produces a `.problem(condition)` in the first place — see
  /// `FeedbackCondition.gazeOff`'s doc comment); its real payload lives in
  /// `tickGoodZoneGaze(output:at:)` above, the good-zone-internal advisory
  /// that replaced it. Kept here only for switch exhaustiveness.
  private static func announcementPayload(
    for condition: FeedbackCondition,
    output: EngineOutput
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
      return (nil, framingInstruction(for: output))
    case .gazeOff:
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

  // swiftlint:disable opening_brace
  /// §5.2 Monitor-mode rate limit: "max 1 announcement per 20s. Same
  /// condition not repeated within 3 minutes." Setup mode has neither
  /// limit (§5.1: "no rate limiting beyond the dwell time"), modeled here
  /// as `FeedbackConfig.setup`'s `ModeLimits` fields being `nil`. Returns
  /// `false` when either limit blocks this announcement; on success,
  /// records `time` for both the global and per-condition clocks so the
  /// window is measured from the last ANNOUNCED time, not the last
  /// attempted one.
  private func attemptAnnounce(_ condition: FeedbackCondition?, at time: ContinuousClock.Instant)
    -> Bool
  {
    // swiftlint:enable opening_brace
    let limits = mode == .setup ? feedbackConfig.setup : feedbackConfig.monitor

    if let minGlobalMs = limits.minAnnouncementIntervalMs, let lastAnnouncementAt {
      guard Self.milliseconds(from: lastAnnouncementAt, to: time) >= minGlobalMs else {
        return false
      }
    }
    // swift-format requires the brace on its own line after a multiline
    // condition; swiftlint's opening_brace rule disagrees. Format wins.
    // swiftlint:disable opening_brace
    if let condition, let minSameMs = limits.minSameConditionIntervalMs,
      let lastSame = lastAnnouncementAtByCondition[condition]
    {
      // swiftlint:enable opening_brace
      guard Self.milliseconds(from: lastSame, to: time) >= minSameMs else { return false }
    }

    lastAnnouncementAt = time
    if let condition {
      lastAnnouncementAtByCondition[condition] = time
    }
    return true
  }

  /// The single call site every announcement (generic dwell, good-zone
  /// entry, heartbeat, face-lost ladder, face-reacquired) routes through.
  /// Order matters: silence is checked before anything else (§7.5 — silence
  /// must produce zero renderer calls, not just zero AUDIBLE output), then
  /// the no-op short-circuit (nothing to say ⇒ don't consume a rate-limit
  /// slot for it), then rate limiting (unless `bypassRateLimit`, used by
  /// the heartbeat/face-lost-ladder/face-reacquired call sites — see their
  /// call sites above for why each is exempt), then finally the actual
  /// `audio`/`speech`/`EventSubscriber` calls.
  ///
  /// `key: nil` marks firings that never participate in per-condition rate
  /// limiting even when `bypassRateLimit` is `false` (not currently used
  /// that way, but kept distinct from `AnnouncementKey.condition` so a
  /// future non-exempt event-only firing doesn't have to invent a fake
  /// `FeedbackCondition` just to get a dictionary key).
  func fire(
    event: AudioEvent?,
    phrase: Lexicon.Phrase?,
    key: AnnouncementKey?,
    at time: ContinuousClock.Instant,
    bypassRateLimit: Bool = false
  ) async {
    guard !isSilenced else { return }
    guard event != nil || phrase != nil else { return }

    if !bypassRateLimit {
      let condition: FeedbackCondition? = {
        if case .condition(let condition) = key { return condition }
        return nil
      }()
      guard attemptAnnounce(condition, at: time) else { return }
    }

    if let event {
      await audio.play(event)
      for subscriber in eventSubscribers {
        await subscriber.handle(event)
      }
    }
    if let phrase {
      await speech.speak(phrase)
    }
  }
}
