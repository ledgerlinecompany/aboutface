import Testing

@testable import AboutFaceCore

/// §12.5 × §7.3: the face-lost ladder under Center Stage.
///
/// ## The measurement these tests encode
///
/// With Center Stage active and the user moving normally, 24.6% of frames
/// returned no face at all — 31 episodes in 30 seconds, longest 2.5s —
/// against 2.4% / 9 episodes / 169ms for the same movement with Center Stage
/// off (maintainer's machine, Continuity Camera, 2026-08-05). Center Stage
/// re-aims its crop and Vision loses the face while it pans.
///
/// Every one of those episodes cleared rung 1's 500ms Setup threshold, so the
/// user heard face-lost and face-reacquired earcons cycling continuously
/// while sitting in front of a camera that was framing them perfectly. The
/// face was never lost in any sense they could act on.
///
/// ## What must NOT break while fixing it
///
/// Rungs 2 and 3 are reachable only THROUGH rung 1, and §7.3's 30s STOP is
/// safety-critical ("a tool that nags at an empty chair for the rest of a
/// meeting gets uninstalled"). Suppressing the rung itself would strand the
/// STOP — a far worse bug than the nagging. So the rung advances
/// unconditionally and only the EARCON is gated, the same split
/// `faceLostSpeechEnabled` already uses at rung 2.
struct FeedbackRouterCenterStageFaceLostTests {

  /// The headline fix: a Center-Stage-induced dropout is silent in BOTH
  /// directions. Silencing only rung 1 would leave `.faceReacquired` firing
  /// on the way back — half the cycling the maintainer actually heard.
  @Test("under Center Stage, a short face-lost episode is silent in both directions")
  func shortEpisodeIsSilentBothWaysUnderCenterStage() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .setup)
    let t0 = ContinuousClock().now

    await router.setCenterStageActive(true, at: t0)
    await ingestRepeated(router, faceLostOutput(), at: t0.plus(ms: 1), count: 5)
    // Well past rung 1's 500ms Setup threshold — and past the 2.5s longest
    // episode actually measured, so this covers the whole observed range.
    await router.ingest(faceLostOutput(), at: t0.plus(ms: 2600))
    #expect(await audio.playedEvents().isEmpty)

    // Reacquire. Nothing from the LADDER on the way back either — asserted
    // as the absence of those two specific earcons rather than as total
    // silence, because the good-zone arrival chime is independently
    // Config-keyed under Center Stage (`centerStageArrivalChimeEnabled`,
    // default on) and may legitimately sound here. Conflating the two would
    // make this test fail for a reason that has nothing to do with §7.3.
    await ingestRepeated(router, goodZoneOutput(), at: t0.plus(ms: 2700), count: 5)
    let events = await audio.playedEvents()
    #expect(!events.contains(.faceLost))
    #expect(!events.contains(.faceReacquired))
  }

  /// The same episode with Center Stage OFF still behaves exactly as before —
  /// this is the control, and it is what proves the test above is measuring
  /// Center Stage rather than a broken ladder.
  @Test("with Center Stage off, the same episode still fires both earcons")
  func sameEpisodeStillAudibleWithCenterStageOff() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .setup)
    let t0 = ContinuousClock().now

    await ingestRepeated(router, faceLostOutput(), at: t0.plus(ms: 1), count: 5)
    await router.ingest(faceLostOutput(), at: t0.plus(ms: 2600))
    #expect(await audio.playedEvents() == [.faceLost])

    await ingestRepeated(router, goodZoneOutput(), at: t0.plus(ms: 2700), count: 5)
    #expect(await audio.playedEvents().contains(.faceReacquired))
  }

  /// Rung 2 is NOT suppressed. A five-second absence is a real absence — no
  /// measured Center Stage re-aim came close — so the user who actually
  /// walked away is still told.
  @Test("rung 2 still speaks No face. at 5s under Center Stage")
  func rungTwoStillSpeaksUnderCenterStage() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .setup)
    let t0 = ContinuousClock().now

    await router.setCenterStageActive(true, at: t0)
    await ingestRepeated(router, faceLostOutput(), at: t0.plus(ms: 1), count: 5)
    await router.ingest(faceLostOutput(), at: t0.plus(ms: 600))  // rung 1, silent
    await router.ingest(faceLostOutput(), at: t0.plus(ms: 5001))  // rung 2

    #expect(await audio.playedEvents().isEmpty)
    #expect(await speech.calls.contains(.speak(Lexicon.Instruction.noFace)))
  }

  /// The STOP must remain reachable through a silenced rung 1 — the failure
  /// this whole design is arranged to avoid. Rung 3 is what stops the app
  /// nagging an empty chair for the rest of a meeting.
  @Test("rung 3's 30s STOP is still reached through a silenced rung 1")
  func rungThreeStopStillReachedUnderCenterStage() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .setup)
    let t0 = ContinuousClock().now

    await router.setCenterStageActive(true, at: t0)
    await ingestRepeated(router, faceLostOutput(), at: t0.plus(ms: 1), count: 5)
    await router.ingest(faceLostOutput(), at: t0.plus(ms: 600))
    await router.ingest(faceLostOutput(), at: t0.plus(ms: 5001))
    await router.ingest(faceLostOutput(), at: t0.plus(ms: 30_001))

    #expect(await router.isUserLikelyAway() == true)
  }

  /// Recovery from an ACTUAL absence still announces, even though rung 1 was
  /// silent. `wasAway` is what guarantees this: after a 30s STOP the user
  /// must be told feedback resumed, or the app has gone quiet with no
  /// audible route back.
  @Test("recovery after the 30s STOP still fires, despite rung 1 being silenced")
  func recoveryAfterStopStillFiresUnderCenterStage() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .setup)
    let t0 = ContinuousClock().now

    await router.setCenterStageActive(true, at: t0)
    await ingestRepeated(router, faceLostOutput(), at: t0.plus(ms: 1), count: 5)
    await router.ingest(faceLostOutput(), at: t0.plus(ms: 600))
    await router.ingest(faceLostOutput(), at: t0.plus(ms: 5001))
    await router.ingest(faceLostOutput(), at: t0.plus(ms: 30_001))
    #expect(await router.isUserLikelyAway() == true)

    await ingestRepeated(router, goodZoneOutput(), at: t0.plus(ms: 30_101), count: 5)

    #expect(await router.isUserLikelyAway() == false)
    #expect(await audio.playedEvents().contains(.faceReacquired))
  }

  /// Back-to-back short dropouts — the actual measured shape, 31 of them in
  /// 30 seconds — produce nothing at all. A per-episode latch that reset
  /// wrongly would show up here as one earcon per cycle.
  @Test("repeated short dropouts under Center Stage stay silent across every cycle")
  func repeatedDropoutsStaySilentUnderCenterStage() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .setup)
    let t0 = ContinuousClock().now

    await router.setCenterStageActive(true, at: t0)
    for cycle in 0..<5 {
      let base = 1 + cycle * 4000
      await ingestRepeated(router, faceLostOutput(), at: t0.plus(ms: base), count: 5)
      await router.ingest(faceLostOutput(), at: t0.plus(ms: base + 1000))
      await ingestRepeated(router, goodZoneOutput(), at: t0.plus(ms: base + 1100), count: 5)
    }

    // Ladder earcons specifically — the arrival chime is a separate,
    // Config-keyed decision under Center Stage (see the first test above).
    let events = await audio.playedEvents()
    #expect(!events.contains(.faceLost))
    #expect(!events.contains(.faceReacquired))
  }
}
