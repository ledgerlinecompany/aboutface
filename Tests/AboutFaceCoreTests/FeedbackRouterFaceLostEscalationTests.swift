import Testing

@testable import AboutFaceCore

/// §7.3's face-lost escalation ladder, rungs 2/3 and recovery — the Phase 4
/// half of the ladder (`FeedbackRouter+FaceLost.swift`). Split out of
/// `FeedbackRouterFaceLostTests.swift` (rungs 0/1, Phase 3) once this half
/// grew past what fit comfortably alongside it, same reasoning the
/// production-code split into `FeedbackRouter+FaceLost.swift` gives.
///
/// All tests here use Monitor mode: rung 2's "No face." and the rung-3 STOP
/// are the scenario §7.3 is actually written for — an unattended background
/// call, not the actively-watched Setup window — and Monitor's earcon-only
/// default is what makes rung 2's speech carve-out (§5.2: "except face-lost
/// which escalates to speech") and rung 3's total-silence guard worth
/// pinning down explicitly rather than being incidentally satisfied by
/// Setup's own more permissive posture.
struct FeedbackRouterFaceLostEscalationTests {

  // swift-format requires the brace on its own line after a wrapped
  // function signature; swiftlint's opening_brace rule disagrees. Format
  // wins (see FeedbackRouter.swift for the same disagreement).
  // swiftlint:disable opening_brace
  /// Escalates `router` (Monitor mode, already N-frame-confirmed face-lost
  /// as of `t0`) through all three ladder rungs. Each rung's own boundary
  /// is independently pinned down elsewhere (rung 1 by
  /// `FeedbackRouterFaceLostTests`, rung 2 by
  /// `monitorRung2SpeaksNoFaceAt5000ms` below), so this helper exists only
  /// to get the later rung-3/recovery tests into a realistic "already deep
  /// into the ladder" starting state without re-asserting the earlier
  /// rungs' own timing in every one of them.
  private func escalateMonitorToRung3(_ router: FeedbackRouter, from t0: ContinuousClock.Instant)
    async
  {
    // swiftlint:enable opening_brace
    await router.ingest(faceLostOutput(), at: t0.plus(ms: 1500))  // rung 1: earcon
    await router.ingest(faceLostOutput(), at: t0.plus(ms: 5000))  // rung 2: "No face."
    await router.ingest(faceLostOutput(), at: t0.plus(ms: 30_000))  // rung 3: STOP
  }

