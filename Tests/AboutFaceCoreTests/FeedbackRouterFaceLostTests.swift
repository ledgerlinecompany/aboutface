import Testing

@testable import AboutFaceCore

/// §7.3's face-lost escalation ladder, Phase 3 scope (rungs 0–1 only):
/// "0 – [delay]: Nothing... [delay]: Distinct earcon. Non-positional." Plus
/// recovery: "On face reacquisition... announce recovery once." The rung-1
/// delay is now MODE-SELECTED (app field finding, 2026-08-02: "it takes
/// ~1.5s for the no-face warning to sound after the tone stops") — Setup's
/// active convergence loop uses 500ms (`FeedbackConfig
/// .faceLostEarconDelaySetupMs`), Monitor keeps the original 1500ms
/// (`faceLostEarconDelayMonitorMs`) per §7.3's own "covers turning to a
/// second monitor, reaching for coffee" rationale. See
/// `FeedbackRouter.faceLostEarconDelayMs`'s doc comment for the full story.
struct FeedbackRouterFaceLostTests {

  @Test("Setup: nothing happens before 500ms of face loss")
  func setupNothingBefore500ms() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .setup)
    let clock = ContinuousClock()
    let t0 = clock.now

    await ingestRepeated(router, faceLostOutput(), at: t0, count: 5)
    await router.ingest(faceLostOutput(), at: t0.plus(ms: 499))

    #expect(await audio.calls.isEmpty)
    #expect(await speech.calls.isEmpty)
  }

  @Test("Setup: 500ms of face loss fires a single non-positional earcon")
  func setupEarconAt500ms() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .setup)
    let clock = ContinuousClock()
    let t0 = clock.now

    await ingestRepeated(router, faceLostOutput(), at: t0, count: 5)
    await router.ingest(faceLostOutput(), at: t0.plus(ms: 499))
    await router.ingest(faceLostOutput(), at: t0.plus(ms: 500))

    #expect(await audio.calls == [.play(.faceLost)])
    // Phase 3 ships no spoken rung yet (§7.3 rung 2, ~5s, is Phase 4).
    #expect(await speech.calls.isEmpty)

    // Continuing to hold face-lost must not refire the earcon.
    await router.ingest(faceLostOutput(), at: t0.plus(ms: 10_000))
    #expect(await audio.calls == [.play(.faceLost)])
  }

  @Test("Monitor: nothing happens before 1500ms of face loss")
  func monitorNothingBefore1500ms() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .monitor)
    let clock = ContinuousClock()
    let t0 = clock.now

    // Monitor's N-frame threshold is 3 (`nFrameMonitor`).
    await ingestRepeated(router, faceLostOutput(), at: t0, count: 3)
    await router.ingest(faceLostOutput(), at: t0.plus(ms: 1499))

    #expect(await audio.calls.isEmpty)
    #expect(await speech.calls.isEmpty)
  }

  @Test("Monitor: 1500ms of face loss fires a single non-positional earcon")
  func monitorEarconAt1500ms() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .monitor)
    let clock = ContinuousClock()
    let t0 = clock.now

    await ingestRepeated(router, faceLostOutput(), at: t0, count: 3)
    await router.ingest(faceLostOutput(), at: t0.plus(ms: 1499))
    await router.ingest(faceLostOutput(), at: t0.plus(ms: 1500))

    #expect(await audio.calls == [.play(.faceLost)])

    // Continuing to hold face-lost must not refire the earcon. Bypasses
    // Monitor's rate limit deliberately (§7.3's ladder is exempt — see
    // `tickFaceLostLadder`'s doc comment), so this is purely the "fires at
    // most once per episode" latch under test, not the rate limiter.
    await router.ingest(faceLostOutput(), at: t0.plus(ms: 10_000))
    #expect(await audio.calls == [.play(.faceLost)])
  }

  @Test("reacquiring the face after the earcon fires faceReacquired once")
  func reacquisitionFiresFaceReacquiredOnce() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .setup)
    let clock = ContinuousClock()
    let t0 = clock.now

    await ingestRepeated(router, faceLostOutput(), at: t0, count: 5)
    await router.ingest(faceLostOutput(), at: t0.plus(ms: 500))
    #expect(await audio.calls == [.play(.faceLost)])

    // Reacquire: 5 consecutive good-zone frames confirm the recovery.
    await ingestRepeated(router, goodZoneOutput(), at: t0.plus(ms: 600), count: 5)

    #expect(await audio.calls == [.play(.faceLost), .play(.faceReacquired)])

    // Holding the recovered state must not refire `faceReacquired` (checked
    // before the now-good-zone state's own 800ms entry dwell would add an
    // unrelated `enteredGoodZone`, to keep this assertion isolated to
    // recovery-firing behavior).
    await router.ingest(goodZoneOutput(), at: t0.plus(ms: 700))
    #expect(await audio.calls == [.play(.faceLost), .play(.faceReacquired)])
  }

  @Test("a face-lost episode that never reaches the earcon does not announce a recovery")
  func briefLossBeforeEarconIsSilentBothWays() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .setup)
    let clock = ContinuousClock()
    let t0 = clock.now

    // Confirmed face-lost, but reacquired well before Setup's 500ms earcon
    // rung.
    await ingestRepeated(router, faceLostOutput(), at: t0, count: 5)
    await ingestRepeated(router, goodZoneOutput(), at: t0.plus(ms: 200), count: 5)

    #expect(await audio.calls.isEmpty)
  }
}
