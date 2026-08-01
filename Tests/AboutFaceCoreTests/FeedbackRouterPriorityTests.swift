import Testing

@testable import AboutFaceCore

/// §7.4: "When several conditions are true, announce only the top one." 1.
/// No signal outranks 5. Framing error outside dead zone.
struct FeedbackRouterPriorityTests {

  @Test("noSignal and a framing error present together surface only noSignal")
  func noSignalOutranksFramingError() async {
    let audio = MockAudioRenderer()
    let speech = MockSpeechRenderer()
    let router = FeedbackRouter(audio: audio, speech: speech, mode: .setup)
    let clock = ContinuousClock()
    let t0 = clock.now

    // A frame that is simultaneously `.noSignal` (near-uniform frame) AND
    // carries an out-of-dead-zone `framing` — see `makeOutput`'s doc
    // comment for why `EngineOutput`'s own contract allows this combination
    // (`AnalysisEngine` can classify `.noSignal` even when a face, and
    // therefore framing, was found).
    let ambiguousOutput = makeOutput(
      signalState: .noSignal,
      hasFace: true,
      errorX: 0.9,
      inDeadZone: false,
      gazeOnCamera: true
    )

    await ingestRepeated(router, ambiguousOutput, at: t0, count: 5)
    await router.ingest(ambiguousOutput, at: t0.plus(ms: 800))

    // Only the top-ranked condition's payload appears — never a framing
    // instruction ("Right."), and never both.
    #expect(await audio.calls == [.play(.noSignal)])
    #expect(await speech.calls == [.speak(Lexicon.Instruction.noSignal)])
  }
}
