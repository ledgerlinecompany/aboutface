import Testing

@testable import AboutFaceCore

/// §7.3's face-lost escalation ladder, Phase 3 scope (rungs 0–1 only): "0 –
/// 1.5s: Nothing... 1.5s: Distinct earcon. Non-positional." Plus recovery:
/// "On face reacquisition... announce recovery once."
struct FeedbackRouterFaceLostTests {

  @Test("nothing happens before 1.5s of face loss")
  func nothingBefore1500ms() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .setup)
    let clock = ContinuousClock()
    let t0 = clock.now

    await ingestRepeated(router, faceLostOutput(), at: t0, count: 5)
    await router.ingest(faceLostOutput(), at: t0.plus(ms: 1499))

    #expect(await audio.calls.isEmpty)
    #expect(await speech.calls.isEmpty)
  }

  @Test("1.5s of face loss fires a single non-positional earcon")
  func earconAt1500ms() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .setup)
    let clock = ContinuousClock()
    let t0 = clock.now

    await ingestRepeated(router, faceLostOutput(), at: t0, count: 5)
    await router.ingest(faceLostOutput(), at: t0.plus(ms: 1499))
    await router.ingest(faceLostOutput(), at: t0.plus(ms: 1500))

    #expect(await audio.calls == [.play(.faceLost)])
    // Phase 3 ships no spoken rung yet (§7.3 rung 2, ~5s, is Phase 4).
    #expect(await speech.calls.isEmpty)

    // Continuing to hold face-lost must not refire the earcon.
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
    await router.ingest(faceLostOutput(), at: t0.plus(ms: 1500))
    #expect(await audio.calls == [.play(.faceLost)])

    // Reacquire: 5 consecutive good-zone frames confirm the recovery.
    await ingestRepeated(router, goodZoneOutput(), at: t0.plus(ms: 1600), count: 5)

    #expect(await audio.calls == [.play(.faceLost), .play(.faceReacquired)])

    // Holding the recovered state must not refire `faceReacquired` (checked
    // before the now-good-zone state's own 800ms entry dwell would add an
    // unrelated `enteredGoodZone`, to keep this assertion isolated to
    // recovery-firing behavior).
    await router.ingest(goodZoneOutput(), at: t0.plus(ms: 2000))
    #expect(await audio.calls == [.play(.faceLost), .play(.faceReacquired)])
  }

  @Test("a face-lost episode that never reaches the earcon does not announce a recovery")
  func briefLossBeforeEarconIsSilentBothWays() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .setup)
    let clock = ContinuousClock()
    let t0 = clock.now

    // Confirmed face-lost, but reacquired well before the 1.5s earcon rung.
    await ingestRepeated(router, faceLostOutput(), at: t0, count: 5)
    await ingestRepeated(router, goodZoneOutput(), at: t0.plus(ms: 500), count: 5)

    #expect(await audio.calls.isEmpty)
  }
}
