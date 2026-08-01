import Testing

@testable import AboutFaceCore

/// §7.1: "A condition MUST hold for 800ms before it generates any
/// announcement. Applies to every condition without exception." Uses
/// `.noSignal` as the condition under test since it fires a single,
/// unambiguous `AudioEvent` + `Lexicon.Phrase` pair in Setup mode with no
/// other machinery (heartbeats, ladders) to interfere.
struct FeedbackRouterDwellTests {

  @Test("799ms of a held condition produces no announcement")
  func noAnnouncementBefore800ms() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .setup)
    let clock = ContinuousClock()
    let t0 = clock.now

    // N-frame confirmation (5 frames at 30Hz/Setup default) happens at t0;
    // the dwell clock then starts counting from t0.
    await ingestRepeated(router, noSignalOutput(), at: t0, count: 5)
    await router.ingest(noSignalOutput(), at: t0.plus(ms: 799))

    #expect(await audio.calls.isEmpty)
    #expect(await speech.calls.isEmpty)
  }

  @Test("800ms of a held condition announces exactly once")
  func announcesExactlyOnceAt800ms() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .setup)
    let clock = ContinuousClock()
    let t0 = clock.now

    await ingestRepeated(router, noSignalOutput(), at: t0, count: 5)
    await router.ingest(noSignalOutput(), at: t0.plus(ms: 799))
    await router.ingest(noSignalOutput(), at: t0.plus(ms: 800))

    #expect(await audio.calls == [.play(.noSignal)])
    #expect(await speech.calls == [.speak(Lexicon.Instruction.noSignal)])

    // Continuing to hold the same condition must not refire it (§7.1's
    // dwell fires the episode once, not once per frame it continues to
    // hold).
    await router.ingest(noSignalOutput(), at: t0.plus(ms: 1600))
    await router.ingest(noSignalOutput(), at: t0.plus(ms: 5000))

    #expect(await audio.calls == [.play(.noSignal)])
    #expect(await speech.calls == [.speak(Lexicon.Instruction.noSignal)])
  }
}
