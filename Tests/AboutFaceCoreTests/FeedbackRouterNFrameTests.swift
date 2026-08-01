import Testing

@testable import AboutFaceCore

/// §7.2: "General N-frame requirement (default 5 at 30Hz, 3 at 5Hz) so a
/// hand raised to the face or a sip of coffee triggers nothing." Setup mode
/// uses the 30Hz/5-frame default (`FeedbackConfig.nFrameSetup`).
struct FeedbackRouterNFrameTests {

  @Test("4 consecutive frames of a new condition produce nothing")
  func fourFramesProduceNothing() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .setup)
    let clock = ContinuousClock()
    let t0 = clock.now

    await ingestRepeated(router, noSignalOutput(), at: t0, count: 4)

    // Below the N-frame threshold: `confirmedState` never changes, so even
    // a generous dwell-sized time jump on the (still-unconfirmed) 5th call
    // must not announce anything.
    await router.ingest(noSignalOutput(), at: t0.plus(ms: 2000))

    #expect(await audio.calls.isEmpty)
    #expect(await speech.calls.isEmpty)
  }

  @Test("5th consecutive frame confirms the candidate and starts its dwell clock")
  func fifthFrameStartsDwell() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .setup)
    let clock = ContinuousClock()
    let t0 = clock.now

    await ingestRepeated(router, noSignalOutput(), at: t0, count: 4)
    // The 5th frame confirms the candidate. Dwell has not elapsed yet
    // (elapsed == 0 relative to this frame's own timestamp), so still no
    // announcement.
    await router.ingest(noSignalOutput(), at: t0.plus(ms: 100))
    #expect(await audio.calls.isEmpty)
    #expect(await speech.calls.isEmpty)

    // The dwell clock started at the CONFIRMATION frame's time (t0+100ms),
    // not at t0 — confirm it fires 800ms after confirmation, proving the
    // N-frame gate and the dwell clock are properly chained.
    await router.ingest(noSignalOutput(), at: t0.plus(ms: 100 + 799))
    #expect(await audio.calls.isEmpty)

    await router.ingest(noSignalOutput(), at: t0.plus(ms: 100 + 800))
    #expect(await audio.calls == [.play(.noSignal)])
  }

  @Test("a single-frame blip does not reset an in-progress dwell")
  func blipDoesNotResetDwell() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .setup)
    let clock = ContinuousClock()
    let t0 = clock.now

    await ingestRepeated(router, noSignalOutput(), at: t0, count: 5)
    // A single differing frame (e.g. a momentary detector hiccup) at
    // t0+400ms: not enough to reach the N-frame threshold for the new
    // condition, so `confirmedState` (and its dwell clock) must be
    // unaffected.
    await router.ingest(faceLostOutput(), at: t0.plus(ms: 400))
    // Back to the original condition — dwell should still fire at
    // t0+800ms, not be pushed out by the blip.
    await router.ingest(noSignalOutput(), at: t0.plus(ms: 800))

    #expect(await audio.calls == [.play(.noSignal)])
  }
}
