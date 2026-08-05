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
  ///
  /// `output` is the frame that TRIGGERED this confirmation (the one
  /// `FeedbackRouter.ingest(_:at:)` was processing when `pendingStreak`
  /// crossed the N-frame threshold) — threaded through purely so the rung-3
  /// recovery branch below can resolve "the problem, if there is one"
  /// (§7.3) via the SAME `announcementPayload(for:output:centerStageActive:)`
  /// (`FeedbackRouter+AnnouncementPayload.swift`) machinery
  /// `tickGenericDwell` already uses, rather than a parallel classifier
  /// that could drift out of sync with it.
  func onConfirmedStateChanged(
    from previous: DiscreteState?,
    to next: DiscreteState,
    output: EngineOutput,
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
      // Roll's sibling advisory (§4 extension): same reset, same reason,
      // fully independent bookkeeping — see
      // `FeedbackRouter.headTiltPendingStreak`'s doc comment.
      headTiltPendingStreak = 0
      headTiltConfirmedStart = nil
      headTiltAnnouncedForEpisode = false
    }

    // §7.3 face-lost recovery: a no-op unless `previous` was face-lost (the
    // guard lives at the top of the callee). Delegated to
    // `FeedbackRouter+FaceLost.swift` rather than inlined here — see that
    // function's own doc comment for why the whole §7.3 lifecycle
    // (escalate/STOP/recover) lives together in one file.
    await handleFaceLostReacquisition(from: previous, to: next, output: output, at: time)
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

  // swiftlint:disable opening_brace
  /// §6.1 good-zone handling: the `.enteredGoodZone` confirmation fires at
  /// N-frame-confirmed zone entry plus `goodZoneChimeDelayMs` (default 0 —
  /// see that field's doc comment for the atomic-arrival rationale; the
  /// continuous beacon keeps playing until this fires, so the cut and the
  /// chime land together), then — on every later frame this episode — the
  /// gaze-off advisory (`tickGoodZoneGaze`), its roll sibling
  /// (`tickGoodZoneRoll`, §4 extension), and the 7s-cadence liveness
  /// heartbeat, all independent of each other. Setup mode additionally
  /// speaks `Lexicon.Instruction.centered` on entry (§5.1: Setup speaks
  /// instructions); Monitor stays earcon-only (§5.2).
  ///
  /// The early `return` right after firing `enteredGoodZone` is what
  /// guarantees `tickGoodZoneGaze`/`tickGoodZoneRoll` — and therefore any
  /// `lookAtCamera`/`level` announcement — can never run on the SAME frame
  /// the entry earcon fires: both only ever run once
  /// `dwellFiredForCurrentEpisode` is already `true`, i.e. strictly on a
  /// later frame, and even then each needs its own N-frame+800ms dwell on
  /// top of that. See `FeedbackCondition.gazeOff`/`.headTilt`'s doc
  /// comments for why gaze/roll moved here from the exclusive
  /// classification ladder. Gaze runs first below purely by textual
  /// order — the two are fully independent, so whichever's own
  /// N-frame+dwell timer completes first speaks first; if both land the
  /// same frame, `fire`'s per-call rate-limit check (Monitor mode only)
  /// is what arbitrates, not this ordering.
  private func tickGoodZone(
    output: EngineOutput, from start: ContinuousClock.Instant, at time: ContinuousClock.Instant
  )
    async
  {
    // swiftlint:enable opening_brace
    if !dwellFiredForCurrentEpisode {
      let elapsedMs = Self.milliseconds(from: start, to: time)
      guard elapsedMs >= feedbackConfig.goodZoneChimeDelayMs else { return }
      // §12.5: bookkeeping ALWAYS runs, even under Center Stage — only the
      // arrival earcon/phrase below are conditional. This is the PR brief's
      // point (c), called out explicitly because getting it wrong is easy
      // and silent: `nextHeartbeatAt` is what schedules §6.1's liveness
      // heartbeat ("not optional... what distinguishes 'good' from 'the app
      // crashed'"), and `dwellFiredForCurrentEpisode`/`goodZoneConfirmedAt`
      // are what every later frame in this episode (the heartbeat tick
      // below, the gaze/roll advisories) reads to know arrival already
      // happened. Skipping this block under Center Stage would silently
      // kill the heartbeat for the rest of the episode — see
      // `FeedbackRouterCenterStageTests.heartbeatStillFiresWhileCenterStageActive`.
      dwellFiredForCurrentEpisode = true
      goodZoneConfirmedAt = time
      nextHeartbeatAt = time.advanced(by: .milliseconds(feedbackConfig.heartbeatIntervalMs))
      // Drops only the arrival chime and "Centered." — the beacon that
      // would otherwise cut on this same frame is already suppressed
      // upstream by `updateContinuousSonification`'s own `centerStageActive`
      // branch, so there is no cut/chime pairing to keep atomic here.
      let event: AudioEvent? = centerStageActive ? nil : .enteredGoodZone
      let phrase: Lexicon.Phrase? =
        centerStageActive ? nil : (mode == .setup ? Lexicon.Instruction.centered : nil)
      await fire(event: event, phrase: phrase, key: .goodZoneEntered, at: time)
      return
    }

    await tickGoodZoneGaze(output: output, at: time)
    await tickGoodZoneRoll(output: output, at: time)

    guard let nextHeartbeatAt, time >= nextHeartbeatAt else { return }
    self.nextHeartbeatAt = nextHeartbeatAt.advanced(
      by: .milliseconds(feedbackConfig.heartbeatIntervalMs))
    // §6.1: "The heartbeat is not optional" — exempt from rate limiting for
    // the same reason face-lost is: it is the mechanism that makes "good"
    // distinguishable from "the app crashed," not a discretionary
    // announcement §5.2's budget is meant to ration.
    await fire(event: .livenessHeartbeat, phrase: nil, key: nil, at: time, bypassRateLimit: true)
  }

  /// §7.1 generic dwell: any `FeedbackCondition` other than `.faceLost`
  /// fires (at most) once per confirmed episode, 800ms
  /// (`Config.dwellMs`) after `confirmedStateStart`, subject to §5.2's
  /// per-mode rate limit. `announcementPayload(for:output:centerStageActive:)`
  /// (`FeedbackRouter+AnnouncementPayload.swift`) decides what (if anything)
  /// that firing actually says.
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

    let (event, instruction) = Self.announcementPayload(
      for: condition, output: output, centerStageActive: centerStageActive)
    let phrase: Lexicon.Phrase? = mode == .setup ? instruction : nil
    await fire(event: event, phrase: phrase, key: .condition(condition), at: time)
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
  /// Order matters: silence (§7.5) and §7.3's rung-3 `userLikelyAway` STOP
  /// are both checked before anything else — each must produce zero
  /// renderer calls, not just zero AUDIBLE output — and specifically
  /// BEFORE the rate-limit branch below, not folded into it: the
  /// heartbeat/face-lost-ladder/face-reacquired call sites all pass
  /// `bypassRateLimit: true` for their own legitimate reasons (see their
  /// call sites), so a guard placed only inside that branch would let every
  /// one of them straight through and rung 3 would never actually go
  /// silent. Then the no-op short-circuit (nothing to say ⇒ don't consume a
  /// rate-limit slot for it), then rate limiting itself (unless
  /// `bypassRateLimit`), then finally the actual `audio`/`speech`/
  /// `EventSubscriber` calls.
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
    // §7.3 rung 3 — see `userLikelyAway`'s doc comment in
    // `FeedbackRouter.swift` for the full rationale, and
    // `onConfirmedStateChanged`'s face-lost branch above for why the
    // recovery announcement that ends an away episode is never itself
    // caught here (it clears the flag before calling `fire`).
    guard !userLikelyAway else { return }
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
      // §8 repeat-last bookkeeping — see `lastSpokenPhrase`'s doc comment
      // in `FeedbackRouter.swift`.
      lastSpokenPhrase = phrase
    }
  }
}
