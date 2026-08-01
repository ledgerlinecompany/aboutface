import Testing

@testable import AboutFaceCore

/// §7.5: "Silences all feedback immediately while leaving analysis running.
/// This is the 'someone just started talking to me' key. It MUST be
/// reachable without thinking and MUST take effect within one audio buffer
/// — cut the render, do not wait for the current utterance to finish."
struct FeedbackRouterSilenceTests {

  @Test(
    "setSilenced(true) immediately silences both renderers, and subsequent events produce zero calls until unsilenced"
  )
  func silenceCutsRenderImmediatelyAndBlocksSubsequentCalls() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .setup)
    let clock = ContinuousClock()
    let t0 = clock.now

    await router.setSilenced(true)
    #expect(await audio.calls == [.setSilenced(true)])
    #expect(await speech.calls == [.stopSpeaking])

    // Analysis keeps running (§7.5: "leaving analysis running") — feed a
    // full dwell-eligible condition — but with everything silenced, it
    // must produce ZERO additional renderer calls: neither the continuous
    // positional loop nor a dwell-fired announcement.
    let errorOutput = framingErrorOutput(errorX: 0.5)
    await ingestRepeated(router, errorOutput, at: t0, count: 5)
    await router.ingest(errorOutput, at: t0.plus(ms: 800))

    #expect(await audio.calls == [.setSilenced(true)])
    #expect(await speech.calls == [.stopSpeaking])

    await router.setSilenced(false)
    #expect(await audio.calls == [.setSilenced(true), .setSilenced(false)])

    // A fresh condition/episode after unsilencing produces real calls
    // again — confirms silence is a transient gate, not a permanently
    // stuck latch.
    await ingestRepeated(router, goodZoneOutput(), at: t0.plus(ms: 1000), count: 5)
    await router.ingest(goodZoneOutput(), at: t0.plus(ms: 1800))

    #expect(await audio.calls.contains(.play(.enteredGoodZone)))
    #expect(await speech.calls.contains(.speak(Lexicon.Instruction.centered)))
  }

  @Test("setSilenced does not stop continuous analysis ingestion from advancing internal state")
  func silenceDoesNotStopAnalysisIngestion() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .setup)
    let clock = ContinuousClock()
    let t0 = clock.now

    await router.setSilenced(true)

    // Confirm + dwell a face-lost episode entirely while silenced...
    await ingestRepeated(router, faceLostOutput(), at: t0, count: 5)
    await router.ingest(faceLostOutput(), at: t0.plus(ms: 1500))
    #expect(await audio.calls == [.setSilenced(true)])

    // ...then unsilence and reacquire. If ingestion had truly been
    // stopped rather than just muted, the face-lost condition would never
    // have been confirmed, the earcon rung would never have "fired" (even
    // silently), and this recovery would have nothing to report.
    // `FeedbackRouter` still tracked it internally, so recovery fires the
    // instant rendering is unmuted.
    await router.setSilenced(false)
    await ingestRepeated(router, goodZoneOutput(), at: t0.plus(ms: 1600), count: 5)

    #expect(await audio.calls.contains(.play(.faceReacquired)))
  }
}