  @Test("Monitor: rung 2 speaks \"No face.\" at exactly 5000ms, not before, and only once")
  func monitorRung2SpeaksNoFaceAt5000ms() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .monitor)
    let clock = ContinuousClock()
    let t0 = clock.now

    await ingestRepeated(router, faceLostOutput(), at: t0, count: 3)
    await router.ingest(faceLostOutput(), at: t0.plus(ms: 1500))
    #expect(await audio.calls == [.play(.faceLost)])

    await router.ingest(faceLostOutput(), at: t0.plus(ms: 4999))
    #expect(await speech.calls.isEmpty)

    await router.ingest(faceLostOutput(), at: t0.plus(ms: 5000))
    #expect(await speech.calls == [.speak(Lexicon.Instruction.noFace)])

    // Continuing to hold face-lost must not refire it — stays strictly
    // before rung 3's 30000ms boundary so this is purely rung 2's own
    // "fires at most once" latch under test.
    await router.ingest(faceLostOutput(), at: t0.plus(ms: 20_000))
    #expect(await speech.calls == [.speak(Lexicon.Instruction.noFace)])
  }

  @Test("Setup: rung 2 also speaks \"No face.\" at 5000ms — §5.2's carve-out is mode-independent")
  func setupRung2SpeaksNoFaceAt5000ms() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .setup)
    let clock = ContinuousClock()
    let t0 = clock.now

    await ingestRepeated(router, faceLostOutput(), at: t0, count: 5)
    await router.ingest(faceLostOutput(), at: t0.plus(ms: 500))
    #expect(await audio.calls == [.play(.faceLost)])

    await router.ingest(faceLostOutput(), at: t0.plus(ms: 4999))
    #expect(await speech.calls.isEmpty)

    await router.ingest(faceLostOutput(), at: t0.plus(ms: 5000))
    #expect(await speech.calls == [.speak(Lexicon.Instruction.noFace)])
  }

  @Test(
    "Monitor: rung 3 STOPs at 30000ms — sets userLikelyAway and produces total silence under continued pressure"
  )
  func rung3StopsAndStaysSilentUnderPressure() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .monitor)
    let clock = ContinuousClock()
    let t0 = clock.now

    await ingestRepeated(router, faceLostOutput(), at: t0, count: 3)
    await router.ingest(faceLostOutput(), at: t0.plus(ms: 1500))
    await router.ingest(faceLostOutput(), at: t0.plus(ms: 5000))

    await router.ingest(faceLostOutput(), at: t0.plus(ms: 29_999))
    #expect(await router.isUserLikelyAway() == false)

    await router.ingest(faceLostOutput(), at: t0.plus(ms: 30_000))
    #expect(await router.isUserLikelyAway() == true)
    // The STOP itself fires NOTHING — no third earcon, no third phrase, not
    // even a distinct "going quiet" cue (§7.3: any sound here would BE the
    // failure mode it exists to prevent).
    #expect(await audio.calls == [.play(.faceLost)])
    #expect(await speech.calls == [.speak(Lexicon.Instruction.noFace)])

    let audioCallCountAtStop = await audio.calls.count
    let speechCallCountAtStop = await speech.calls.count

    // Keep holding face-lost well past the §6.1 heartbeat cadence (7s
    // default) — the ladder itself must stay inert at rung 3.
    await router.ingest(faceLostOutput(), at: t0.plus(ms: 40_000))
    await router.ingest(faceLostOutput(), at: t0.plus(ms: 60_000))

    // Also feed frames that WOULD ordinarily produce continuous-
    // sonification output (`.ok` signal, framing in the dead zone) — but
    // too few consecutive ones (Monitor's `nFrameMonitor` is 3) to actually
    // reconfirm the state away from face-lost. Without the blanket
    // `userLikelyAway` guard in `updateContinuousSonification`, THESE are
    // exactly the frames that would slip a `SonificationTarget` out to
    // `audio.update` even while the router still believes the user is
    // away — see that guard's doc comment in `FeedbackRouter.swift`.
    await ingestRepeated(router, goodZoneOutput(), at: t0.plus(ms: 65_000), count: 2)
    await router.ingest(faceLostOutput(), at: t0.plus(ms: 90_000))

    #expect(await audio.calls.count == audioCallCountAtStop)
    #expect(await speech.calls.count == speechCallCountAtStop)
    #expect(await audio.calls.contains(.play(.livenessHeartbeat)) == false)
  }

  /// Runs in SETUP because Phase 4.5 made the positional beacon a converging
  /// instrument only (design doc §3.3, `FeedbackRouter+Continuous.swift`) —
  /// in monitoring there is no longer any beacon for the STOP to cut. The
  /// safety property this pins down is unchanged and still reachable: an
  /// episode that escalates all the way to rung 3 while a beacon is playing
  /// must actively CUT it, not merely stop sending updates. Converging is
  /// simply where a beacon can now be playing when that happens.
  @Test("Setup: rung 3 STOP cuts a beacon left playing by a stray pre-STOP frame")
  func rung3StopCutsBeaconLeftPlayingByStrayFrame() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .setup)
    let clock = ContinuousClock()
    let t0 = clock.now

    // Setup's N-frame threshold is 5, not Monitor's 3, and its rung-1 delay
    // is 500ms rather than 1500ms — see `FeedbackConfig.nFrameSetup` and
    // `faceLostEarconDelaySetupMs`. Rungs 2 and 3 are mode-independent.
    await ingestRepeated(router, faceLostOutput(), at: t0, count: 5)
    await router.ingest(faceLostOutput(), at: t0.plus(ms: 600))  // rung 1
    await router.ingest(faceLostOutput(), at: t0.plus(ms: 5000))  // rung 2

    // A single stray frame with an `.ok` signal and in-dead-zone framing —
    // Vision briefly "detecting a face" in an empty chair, a poster, a
    // shadow. `nFrameMonitor` is 3, so this ALONE cannot reconfirm
    // `confirmedState` away from `.problem(.faceLost)` (`pendingStreak`
    // only reaches 1) — but the continuous channel is deliberately NOT
    // N-frame gated (§6.2: the ~100ms correction loop has to stay
    // real-time), so it resolves and sends a real `SonificationTarget`
    // regardless, and the beacon is now audibly playing.
    await router.ingest(goodZoneOutput(), at: t0.plus(ms: 29_500))

    // The face-lost frame that crosses the 30000ms STOP boundary: rung 3
    // fires (silently, inside `tickAnnouncements`, which `ingest` runs
    // BEFORE the continuous channel) and sets `userLikelyAway`. The bug
    // this test pins down: a guard that merely stops SENDING further
    // updates leaves the target sent at 29_500ms "playing" forever as far
    // as the audio renderer is concerned — rung 3's silence has to
    // actively CUT whatever was last playing, not just go quiet from here
    // on.
    await router.ingest(faceLostOutput(), at: t0.plus(ms: 30_000))
    #expect(await router.isUserLikelyAway() == true)

    #expect(await audio.calls.last == .update(nil))

    // The cut is a one-time transition, not a repeating "keep sending nil"
    // — no further calls of any kind on later frames.
    let audioCallCountAtStop = await audio.calls.count
    await router.ingest(faceLostOutput(), at: t0.plus(ms: 40_000))
    #expect(await audio.calls.count == audioCallCountAtStop)
  }

  @Test("recovering from rung 3 into the good zone speaks recovery once and resumes monitoring")
  func rung3RecoveryIntoGoodZoneSpeaksRecoveredOnce() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .monitor)
    let clock = ContinuousClock()
    let t0 = clock.now

    await ingestRepeated(router, faceLostOutput(), at: t0, count: 3)
    await escalateMonitorToRung3(router, from: t0)
    #expect(await router.isUserLikelyAway() == true)

    // Reacquire: `nFrameMonitor` (3) consecutive good-zone frames
    // reconfirm. Atomic arrival means this SAME confirming frame both
    // clears `userLikelyAway`/fires the recovery announcement (in
    // `onConfirmedStateChanged`, called first) AND fires `enteredGoodZone`
    // (`goodZoneChimeDelayMs` 0) — see `reacquisitionFiresFaceReacquiredOnce`
    // in `FeedbackRouterFaceLostTests.swift` for the same ordering
    // documented on the (non-away) rung-1 case this generalizes.
    await ingestRepeated(router, goodZoneOutput(), at: t0.plus(ms: 30_100), count: 3)

    // swift-format wants a trailing comma on the last element of a
    // multiline collection literal; swiftlint's (default-on)
    // trailing_comma rule forbids one. Same tool disagreement noted
    // elsewhere in this codebase (see FeedbackRouter+Announcements.swift's
    // `framingInstruction(for:)`) — format wins.
    // swiftlint:disable trailing_comma
    #expect(await router.isUserLikelyAway() == false)
    #expect(await audio.playedEvents() == [.faceLost, .faceReacquired, .enteredGoodZone])
    #expect(
      await speech.calls == [
        .speak(Lexicon.Instruction.noFace),
        .speak(Lexicon.Instruction.recovered),
      ])

    // Holding the recovered state must not refire anything.
    await router.ingest(goodZoneOutput(), at: t0.plus(ms: 30_200))
    #expect(await audio.playedEvents() == [.faceLost, .faceReacquired, .enteredGoodZone])
    #expect(
      await speech.calls == [
        .speak(Lexicon.Instruction.noFace),
        .speak(Lexicon.Instruction.recovered),
      ])
    // swiftlint:enable trailing_comma

    // "resume normal monitoring": the good-zone episode this recovery
    // landed in is a REAL one, not a special recovered-but-inert state —
    // holding it long enough still earns the ordinary §6.1 liveness
    // heartbeat, scheduled from the entry frame (`t0.plus(ms: 30_100)`)
    // exactly like any other good-zone episode.
    await router.ingest(goodZoneOutput(), at: t0.plus(ms: 37_100))
    #expect(await audio.playedEvents().last == .livenessHeartbeat)
  }

  @Test("faceLostSpeechEnabled false silences rung 2 but the ladder still reaches STOP")
  func rung2SpeechDisabledStillAdvancesToStop() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    var feedbackConfig = FeedbackConfig.defaults
    feedbackConfig.faceLostSpeechEnabled = false
    let router = FeedbackRouter(
      audio: audio, speech: speech, feedbackConfig: feedbackConfig, mode: .monitor)
    let clock = ContinuousClock()
    let t0 = clock.now

    await ingestRepeated(router, faceLostOutput(), at: t0, count: 3)

    // Rung 1's earcon is untouched by this toggle — it gates rung 2's
    // PHRASE only.
    await router.ingest(faceLostOutput(), at: t0.plus(ms: 1500))
    #expect(await audio.calls == [.play(.faceLost)])

    // Rung 2's boundary crosses with nothing spoken.
    await router.ingest(faceLostOutput(), at: t0.plus(ms: 5000))
    #expect(await speech.calls.isEmpty)

    // The regression this toggle could most easily introduce: silencing
    // rung 2's phrase must NOT stall the ladder or make rung 3
    // unreachable. It still STOPs and sets `userLikelyAway` at exactly the
    // same 30000ms boundary as when speech is on.
    await router.ingest(faceLostOutput(), at: t0.plus(ms: 29_999))
    #expect(await router.isUserLikelyAway() == false)
    await router.ingest(faceLostOutput(), at: t0.plus(ms: 30_000))
    #expect(await router.isUserLikelyAway() == true)
    #expect(await speech.calls.isEmpty)
  }

  @Test("faceLostRecoverySpeechEnabled false silences recovery speech, not the earcon or the clear")
  func recoverySpeechDisabledStillClearsAway() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    var feedbackConfig = FeedbackConfig.defaults
    feedbackConfig.faceLostRecoverySpeechEnabled = false
    let router = FeedbackRouter(
      audio: audio, speech: speech, feedbackConfig: feedbackConfig, mode: .monitor)
    let clock = ContinuousClock()
    let t0 = clock.now

    await ingestRepeated(router, faceLostOutput(), at: t0, count: 3)
    // Rung 2's own speech is still enabled (default) — only recovery
    // speech is disabled here, so the "No face." below is expected, and
    // its presence with no phrase added after reacquisition is exactly
    // what distinguishes "recovery phrase suppressed" from "nothing ever
    // spoke."
    await escalateMonitorToRung3(router, from: t0)
    #expect(await router.isUserLikelyAway() == true)

    await ingestRepeated(router, goodZoneOutput(), at: t0.plus(ms: 30_100), count: 3)

    #expect(await router.isUserLikelyAway() == false)
    #expect(await audio.playedEvents() == [.faceLost, .faceReacquired, .enteredGoodZone])
    #expect(await speech.calls == [.speak(Lexicon.Instruction.noFace)])
  }

  @Test("recovering from rung 3 into a framing error speaks the problem, not recovery")
  func rung3RecoveryIntoProblemSpeaksProblemInstruction() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .monitor)
    let clock = ContinuousClock()
    let t0 = clock.now

    await ingestRepeated(router, faceLostOutput(), at: t0, count: 3)
    await escalateMonitorToRung3(router, from: t0)
    #expect(await router.isUserLikelyAway() == true)

    // Reacquire into a framing error (out of the dead zone) rather than
    // the good zone. `framingErrorOutput()`'s default `errorX` (0.5) is
    // positive, so per `FramingState.error`'s own sign convention the
    // subject is right of target and the correcting instruction is
    // "Left." — the SAME phrase a live (non-recovery) framing-error
    // episode would speak, via the SAME `announcementPayload(for:output:)`
    // (see `faceLostRecoveryPhrase(for:output:)`'s doc comment for why
    // this reuses rather than re-derives it).
    await ingestRepeated(router, framingErrorOutput(), at: t0.plus(ms: 30_100), count: 3)

    // swift-format wants a trailing comma on the last element of a
    // multiline collection literal; swiftlint's (default-on)
    // trailing_comma rule forbids one. Format wins (see the recovery test
    // above for the same disagreement).
    // swiftlint:disable trailing_comma
    #expect(await router.isUserLikelyAway() == false)
    #expect(await audio.playedEvents() == [.faceLost, .faceReacquired])
    #expect(
      await speech.calls == [
        .speak(Lexicon.Instruction.noFace),
        .speak(Lexicon.Instruction.left),
      ])
    // swiftlint:enable trailing_comma
  }
}
